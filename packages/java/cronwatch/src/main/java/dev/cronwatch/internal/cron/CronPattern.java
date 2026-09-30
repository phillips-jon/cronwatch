package dev.cronwatch.internal.cron;

import dev.cronwatch.internal.js.Js;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import org.jspecify.annotations.Nullable;

/**
 * Croner's CronPattern: the fields of an expression as tables of what matches, read with croner's
 * checks and its messages word for word.
 */
final class CronPattern {
  // Croner's bits for "the nth weekday of the month"; 32 is the last one, 63 any.
  static final int[] NTH_BITS = {1, 2, 4, 8, 16};
  static final int LAST_BIT = 32;
  static final int ANY_BITS = 63;

  private static final String[] MONTH_NAMES = {
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
  };
  private static final String[] DAY_NAMES = {"sun", "mon", "tue", "wed", "thu", "fri", "sat"};

  /** The fields of a pattern, by croner's names. */
  enum Kind {
    SECOND("second", 60),
    MINUTE("minute", 60),
    HOUR("hour", 24),
    DAY("day", 31),
    MONTH("month", 12),
    DAY_OF_WEEK("dayOfWeek", 7),
    YEAR("year", 10_000),
    NEAREST_WEEKDAYS("nearestWeekdays", 31);

    final String label;
    final int size;

    Kind(String label, int size) {
      this.label = label;
      this.size = size;
    }
  }

  /**
   * What a field's table is set to: 1 (a match), croner's 63 for any nth weekday, or the text of a
   * day-of-week modifier ("2" of "1#2", "L").
   */
  private record Val(int n, @Nullable String s) {
    static Val of(int n) {
      return new Val(n, null);
    }
  }

  private String pattern;
  final int[] second = new int[60];
  final int[] minute = new int[60];
  final int[] hour = new int[24];
  final int[] day = new int[31];
  final int[] month = new int[12];
  final int[] dayOfWeek = new int[7];
  final int[] nearestWeekdays = new int[31];
  // The years that match: every one ("*"), or the table croner keeps, made only when the field
  // names years.
  private boolean everyYear;
  private boolean @Nullable [] years;

  boolean lastDayOfMonth;
  boolean lastWeekday;
  boolean starDom;
  boolean starDow;
  boolean starYear;
  boolean useAndLogic;

  /** Reads an expression as croner's CronPattern does, or throws croner's message. */
  CronPattern(String text) {
    this.pattern = text;
    parse();
  }

  int[] table(Kind k) {
    return switch (k) {
      case SECOND -> second;
      case MINUTE -> minute;
      case HOUR -> hour;
      case DAY -> day;
      case MONTH -> month;
      case DAY_OF_WEEK -> dayOfWeek;
      case NEAREST_WEEKDAYS -> nearestWeekdays;
      case YEAR -> new int[0];
    };
  }

  /** Croner's {@code year[y]}: whether year {@code y} matches (none outside the table). */
  boolean hasYear(long y) {
    if (y < 0 || y >= 10_000) {
      return false;
    }
    boolean[] t = years;
    return everyYear || (t != null && t[(int) y]);
  }

  private static CronException fail(String message) {
    return new CronException(message);
  }

  private static String upper(String s) {
    return s.toUpperCase(Locale.ROOT);
  }

  private void parse() {
    if (pattern.indexOf('@') >= 0) {
      pattern = Js.trim(nicknames(pattern));
    }
    List<String> parts = new ArrayList<>();
    StringBuilder cur = new StringBuilder();
    for (int i = 0; i < pattern.length(); i++) {
      char c = pattern.charAt(i);
      if (Js.isSpace(c)) {
        if (cur.length() > 0) {
          parts.add(cur.toString());
          cur.setLength(0);
        }
      } else {
        cur.append(c);
      }
    }
    if (cur.length() > 0) {
      parts.add(cur.toString());
    }
    if (parts.isEmpty()) {
      parts.add("");
    }
    if (parts.size() < 5 || parts.size() > 7) {
      throw fail(
          "CronPattern: invalid configuration format ('"
              + pattern
              + "'), exactly five, six, or seven space separated parts are required.");
    }
    if (parts.size() == 5) {
      parts.add(0, "0");
    }
    if (parts.size() == 6) {
      parts.add("*");
    }
    if (upper(parts.get(3)).equals("LW")) {
      lastWeekday = true;
      parts.set(3, "");
    } else if (upper(parts.get(3)).contains("L")) {
      parts.set(3, replaceFold(parts.get(3), "l", ""));
      lastDayOfMonth = true;
    }
    if (parts.get(3).equals("*")) {
      starDom = true;
    }
    if (parts.get(6).equals("*")) {
      starYear = true;
    }
    if (parts.get(4).length() >= 3) {
      for (int i = 0; i < MONTH_NAMES.length; i++) {
        parts.set(4, replaceFold(parts.get(4), MONTH_NAMES[i], Integer.toString(i + 1)));
      }
    }
    if (parts.get(5).length() >= 3) {
      parts.set(5, replaceFold(parts.get(5), "-sun", "-7"));
      for (int i = 0; i < DAY_NAMES.length; i++) {
        parts.set(5, replaceFold(parts.get(5), DAY_NAMES[i], Integer.toString(i)));
      }
    }
    if (parts.get(5).startsWith("+")) {
      useAndLogic = true;
      parts.set(5, parts.get(5).substring(1));
      if (parts.get(5).isEmpty()) {
        throw fail("CronPattern: Day-of-week field cannot be empty after '+' modifier.");
      }
    }
    if (parts.get(5).equals("*")) {
      starDow = true;
    }
    if (pattern.indexOf('?') >= 0) {
      parts.replaceAll(p -> p.replace('?', '*'));
    }
    illegalCharacters(parts);
    Kind[] kinds = {
      Kind.SECOND, Kind.MINUTE, Kind.HOUR, Kind.DAY, Kind.MONTH, Kind.DAY_OF_WEEK, Kind.YEAR
    };
    double[] offsets = {0, 0, 0, -1, -1, 0, 0};
    for (int i = 0; i < kinds.length; i++) {
      Val v = kinds[i] == Kind.DAY_OF_WEEK ? Val.of(ANY_BITS) : Val.of(1);
      part(kinds[i], parts.get(i), offsets[i], v);
    }
  }

  private void part(Kind k, String text, double offset, Val v) {
    boolean lastDom = k == Kind.DAY && lastDayOfMonth;
    boolean lastWd = k == Kind.DAY && lastWeekday;
    if (text.isEmpty() && !lastDom && !lastWd) {
      throw fail(
          "CronPattern: configuration entry "
              + k.label
              + " ("
              + text
              + ") is empty, check for trailing spaces.");
    }
    if (text.equals("*")) {
      if (k == Kind.YEAR) {
        everyYear = true;
        return;
      }
      Arrays.fill(table(k), v.n());
      return;
    }
    String[] items = text.split(",", -1);
    if (items.length > 1) {
      for (String item : items) {
        part(k, item, offset, v);
      }
    } else if (text.contains("-") && text.contains("/")) {
      rangeWithStepping(text, k, offset, v);
    } else if (text.contains("-")) {
      rangeOf(text, k, offset, v);
    } else if (text.contains("/")) {
      stepping(text, k, v);
    } else if (!text.isEmpty()) {
      number(text, k, offset, v);
    }
  }

  private void number(String text, Kind k, double offset, Val v) {
    String[] nth = extractNth(text, k);
    boolean nearest = upper(text).contains("W");
    if (k != Kind.DAY && nearest) {
      throw fail("CronPattern: Nearest weekday modifier (W) only allowed in day-of-month.");
    }
    Kind kind = nearest ? Kind.NEAREST_WEEKDAYS : k;
    double n = parseInt(nth[0]);
    if (Double.isNaN(n)) {
      throw fail("CronPattern: " + kind.label + " is not a number: '" + text + "'");
    }
    set(kind, n + offset, modifierOr(nth[1], v));
  }

  private void set(Kind k, double at0, Val v) {
    double at = at0;
    if (k == Kind.DAY_OF_WEEK) {
      if (at == 7) {
        at = 0;
      }
      if (!(at >= 0 && at <= 6)) {
        throw fail("CronPattern: Invalid value for dayOfWeek: " + Js.formatNumber(at));
      }
      nthWeekday((int) at, v);
      return;
    }
    if (k == Kind.YEAR) {
      if (!(at >= 1 && at < 10_000)) {
        throw fail(
            "CronPattern: Invalid value for "
                + k.label
                + ": "
                + Js.formatNumber(at)
                + " (supported range: 1-9999)");
      }
      boolean[] t = years;
      if (t == null) {
        t = new boolean[10_000];
        years = t;
      }
      t[(int) at] = v.n() != 0 || v.s() != null;
      return;
    }
    if (!(at >= 0 && at < k.size)) {
      throw fail("CronPattern: Invalid value for " + k.label + ": " + Js.formatNumber(at));
    }
    table(k)[(int) at] = v.n();
  }

  private void rangeWithStepping(String text, Kind k, double offset, Val v) {
    if (upper(text).contains("W")) {
      throw fail("CronPattern: Syntax error, W is not allowed in ranges with stepping.");
    }
    String[] nth = extractNth(text, k);
    String base = nth[0];
    // /^(\d+)-(\d+)\/(\d+)$/
    String illegal = "CronPattern: Syntax error, illegal range with stepping: '" + text + "'";
    int slash = base.indexOf('/');
    if (slash < 0) {
      throw fail(illegal);
    }
    String range = base.substring(0, slash);
    String stepText = base.substring(slash + 1);
    int dash = range.indexOf('-');
    if (dash < 0) {
      throw fail(illegal);
    }
    String lowText = range.substring(0, dash);
    String highText = range.substring(dash + 1);
    if (!digitsOnly(lowText) || !digitsOnly(highText) || !digitsOnly(stepText)) {
      throw fail(illegal);
    }
    double low = Double.parseDouble(lowText) + offset;
    double high = Double.parseDouble(highText) + offset;
    double step = Double.parseDouble(stepText);
    validateRange(low, high, step, k.size, text);
    Val val = modifierOr(nth[1], v);
    for (double at = low; at <= high; at += step) {
      set(k, at, val);
    }
  }

  private void rangeOf(String text, Kind k, double offset, Val v) {
    if (upper(text).contains("W")) {
      throw fail("CronPattern: Syntax error, W is not allowed in a range.");
    }
    String[] nth = extractNth(text, k);
    String[] bounds = nth[0].split("-", -1);
    if (bounds.length != 2) {
      throw fail("CronPattern: Syntax error, illegal range: '" + text + "'");
    }
    double low = parseInt(bounds[0]);
    double high = parseInt(bounds[1]);
    if (Double.isNaN(low)) {
      throw fail("CronPattern: Syntax error, illegal lower range (NaN)");
    }
    if (Double.isNaN(high)) {
      throw fail("CronPattern: Syntax error, illegal upper range (NaN)");
    }
    low += offset;
    high += offset;
    validateRange(low, high, Double.NaN, k.size, text);
    Val val = modifierOr(nth[1], v);
    for (double at = low; at <= high; at += 1) {
      set(k, at, val);
    }
  }

  private void stepping(String text, Kind k, Val v) {
    if (upper(text).contains("W")) {
      throw fail("CronPattern: Syntax error, W is not allowed in parts with stepping.");
    }
    String[] nth = extractNth(text, k);
    String[] parts = nth[0].split("/", -1);
    if (parts.length != 2) {
      throw fail("CronPattern: Syntax error, illegal stepping: '" + text + "'");
    }
    if (parts[0].isEmpty()) {
      throw fail(
          "CronPattern: Syntax error, stepping with missing prefix ('"
              + text
              + "') is not allowed. Use wildcard (*/step) or range (min-max/step) instead.");
    }
    if (!parts[0].equals("*")) {
      throw fail(
          "CronPattern: Syntax error, stepping with numeric prefix ('"
              + text
              + "') is not allowed. Use wildcard (*/step) or range (min-max/step) instead.");
    }
    double step = parseInt(parts[1]);
    if (Double.isNaN(step)) {
      throw fail("CronPattern: Syntax error, illegal stepping: (NaN)");
    }
    int size = k.size;
    validateRange(0, size - 1, step, size, text);
    if (step > 0) {
      Val val = modifierOr(nth[1], v);
      for (double at = 0; at < size; at += step) {
        set(k, at, val);
      }
    }
  }

  private void nthWeekday(int d, Val nth) {
    String s = nth.s();
    if (s != null) {
      if (upper(s).equals("L")) {
        dayOfWeek[d] |= LAST_BIT;
        return;
      }
    } else if (nth.n() == ANY_BITS) {
      dayOfWeek[d] = ANY_BITS;
      return;
    }
    double n = s != null ? toNumber(s) : nth.n();
    if (n < 6 && n > 0) {
      double index = n - 1;
      if (index == Math.floor(index) && index >= 0 && index < NTH_BITS.length) {
        dayOfWeek[d] |= NTH_BITS[(int) index];
      }
      return;
    }
    if (s != null) {
      throw fail(
          "CronPattern: nth weekday out of range, should be 1-5 or L. Value: "
              + s
              + ", Type: string");
    }
    throw fail(
        "CronPattern: nth weekday out of range, should be 1-5 or L. Value: "
            + Js.formatNumber(n)
            + ", Type: number");
  }

  /** Croner's {@code nth[1] || value}: the modifier when there is one, else the field's value. */
  private static Val modifierOr(@Nullable String nth, Val v) {
    return nth != null && !nth.isEmpty() ? new Val(0, nth) : v;
  }

  private static String nicknames(String pattern) {
    return switch (Js.trim(pattern).toLowerCase(Locale.ROOT)) {
      case "@yearly", "@annually" -> "0 0 1 1 *";
      case "@monthly" -> "0 0 1 * *";
      case "@weekly" -> "0 0 * * 0";
      case "@daily", "@midnight" -> "0 0 * * *";
      case "@hourly" -> "0 * * * *";
      case "@reboot" ->
          throw fail(
              "CronPattern: @reboot is not supported in this environment. This is an event-based"
                  + " trigger that requires system startup detection.");
      default -> pattern;
    };
  }

  /**
   * Croner's check of each field's characters: digits, "/*,-" everywhere, W and L in the day of the
   * month, # and L in the day of the week.
   */
  private static void illegalCharacters(List<String> parts) {
    for (int i = 0; i < parts.size(); i++) {
      String part = parts.get(i);
      String extra =
          switch (i) {
            case 3 -> "WwLl";
            case 5 -> "#Ll";
            default -> "";
          };
      for (int j = 0; j < part.length(); j++) {
        char c = part.charAt(j);
        if ("/*0123456789,-".indexOf(c) < 0 && extra.indexOf(c) < 0) {
          throw fail(
              "CronPattern: configuration entry "
                  + i
                  + " ("
                  + part
                  + ") contains illegal characters.");
        }
      }
    }
  }

  /** Croner's range checks; {@code step} is NaN for a range without one. */
  private static void validateRange(double low, double high, double step, int size, String text) {
    if (low > high) {
      throw fail("CronPattern: From value is larger than to value: '" + text + "'");
    }
    if (!Double.isNaN(step)) {
      if (step == 0) {
        throw fail("CronPattern: Syntax error, illegal stepping: 0");
      }
      if (step > size) {
        throw fail(
            "CronPattern: Syntax error, steps cannot be greater than maximum value of part ("
                + size
                + ")");
      }
    }
  }

  /** Whether {@code s} is one or more ASCII digits. */
  private static boolean digitsOnly(String s) {
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

  /**
   * Splits a day-of-week modifier off: "1#2" is 1 and "2", "5L" is 5 and "L". Anywhere else a
   * modifier is an error. The second element is null when there is none.
   */
  private static @Nullable String[] extractNth(String text, Kind k) {
    int hash = text.indexOf('#');
    if (hash >= 0) {
      if (k != Kind.DAY_OF_WEEK) {
        throw fail("CronPattern: nth (#) only allowed in day-of-week field");
      }
      int next = text.indexOf('#', hash + 1);
      String second = next < 0 ? text.substring(hash + 1) : text.substring(hash + 1, next);
      return new String[] {text.substring(0, hash), second};
    }
    if (upper(text).endsWith("L")) {
      if (k != Kind.DAY_OF_WEEK) {
        throw fail(
            "CronPattern: L modifier only allowed in day-of-week field (use L alone for"
                + " day-of-month)");
      }
      return new String[] {text.substring(0, text.length() - 1), "L"};
    }
    return new String[] {text, null};
  }

  /**
   * Replaces every occurrence of an ASCII word, matched without regard to ASCII case (a JavaScript
   * /gi regular expression).
   */
  private static String replaceFold(String text, String word, String with) {
    StringBuilder b = new StringBuilder(text.length());
    int i = 0;
    while (i < text.length()) {
      if (text.regionMatches(true, i, word, 0, word.length()) && asciiFold(text, i, word)) {
        b.append(with);
        i += word.length();
        continue;
      }
      b.append(text.charAt(i));
      i++;
    }
    return b.toString();
  }

  /** Whether the match at {@code i} is ASCII letters only, as /i without the u flag folds them. */
  private static boolean asciiFold(String text, int i, String word) {
    for (int j = 0; j < word.length(); j++) {
      char c = text.charAt(i + j);
      char w = word.charAt(j);
      if (c != w && (c > 0x7f || Character.toLowerCase(c) != w)) {
        return false;
      }
    }
    return true;
  }

  /** {@code parseInt(text, 10)}: NaN when no digits lead. */
  static double parseInt(String text) {
    int i = 0;
    int n = text.length();
    while (i < n && Js.isSpace(text.charAt(i))) {
      i++;
    }
    int start = i;
    if (i < n && (text.charAt(i) == '+' || text.charAt(i) == '-')) {
      i++;
    }
    int j = i;
    while (j < n && text.charAt(j) >= '0' && text.charAt(j) <= '9') {
      j++;
    }
    if (j == i) {
      return Double.NaN;
    }
    return Double.parseDouble(text.substring(start, j));
  }

  /**
   * JavaScript's {@code Number(text)} for the characters a field may hold: NaN when it is not one.
   */
  static double toNumber(String text) {
    String s = Js.trim(text);
    if (s.isEmpty()) {
      return 0;
    }
    int i = 0;
    if (s.charAt(0) == '+' || s.charAt(0) == '-') {
      i++;
    }
    int digits = 0;
    int frac = 0;
    boolean dot = false;
    while (i < s.length()) {
      char c = s.charAt(i);
      if (c >= '0' && c <= '9') {
        if (dot) {
          frac++;
        } else {
          digits++;
        }
      } else if (c == '.' && !dot) {
        dot = true;
      } else if ((c == 'e' || c == 'E') && digits + frac > 0) {
        int r = i + 1;
        if (r < s.length() && (s.charAt(r) == '+' || s.charAt(r) == '-')) {
          r++;
        }
        if (r >= s.length()) {
          return Double.NaN;
        }
        for (int q = r; q < s.length(); q++) {
          if (s.charAt(q) < '0' || s.charAt(q) > '9') {
            return Double.NaN;
          }
        }
        break;
      } else {
        return Double.NaN;
      }
      i++;
    }
    if (digits + frac == 0) {
      return Double.NaN;
    }
    return Double.parseDouble(s);
  }
}
