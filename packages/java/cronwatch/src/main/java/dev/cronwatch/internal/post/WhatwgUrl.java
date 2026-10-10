package dev.cronwatch.internal.post;

import dev.cronwatch.internal.js.Js;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * A URL read as the WHATWG URL parser (and so fetch) reads an http or https URL, the Go, Rust, and
 * Elixir ports' rules: characters up to U+0020 around it dropped and every tab, CR, and LF inside
 * it removed; the slashes after the scheme, and backslashes, read as fetch reads them; the host
 * lowercased, IPv4 in its dotted form (hex, octal, and short forms read) and IPv6 compressed; the
 * scheme's own port left out; dot segments resolved; and a space or other character a URL cannot
 * hold percent-encoded in the path, query, and fragment. {@code java.net.URI} is RFC 2396, which
 * refuses a space and reads several of these differently. A host outside ASCII is refused rather
 * than converted to punycode (the JDK's IDNA is 2003, WHATWG's is UTS 46), and so is an IPv6 host
 * with a zone, which WHATWG's IPv6 parser does not read.
 *
 * @param scheme the scheme, lowercased
 * @param username the user name, percent-encoded as WHATWG writes it, or {@code ""}
 * @param password the password, percent-encoded, or {@code ""}
 * @param host the host as WHATWG writes it (an IPv6 address in brackets)
 * @param port the port, or -1 for the scheme's own
 * @param path the path, starting with {@code /}
 * @param query the query without its {@code ?}, or null for none
 * @param fragment the fragment without its {@code #}, or null for none
 */
public record WhatwgUrl(
    String scheme,
    String username,
    String password,
    String host,
    int port,
    String path,
    @Nullable String query,
    @Nullable String fragment) {

  private static final Map<String, Integer> DEFAULT_PORTS =
      Map.of("http", 80, "https", 443, "ws", 80, "wss", 443, "ftp", 21);

  /** What reading a URL found. */
  public sealed interface Parsed permits Special, Other, Invalid {}

  /**
   * A URL of a special scheme (http, https, ws, wss, ftp) with a host.
   *
   * @param url the URL
   */
  public record Special(WhatwgUrl url) implements Parsed {}

  /**
   * A URL of another scheme.
   *
   * @param scheme its scheme, lowercased
   */
  public record Other(String scheme) implements Parsed {}

  /** Text that is no URL. */
  public record Invalid() implements Parsed {}

  /** Whether the URL has a user name or a password, which fetch refuses to send. */
  public boolean hasCredentials() {
    return !username.isEmpty() || !password.isEmpty();
  }

  /** {@code url.origin}: the scheme, host, and port. */
  public String origin() {
    return scheme + "://" + host + (port < 0 ? "" : ":" + port);
  }

  /** The path and query, as a request's target. */
  public String target() {
    return query == null ? path : path + "?" + query;
  }

  /** The URL as the parser writes it, without its user name and password. */
  @Override
  public String toString() {
    return origin()
        + path
        + (query == null ? "" : "?" + query)
        + (fragment == null ? "" : "#" + fragment);
  }

  /** The text as the parser first cleans it. */
  public static String clean(String raw) {
    int start = 0;
    int end = raw.length();
    while (start < end && raw.charAt(start) <= 0x20) {
      start++;
    }
    while (end > start && raw.charAt(end - 1) <= 0x20) {
      end--;
    }
    StringBuilder b = new StringBuilder(end - start);
    for (int i = start; i < end; i++) {
      char c = raw.charAt(i);
      if (c != '\t' && c != '\r' && c != '\n') {
        b.append(c);
      }
    }
    return b.toString();
  }

  /** Reads a URL. */
  public static Parsed parse(String raw) {
    String s = clean(raw);
    if (s.isEmpty() || !asciiAlpha(s.charAt(0))) {
      return new Invalid();
    }
    int colon = s.indexOf(':');
    if (colon < 0) {
      return new Invalid();
    }
    for (int i = 1; i < colon; i++) {
      char c = s.charAt(i);
      if (!asciiAlpha(c) && !(c >= '0' && c <= '9') && c != '+' && c != '.' && c != '-') {
        return new Invalid();
      }
    }
    String scheme = s.substring(0, colon).toLowerCase(Locale.ROOT);
    if (!DEFAULT_PORTS.containsKey(scheme)) {
      return new Other(scheme);
    }
    WhatwgUrl url = special(scheme, s.substring(colon + 1));
    return url == null ? new Invalid() : new Special(url);
  }

  private static boolean asciiAlpha(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
  }

  private static @Nullable WhatwgUrl special(String scheme, String rest) {
    int i = 0;
    while (i < rest.length() && (rest.charAt(i) == '/' || rest.charAt(i) == '\\')) {
      i++;
    }
    rest = rest.substring(i);
    int stop = rest.length();
    for (int k = 0; k < rest.length(); k++) {
      char c = rest.charAt(k);
      if (c == '/' || c == '\\' || c == '?' || c == '#') {
        stop = k;
        break;
      }
    }
    String authority = rest.substring(0, stop);
    String tail = rest.substring(stop);
    String fragment = null;
    int hash = tail.indexOf('#');
    if (hash >= 0) {
      fragment = tail.substring(hash + 1);
      tail = tail.substring(0, hash);
    }
    String query = null;
    int q = tail.indexOf('?');
    if (q >= 0) {
      query = tail.substring(q + 1);
      tail = tail.substring(0, q);
    }

    // The part before the last "@" is the user name and password.
    String username = "";
    String password = "";
    String hostPort = authority;
    int at = authority.lastIndexOf('@');
    if (at >= 0) {
      String info = authority.substring(0, at);
      hostPort = authority.substring(at + 1);
      int split = info.indexOf(':');
      username = encode(split < 0 ? info : info.substring(0, split), WhatwgUrl::userinfoChar);
      password = split < 0 ? "" : encode(info.substring(split + 1), WhatwgUrl::userinfoChar);
    }

    String hostText;
    String portText;
    if (hostPort.startsWith("[")) {
      int close = hostPort.indexOf(']');
      if (close < 0) {
        return null;
      }
      hostText = hostPort.substring(0, close + 1);
      String after = hostPort.substring(close + 1);
      if (after.isEmpty()) {
        portText = "";
      } else if (after.startsWith(":")) {
        portText = after.substring(1);
      } else {
        return null;
      }
    } else {
      int c = hostPort.indexOf(':');
      hostText = c < 0 ? hostPort : hostPort.substring(0, c);
      portText = c < 0 ? "" : hostPort.substring(c + 1);
    }
    String host = host(hostText);
    if (host == null) {
      return null;
    }
    int port = -1;
    if (!portText.isEmpty()) {
      for (int k = 0; k < portText.length(); k++) {
        char c = portText.charAt(k);
        if (c < '0' || c > '9') {
          return null;
        }
      }
      String digits = portText.replaceFirst("^0+(?=.)", "");
      if (digits.length() > 5) {
        return null;
      }
      port = Integer.parseInt(digits);
      if (port > 65_535) {
        return null;
      }
      if (port == DEFAULT_PORTS.get(scheme)) {
        port = -1;
      }
    }
    return new WhatwgUrl(
        scheme,
        username,
        password,
        host,
        port,
        path(tail),
        query == null ? null : encode(query, WhatwgUrl::queryChar),
        fragment == null ? null : encode(fragment, WhatwgUrl::fragmentChar));
  }

  // ---- the host

  private static @Nullable String host(String text) {
    if (text.isEmpty()) {
      return null;
    }
    if (text.startsWith("[")) {
      String v6 = text.substring(1, text.length() - 1);
      // WHATWG's IPv6 parser has no zone (%eth0).
      int[] pieces = v6.indexOf('%') >= 0 ? null : ipv6(v6);
      return pieces == null ? null : "[" + ipv6Text(pieces) + "]";
    }
    byte[] decoded = percentDecodeBytes(text);
    for (byte b : decoded) {
      int c = b & 0xff;
      // Outside ASCII: refused rather than converted to punycode, since the JDK's IDNA is not
      // WHATWG's. Invalid UTF-8 is refused by the same test.
      if (c >= 0x80 || c < 0x21 || c == 0x7f || "#%/:<>?@[\\]^|".indexOf(c) >= 0) {
        return null;
      }
    }
    String host = new String(decoded, StandardCharsets.US_ASCII).toLowerCase(Locale.ROOT);
    List<String> labels = new ArrayList<>(List.of(host.split("\\.", -1)));
    if (labels.size() > 1 && labels.get(labels.size() - 1).isEmpty()) {
      labels.remove(labels.size() - 1);
    }
    return number(labels.get(labels.size() - 1)) ? ipv4(labels) : host;
  }

  /** Whether a label reads as a number, so the host is an IPv4 address. */
  private static boolean number(String label) {
    if (label.isEmpty()) {
      return false;
    }
    if (label.matches("[0-9]+")) {
      return true;
    }
    return label.matches("0[xX][0-9A-Fa-f]*");
  }

  private static @Nullable String ipv4(List<String> labels) {
    int n = labels.size();
    if (n > 4) {
      return null;
    }
    long[] parts = new long[n];
    for (int i = 0; i < n; i++) {
      long v = ipv4Number(labels.get(i));
      if (v < 0) {
        return null;
      }
      parts[i] = v;
    }
    long address = parts[n - 1];
    if (address >= 1L << (8 * (5 - n))) {
      return null;
    }
    for (int i = 0; i < n - 1; i++) {
      if (parts[i] > 255) {
        return null;
      }
      address += parts[i] << (8 * (3 - i));
    }
    return (address >>> 24 & 255)
        + "."
        + (address >>> 16 & 255)
        + "."
        + (address >>> 8 & 255)
        + "."
        + (address & 255);
  }

  /** A label's number, or -1 when it is none (or past what an address can hold). */
  private static long ipv4Number(String label) {
    if (label.isEmpty()) {
      return -1;
    }
    int radix = 10;
    String digits = label;
    if (label.length() >= 2 && label.charAt(0) == '0' && (label.charAt(1) | 0x20) == 'x') {
      radix = 16;
      digits = label.substring(2);
      if (digits.isEmpty()) {
        return 0;
      }
    } else if (label.length() >= 2 && label.charAt(0) == '0') {
      radix = 8;
      digits = label.substring(1);
    }
    long v = 0;
    for (int i = 0; i < digits.length(); i++) {
      int d = Character.digit(digits.charAt(i), radix);
      if (d < 0 || digits.charAt(i) > 0x7f) {
        return -1;
      }
      v = v * radix + d;
      if (v > 0xFFFF_FFFFL) {
        // Past any address: the host is refused, as WHATWG refuses it.
        return 1L << 40;
      }
    }
    return v;
  }

  /** WHATWG's IPv6 parser: eight pieces, or null for text that is no IPv6 address. */
  static int @Nullable [] ipv6(String input) {
    int[] address = new int[8];
    int piece = 0;
    int compress = -1;
    int p = 0;
    int n = input.length();
    if (n > 0 && input.charAt(0) == ':') {
      if (n < 2 || input.charAt(1) != ':') {
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
      if (input.charAt(p) == ':') {
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
      while (length < 4
          && p < n
          && Character.digit(input.charAt(p), 16) >= 0
          && input.charAt(p) < 0x80) {
        value = value * 16 + Character.digit(input.charAt(p), 16);
        p++;
        length++;
      }
      if (p < n && input.charAt(p) == '.') {
        if (length == 0) {
          return null;
        }
        p -= length;
        if (piece > 6) {
          return null;
        }
        int seen = 0;
        while (p < n) {
          int v4 = -1;
          if (seen > 0) {
            if (input.charAt(p) == '.' && seen < 4) {
              p++;
            } else {
              return null;
            }
          }
          if (p >= n || input.charAt(p) < '0' || input.charAt(p) > '9') {
            return null;
          }
          while (p < n && input.charAt(p) >= '0' && input.charAt(p) <= '9') {
            int number = input.charAt(p) - '0';
            if (v4 < 0) {
              v4 = number;
            } else if (v4 == 0) {
              return null;
            } else {
              v4 = v4 * 10 + number;
            }
            if (v4 > 255) {
              return null;
            }
            p++;
          }
          address[piece] = address[piece] * 0x100 + v4;
          seen++;
          if (seen == 2 || seen == 4) {
            piece++;
          }
        }
        if (seen != 4) {
          return null;
        }
        break;
      } else if (p < n && input.charAt(p) == ':') {
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
        int t = address[piece];
        address[piece] = address[other];
        address[other] = t;
        piece--;
        swaps--;
      }
    } else if (piece != 8) {
      return null;
    }
    return address;
  }

  /** WHATWG's IPv6 serializer: lowercase hex, the first longest run of two or more zeros cut. */
  static String ipv6Text(int[] pieces) {
    int best = -1;
    int bestLength = 1;
    for (int i = 0; i < 8; ) {
      if (pieces[i] != 0) {
        i++;
        continue;
      }
      int j = i;
      while (j < 8 && pieces[j] == 0) {
        j++;
      }
      if (j - i > bestLength) {
        best = i;
        bestLength = j - i;
      }
      i = j;
    }
    StringBuilder b = new StringBuilder();
    boolean ignore0 = false;
    for (int i = 0; i < 8; i++) {
      if (ignore0 && pieces[i] == 0) {
        continue;
      }
      ignore0 = false;
      if (best == i) {
        b.append(i == 0 ? "::" : ":");
        ignore0 = true;
        continue;
      }
      b.append(Integer.toHexString(pieces[i]));
      if (i != 7) {
        b.append(':');
      }
    }
    return b.toString();
  }

  // ---- the path, query, and fragment

  private static String path(String text) {
    String[] split = text.replace('\\', '/').split("/", -1);
    List<String> out = new ArrayList<>();
    for (int i = 1; i < split.length; i++) {
      String seg = split[i];
      boolean last = i == split.length - 1;
      String lower = seg.toLowerCase(Locale.ROOT);
      if (lower.equals("..")
          || lower.equals(".%2e")
          || lower.equals("%2e.")
          || lower.equals("%2e%2e")) {
        if (!out.isEmpty()) {
          out.remove(out.size() - 1);
        }
        if (last) {
          out.add("");
        }
      } else if (lower.equals(".") || lower.equals("%2e")) {
        if (last) {
          out.add("");
        }
      } else {
        out.add(encode(seg, WhatwgUrl::pathChar));
      }
    }
    return "/" + String.join("/", out);
  }

  private interface Keep {
    boolean keep(int c);
  }

  private static boolean c0OrHigh(int c) {
    return c < 0x20 || c > 0x7e;
  }

  private static boolean pathChar(int c) {
    return !(c0OrHigh(c) || " \"#<>?^`{}".indexOf(c) >= 0);
  }

  private static boolean queryChar(int c) {
    return !(c0OrHigh(c) || " \"#<>'".indexOf(c) >= 0);
  }

  private static boolean fragmentChar(int c) {
    return !(c0OrHigh(c) || " \"<>`".indexOf(c) >= 0);
  }

  private static boolean userinfoChar(int c) {
    return !(c0OrHigh(c) || " \"#<>?`{}/:;=@[\\]^|".indexOf(c) >= 0);
  }

  /**
   * The text's UTF-8 (a lone surrogate as U+FFFD), each byte {@code keep} refuses as {@code %XX}.
   */
  private static String encode(String text, Keep keep) {
    StringBuilder b = new StringBuilder(text.length());
    for (byte x : Js.utf8(text)) {
      int c = x & 0xff;
      if (keep.keep(c)) {
        b.append((char) c);
      } else {
        b.append('%').append(Character.toUpperCase(Character.forDigit(c >> 4, 16)));
        b.append(Character.toUpperCase(Character.forDigit(c & 15, 16)));
      }
    }
    return b.toString();
  }

  /** {@code %XX} decoded, bytes as they are (the text's own as UTF-8). */
  public static byte[] percentDecodeBytes(String text) {
    byte[] in = Js.utf8(text);
    ByteArrayOutputStream out = new ByteArrayOutputStream(in.length);
    for (int i = 0; i < in.length; i++) {
      if (in[i] == '%' && i + 2 < in.length) {
        int h = Character.digit(in[i + 1], 16);
        int l = Character.digit(in[i + 2], 16);
        if (h >= 0 && l >= 0) {
          out.write(h << 4 | l);
          i += 2;
          continue;
        }
      }
      out.write(in[i]);
    }
    return out.toByteArray();
  }
}
