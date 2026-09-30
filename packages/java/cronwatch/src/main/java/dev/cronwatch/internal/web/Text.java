package dev.cronwatch.internal.web;

import dev.cronwatch.internal.evaluate.Format;
import dev.cronwatch.internal.js.Js;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import org.jspecify.annotations.Nullable;

/**
 * What the dashboard's pages need to write values the way the SDK's templates do ({@code
 * routes/escape.ts} and JavaScript itself): {@code escapeHtml}, {@code escapeName}, {@code
 * String(value)}, {@code toFixed} and {@code encodeURIComponent}, how text read from the wire is
 * decoded, and how a secret is compared. Carried over from the Rust port's {@code web/text.rs}.
 */
public final class Text {
  private Text() {}

  private static final char[] HEX = "0123456789ABCDEF".toCharArray();

  /** {@code escapeHtml}: {@code & < > " '} escaped. Every string a page shows goes through it. */
  public static String escapeHtml(String s) {
    StringBuilder out = null;
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      String rep =
          switch (c) {
            case '&' -> "&amp;";
            case '<' -> "&lt;";
            case '>' -> "&gt;";
            case '"' -> "&quot;";
            case '\'' -> "&#39;";
            default -> null;
          };
      if (rep == null) {
        if (out != null) {
          out.append(c);
        }
        continue;
      }
      if (out == null) {
        out = new StringBuilder(s.length() + 16);
        out.append(s, 0, i);
      }
      out.append(rep);
    }
    return out == null ? s : out.toString();
  }

  /** {@code escapeHtml(value ?? "")} for a JSON value: {@code String(value)}, null as nothing. */
  public static String escapeValue(@Nullable Object v) {
    return v == null ? "" : escapeHtml(Format.jsText(v));
  }

  private static boolean isSeparator(char c) {
    return c == '_' || c == ':' || c == '.' || c == '/' || c == '-';
  }

  /**
   * {@code escapeName}: a job name shown as text, with {@code <wbr>} after each run of {@code _ : .
   * / -} that something else follows, so a long name wraps at its separators. Only for text, never
   * an attribute, a URL or a title.
   */
  public static String escapeName(String s) {
    String text = escapeHtml(s);
    StringBuilder out = new StringBuilder(text.length() + 16);
    int from = 0;
    for (int i = 0; i < text.length(); i++) {
      if (isSeparator(text.charAt(i))
          && i + 1 < text.length()
          && !isSeparator(text.charAt(i + 1))) {
        out.append(text, from, i + 1).append("<wbr>");
        from = i + 1;
      }
    }
    return out.append(text, from, text.length()).toString();
  }

  /** {@code String(n)} for a number. */
  public static String num(double n) {
    return Js.formatNumber(n);
  }

  /** {@code String(n)} for a count. */
  public static String count(long n) {
    return Js.formatLong(n);
  }

  /**
   * {@code Number.prototype.toFixed}: the decimal nearest the exact value of the double, a half
   * rounded away from zero, which {@link BigDecimal} works out from the double's exact value.
   */
  public static String toFixed(double x, int digits) {
    if (!Double.isFinite(x) || Math.abs(x) >= 1e21) {
      return Js.formatNumber(x);
    }
    String text =
        new BigDecimal(Math.abs(x))
            .setScale(Math.min(digits, 100), RoundingMode.HALF_UP)
            .toPlainString();
    return x < 0 ? "-" + text : text;
  }

  /** {@code encodeURIComponent}, over the text's UTF-8 bytes. */
  public static String encodeUriComponent(String s) {
    StringBuilder out = new StringBuilder(s.length());
    for (byte b : Js.utf8(s)) {
      int c = b & 0xff;
      if (isAsciiAlphanumeric(c) || "-_.!~*'()".indexOf(c) >= 0) {
        out.append((char) c);
      } else {
        out.append('%').append(HEX[c >> 4]).append(HEX[c & 15]);
      }
    }
    return out.toString();
  }

  /** Whether {@code c} is an ASCII letter or digit. */
  public static boolean isAsciiAlphanumeric(int c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
  }

  /**
   * Compares two secrets without stopping at the first character that differs, over their UTF-16
   * code units as the SDK compares them. Only a difference in length answers early, as the SDK's
   * does.
   */
  public static boolean constantTimeEquals(String a, String b) {
    return MessageDigest.isEqual(units(a), units(b));
  }

  private static byte[] units(String s) {
    byte[] out = new byte[s.length() * 2];
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      out[2 * i] = (byte) (c >> 8);
      out[2 * i + 1] = (byte) c;
    }
    return out;
  }

  /** Whether every character of {@code s} is one byte, as text read from the wire as Latin-1 is. */
  public static boolean isLatin1(String s) {
    for (int i = 0; i < s.length(); i++) {
      if (s.charAt(i) > 0xff) {
        return false;
      }
    }
    return true;
  }

  /** The bytes of text read from the wire as Latin-1, one a character. */
  public static byte[] latin1Bytes(String s) {
    return s.getBytes(StandardCharsets.ISO_8859_1);
  }

  /**
   * Text a server read as Latin-1 (each byte a character, as the JDK's server and the servlet
   * containers read a request line and headers) as the UTF-8 it was sent in, with anything that is
   * not UTF-8 as U+FFFD. Text that already holds a character past U+00FF was decoded by the server
   * and is left as it is.
   */
  public static String utf8Lossy(String s) {
    if (!isLatin1(s)) {
      return s;
    }
    return new String(latin1Bytes(s), StandardCharsets.UTF_8);
  }

  /**
   * {@link #utf8Lossy}, but text whose bytes are not UTF-8 is left as it is rather than changed.
   */
  public static String utf8OrAsIs(String s) {
    if (!isLatin1(s)) {
      return s;
    }
    boolean ascii = true;
    for (int i = 0; i < s.length() && ascii; i++) {
      ascii = s.charAt(i) < 0x80;
    }
    if (ascii) {
      return s;
    }
    try {
      return StandardCharsets.UTF_8
          .newDecoder()
          .onMalformedInput(CodingErrorAction.REPORT)
          .onUnmappableCharacter(CodingErrorAction.REPORT)
          .decode(ByteBuffer.wrap(latin1Bytes(s)))
          .toString();
    } catch (CharacterCodingException e) {
      return s;
    }
  }

  /** Bytes as UTF-8, or null when they are not. */
  public static @Nullable String strictUtf8(byte[] bytes) {
    try {
      return StandardCharsets.UTF_8
          .newDecoder()
          .onMalformedInput(CodingErrorAction.REPORT)
          .onUnmappableCharacter(CodingErrorAction.REPORT)
          .decode(ByteBuffer.wrap(bytes))
          .toString();
    } catch (CharacterCodingException e) {
      return null;
    }
  }

  /** {@code s.replace(from, to)} for a string pattern: the first occurrence only. */
  public static String replaceFirst(String s, String from, String to) {
    int i = s.indexOf(from);
    return i < 0 ? s : s.substring(0, i) + to + s.substring(i + from.length());
  }
}
