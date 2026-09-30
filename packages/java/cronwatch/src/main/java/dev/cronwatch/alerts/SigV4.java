package dev.cronwatch.alerts;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.post.WhatwgUrl;
import dev.cronwatch.json.JsObject;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * AWS Signature Version 4, for the SES channel ({@code alerts/sigv4.ts}), with the JDK's HMAC and
 * SHA-256, so no AWS SDK is needed. Checked against the AWS SigV4 test suite.
 */
final class SigV4 {
  private SigV4() {}

  /**
   * The headers to send: the given ones (names lowercased), then {@code x-amz-date}, the session
   * token when there is one, and {@code authorization}. {@code host} is signed but not returned,
   * since the transport sets it.
   */
  static List<Map.Entry<String, String>> sign(
      String method,
      String url,
      List<Map.Entry<String, String>> given,
      String body,
      String region,
      String service,
      long now,
      String accessKeyId,
      String secretAccessKey,
      @Nullable String sessionToken) {
    if (!(WhatwgUrl.parse(url) instanceof WhatwgUrl.Special s)) {
      throw new IllegalArgumentException("Invalid URL");
    }
    WhatwgUrl u = s.url();
    String amzDate =
        Shared.isoString(now).replace("-", "").replace(":", "").replaceFirst("\\.\\d{3}", "");
    String day = amzDate.substring(0, 8);
    // A JavaScript object: a name given again keeps its first place.
    JsObject headers = new JsObject();
    for (Map.Entry<String, String> h : given) {
      headers.set(h.getKey().toLowerCase(Locale.ROOT), h.getValue());
    }
    headers.set("x-amz-date", amzDate);
    if (sessionToken != null && !sessionToken.isEmpty()) {
      headers.set("x-amz-security-token", sessionToken);
    }
    JsObject signed = headers.copy();
    signed.set("host", u.port() < 0 ? u.host() : u.host() + ":" + u.port());
    List<String> names = new ArrayList<>(signed.keys());
    names.sort(null);
    StringBuilder canonicalHeaders = new StringBuilder();
    for (String n : names) {
      canonicalHeaders
          .append(n)
          .append(':')
          .append(collapse(Js.trim(String.valueOf(signed.get(n)))))
          .append('\n');
    }
    String signedHeaders = String.join(";", names);
    String canonicalRequest =
        String.join(
            "\n",
            method.toUpperCase(Locale.ROOT),
            canonicalUri(u.path()),
            canonicalQuery(u.query()),
            canonicalHeaders.toString(),
            signedHeaders,
            Shared.sha256Hex(body));
    String scope = day + "/" + region + "/" + service + "/aws4_request";
    String stringToSign =
        String.join("\n", "AWS4-HMAC-SHA256", amzDate, scope, Shared.sha256Hex(canonicalRequest));
    byte[] key = Shared.hmacSha256(Js.utf8("AWS4" + secretAccessKey), day);
    key = Shared.hmacSha256(key, region);
    key = Shared.hmacSha256(key, service);
    key = Shared.hmacSha256(key, "aws4_request");
    String signature = Shared.hex(Shared.hmacSha256(key, stringToSign));
    headers.set(
        "authorization",
        "AWS4-HMAC-SHA256 Credential="
            + accessKeyId
            + "/"
            + scope
            + ", SignedHeaders="
            + signedHeaders
            + ", Signature="
            + signature);
    List<Map.Entry<String, String>> out = new ArrayList<>();
    for (Map.Entry<String, Object> e : headers.entries()) {
      out.add(Map.entry(e.getKey(), String.valueOf(e.getValue())));
    }
    return out;
  }

  /** {@code .replace(/\s+/g, " ")}, JavaScript's whitespace. */
  private static String collapse(String text) {
    StringBuilder b = new StringBuilder(text.length());
    boolean space = false;
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      if (Js.isSpace(c) || c == ' ' || c == ' ') {
        if (!space) {
          b.append(' ');
        }
        space = true;
      } else {
        b.append(c);
        space = false;
      }
    }
    return b.toString();
  }

  /** RFC 3986 encoding of every byte but the unreserved characters. */
  private static String uriEncode(String text) {
    return Shared.percent(text, "-_.~", false);
  }

  private static String canonicalUri(String path) {
    if (path.isEmpty()) {
      return "/";
    }
    // The path is already encoded once; every AWS service but S3 expects each segment encoded
    // again.
    String[] segments = path.split("/", -1);
    List<String> out = new ArrayList<>(segments.length);
    for (String seg : segments) {
      out.add(uriEncode(seg));
    }
    return String.join("/", out);
  }

  /** The query as {@code URLSearchParams} reads it, each part encoded again and sorted. */
  private static String canonicalQuery(@Nullable String query) {
    if (query == null || query.isEmpty()) {
      return "";
    }
    List<String[]> pairs = new ArrayList<>();
    for (String part : query.split("&", -1)) {
      if (part.isEmpty()) {
        continue;
      }
      int eq = part.indexOf('=');
      String name = eq < 0 ? part : part.substring(0, eq);
      String value = eq < 0 ? "" : part.substring(eq + 1);
      pairs.add(new String[] {uriEncode(formDecode(name)), uriEncode(formDecode(value))});
    }
    pairs.sort(
        (a, b) -> {
          int c = a[0].compareTo(b[0]);
          return c != 0 ? c : a[1].compareTo(b[1]);
        });
    List<String> out = new ArrayList<>(pairs.size());
    for (String[] p : pairs) {
      out.add(p[0] + "=" + p[1]);
    }
    return String.join("&", out);
  }

  /** A form's {@code +} as a space and {@code %XX} decoded, U+FFFD for bytes that are not UTF-8. */
  private static String formDecode(String text) {
    return new String(WhatwgUrl.percentDecodeBytes(text.replace('+', ' ')), StandardCharsets.UTF_8);
  }
}
