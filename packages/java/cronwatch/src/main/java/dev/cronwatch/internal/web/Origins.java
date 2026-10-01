package dev.cronwatch.internal.web;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.Json;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import org.jspecify.annotations.Nullable;

/**
 * Origins read as the SDK's {@code new URL(value).origin} reads them, carried over from the Go
 * port's {@code routes_origin.go} through the Rust port's {@code web/origin.rs}: spaces and control
 * characters around the value and tabs or line breaks in it are dropped, slashes after the scheme
 * may be missing or backslashes, credentials are ignored, the host is lowercased (percent escapes
 * decoded, IPv4 numbers written out, IPv6 compressed, a host outside ASCII written in punycode) and
 * a default port is left out. Not {@code java.net.URI}, which is RFC 2396 and reads hosts its own
 * way, and never {@code InetAddress}, which could ask DNS.
 */
public final class Origins {
  private Origins() {}

  /**
   * The longest host outside ASCII read, in bytes. Punycode takes time in the label's length times
   * its distinct characters, and a {@code Host} header is anyone's to send: a name no DNS could
   * hold (253 bytes) is refused well past that bound.
   */
  static final int MAX_IDN_HOST = 1024;

  /** Why a value is not an origin. */
  static final class NotOrigin extends Exception {
    private static final long serialVersionUID = 1L;
    final boolean notHttp;

    NotOrigin(boolean notHttp) {
      super(null, null, false, false);
      this.notHttp = notHttp;
    }
  }

  /** An origin and whether anything past its host would show in the URL. */
  record Read(String origin, boolean extra) {}

  /**
   * The origin option as {@code scheme://host[:port]}, null for {@code ""}, or the SDK's error for
   * anything that is not an http or https URL, so a typo fails when the routes are made.
   *
   * @throws IllegalArgumentException with the SDK's message
   */
  public static @Nullable String configured(@Nullable String value) {
    if (value == null || value.isEmpty()) {
      return null;
    }
    try {
      return read(value).origin();
    } catch (NotOrigin e) {
      if (e.notHttp) {
        throw new IllegalArgumentException(
            "routes: origin must be http or https, got " + Json.stringify(value));
      }
      throw new IllegalArgumentException(
          "routes: origin must be an absolute URL such as \"https://app.example.com\", got "
              + Json.stringify(value));
    }
  }

  /**
   * {@code scheme://host[:port]} for text that is a scheme and a bare host, or null when it carries
   * a path, credentials, a query or a fragment, or is not an http or https URL.
   */
  public static @Nullable String bare(String value) {
    try {
      Read r = read(value);
      return r.extra() ? null : r.origin();
    } catch (NotOrigin e) {
      return null;
    }
  }

  private static boolean isSchemeChar(char c) {
    return Text.isAsciiAlphanumeric(c) || c == '+' || c == '.' || c == '-';
  }

  static Read read(String value) throws NotOrigin {
    int start = 0;
    int end = value.length();
    while (start < end && value.charAt(start) <= ' ') {
      start++;
    }
    while (end > start && value.charAt(end - 1) <= ' ') {
      end--;
    }
    StringBuilder t = new StringBuilder(end - start);
    for (int i = start; i < end; i++) {
      char c = value.charAt(i);
      if (c != '\t' && c != '\n' && c != '\r') {
        t.append(c);
      }
    }
    String text = t.toString();
    int colon = text.indexOf(':');
    if (colon <= 0) {
      throw new NotOrigin(false);
    }
    String scheme = text.substring(0, colon);
    char first = scheme.charAt(0);
    if (!((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z'))) {
      throw new NotOrigin(false);
    }
    for (int i = 0; i < scheme.length(); i++) {
      if (!isSchemeChar(scheme.charAt(i))) {
        throw new NotOrigin(false);
      }
    }
    scheme = scheme.toLowerCase(Locale.ROOT);
    int defaultPort =
        switch (scheme) {
          case "http" -> 80;
          case "https" -> 443;
          default -> throw new NotOrigin(true);
        };
    int r = colon + 1;
    while (r < text.length() && (text.charAt(r) == '/' || text.charAt(r) == '\\')) {
      r++;
    }
    String rest = text.substring(r);
    int stop = rest.length();
    for (int i = 0; i < rest.length(); i++) {
      char c = rest.charAt(i);
      if (c == '/' || c == '\\' || c == '?' || c == '#') {
        stop = i;
        break;
      }
    }
    String authority = rest.substring(0, stop);
    String after = rest.substring(stop);
    int at = authority.lastIndexOf('@');
    String userinfo = at < 0 ? "" : authority.substring(0, at);
    String hostport = at < 0 ? authority : authority.substring(at + 1);
    String[] split = splitPort(hostport);
    String host = readHost(split[0]);
    String shown = "";
    if (split[1] != null && Integer.parseInt(split[1]) != defaultPort) {
      shown = ":" + split[1];
    }
    boolean extra = (at >= 0 && !userinfo.isEmpty() && !userinfo.equals(":")) || pastHost(after);
    return new Read(scheme + "://" + host + shown, extra);
  }

  private static boolean pastHost(String after) {
    String path = after;
    String fragment = null;
    int hash = after.indexOf('#');
    if (hash >= 0) {
      path = after.substring(0, hash);
      fragment = after.substring(hash + 1);
    }
    String query = "";
    int q = path.indexOf('?');
    if (q >= 0) {
      query = path.substring(q + 1);
      path = path.substring(0, q);
    }
    return (!path.isEmpty() && !path.equals("/") && !path.equals("\\"))
        || !query.isEmpty()
        || (fragment != null && !fragment.isEmpty());
  }

  /** The host and the port (null for none, else its digits without leading zeros). */
  private static String[] splitPort(String authority) throws NotOrigin {
    String host;
    String rest;
    if (authority.startsWith("[")) {
      int end = authority.indexOf(']');
      if (end < 0) {
        throw new NotOrigin(false);
      }
      host = authority.substring(0, end + 1);
      rest = authority.substring(end + 1);
    } else {
      int i = authority.lastIndexOf(':');
      host = i < 0 ? authority : authority.substring(0, i);
      rest = i < 0 ? "" : authority.substring(i);
    }
    if (rest.isEmpty() || rest.equals(":")) {
      return new String[] {host, null};
    }
    if (rest.charAt(0) != ':') {
      throw new NotOrigin(false);
    }
    String digits = rest.substring(1);
    for (int i = 0; i < digits.length(); i++) {
      char c = digits.charAt(i);
      if (c < '0' || c > '9') {
        throw new NotOrigin(false);
      }
    }
    int z = 0;
    while (z < digits.length() && digits.charAt(z) == '0') {
      z++;
    }
    digits = digits.substring(z);
    if (digits.length() > 5) {
      throw new NotOrigin(false);
    }
    int port = digits.isEmpty() ? 0 : Integer.parseInt(digits);
    if (port > 65535) {
      throw new NotOrigin(false);
    }
    return new String[] {host, Integer.toString(port)};
  }

  private static boolean forbiddenHostChar(char c) {
    return c <= ' ' || c == 0x7f || "#%/:<>?@[\\]^|".indexOf(c) >= 0;
  }

  private static String readHost(String host) throws NotOrigin {
    if (host.isEmpty()) {
      throw new NotOrigin(false);
    }
    if (host.startsWith("[")) {
      if (!host.endsWith("]") || host.length() < 2) {
        throw new NotOrigin(false);
      }
      String inner = host.substring(1, host.length() - 1);
      if (inner.indexOf('%') >= 0) {
        throw new NotOrigin(false);
      }
      int[] groups = parseIpv6(inner);
      if (groups == null) {
        throw new NotOrigin(false);
      }
      return "[" + ipv6Text(groups) + "]";
    }
    String decoded = Text.strictUtf8(Requests.percentDecode(Js.utf8(host)));
    if (decoded == null) {
      throw new NotOrigin(false);
    }
    decoded = decoded.toLowerCase(Locale.ROOT);
    if (!isAscii(decoded)) {
      if (decoded.getBytes(StandardCharsets.UTF_8).length > MAX_IDN_HOST) {
        throw new NotOrigin(false);
      }
      List<String> labels = new ArrayList<>();
      for (String label : decoded.split("\\.", -1)) {
        if (isAscii(label)) {
          labels.add(label);
        } else {
          String code = punycode(label);
          if (code == null) {
            throw new NotOrigin(false);
          }
          labels.add("xn--" + code);
        }
      }
      decoded = String.join(".", labels);
    }
    if (decoded.isEmpty()) {
      throw new NotOrigin(false);
    }
    for (int i = 0; i < decoded.length(); i++) {
      if (forbiddenHostChar(decoded.charAt(i))) {
        throw new NotOrigin(false);
      }
    }
    String v4 = ipv4(decoded);
    return v4 != null ? v4 : decoded;
  }

  private static boolean isAscii(String s) {
    for (int i = 0; i < s.length(); i++) {
      if (s.charAt(i) >= 0x80) {
        return false;
      }
    }
    return true;
  }

  /** WHATWG's IPv6 parser: the eight groups, or null for text that is not an address. */
  static int @Nullable [] parseIpv6(String s) {
    int[] address = new int[8];
    int piece = 0;
    int compress = -1;
    int p = 0;
    int n = s.length();
    if (p < n && s.charAt(p) == ':') {
      if (p + 1 >= n || s.charAt(p + 1) != ':') {
        return null;
      }
      p += 2;
      piece++;
      compress = piece;
    }
    while (p < n) {
      if (piece == 8) {
        return null;
      }
      if (s.charAt(p) == ':') {
        if (compress >= 0) {
          return null;
        }
        p++;
        piece++;
        compress = piece;
        continue;
      }
      int value = 0;
      int length = 0;
      while (length < 4 && p < n && Character.digit(s.charAt(p), 16) >= 0 && s.charAt(p) < 0x80) {
        value = value * 16 + Character.digit(s.charAt(p), 16);
        p++;
        length++;
      }
      if (p < n && s.charAt(p) == '.') {
        if (length == 0) {
          return null;
        }
        p -= length;
        if (piece > 6) {
          return null;
        }
        int seen = 0;
        while (p < n) {
          int part = -1;
          if (seen > 0) {
            if (s.charAt(p) == '.' && seen < 4) {
              p++;
            } else {
              return null;
            }
          }
          if (p >= n || s.charAt(p) < '0' || s.charAt(p) > '9') {
            return null;
          }
          while (p < n && s.charAt(p) >= '0' && s.charAt(p) <= '9') {
            int d = s.charAt(p) - '0';
            if (part < 0) {
              part = d;
            } else if (part == 0) {
              return null;
            } else {
              part = part * 10 + d;
            }
            if (part > 255) {
              return null;
            }
            p++;
          }
          address[piece] = address[piece] * 0x100 + part;
          seen++;
          if (seen == 2 || seen == 4) {
            piece++;
          }
        }
        if (seen != 4) {
          return null;
        }
        break;
      } else if (p < n && s.charAt(p) == ':') {
        p++;
        if (p >= n) {
          return null;
        }
      } else if (p < n) {
        return null;
      }
      address[piece] = value;
      piece++;
    }
    if (compress >= 0) {
      int swaps = piece - compress;
      piece = 7;
      while (piece != 0 && swaps > 0) {
        int other = compress + swaps - 1;
        int tmp = address[piece];
        address[piece] = address[other];
        address[other] = tmp;
        piece--;
        swaps--;
      }
    } else if (piece != 8) {
      return null;
    }
    return address;
  }

  /**
   * An IPv6 address as the URL serializer writes it: groups in lowercase hex, the first longest run
   * of two or more zero groups as {@code ::}, and never the dotted form.
   */
  static String ipv6Text(int[] groups) {
    int start = -1;
    int length = 0;
    int i = 0;
    while (i < 8) {
      if (groups[i] != 0) {
        i++;
        continue;
      }
      int j = i;
      while (j < 8 && groups[j] == 0) {
        j++;
      }
      if (j - i > length && j - i > 1) {
        start = i;
        length = j - i;
      }
      i = j;
    }
    StringBuilder out = new StringBuilder();
    i = 0;
    while (i < 8) {
      if (i == start) {
        out.append(i == 0 ? "::" : ":");
        i += length;
        continue;
      }
      out.append(Integer.toHexString(groups[i]));
      if (i < 7) {
        out.append(':');
      }
      i++;
    }
    return out.toString();
  }

  private static boolean isDecimal(String s) {
    if (s.isEmpty()) {
      return false;
    }
    for (int i = 0; i < s.length(); i++) {
      if (s.charAt(i) < '0' || s.charAt(i) > '9') {
        return false;
      }
    }
    return true;
  }

  private static boolean isHexLabel(String s) {
    if (s.length() < 2 || s.charAt(0) != '0' || (s.charAt(1) != 'x' && s.charAt(1) != 'X')) {
      return false;
    }
    for (int i = 2; i < s.length(); i++) {
      if (Character.digit(s.charAt(i), 16) < 0 || s.charAt(i) >= 0x80) {
        return false;
      }
    }
    return true;
  }

  private static boolean isOctalLabel(String s) {
    if (s.length() < 2 || s.charAt(0) != '0') {
      return false;
    }
    for (int i = 1; i < s.length(); i++) {
      if (s.charAt(i) < '0' || s.charAt(i) > '7') {
        return false;
      }
    }
    return true;
  }

  /**
   * WHATWG's IPv4 parser, for a host whose last label is a number: {@code 127.1} and {@code 0x7f.1}
   * are 127.0.0.1. Null for a host that is a name.
   */
  private static @Nullable String ipv4(String host) throws NotOrigin {
    List<String> parts = new ArrayList<>(List.of(host.split("\\.", -1)));
    if (parts.size() > 1 && parts.get(parts.size() - 1).isEmpty()) {
      parts.remove(parts.size() - 1);
    }
    String last = parts.get(parts.size() - 1);
    if (!isDecimal(last) && !isHexLabel(last)) {
      return null;
    }
    if (parts.size() > 4) {
      throw new NotOrigin(false);
    }
    double[] numbers = new double[parts.size()];
    for (int i = 0; i < numbers.length; i++) {
      numbers[i] = ipv4Number(parts.get(i));
    }
    for (int i = 0; i < numbers.length - 1; i++) {
      if (numbers[i] > 255) {
        throw new NotOrigin(false);
      }
    }
    double lastN = numbers[numbers.length - 1];
    if (lastN >= Math.pow(256, 5 - numbers.length)) {
      throw new NotOrigin(false);
    }
    double address = lastN;
    for (int i = 0; i < numbers.length - 1; i++) {
      address += numbers[i] * Math.pow(256, 3 - i);
    }
    long a = (long) address;
    return (a >> 24) + "." + ((a >> 16) & 255) + "." + ((a >> 8) & 255) + "." + (a & 255);
  }

  private static double ipv4Number(String part) throws NotOrigin {
    if (part.isEmpty()) {
      throw new NotOrigin(false);
    }
    if (isHexLabel(part)) {
      return part.length() == 2 ? 0 : parseBig(part.substring(2), 16);
    }
    if (isOctalLabel(part)) {
      return parseBig(part.substring(1), 8);
    }
    if (isDecimal(part) && (part.equals("0") || part.charAt(0) != '0')) {
      return parseBig(part, 10);
    }
    throw new NotOrigin(false);
  }

  /** Digits as a number; too many for a long are past every limit the checks test. */
  private static double parseBig(String digits, int radix) {
    int z = 0;
    while (z < digits.length() - 1 && digits.charAt(z) == '0') {
      z++;
    }
    String d = digits.substring(z);
    if (d.length() > 24) {
      return Double.POSITIVE_INFINITY;
    }
    return new BigInteger(d, radix).doubleValue();
  }

  /** RFC 3492's encoding of one label, without the {@code xn--}, or null past its limits. */
  static @Nullable String punycode(String label) {
    int[] runes = label.codePoints().toArray();
    StringBuilder out = new StringBuilder();
    for (int r : runes) {
      if (r < 0x80) {
        out.append((char) r);
      }
    }
    int basic = out.length();
    int handled = basic;
    if (basic > 0) {
      out.append('-');
    }
    long n = 128;
    long delta = 0;
    long bias = 72;
    while (handled < runes.length) {
      long m = Integer.MAX_VALUE;
      for (int r : runes) {
        if (r >= n && r < m) {
          m = r;
        }
      }
      if ((m - n) * (handled + 1) > Integer.MAX_VALUE - delta) {
        return null;
      }
      delta += (m - n) * (handled + 1);
      n = m;
      for (int r : runes) {
        if (r < n) {
          delta++;
        }
        if (r == n) {
          long q = delta;
          for (long k = BASE; ; k += BASE) {
            long t = Math.max(T_MIN, Math.min(T_MAX, k - bias));
            if (q < t) {
              break;
            }
            out.append(digit(t + (q - t) % (BASE - t)));
            q = (q - t) / (BASE - t);
          }
          out.append(digit(q));
          bias = adapt(delta, handled + 1, handled == basic);
          delta = 0;
          handled++;
        }
      }
      delta++;
      n++;
    }
    return out.toString();
  }

  private static char digit(long d) {
    return d < 26 ? (char) ('a' + d) : (char) ('0' + (d - 26));
  }

  private static final long BASE = 36;
  private static final long T_MIN = 1;
  private static final long T_MAX = 26;
  private static final long SKEW = 38;
  private static final long DAMP = 700;

  private static long adapt(long delta, long points, boolean first) {
    long d = delta / (first ? DAMP : 2);
    d += d / points;
    long k = 0;
    while (d > ((BASE - T_MIN) * T_MAX) / 2) {
      d /= BASE - T_MIN;
      k += BASE;
    }
    return k + (BASE - T_MIN + 1) * d / (d + SKEW);
  }

  /**
   * The origin of a request's own URL: its scheme (https when it came over TLS) and {@code Host},
   * lowercased and without a default port. The host is read as UTF-8 from the bytes sent.
   */
  public static String ofRequest(boolean tls, String hostHeader) {
    String scheme = tls ? "https" : "http";
    String host = Text.utf8Lossy(hostHeader);
    String bare = bare(scheme + "://" + host);
    return bare != null ? bare : scheme + "://" + host.toLowerCase(Locale.ROOT);
  }

  /**
   * Whether an origin's host is loopback: {@code localhost}, a name ending in {@code .localhost},
   * an IPv4 address in 127.0.0.0/8, or the IPv6 address ::1. Only an origin that reads as one
   * counts: a {@code Host} header is anyone's to send, and one such as {@code
   * evil.example/.localhost} or {@code localhost:1@evil.example} must not put the development token
   * in a link to another host.
   */
  public static boolean isLoopback(String origin) {
    String o = bare(origin);
    if (o == null) {
      return false;
    }
    int sep = o.indexOf("://");
    String authority = sep < 0 ? o : o.substring(sep + 3);
    String host;
    if (authority.startsWith("[")) {
      int end = authority.indexOf(']');
      host = end < 0 ? authority : authority.substring(0, end + 1);
    } else {
      int c = authority.indexOf(':');
      host = c < 0 ? authority : authority.substring(0, c);
    }
    host = host.toLowerCase(Locale.ROOT);
    if (host.equals("localhost") || host.equals("[::1]") || host.endsWith(".localhost")) {
      return true;
    }
    if (!host.startsWith("127.")) {
      return false;
    }
    String[] octets = host.substring(4).split("\\.", -1);
    if (octets.length != 3) {
      return false;
    }
    for (String octet : octets) {
      if (octet.isEmpty() || octet.length() > 3 || !isDecimal(octet)) {
        return false;
      }
      if (Integer.parseInt(octet) > 255) {
        return false;
      }
    }
    return true;
  }
}
