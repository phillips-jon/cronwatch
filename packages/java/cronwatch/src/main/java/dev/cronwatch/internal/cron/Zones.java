package dev.cronwatch.internal.cron;

import dev.cronwatch.internal.js.Js;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.zone.ZoneRules;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * Zones are java.time's, from the IANA database the JDK carries, named as {@code Intl} names them:
 * without regard to case, so "america/new_york" is New York. A fixed offset ("+05:30", "-0800",
 * "+05") is a zone too, since {@code Intl} and croner both take one.
 */
public final class Zones {
  private Zones() {}

  /** Every IANA name the JDK knows, by its lowercase spelling. */
  private static final Map<String, String> NAMES = names();

  private static Map<String, String> names() {
    Map<String, String> out = new HashMap<>();
    for (String id : ZoneId.getAvailableZoneIds()) {
      out.put(id.toLowerCase(Locale.ROOT), id);
    }
    return out;
  }

  /**
   * The zone an IANA name (or a fixed offset) names, matched without regard to case; "" is the
   * JVM's own zone. Null when there is no such zone.
   */
  public static @Nullable ZoneId find(String name) {
    if (name.isEmpty()) {
      return ZoneId.systemDefault();
    }
    ZoneOffset fixed = fixedOffset(name);
    if (fixed != null) {
      return fixed;
    }
    String id = NAMES.get(name.toLowerCase(Locale.ROOT));
    return id == null ? null : ZoneId.of(id);
  }

  /** Reads "+HH", "+HHMM" or "+HH:MM" (or "-"), as {@code Intl} reads an offset time zone. */
  private static @Nullable ZoneOffset fixedOffset(String name) {
    if (name.length() < 3 || (name.charAt(0) != '+' && name.charAt(0) != '-')) {
      return null;
    }
    String rest = name.substring(1);
    String hh;
    String mm;
    if (rest.length() == 2) {
      hh = rest;
      mm = "00";
    } else if (rest.length() == 4) {
      hh = rest.substring(0, 2);
      mm = rest.substring(2);
    } else if (rest.length() == 5 && rest.charAt(2) == ':') {
      hh = rest.substring(0, 2);
      mm = rest.substring(3);
    } else {
      return null;
    }
    String digits = hh + mm;
    for (int i = 0; i < digits.length(); i++) {
      if (digits.charAt(i) < '0' || digits.charAt(i) > '9') {
        return null;
      }
    }
    int h = Integer.parseInt(hh);
    int m = Integer.parseInt(mm);
    if (h > 23 || m > 59) {
      return null;
    }
    int sec = (h * 60 + m) * 60;
    return ZoneOffset.ofTotalSeconds(name.charAt(0) == '-' ? -sec : sec);
  }

  private static final long MIN_SECOND = Instant.MIN.getEpochSecond();
  private static final long MAX_SECOND = Instant.MAX.getEpochSecond();

  /** The seconds a zone's wall clock is ahead of UTC at epoch second {@code sec}. */
  public static long offset(long sec, ZoneRules rules) {
    long at = Math.max(MIN_SECOND, Math.min(MAX_SECOND, sec));
    return rules.getOffset(Instant.ofEpochSecond(at)).getTotalSeconds();
  }

  /** The wall clock at an epoch second: year, month (1 to 12), day, hour, minute, second. */
  static long[] wallAt(long sec, ZoneRules rules) {
    long local = sec + offset(sec, rules);
    long days = Math.floorDiv(local, 86_400);
    long rest = local - days * 86_400;
    long[] ymd = Js.civilFromDays(days);
    return new long[] {ymd[0], ymd[1], ymd[2], rest / 3600, rest % 3600 / 60, rest % 60};
  }

  /** A wall-clock time read as if it were UTC, in epoch seconds (croner's {@code T()}). */
  private static long civilSeconds(long[] w) {
    return Math.floorDiv(Js.dateUtc(w[0], w[1] - 1, w[2], w[3], w[4], w[5], 0), 1000);
  }

  private static boolean same(long[] a, long[] b) {
    return java.util.Arrays.equals(a, b);
  }

  /**
   * Croner's {@code fromTZ}: the instant a wall-clock time names, in epoch seconds. A time in a
   * spring-forward gap moves forward by the gap; a time that happens twice (fall back) is the
   * earlier of the two.
   */
  static long toUtc(long[] w, ZoneRules rules) {
    long target = civilSeconds(w);
    long guess = target + (target - civilSeconds(wallAt(target, rules)));
    long[] seen = wallAt(guess, rules);
    if (same(seen, w)) {
      long earlier = guess - 3600;
      if (same(wallAt(earlier, rules), w)) {
        return earlier;
      }
      return guess;
    }
    long shifted = guess + target - civilSeconds(seen);
    if (same(wallAt(shifted, rules), w)) {
      return shifted;
    }
    return Math.max(guess, shifted);
  }
}
