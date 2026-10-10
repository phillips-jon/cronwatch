package dev.cronwatch.internal.js;

import dev.cronwatch.json.JsObject;
import java.math.BigDecimal;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CharsetEncoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * What the port needs of JavaScript's own behaviour, so that every value the SDK writes, compares,
 * or counts is written, compared, and counted the same way here: numbers as {@code
 * Number.prototype.toString} prints them, the characters {@code \s} matches and {@code trim}
 * removes, {@code Date}'s calendar arithmetic and {@code toISOString}, and strings written out as
 * UTF-8 with a lone surrogate as U+FFFD.
 *
 * <p>Java strings are UTF-16, as JavaScript's are, so {@code length()}, {@code substring}, and
 * {@code charAt} count and cut as the SDK does.
 */
public final class Js {
  private Js() {}

  /** 2^53 - 1, the largest integer JavaScript holds exactly. */
  public static final long MAX_SAFE_INTEGER = 9_007_199_254_740_991L;

  /** How deep {@code Json} lets arrays and objects nest, reading or writing. */
  public static final int JSON_MAX_DEPTH = 256;

  /** The first millisecond written as a date: 0001-01-01T00:00:00.000Z. */
  public static final long FIRST_DATE_MS = -62_135_596_800_000L;

  /** The last millisecond written as a date: 9999-12-31T23:59:59.999Z. */
  public static final long LAST_DATE_MS = 253_402_300_799_999L;

  // ---- numbers

  /**
   * {@code String(n)}: the shortest digits that read back as {@code n}, in plain notation from 1e-7
   * up to 1e21 and exponential notation outside it, as {@code Number.prototype.toString} writes
   * them. The digits come from {@link Double#toString}, the shortest since Java 19.
   */
  public static String formatNumber(double n) {
    if (Double.isNaN(n)) {
      return "NaN";
    }
    if (Double.isInfinite(n)) {
      return n > 0 ? "Infinity" : "-Infinity";
    }
    if (n == 0) {
      return "0";
    }
    BigDecimal d = shortest(Math.abs(n));
    String digits = d.unscaledValue().toString();
    int k = digits.length();
    // ECMAScript's n: the value is d1...dk * 10^(point - k).
    long point = (long) k - d.scale();
    StringBuilder b = new StringBuilder(n < 0 ? "-" : "");
    if (k <= point && point <= 21) {
      b.append(digits);
      b.append("0".repeat((int) (point - k)));
    } else if (0 < point && point <= 21) {
      b.append(digits, 0, (int) point).append('.').append(digits, (int) point, k);
    } else if (-6 < point && point <= 0) {
      b.append("0.").append("0".repeat((int) -point)).append(digits);
    } else {
      b.append(digits.charAt(0));
      if (k > 1) {
        b.append('.').append(digits, 1, k);
      }
      b.append('e');
      if (point >= 1) {
        b.append('+');
      }
      b.append(point - 1);
    }
    return b.toString();
  }

  /**
   * The shortest decimal that reads back as {@code x} (positive and finite), the closest to it of
   * those. {@link Double#toString} gives that, except that it writes at least two digits: where one
   * digit would do, it gives the two-digit decimal closest to the value ({@code 4.9E-324} for
   * JavaScript's {@code 5e-324}), so the one-digit decimals around it are tried first.
   */
  public static BigDecimal shortest(double x) {
    BigDecimal d = new BigDecimal(Double.toString(x)).stripTrailingZeros();
    if (d.precision() != 2) {
      return d;
    }
    BigDecimal exact = new BigDecimal(x);
    BigDecimal unit = BigDecimal.ONE.scaleByPowerOfTen(-d.scale() + 1);
    BigDecimal low = d.divide(unit).setScale(0, java.math.RoundingMode.FLOOR).multiply(unit);
    BigDecimal best = null;
    for (BigDecimal c : new BigDecimal[] {low, low.add(unit)}) {
      if (c.signum() > 0 && Double.parseDouble(c.toString()) == x) {
        if (best == null || c.subtract(exact).abs().compareTo(best.subtract(exact).abs()) < 0) {
          best = c;
        }
      }
    }
    return best == null ? d : best.stripTrailingZeros();
  }

  /**
   * A {@code long} as JavaScript prints the number it would hold: its digits within 2^53, else the
   * double nearest to it.
   */
  public static String formatLong(long n) {
    if (n <= MAX_SAFE_INTEGER && n >= -MAX_SAFE_INTEGER) {
      return Long.toString(n);
    }
    return formatNumber((double) n);
  }

  /** {@code Number.isInteger}. */
  public static boolean isInteger(double n) {
    return Double.isFinite(n) && n == Math.rint(n);
  }

  /**
   * A JavaScript number as a {@code long}, as the ports hold times: truncated, NaN as 0, and held
   * at the ends of the range (Java's cast does all three).
   */
  public static long toLong(double n) {
    return (long) n;
  }

  /** {@code Math.round}: halves round up, toward positive infinity. */
  public static double round(double n) {
    if (!Double.isFinite(n)) {
      return n;
    }
    double f = Math.floor(n);
    return n - f >= 0.5 ? f + 1 : f;
  }

  // ---- text

  /**
   * Whether JavaScript's {@code \s} matches {@code c}: WhiteSpace and LineTerminator, which is also
   * what {@code String.prototype.trim} removes.
   */
  public static boolean isSpace(char c) {
    return switch (c) {
      case '\t', '\n', '\u000b', '\f', '\r', ' ', ' ', ' ', ' ', ' ', ' ', ' ', '　', '﻿' -> true;
      default -> c >= ' ' && c <= ' ';
    };
  }

  /** {@code String.prototype.trim}. */
  public static String trim(String s) {
    int start = 0;
    int end = s.length();
    while (start < end && isSpace(s.charAt(start))) {
      start++;
    }
    while (end > start && isSpace(s.charAt(end - 1))) {
      end--;
    }
    return s.substring(start, end);
  }

  /**
   * Whether {@code s} is null, empty, or only whitespace as {@code String.prototype.trim} sees it:
   * a token or secret like that counts as unset, so the routes and handlers fail closed.
   */
  public static boolean isBlank(@Nullable String s) {
    return s == null || trim(s).isEmpty();
  }

  /** {@code String.prototype.trimEnd}. */
  public static String trimEnd(String s) {
    int end = s.length();
    while (end > 0 && isSpace(s.charAt(end - 1))) {
      end--;
    }
    return s.substring(0, end);
  }

  /**
   * {@code s.slice(start, end)}, with JavaScript's clamping (a negative index counts from the end).
   */
  public static String slice(String s, long start, long end) {
    long n = s.length();
    long a = start < 0 ? Math.max(start + n, 0) : Math.min(start, n);
    long z = end < 0 ? Math.max(end + n, 0) : Math.min(end, n);
    return a >= z ? "" : s.substring((int) a, (int) z);
  }

  /** {@code s.slice(-n)}: the last {@code n} code units (all of it when shorter). */
  public static String tail(String s, int n) {
    return s.length() <= n ? s : s.substring(s.length() - n);
  }

  /** {@code s.slice(0, n)}. */
  public static String head(String s, int n) {
    return s.length() <= n ? s : s.substring(0, n);
  }

  /**
   * The string as UTF-8 bytes, as JavaScript writes a string out: a lone surrogate becomes U+FFFD
   * ({@code getBytes} would write {@code ?}).
   */
  public static byte[] utf8(String s) {
    CharsetEncoder encoder =
        StandardCharsets.UTF_8
            .newEncoder()
            .onMalformedInput(CodingErrorAction.REPLACE)
            .onUnmappableCharacter(CodingErrorAction.REPLACE)
            .replaceWith(new byte[] {(byte) 0xef, (byte) 0xbf, (byte) 0xbd});
    try {
      ByteBuffer out = encoder.encode(CharBuffer.wrap(s));
      byte[] bytes = new byte[out.remaining()];
      out.get(bytes);
      return bytes;
    } catch (CharacterCodingException e) {
      throw new IllegalStateException(e);
    }
  }

  /**
   * The string as JavaScript would read it back once written out: each lone surrogate as U+FFFD.
   */
  public static String wellFormed(String s) {
    for (int i = 0; i < s.length(); i++) {
      if (Character.isSurrogate(s.charAt(i))) {
        return new String(utf8(s), StandardCharsets.UTF_8);
      }
    }
    return s;
  }

  // ---- dates

  /** The days since 1970-01-01 of a proleptic Gregorian date, month 1 to 12. */
  public static long daysFromCivil(long y, long m, long d) {
    long yy = m <= 2 ? y - 1 : y;
    long era = Math.floorDiv(yy, 400);
    long yoe = yy - era * 400;
    long mp = (m + 9) % 12;
    long doy = (153 * mp + 2) / 5 + d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
  }

  /** The date of a day counted from 1970-01-01: year, month (1 to 12), and day. */
  public static long[] civilFromDays(long z0) {
    long z = z0 + 719_468;
    long era = Math.floorDiv(z, 146_097);
    long doe = z - era * 146_097;
    long yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    long y = yoe + era * 400;
    long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long mp = (5 * doy + 2) / 153;
    long d = doy - (153 * mp + 2) / 5 + 1;
    long m = mp + 3;
    if (m > 12) {
      m -= 12;
    }
    if (m <= 2) {
      y += 1;
    }
    return new long[] {y, m, d};
  }

  /**
   * {@code Date.UTC(year, month, day, hour, minute, second, ms)} with a 0-based month, every field
   * free to overflow into the next, as {@code Date.UTC} allows.
   */
  public static long dateUtc(
      long year, long month, long day, long hour, long minute, long second, long ms) {
    long y = year + Math.floorDiv(month, 12);
    long mo = Math.floorMod(month, 12);
    long days = daysFromCivil(y, mo + 1, 1) + day - 1;
    return days * 86_400_000L + hour * 3_600_000L + minute * 60_000L + second * 1000L + ms;
  }

  /**
   * {@code new Date(ms).toISOString()}: {@code "2026-01-05T09:30:00.000Z"}, with a signed six-digit
   * year outside 0 to 9999.
   */
  public static String isoString(long ms) {
    long days = Math.floorDiv(ms, 86_400_000L);
    long rest = Math.floorMod(ms, 86_400_000L);
    long[] ymd = civilFromDays(days);
    long y = ymd[0];
    String year;
    if (y < 0) {
      year = "-" + pad(-y, 6);
    } else if (y > 9999) {
      year = "+" + pad(y, 6);
    } else {
      year = pad(y, 4);
    }
    return year
        + "-"
        + pad(ymd[1], 2)
        + "-"
        + pad(ymd[2], 2)
        + "T"
        + pad(rest / 3_600_000L, 2)
        + ":"
        + pad(rest / 60_000L % 60, 2)
        + ":"
        + pad(rest / 1000L % 60, 2)
        + "."
        + pad(rest % 1000L, 3)
        + "Z";
  }

  /** The number with leading zeros to {@code width} digits. */
  public static String pad(long n, int width) {
    String s = Long.toString(n);
    return s.length() >= width ? s : "0".repeat(width - s.length()) + s;
  }

  /** Whether {@code ms} falls in the years 1 to 9999, the times written as dates. */
  public static boolean inDateRange(long ms) {
    return ms >= FIRST_DATE_MS && ms <= LAST_DATE_MS;
  }

  /**
   * {@code "2026-01-05T09:30:00.000Z"}, or null for a time before the year 1 or after 9999, such as
   * a start read from a foreign or damaged row, which is not written as a date at all (the SDK's
   * {@code isoTime}).
   */
  public static @Nullable String isoTime(long ms) {
    return inDateRange(ms) ? isoString(ms) : null;
  }

  /**
   * The words that stand in for a time {@link #isoTime} does not write (the SDK's {@code
   * beyondDates}).
   */
  public static String beyondDates(long ms) {
    return ms > LAST_DATE_MS ? "after 9999-12-31 23:59:59 UTC" : "before 0001-01-01 00:00:00 UTC";
  }

  /** {@link #isoTime}, or the words for a time outside its years. */
  public static String isoOrWords(long ms) {
    String iso = isoTime(ms);
    return iso != null ? iso : beyondDates(ms);
  }

  /** A value's type as JavaScript's {@code typeof} names it, for messages. */
  public static String typeOf(@Nullable Object v) {
    return switch (v) {
      case null -> "null";
      case Boolean b -> "boolean";
      case Number n -> "number";
      case CharSequence s -> "string";
      default -> "object";
    };
  }

  /** A deep copy of a JSON value: nested objects and lists are copied, the rest is immutable. */
  public static @Nullable Object copyJson(@Nullable Object value) {
    if (value instanceof JsObject o) {
      return o.copy();
    }
    if (value instanceof List<?> list) {
      List<@Nullable Object> out = new ArrayList<>(list.size());
      for (Object x : list) {
        out.add(copyJson(x));
      }
      return out;
    }
    return value;
  }
}
