package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.AlertType;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.Run;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.jspecify.annotations.Nullable;

/**
 * What the channels share ({@code alerts/shared.ts}): severity, the stable alert id, the run
 * summary trackers attach, the plain text every channel reads, the encodings the requests use, and
 * the POST through the channel's transport or the client's.
 */
final class Shared {
  private Shared() {}

  /** The level for trackers that have levels. Recovered is informational. */
  static String severity(AlertType type) {
    if (type.equals(AlertType.RECOVERED)) {
      return "info";
    }
    if (type.equals(AlertType.SLOW)
        || type.equals(AlertType.OVER_BUDGET)
        || type.equals(AlertType.UNDER_FLOOR)) {
      return "warning";
    }
    return "error";
  }

  static String hex(byte[] bytes) {
    return HexFormat.of().formatHex(bytes);
  }

  static byte[] sha256(byte[] data) {
    try {
      return MessageDigest.getInstance("SHA-256").digest(data);
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException(e);
    }
  }

  /** SHA-256 of the text's UTF-8, as lowercase hex. */
  static String sha256Hex(String text) {
    return hex(sha256(Js.utf8(text)));
  }

  /** HMAC-SHA256 of the text's UTF-8 with the key. */
  static byte[] hmacSha256(byte[] key, String data) {
    try {
      Mac mac = Mac.getInstance("HmacSHA256");
      // An empty key, which the JDK refuses, is padded to the same block as one zero byte.
      mac.init(new SecretKeySpec(key.length == 0 ? new byte[1] : key, "HmacSHA256"));
      return mac.doFinal(Js.utf8(data));
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException(e);
    }
  }

  /**
   * A stable 32 hex character id for one alert: the same job, type and time always give the same
   * id, so a provider that deduplicates on it drops a resend of an alert it already took.
   */
  static String alertId(Alert a) {
    return sha256Hex(a.job() + "\n" + a.type().value() + "\n" + Js.formatLong(a.at()))
        .substring(0, 32);
  }

  /** The same id laid out as a UUID, for APIs that ask for one. */
  static String asUuid(String id) {
    return id.substring(0, 8)
        + "-"
        + id.substring(8, 12)
        + "-"
        + id.substring(12, 16)
        + "-"
        + id.substring(16, 20)
        + "-"
        + id.substring(20, 32);
  }

  /**
   * The run fields worth attaching to a tracker event, or null. A start before the year 1 or after
   * 9999 is null.
   */
  static @Nullable JsObject runSummary(Alert a) {
    Run r = a.run();
    if (r == null) {
      return null;
    }
    return new JsObject()
        .set("id", r.id())
        .set("status", r.status().value())
        .set("startedAt", Js.isoTime(r.startedAt()))
        .set("durationMs", r.durationMs())
        .set("trigger", r.trigger());
  }

  /** The largest time a JavaScript {@code Date} holds, either side of 1970. */
  private static final long MAX_DATE_MS = 8_640_000_000_000_000L;

  /**
   * {@code new Date(ms).toISOString()}, which throws past what a {@code Date} holds, as it throws
   * in JavaScript (so the send fails, as the SDK's does).
   */
  static String isoString(long ms) {
    if (ms > MAX_DATE_MS || ms < -MAX_DATE_MS) {
      throw new IllegalArgumentException("Invalid time value");
    }
    return Js.isoString(ms);
  }

  /** The alert's diagnosis, {@code ""} for none (JavaScript reads null and "" alike as absent). */
  static String triage(Alert a) {
    String t = a.triage();
    return t == null ? "" : t;
  }

  /** The link option's answer for this alert, {@code ""} for none. */
  static String link(@Nullable Function<Alert, @Nullable String> link, Alert a) {
    if (link == null) {
      return "";
    }
    String out = link.apply(a);
    return out == null ? "" : out;
  }

  /** The title, message, triage and link as one plain text block, the way every channel reads. */
  static String plainText(Alert a, String link) {
    List<String> lines = new ArrayList<>(List.of(a.title(), "", a.message()));
    if (!triage(a).isEmpty()) {
      lines.add("");
      lines.add("Triage: " + triage(a));
    }
    if (!link.isEmpty()) {
      lines.add("");
      lines.add("Open: " + link);
    }
    return String.join("\n", lines);
  }

  /** A credential with the spaces and newlines a paste leaves around it taken off. */
  static String trimmed(@Nullable String value) {
    return value == null ? "" : Js.trim(value);
  }

  /** {@code value}, or {@code ""} for null. */
  static String text(@Nullable String value) {
    return value == null ? "" : value;
  }

  static String basicAuth(String user, String password) {
    return "Basic " + Base64.getEncoder().encodeToString(Js.utf8(user + ":" + password));
  }

  /** JavaScript's {@code encodeURIComponent}. */
  static String encodeUriComponent(String text) {
    return percent(text, "-_.!~*'()", false);
  }

  /** {@code URLSearchParams#toString} for these pairs: a space as {@code +}. */
  static String form(List<Map.Entry<String, String>> pairs) {
    List<String> out = new ArrayList<>(pairs.size());
    for (Map.Entry<String, String> p : pairs) {
      out.add(percent(p.getKey(), "*-._", true) + "=" + percent(p.getValue(), "*-._", true));
    }
    return String.join("&", out);
  }

  static String percent(String text, String safe, boolean plus) {
    StringBuilder b = new StringBuilder(text.length());
    for (byte x : Js.utf8(text)) {
      int c = x & 0xff;
      if ((c >= 'a' && c <= 'z')
          || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9')
          || safe.indexOf(c) >= 0) {
        b.append((char) c);
      } else if (c == ' ' && plus) {
        b.append('+');
      } else {
        b.append('%').append(Character.toUpperCase(Character.forDigit(c >> 4, 16)));
        b.append(Character.toUpperCase(Character.forDigit(c & 15, 16)));
      }
    }
    return b.toString();
  }

  /** The channel's own transport, else the client's. */
  static Transport transport(@Nullable Transport own, ChannelContext context) {
    return own != null ? own : context.transport();
  }

  /** Headers in the order given, as name and value pairs. */
  static List<Map.Entry<String, String>> headers(String... pairs) {
    List<Map.Entry<String, String>> out = new ArrayList<>(pairs.length / 2);
    for (int i = 0; i + 1 < pairs.length; i += 2) {
      out.add(Map.entry(pairs[i], pairs[i + 1]));
    }
    return out;
  }

  /** Posts a body and fails on an answer outside 2xx, the secrets cut out of a quoted answer. */
  static void send(
      Transport transport,
      String provider,
      String url,
      List<Map.Entry<String, String>> headers,
      String body,
      List<@Nullable String> secrets)
      throws InterruptedException {
    Post.post(transport, provider, url, headers, body, secrets);
  }

  /** A refusal of a channel's options, which never quotes their values. */
  static dev.cronwatch.CronwatchException invalid(String message) {
    return dev.cronwatch.CronwatchException.invalid(message);
  }
}
