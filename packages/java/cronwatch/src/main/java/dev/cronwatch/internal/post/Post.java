package dev.cronwatch.internal.post;

import dev.cronwatch.CronwatchException;
import dev.cronwatch.alerts.Request;
import dev.cronwatch.alerts.Response;
import dev.cronwatch.alerts.Transport;
import dev.cronwatch.internal.js.Js;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.URISyntaxException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import org.jspecify.annotations.Nullable;

/**
 * The one POST the alert channels and Claude triage make, as the SDK makes it with fetch ({@code
 * alerts/shared.ts}), the Go port's {@code internal/post}, the Rust port's {@code alerts::post} and
 * the Elixir port's {@code Alerts.Post}: the URL read as fetch reads it, only http and https,
 * headers checked as fetch checks them, one ten second deadline for the whole request, a redirect
 * refused rather than followed (the transport's rule), at most 1 MiB of an answer read, and an
 * error that names only the URL's origin, with every secret the caller holds cut out of a quoted
 * answer before it is cut to 200 characters.
 *
 * <p>The request goes out through a {@link Transport} on a virtual thread of its own, interrupted
 * past the deadline, so the deadline holds whatever the transport does, while connecting, sending
 * or reading the answer.
 */
public final class Post {
  private Post() {}

  /** How long one request may take, as the SDK's {@code AbortSignal.timeout(10_000)}. */
  public static final long TIMEOUT_MS = 10_000;

  /** How much of an answer is read. */
  public static final int MAX_BODY = 1 << 20;

  /** How much of an answer's body goes into an error, in UTF-16 code units. */
  public static final int ERROR_BODY_MAX = 200;

  /** Fetch's message for a request past its deadline. */
  public static final String TIMED_OUT = "The operation was aborted due to timeout";

  private static volatile long timeoutMs = TIMEOUT_MS;

  /** The deadline channels post within: {@link #TIMEOUT_MS} unless a test shortened it. */
  public static long timeoutMs() {
    return timeoutMs;
  }

  /** Shortens (or restores) the channels' deadline, for the tests. */
  public static void timeoutForTests(long ms) {
    timeoutMs = ms;
  }

  /**
   * An answer: its status, and as much of its body as was read, as {@code response.text()} reads
   * it.
   *
   * @param status the status
   * @param body the body, {@code ""} for one cut short or unreadable
   */
  public record Answer(int status, String body) {
    /** {@code response.ok}: a 2xx status. */
    public boolean ok() {
      return status >= 200 && status < 300;
    }
  }

  /** An error of this module's, with its message. */
  public static CronwatchException fail(String message) {
    return new CronwatchException(CronwatchException.Kind.OTHER, message);
  }

  /**
   * The URL, once it is one a channel can post to: http or https with a host, no user name or
   * password, and one {@code java.net.URI} reads with the same host. Refused without quoting it,
   * since a webhook URL's path is its credential: "not ftp:" for another scheme, "not this URL" for
   * anything else.
   */
  public static WhatwgUrl postable(String raw) {
    CronwatchException refused = fail("only http and https URLs can be posted to, not this URL");
    switch (WhatwgUrl.parse(raw)) {
      case WhatwgUrl.Special s -> {
        WhatwgUrl u = s.url();
        if (!u.scheme().equals("http") && !u.scheme().equals("https")) {
          throw fail("only http and https URLs can be posted to, not " + u.scheme() + ":");
        }
        if (u.hasCredentials()) {
          throw refused;
        }
        URI uri = uri(u);
        if (uri == null) {
          throw refused;
        }
        return u;
      }
      case WhatwgUrl.Other o ->
          throw fail("only http and https URLs can be posted to, not " + o.scheme() + ":");
      case WhatwgUrl.Invalid i -> throw refused;
    }
  }

  /**
   * The URL as a {@code java.net.URI}, without its fragment, which is never sent: the text itself
   * when the URI reads it, else with each character the URI cannot hold percent-encoded; null when
   * the host the URI reads is not the host WHATWG read (a host name with an underscore, say, which
   * the URI takes for a registry name), so what the URL names and what is reached cannot differ.
   */
  public static @Nullable URI uri(WhatwgUrl u) {
    URI uri;
    try {
      uri = new URI(u.origin() + uriSafe(u.target()));
    } catch (URISyntaxException e) {
      return null;
    }
    String host = uri.getHost();
    if (host == null || !host.toLowerCase(Locale.ROOT).equals(u.host())) {
      return null;
    }
    return uri.getPort() == u.port() ? uri : null;
  }

  /**
   * A request target with each character {@code java.net.URI} cannot hold percent-encoded: WHATWG
   * leaves {@code [ ] ^ | { } `} and a {@code %} not followed by two hex digits as they are, which
   * the URI refuses. Only ASCII remains once WHATWG has encoded the rest.
   */
  static String uriSafe(String target) {
    StringBuilder b = new StringBuilder(target.length());
    for (int i = 0; i < target.length(); i++) {
      char c = target.charAt(i);
      boolean legal =
          (c >= 'a' && c <= 'z')
              || (c >= 'A' && c <= 'Z')
              || (c >= '0' && c <= '9')
              || "-_.!~*'();/:@&=+$,".indexOf(c) >= 0
              || c == '?'
              || (c == '%'
                  && i + 2 < target.length()
                  && Character.digit(target.charAt(i + 1), 16) >= 0
                  && Character.digit(target.charAt(i + 2), 16) >= 0);
      if (legal) {
        b.append(c);
      } else {
        b.append('%').append(Character.toUpperCase(Character.forDigit(c >> 4 & 15, 16)));
        b.append(Character.toUpperCase(Character.forDigit(c & 15, 16)));
      }
    }
    return b.toString();
  }

  /**
   * {@code new URL(url).origin}: the scheme, host and port only; {@code "null"} for a URL of a
   * scheme that has no origin and {@code "(invalid URL)"} for text that is no URL. A URL's path or
   * query can hold a credential, so an error names only this.
   */
  public static String origin(String raw) {
    return switch (WhatwgUrl.parse(raw)) {
      case WhatwgUrl.Special s -> s.url().origin();
      case WhatwgUrl.Other o -> "null";
      case WhatwgUrl.Invalid i -> "(invalid URL)";
    };
  }

  /** Whether a header name is an HTTP token (RFC 9110). */
  static boolean token(String name) {
    if (name.isEmpty()) {
      return false;
    }
    for (int i = 0; i < name.length(); i++) {
      char c = name.charAt(i);
      boolean ok =
          (c >= 'a' && c <= 'z')
              || (c >= 'A' && c <= 'Z')
              || (c >= '0' && c <= '9')
              || "!#$%&'*+.^_`|~-".indexOf(c) >= 0;
      if (!ok) {
        return false;
      }
    }
    return true;
  }

  /**
   * The headers as a request sends them: each name a token, each value without the spaces, tabs and
   * line breaks around it, as fetch sends it. A name that is not a token, or a value with a line
   * break or NUL inside, is refused, as fetch refuses them, so no header can add another; the error
   * names the header, never its value, which may be a credential.
   */
  public static List<Map.Entry<String, String>> headers(List<Map.Entry<String, String>> list) {
    List<Map.Entry<String, String>> out = new ArrayList<>(list.size());
    for (Map.Entry<String, String> h : list) {
      String name = h.getKey();
      if (!token(name)) {
        throw fail("a header name must be a token (letters, digits and !#$%&'*+.^_`|~-)");
      }
      String value = trimHttp(h.getValue());
      if (value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0 || value.indexOf('\0') >= 0) {
        throw fail("the " + name + " header's value may not contain a line break");
      }
      out.add(Map.entry(name, value));
    }
    return out;
  }

  private static boolean httpSpace(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
  }

  private static String trimHttp(String s) {
    int a = 0;
    int b = s.length();
    while (a < b && httpSpace(s.charAt(a))) {
      a++;
    }
    while (b > a && httpSpace(s.charAt(b - 1))) {
      b--;
    }
    return s.substring(a, b);
  }

  /** Bytes as {@code response.text()} reads them: UTF-8, U+FFFD for bytes that are not, no BOM. */
  public static String text(byte[] data) {
    String s;
    try {
      s =
          StandardCharsets.UTF_8
              .newDecoder()
              .onMalformedInput(CodingErrorAction.REPLACE)
              .onUnmappableCharacter(CodingErrorAction.REPLACE)
              .decode(ByteBuffer.wrap(data))
              .toString();
    } catch (CharacterCodingException e) {
      throw new IllegalStateException(e);
    }
    return s.startsWith("﻿") ? s.substring(1) : s;
  }

  /**
   * Posts {@code body} to {@code rawUrl} through {@code transport} within {@code withinMs}, and
   * answers whatever the status. A refused URL or header, a request past the deadline ({@link
   * #TIMED_OUT}) or the transport's own error is a {@link CronwatchException} naming no more of the
   * URL than its origin. A body the deadline cut short, or one that could not be read, is {@code
   * ""}.
   *
   * @throws InterruptedException when the caller is interrupted, which abandons the request
   */
  public static Answer fetch(
      Transport transport,
      long withinMs,
      String rawUrl,
      List<Map.Entry<String, String>> headers,
      String body)
      throws InterruptedException {
    WhatwgUrl url = postable(rawUrl);
    List<Map.Entry<String, String>> checked = headers(headers);
    // UTF-8 as fetch sends a string, U+FFFD for a lone surrogate.
    Request request = new Request(url.toString(), checked, Js.utf8(body));
    long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(withinMs);
    CompletableFuture<Integer> head = new CompletableFuture<>();
    CompletableFuture<byte[]> data = new CompletableFuture<>();
    AtomicBoolean abandoned = new AtomicBoolean();
    Thread worker =
        Thread.ofVirtual()
            .name("cronwatch-post")
            .start(() -> exchange(transport, request, head, data, abandoned));
    try {
      int status;
      try {
        status = head.get(left(deadline), TimeUnit.NANOSECONDS);
      } catch (TimeoutException e) {
        throw fail(TIMED_OUT);
      } catch (ExecutionException e) {
        Throwable cause = e.getCause() == null ? e : e.getCause();
        throw withoutUrl(describe(cause), rawUrl, url);
      }
      byte[] bytes;
      try {
        bytes = data.get(left(deadline), TimeUnit.NANOSECONDS);
      } catch (TimeoutException | ExecutionException e) {
        // A body the deadline cut short, or one that could not be read, is none.
        bytes = new byte[0];
      }
      return new Answer(status, text(bytes));
    } finally {
      abandoned.set(true);
      worker.interrupt();
    }
  }

  private static long left(long deadline) {
    return Math.max(0, deadline - System.nanoTime());
  }

  /** The exchange, on the worker: the answer's head, then at most MAX_BODY bytes of its body. */
  private static void exchange(
      Transport transport,
      Request request,
      CompletableFuture<Integer> head,
      CompletableFuture<byte[]> data,
      AtomicBoolean abandoned) {
    Response response;
    try {
      response = transport.post(request);
      if (response == null) {
        throw new IllegalStateException("the transport answered nothing");
      }
    } catch (Throwable e) {
      if (e instanceof InterruptedException) {
        Thread.currentThread().interrupt();
      }
      head.completeExceptionally(e);
      data.completeExceptionally(e);
      return;
    }
    try (Response r = response) {
      head.complete(r.status());
      if (abandoned.get()) {
        data.complete(new byte[0]);
        return;
      }
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      while (out.size() < MAX_BODY) {
        byte[] chunk = r.body().next();
        if (chunk == null) {
          break;
        }
        out.write(chunk, 0, Math.min(chunk.length, MAX_BODY - out.size()));
      }
      data.complete(out.toByteArray());
    } catch (Throwable e) {
      if (e instanceof InterruptedException) {
        Thread.currentThread().interrupt();
      }
      data.completeExceptionally(e);
    }
  }

  /**
   * A transport's error as one line: its simple class name and message, and each cause's that adds
   * something, as the Rust port writes an error's chain.
   */
  static String describe(Throwable error) {
    Throwable e = error;
    while ((e instanceof ExecutionException
            || e instanceof java.util.concurrent.CompletionException)
        && e.getCause() != null) {
      e = e.getCause();
    }
    StringBuilder b = new StringBuilder();
    int depth = 0;
    for (Throwable t = e; t != null && depth < 5; t = t.getCause(), depth++) {
      String one =
          name(t)
              + (t.getMessage() == null || t.getMessage().isEmpty() ? "" : ": " + t.getMessage());
      if (b.indexOf(one) >= 0
          || (depth > 0 && t.getMessage() != null && b.indexOf(t.getMessage()) >= 0)) {
        continue;
      }
      if (b.length() > 0) {
        b.append(": ");
      }
      b.append(one);
    }
    return b.toString();
  }

  private static String name(Throwable t) {
    String simple = t.getClass().getSimpleName();
    return simple.isEmpty() ? t.getClass().getName() : simple;
  }

  /**
   * {@code <origin>: <text>}, with every spelling of the URL in the text written as its origin and
   * its path and query cut out.
   */
  private static CronwatchException withoutUrl(String text, String raw, WhatwgUrl url) {
    String origin = url.origin();
    String out = text;
    for (String s : List.of(Js.trim(raw), url.toString())) {
      if (!s.isEmpty() && !s.equals(origin) && !s.equals(origin + "/")) {
        out = out.replace(s, origin);
      }
    }
    String query = url.query() == null ? "" : url.query();
    String decoded = text(WhatwgUrl.percentDecodeBytes(url.path()));
    for (String s : List.of(url.target(), url.path(), decoded, query)) {
      if (s.length() > 1) {
        out = out.replace(s, "");
      }
    }
    // No cause: its message may quote the URL.
    return fail(origin + ": " + out);
  }

  /** At most {@code max} UTF-16 code units of text, never half a surrogate pair (shared.ts). */
  public static String cut(String text, int max) {
    if (text.length() <= max) {
      return text;
    }
    int end = max;
    if (end > 0 && Character.isHighSurrogate(text.charAt(end - 1))) {
      end--;
    }
    return text.substring(0, end);
  }

  /**
   * The start of an error body: every secret of four or more characters cut out of a prefix long
   * enough to hold one that starts inside the first 200 characters, and only then cut to that
   * length, so no part of a secret survives at the edge.
   */
  public static String errorBody(String text, List<@Nullable String> secrets) {
    List<String> kept = new ArrayList<>();
    int longest = 0;
    for (String s : secrets) {
      if (s != null && s.length() >= 4) {
        kept.add(s);
        longest = Math.max(longest, s.length());
      }
    }
    String head = cut(text, ERROR_BODY_MAX + longest);
    for (String s : kept) {
      head = head.replace(s, "[redacted]");
    }
    return cut(head, ERROR_BODY_MAX);
  }

  /**
   * The error for an answer outside 2xx: {@code <provider> <origin> answered <status>: <body>}, the
   * body's secrets cut out.
   */
  public static CronwatchException refused(
      String provider, String url, Answer answer, List<@Nullable String> secrets) {
    String tail = answer.body().isEmpty() ? "" : ": " + errorBody(answer.body(), secrets);
    return fail(provider + " " + origin(url) + " answered " + answer.status() + tail);
  }

  /** {@link #fetch} within {@link #timeoutMs()} that fails on an answer outside 2xx. */
  public static Answer post(
      Transport transport,
      String provider,
      String url,
      List<Map.Entry<String, String>> headers,
      String body,
      List<@Nullable String> secrets)
      throws InterruptedException {
    Answer answer = fetch(transport, timeoutMs(), url, headers, body);
    if (!answer.ok()) {
      throw refused(provider, url, answer, secrets);
    }
    return answer;
  }
}
