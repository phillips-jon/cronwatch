package dev.cronwatch.web;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.web.Requests;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;

/**
 * A request as a server hands it over: the method, the request target as sent (so a {@code %2F} in
 * a job name stays one), the headers, the body, and whether it came over TLS. What {@link
 * Routes#handle} and {@link Handler#handle} take, so any framework can be an adapter over them.
 * Safe to share between threads; the body is read once.
 *
 * <pre>{@code
 * Request request = Request.builder("POST", "/cronwatch/api/check")
 *     .header("host", "app.example.com")
 *     .header("authorization", "Bearer " + token)
 *     .tls(true)
 *     .build();
 * }</pre>
 *
 * <p>{@link #toString} names the method, the path and the header names, never a header's value or
 * the query, since a request can carry the dashboard's token in either.
 */
public final class Request {
  /**
   * The most of a request body the dashboard reads: its forms and JSON are a few bytes. A body past
   * it is answered 413; the SDK leaves this to the server in front of it.
   */
  public static final int MAX_BODY = 1 << 20;

  /** Reads a request's body, when a route wants it. */
  @FunctionalInterface
  public interface BodyReader {
    /**
     * Reads the body, stopping once more than {@code limit} bytes have arrived (the routes then
     * answer 413, and need no more of it).
     *
     * @throws IOException when the body could not be read to its end: the client went away, a read
     *     deadline passed. The routes read such a body as none, never as the part that arrived.
     */
    byte[] read(int limit) throws IOException;
  }

  /** A body longer than the limit it was read with. */
  public static final class BodyTooLargeException extends IOException {
    private static final long serialVersionUID = 1L;

    /** The exception. */
    public BodyTooLargeException() {
      super("the request body is too large");
    }
  }

  private final String method;
  private final String target;
  private final List<Map.Entry<String, String>> headers;
  private final long length;
  private final @Nullable BodyReader reader;
  private final boolean tls;
  private final @Nullable String mount;
  private final ReentrantLock lock = new ReentrantLock();
  private boolean read;

  private Request(Builder b) {
    this.method = b.method;
    this.target = b.target;
    this.headers = Collections.unmodifiableList(new ArrayList<>(b.headers));
    this.length = b.length;
    this.reader = b.reader;
    this.tls = b.tls;
    this.mount = b.mount;
  }

  /**
   * A builder for a request. {@code target} is the request target as sent: the path and query
   * ({@code /cronwatch/api/jobs?runs=5}), or the absolute form a proxy is sent.
   */
  public static Builder builder(String method, String target) {
    return new Builder(method, target);
  }

  /** A request with no headers and no body. */
  public static Request of(String method, String target) {
    return builder(method, target).build();
  }

  /** The method, as sent. */
  public String method() {
    return method;
  }

  /** The request target as sent. */
  public String target() {
    return target;
  }

  /**
   * A header as fetch's {@code Headers.get} gives it: every value of that name joined with {@code
   * ", "} (a cookie's with {@code "; "}), or null when there is none. Names are matched without
   * regard to case.
   */
  public @Nullable String header(String name) {
    return Requests.header(headers, name);
  }

  /** Every header, in the order given, names lowercase. */
  public List<Map.Entry<String, String>> headers() {
    return headers;
  }

  /** Whether the request came over TLS, which makes its origin https. */
  public boolean isTls() {
    return tls;
  }

  /** Where an adapter found the dashboard mounted, or null. */
  public @Nullable String mount() {
    return mount;
  }

  /** The body's length when the client declared it, else -1. */
  public long declaredLength() {
    return length;
  }

  /**
   * Reads the body, once: a second read answers none. A body declared or found to be longer than
   * {@code limit} bytes is refused without reading the rest.
   *
   * @throws BodyTooLargeException past {@code limit}
   * @throws IOException when the body could not be read to its end
   */
  public byte[] readBody(int limit) throws IOException {
    lock.lock();
    try {
      if (read) {
        return new byte[0];
      }
      read = true;
    } finally {
      lock.unlock();
    }
    if (length > limit) {
      throw new BodyTooLargeException();
    }
    byte[] data = reader == null ? new byte[0] : reader.read(limit);
    if (data.length > limit) {
      throw new BodyTooLargeException();
    }
    return data;
  }

  @Override
  public String toString() {
    int q = target.indexOf('?');
    String path = q < 0 ? target : target.substring(0, q) + "?...";
    List<String> names = new ArrayList<>();
    for (Map.Entry<String, String> h : headers) {
      names.add(h.getKey());
    }
    return "Request[method="
        + method
        + ", target="
        + path
        + ", headers="
        + names
        + ", tls="
        + tls
        + "]";
  }

  /** Builds a {@link Request}. Not safe for use from several threads at once. */
  public static final class Builder {
    private final String method;
    private final String target;
    private final List<Map.Entry<String, String>> headers = new ArrayList<>();
    private long length = 0;
    private @Nullable BodyReader reader;
    private boolean tls;
    private @Nullable String mount;

    private Builder(String method, String target) {
      this.method = Objects.requireNonNull(method, "method");
      this.target = Objects.requireNonNull(target, "target");
    }

    /**
     * Adds a header, its name lowercased. A name sent more than once is read as fetch's {@code
     * Headers.get} reads it. The value is the header as the server read it: each byte one
     * character, as the JDK's server and the servlet containers read it. {@code Host} gives the
     * request's origin.
     */
    public Builder header(String name, String value) {
      headers.add(
          Map.entry(
              Objects.requireNonNull(name, "name").toLowerCase(Locale.ROOT),
              Objects.requireNonNull(value, "value")));
      return this;
    }

    /** The body, already read. */
    public Builder body(byte[] body) {
      byte[] copy = body.clone();
      this.length = copy.length;
      this.reader = limit -> copy;
      return this;
    }

    /** The body as text, written as UTF-8. */
    public Builder body(String body) {
      return body(Js.utf8(body));
    }

    /**
     * A body read only when a route wants it, so a request refused for want of the token is never
     * read. {@code length} is its declared length, or -1 when unknown, so a body past the limit is
     * refused without reading it.
     */
    public Builder body(long length, BodyReader reader) {
      this.length = length;
      this.reader = Objects.requireNonNull(reader, "reader");
      return this;
    }

    /** Whether the request came over TLS. */
    public Builder tls(boolean tls) {
      this.tls = tls;
      return this;
    }

    /**
     * Where the dashboard is mounted, for an adapter that knows (the servlet filter, the Spring
     * starter, {@link WebServer}). {@link RoutesOptions.Builder#basePath} wins over it.
     */
    public Builder mount(String base) {
      this.mount = Objects.requireNonNull(base, "base");
      return this;
    }

    /** The request. */
    public Request build() {
      return new Request(this);
    }

    /** Names what is set, never a header's value. */
    @Override
    public String toString() {
      return "Request.Builder[method=" + method + "]";
    }
  }
}
