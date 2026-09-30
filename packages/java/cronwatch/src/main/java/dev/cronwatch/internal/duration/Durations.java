package dev.cronwatch.internal.duration;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import java.util.List;
import java.util.Locale;
import org.jspecify.annotations.Nullable;

/**
 * The SDK's {@code duration.ts}: durations ("15m", "1h30m", a number of milliseconds) read and
 * written as the SDK does. Refusals are {@link IllegalArgumentException}s with the SDK's message,
 * word for word; an empty label is "duration".
 */
public final class Durations {
  private Durations() {}

  /**
   * The longest duration text read, in characters (code points). No real duration comes near it,
   * and the SDK's pattern is quadratic on a long run of digits, so a longer text is refused before
   * it is read.
   */
  public static final int MAX_LENGTH = 64;

  /** How much of a refused, overlong text its error quotes. */
  private static final int QUOTED = 32;

  private static String label(String label) {
    return label.isEmpty() ? "duration" : label;
  }

  /**
   * {@code parseDuration} over a JSON value, as a stored definition holds one: a string is read as
   * text, a number as milliseconds, and anything else is refused, quoting it as {@code String()}
   * would.
   */
  public static double parseValue(@Nullable Object value, String label) {
    if (value instanceof String s) {
      return parse(s, label);
    }
    if (value instanceof Number n) {
      return parse(n.doubleValue(), label);
    }
    throw new IllegalArgumentException(notADuration(label(label), jsString(value)));
  }

  /** {@code String(value)} for a JSON value, as the SDK's message would quote it. */
  private static String jsString(@Nullable Object v) {
    if (v == null) {
      return "null";
    }
    if (v instanceof Boolean b) {
      return b.toString();
    }
    if (v instanceof Number n) {
      return Js.formatNumber(n.doubleValue());
    }
    if (v instanceof String s) {
      return s;
    }
    if (v instanceof List<?> list) {
      StringBuilder b = new StringBuilder();
      for (int i = 0; i < list.size(); i++) {
        if (i > 0) {
          b.append(',');
        }
        Object e = list.get(i);
        if (e != null) {
          b.append(jsString(e));
        }
      }
      return b.toString();
    }
    if (v instanceof JsObject) {
      return "[object Object]";
    }
    return String.valueOf(v);
  }

  /** {@code parseDuration} of a number of milliseconds: any finite number from 0 up. */
  public static double parse(double ms, String label) {
    if (!Double.isFinite(ms) || ms < 0) {
      throw new IllegalArgumentException(
          label(label) + " must be a non-negative number of milliseconds");
    }
    return ms;
  }

  /**
   * {@code parseDuration} of text: trimmed and lowercased, every {@code
   * /(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)/g} match summed, the whole refused unless the matches, spaces
   * aside, are all of it, and the sum rounded as {@code Math.round} rounds.
   */
  public static double parse(String value, String label) {
    String name = label(label);
    if (value.length() > MAX_LENGTH) {
      tooLong(value, name);
    }
    String text = Js.trim(value).toLowerCase(Locale.ROOT);
    if (text.isEmpty()) {
      throw new IllegalArgumentException(name + " is empty");
    }
    double total = 0;
    StringBuilder consumed = new StringBuilder();
    int i = 0;
    while (i < text.length()) {
      Match m = matchAt(text, i);
      if (m == null) {
        // The global regular expression moves on one code unit.
        i++;
        continue;
      }
      total += m.ms();
      consumed.append(text, i, m.end());
      i = m.end();
    }
    if (!stripSpaces(consumed).equals(stripSpaces(text))) {
      throw new IllegalArgumentException(notADuration(name, value));
    }
    return Js.round(total);
  }

  /** A match of the duration pattern: its milliseconds and where it ends. */
  private record Match(double ms, int end) {}

  /** Tries {@code (\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)} at {@code i}: the match, or null. */
  private static @Nullable Match matchAt(String text, int i) {
    int n = text.length();
    int j = i;
    while (j < n && isDigit(text.charAt(j))) {
      j++;
    }
    if (j == i) {
      return null;
    }
    int end = j;
    if (j + 1 < n && text.charAt(j) == '.' && isDigit(text.charAt(j + 1))) {
      end = j + 1;
      while (end < n && isDigit(text.charAt(end))) {
        end++;
      }
    }
    int k = end;
    while (k < n && Js.isSpace(text.charAt(k))) {
      k++;
    }
    double unit;
    int unitEnd;
    if (text.startsWith("ms", k)) {
      unit = 1;
      unitEnd = k + 2;
    } else if (k < n) {
      unit =
          switch (text.charAt(k)) {
            case 's' -> 1000;
            case 'm' -> 60_000;
            case 'h' -> 3_600_000;
            case 'd' -> 86_400_000;
            case 'w' -> 604_800_000;
            default -> -1;
          };
      unitEnd = k + 1;
    } else {
      return null;
    }
    if (unit < 0) {
      return null;
    }
    return new Match(Double.parseDouble(text.substring(i, end)) * unit, unitEnd);
  }

  private static boolean isDigit(char c) {
    return c >= '0' && c <= '9';
  }

  private static String stripSpaces(CharSequence s) {
    StringBuilder b = new StringBuilder(s.length());
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      if (!Js.isSpace(c)) {
        b.append(c);
      }
    }
    return b.toString();
  }

  private static String notADuration(String label, String value) {
    return label + " \"" + value + "\" is not a duration like \"15m\", \"1h30m\" or \"90s\"";
  }

  /** Refuses a value over {@link #MAX_LENGTH} characters, quoting its first {@link #QUOTED}. */
  private static void tooLong(String value, String label) {
    int count = 0;
    int head = 0;
    for (int i = 0; i < value.length(); i += Character.charCount(value.codePointAt(i))) {
      if (count == QUOTED) {
        head = i;
      }
      if (++count > MAX_LENGTH) {
        throw new IllegalArgumentException(
            label
                + " \""
                + value.substring(0, head)
                + "...\" is too long for a duration (more than "
                + MAX_LENGTH
                + " characters)");
      }
    }
  }

  /** {@code formatDuration}: 90000 is "1m 30s", at most two units; "?" when not finite. */
  public static String format(double ms) {
    if (!Double.isFinite(ms)) {
      return "?";
    }
    if (ms < 1000) {
      return Js.formatNumber(Js.round(ms)) + "ms";
    }
    StringBuilder b = new StringBuilder();
    int parts = 0;
    double rest = Js.round(ms / 1000);
    String[] units = {"d", "h", "m", "s"};
    double[] sizes = {86_400, 3_600, 60, 1};
    for (int u = 0; u < units.length; u++) {
      if (rest >= sizes[u]) {
        double n = Math.floor(rest / sizes[u]);
        rest -= n * sizes[u];
        if (parts > 0) {
          b.append(' ');
        }
        b.append(Js.formatNumber(n)).append(units[u]);
        parts++;
      }
      if (parts == 2) {
        break;
      }
    }
    return parts == 0 ? "0s" : b.toString();
  }

  /** {@code formatRelative}: "5m ago", "in 2h", or "now" within five seconds of {@code now}. */
  public static String formatRelative(long at, long now) {
    long diff;
    try {
      diff = Math.subtractExact(at, now);
    } catch (ArithmeticException e) {
      diff = at < now ? Long.MIN_VALUE : Long.MAX_VALUE;
    }
    long abs = diff == Long.MIN_VALUE ? Long.MAX_VALUE : Math.abs(diff);
    if (abs < 5_000) {
      return "now";
    }
    String text = format((double) abs);
    return diff < 0 ? text + " ago" : "in " + text;
  }
}
