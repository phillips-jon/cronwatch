package dev.cronwatch.internal.web;

import dev.cronwatch.internal.evaluate.Format;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * Reading a request the way the SDK's routes read a fetch {@code Request}, carried over from the Go
 * port's {@code routes_request.go} through the Rust port's {@code web/request.rs}: the path as the
 * URL parser leaves it, the query as {@code URLSearchParams} parses it, headers as {@code
 * Headers.get} joins them, and the body as {@code request.json()} and {@code request.formData()}
 * read it.
 */
public final class Requests {
  private Requests() {}

  private static final char[] HEX = "0123456789ABCDEF".toCharArray();

  /**
   * A header as fetch's {@code Headers.get} gives it: every value joined with {@code ", "} (a
   * cookie's with {@code "; "}, as HTTP/2 sends each cookie apart), or null when there is none.
   */
  public static @Nullable String header(List<Map.Entry<String, String>> headers, String name) {
    String first = null;
    StringBuilder joined = null;
    String sep = name.equalsIgnoreCase("cookie") ? "; " : ", ";
    for (Map.Entry<String, String> h : headers) {
      if (!h.getKey().equalsIgnoreCase(name)) {
        continue;
      }
      if (first == null) {
        first = h.getValue();
      } else {
        if (joined == null) {
          joined = new StringBuilder(first);
        }
        joined.append(sep).append(h.getValue());
      }
    }
    return joined != null ? joined.toString() : first;
  }

  /**
   * The path and query the client sent. A target in the absolute form a proxy is sent starts its
   * path after the host; a fragment is dropped.
   */
  public static String[] target(String target) {
    String t = target;
    if (!t.startsWith("/")) {
      int i = t.indexOf("://");
      if (i >= 0) {
        String rest = t.substring(i + 3);
        int j = -1;
        for (int k = 0; k < rest.length(); k++) {
          char c = rest.charAt(k);
          if (c == '/' || c == '?') {
            j = k;
            break;
          }
        }
        t = j < 0 ? "/" : rest.substring(j);
      }
    }
    int q = t.indexOf('?');
    String path = q < 0 ? t : t.substring(0, q);
    String query = q < 0 ? "" : t.substring(q + 1);
    int hash = path.indexOf('#');
    if (hash >= 0) {
      path = path.substring(0, hash);
    }
    hash = query.indexOf('#');
    if (hash >= 0) {
      query = query.substring(0, hash);
    }
    if (path.isEmpty() || path.equals("*")) {
      path = "/";
    }
    return new String[] {path, query};
  }

  /**
   * Whether the URL parser leaves {@code c} in a path as it is: the path percent-encode set is C0
   * controls, space, {@code " # < > ? ` { }} and everything past {@code ~}.
   */
  private static boolean pathSafe(int c) {
    return c > 0x20 && c < 0x7f && "\"#<>?`{}".indexOf(c) < 0;
  }

  /**
   * A path as {@code new URL()} leaves it for an http URL: backslashes read as slashes, characters
   * outside the path set escaped as UTF-8, and {@code .} and {@code ..} segments (written plainly
   * or as {@code %2e}) resolved.
   */
  public static String normalizePath(String raw) {
    StringBuilder b = new StringBuilder(raw.length());
    for (byte x : Js.utf8(raw)) {
      int c = x & 0xff;
      if (c == '\\') {
        b.append('/');
      } else if (pathSafe(c) || c == '%') {
        b.append((char) c);
      } else {
        b.append('%').append(HEX[c >> 4]).append(HEX[c & 15]);
      }
    }
    String s = b.toString();
    String trimmed = s.startsWith("/") ? s.substring(1) : s;
    String[] segments = trimmed.split("/", -1);
    List<String> out = new ArrayList<>();
    for (int i = 0; i < segments.length; i++) {
      boolean last = i == segments.length - 1;
      switch (segments[i].toLowerCase(Locale.ROOT)) {
        case ".", "%2e" -> {
          if (last) {
            out.add("");
          }
        }
        case "..", ".%2e", "%2e.", "%2e%2e" -> {
          if (!out.isEmpty()) {
            out.remove(out.size() - 1);
          }
          if (last) {
            out.add("");
          }
        }
        default -> out.add(segments[i]);
      }
    }
    return "/" + String.join("/", out);
  }

  /** The path under the base, without a trailing slash. */
  public static String stripBase(String pathname, String base) {
    String path = pathname.startsWith(base) ? pathname.substring(base.length()) : pathname;
    if (path.isEmpty()) {
      path = "/";
    }
    if (path.length() > 1 && path.endsWith("/")) {
      path = path.substring(0, path.length() - 1);
    }
    return path;
  }

  private static boolean isHexDigit(int c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
  }

  /**
   * {@code decodeURIComponent}, or null where it would throw: an escape that is not one, or bytes
   * that are not UTF-8.
   */
  public static @Nullable String safeDecode(String s) {
    for (int i = 0; i < s.length(); i++) {
      if (s.charAt(i) == '%'
          && (i + 2 >= s.length()
              || !isHexDigit(s.charAt(i + 1))
              || !isHexDigit(s.charAt(i + 2)))) {
        return null;
      }
    }
    return Text.strictUtf8(percentDecode(Js.utf8(s)));
  }

  /** Decodes every {@code %XX}, leaving anything else as it is. */
  public static byte[] percentDecode(byte[] s) {
    ByteArrayOutputStream out = new ByteArrayOutputStream(s.length);
    int i = 0;
    while (i < s.length) {
      if (s[i] == '%' && i + 2 < s.length && isHexDigit(s[i + 1]) && isHexDigit(s[i + 2])) {
        out.write((Character.digit(s[i + 1], 16) << 4) | Character.digit(s[i + 2], 16));
        i += 3;
        continue;
      }
      out.write(s[i]);
      i++;
    }
    return out.toByteArray();
  }

  /**
   * {@code application/x-www-form-urlencoded} parsing as {@code URLSearchParams} does it: {@code +}
   * is a space, an escape that is not one is kept as written, and bytes that are not UTF-8 become
   * U+FFFD.
   */
  public static List<Map.Entry<String, String>> parseForm(byte[] text) {
    List<Map.Entry<String, String>> out = new ArrayList<>();
    int start = 0;
    for (int i = 0; i <= text.length; i++) {
      if (i < text.length && text[i] != '&') {
        continue;
      }
      if (i > start) {
        int eq = -1;
        for (int k = start; k < i; k++) {
          if (text[k] == '=') {
            eq = k;
            break;
          }
        }
        String name = formDecode(text, start, eq < 0 ? i : eq);
        String value = eq < 0 ? "" : formDecode(text, eq + 1, i);
        out.add(Map.entry(name, value));
      }
      start = i + 1;
    }
    return out;
  }

  /** {@link #parseForm} of a query as the URL holds it: its text written out as UTF-8. */
  public static List<Map.Entry<String, String>> parseQuery(String query) {
    return parseForm(Js.utf8(query));
  }

  private static String formDecode(byte[] s, int from, int to) {
    byte[] spaced = new byte[to - from];
    for (int i = from; i < to; i++) {
      spaced[i - from] = s[i] == '+' ? (byte) ' ' : s[i];
    }
    return new String(percentDecode(spaced), StandardCharsets.UTF_8);
  }

  /** The {@code application/x-www-form-urlencoded} serializer {@code URLSearchParams} writes. */
  public static String formEncode(String s) {
    StringBuilder out = new StringBuilder(s.length());
    for (byte x : Js.utf8(s)) {
      int c = x & 0xff;
      if (Text.isAsciiAlphanumeric(c) || c == '*' || c == '-' || c == '.' || c == '_') {
        out.append((char) c);
      } else if (c == ' ') {
        out.append('+');
      } else {
        out.append('%').append(HEX[c >> 4]).append(HEX[c & 15]);
      }
    }
    return out.toString();
  }

  /** {@code URLSearchParams#get}: the first value, or null. */
  public static @Nullable String param(List<Map.Entry<String, String>> pairs, String name) {
    for (Map.Entry<String, String> p : pairs) {
      if (p.getKey().equals(name)) {
        return p.getValue();
      }
    }
    return null;
  }

  private static @Nullable String lastField(List<Map.Entry<String, String>> pairs, String name) {
    String found = null;
    for (Map.Entry<String, String> p : pairs) {
      if (p.getKey().equals(name)) {
        found = p.getValue();
      }
    }
    return found;
  }

  /**
   * A field of a request's form or JSON object, as {@code String(value)} gives it in JavaScript;
   * null for anything else, or a body that cannot be read as its type says. The last of several
   * fields of one name wins, as {@code Object.fromEntries} has it.
   */
  public static @Nullable String bodyField(String contentType, byte[] data, String name) {
    if (contentType.contains("application/json")) {
      String text = new String(data, StandardCharsets.UTF_8);
      if (text.startsWith("﻿")) {
        text = text.substring(1);
      }
      Object value;
      try {
        value = Json.parse(text);
      } catch (RuntimeException e) {
        // Not JSON, or nested past Json.MAX_DEPTH: the SDK's readBody reads it as none.
        return null;
      }
      return jsonField(value, name);
    }
    if (contentType.contains("multipart/form-data")) {
      List<Map.Entry<String, String>> fields = multipartFields(contentType, data);
      return fields == null ? null : lastField(fields, name);
    }
    if (contentType.contains("application/x-www-form-urlencoded")) {
      return lastField(parseForm(data), name);
    }
    return null;
  }

  /** {@code String(data[name])} of a parsed JSON body, or null when it has no such field. */
  public static @Nullable String jsonField(@Nullable Object value, String name) {
    if (value instanceof JsObject o) {
      return o.has(name) ? Format.jsText(o.get(name)) : null;
    }
    if (value instanceof List<?> list) {
      long i = arrayIndex(name);
      return i >= 0 && i < list.size() ? Format.jsText(list.get((int) i)) : null;
    }
    return null;
  }

  /** A key that is an array index (a canonical whole number below 2^32 - 1), or -1. */
  static long arrayIndex(String key) {
    int n = key.length();
    if (n == 0 || n > 10 || (n > 1 && key.charAt(0) == '0')) {
      return -1;
    }
    long v = 0;
    for (int i = 0; i < n; i++) {
      char c = key.charAt(i);
      if (c < '0' || c > '9') {
        return -1;
      }
      v = v * 10 + (c - '0');
    }
    return v >= (1L << 32) - 1 ? -1 : v;
  }

  /** A media type's parameter, unquoted, its name matched without regard to case. */
  static @Nullable String mediaParam(String contentType, String name) {
    String[] parts = contentType.split(";", -1);
    for (int i = 1; i < parts.length; i++) {
      int eq = parts[i].indexOf('=');
      if (eq < 0) {
        continue;
      }
      if (!parts[i].substring(0, eq).trim().equalsIgnoreCase(name)) {
        continue;
      }
      return unquote(parts[i].substring(eq + 1).trim());
    }
    return null;
  }

  private static String unquote(String v) {
    if (v.length() < 2 || !v.startsWith("\"") || !v.endsWith("\"")) {
      return v;
    }
    String inner = v.substring(1, v.length() - 1);
    StringBuilder out = new StringBuilder();
    for (int i = 0; i < inner.length(); i++) {
      char c = inner.charAt(i);
      if (c == '\\') {
        if (i + 1 < inner.length()) {
          out.append(inner.charAt(++i));
        }
      } else {
        out.append(c);
      }
    }
    return out.toString();
  }

  private static int find(byte[] haystack, byte[] needle, int from) {
    if (needle.length == 0 || from > haystack.length) {
      return -1;
    }
    outer:
    for (int i = from; i + needle.length <= haystack.length; i++) {
      for (int j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          continue outer;
        }
      }
      return i;
    }
    return -1;
  }

  private static byte[] concat(String prefix, byte[] b) {
    byte[] p = prefix.getBytes(StandardCharsets.ISO_8859_1);
    byte[] out = new byte[p.length + b.length];
    System.arraycopy(p, 0, out, 0, p.length);
    System.arraycopy(b, 0, out, p.length, b.length);
    return out;
  }

  private static boolean startsWith(byte[] data, int at, byte[] prefix) {
    if (at + prefix.length > data.length) {
      return false;
    }
    for (int i = 0; i < prefix.length; i++) {
      if (data[at + i] != prefix[i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * The fields of a {@code multipart/form-data} body, as {@code formData()} reads them: a file
   * part's value is {@code [object File]}. Null for a body that does not parse, as {@code
   * formData()} throws on one.
   */
  static @Nullable List<Map.Entry<String, String>> multipartFields(
      String contentType, byte[] data) {
    String boundary = mediaParam(contentType, "boundary");
    if (boundary == null || boundary.isEmpty()) {
      return null;
    }
    byte[] delimiter = Js.utf8("--" + boundary);
    int at;
    if (startsWith(data, 0, delimiter)) {
      at = 0;
    } else {
      int crlf = find(data, concat("\r\n", delimiter), 0);
      int lf = find(data, concat("\n", delimiter), 0);
      if (crlf >= 0) {
        at = crlf + 2;
      } else if (lf >= 0) {
        at = lf + 1;
      } else {
        return null;
      }
    }
    byte[] nl = {'\n'};
    byte[] nextDelimiter = concat("\n", delimiter);
    List<Map.Entry<String, String>> fields = new ArrayList<>();
    while (true) {
      at += delimiter.length;
      if (startsWith(data, at, new byte[] {'-', '-'})) {
        return fields;
      }
      // The rest of the delimiter's line.
      int eol = find(data, nl, at);
      if (eol < 0) {
        return null;
      }
      at = eol + 1;
      // The part's headers, up to an empty line.
      String disposition = "";
      while (true) {
        int end = find(data, nl, at);
        if (end < 0) {
          return null;
        }
        int lineEnd = end > at && data[end - 1] == '\r' ? end - 1 : end;
        String line = new String(data, at, lineEnd - at, StandardCharsets.UTF_8);
        at = end + 1;
        if (line.isEmpty()) {
          break;
        }
        int colon = line.indexOf(':');
        if (colon >= 0 && line.substring(0, colon).trim().equalsIgnoreCase("content-disposition")) {
          disposition = line.substring(colon + 1).trim();
        }
      }
      // The part's body, up to the next delimiter on a line of its own.
      int next = find(data, nextDelimiter, at);
      if (next < 0) {
        return null;
      }
      int end = next;
      if (end > at && data[end - 1] == '\r') {
        end--;
      }
      String value = new String(data, at, Math.max(end, at) - at, StandardCharsets.UTF_8);
      at = next + 1;
      String kind = disposition.split(";", -1)[0].trim();
      if (!kind.equalsIgnoreCase("form-data")) {
        continue;
      }
      String name = mediaParam(disposition, "name");
      if (name == null || name.isEmpty()) {
        continue;
      }
      String filename = mediaParam(disposition, "filename");
      fields.add(
          Map.entry(name, filename != null && !filename.isEmpty() ? "[object File]" : value));
    }
  }
}
