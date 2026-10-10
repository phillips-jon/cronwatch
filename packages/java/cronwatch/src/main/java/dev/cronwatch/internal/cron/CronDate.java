package dev.cronwatch.internal.cron;

import dev.cronwatch.internal.cron.CronPattern.Kind;
import dev.cronwatch.internal.js.Js;
import java.time.zone.ZoneRules;

/**
 * Croner's CronDate: a wall-clock time whose fields are moved forward to the next match, a field at
 * a time, spilling into the next month or year as croner does. The fields are year, month (0
 * based), day, hour, minute, second, and milliseconds.
 */
final class CronDate {
  private static final long[] DAYS_IN_MONTH = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

  // The fields of a date, by index.
  private static final int YEAR = 0;
  private static final int MONTH = 1;
  private static final int DAY = 2;
  private static final int HOUR = 3;
  private static final int MINUTE = 4;
  private static final int SECOND = 5;
  private static final int MILLIS = 6;

  /**
   * A step of the walk: the field, the field above it, and the offset from a field value to its
   * pattern index (croner's fieldOrder).
   */
  private record Step(int field, int above, Kind k, long offset) {}

  private static final Step[] ORDER = {
    new Step(MONTH, YEAR, Kind.MONTH, 0),
    new Step(DAY, MONTH, Kind.DAY, -1),
    new Step(HOUR, DAY, Kind.HOUR, 0),
    new Step(MINUTE, HOUR, Kind.MINUTE, 0),
    new Step(SECOND, MINUTE, Kind.SECOND, 0),
  };

  private final long[] f;

  private CronDate(long[] f) {
    this.f = f;
  }

  /** {@code new CronDate(new Date(at), tz)}. */
  static CronDate fromMs(long at, ZoneRules rules) {
    long sec = Math.floorDiv(at, 1000);
    long[] w = Zones.wallAt(sec, rules);
    return new CronDate(new long[] {w[0], w[1] - 1, w[2], w[3], w[4], w[5], at - sec * 1000});
  }

  /**
   * Croner's {@code getLastDayOfMonth}, month 0 based; -1 for a month outside 0 to 11 (croner's
   * undefined).
   */
  private static long lastDayOfMonth(long year, long month) {
    if (month != 1) {
      return month >= 0 && month < 12 ? DAYS_IN_MONTH[(int) month] : -1;
    }
    return Js.civilFromDays(Math.floorDiv(Js.dateUtc(year, month + 1, 0, 0, 0, 0, 0), 86_400_000L))[
        2];
  }

  /** {@code new Date(Date.UTC(year, month, day)).getUTCDay()}, month 0 based. 0 is Sunday. */
  private static long weekday(long year, long month, long day) {
    return Math.floorMod(
        Math.floorDiv(Js.dateUtc(year, month, day, 0, 0, 0, 0), 86_400_000L) + 4, 7);
  }

  /**
   * Croner's {@code apply()}: fields out of their range are carried into the fields above, as a
   * Date made from them would be. It says whether it changed anything.
   */
  private boolean apply() {
    long month = f[MONTH];
    boolean out =
        month < 0
            || month >= 12
            || f[DAY] > DAYS_IN_MONTH[(int) month]
            || f[DAY] < 1
            || f[HOUR] > 59
            || f[MINUTE] > 59
            || f[SECOND] > 59
            || f[HOUR] < 0
            || f[MINUTE] < 0
            || f[SECOND] < 0;
    if (!out) {
      return false;
    }
    long at = Js.dateUtc(f[YEAR], month, f[DAY], f[HOUR], f[MINUTE], f[SECOND], f[MILLIS]);
    long sec = Math.floorDiv(at, 1000);
    long days = Math.floorDiv(sec, 86_400);
    long rest = sec - days * 86_400;
    long[] ymd = Js.civilFromDays(days);
    f[YEAR] = ymd[0];
    f[MONTH] = ymd[1] - 1;
    f[DAY] = ymd[2];
    f[HOUR] = rest / 3600;
    f[MINUTE] = rest % 3600 / 60;
    f[SECOND] = rest % 60;
    f[MILLIS] = at - sec * 1000;
    return true;
  }

  private static long lastWeekday(long year, long month) {
    long last = Math.max(lastDayOfMonth(year, month), 0);
    long wd = weekday(year, month, last);
    if (wd == 0) {
      return last - 2;
    }
    if (wd == 6) {
      return last - 1;
    }
    return last;
  }

  private static long nearestWeekday(long year, long month, long day) {
    long last = lastDayOfMonth(year, month);
    if (last >= 0 && day > last) {
      return -1;
    }
    long wd = weekday(year, month, day);
    if (wd == 0) {
      return last == day ? day - 2 : day + 1;
    }
    if (wd == 6) {
      return day == 1 ? day + 2 : day - 1;
    }
    return day;
  }

  private static boolean isNthWeekday(long year, long month, long day, int bits) {
    long wd = weekday(year, month, day);
    int count = 0;
    for (long x = 1; x <= day; x++) {
      if (weekday(year, month, x) == wd) {
        count++;
      }
    }
    if ((bits & CronPattern.ANY_BITS) != 0
        && count >= 1
        && count <= CronPattern.NTH_BITS.length
        && (CronPattern.NTH_BITS[count - 1] & bits) != 0) {
      return true;
    }
    if ((bits & CronPattern.LAST_BIT) != 0) {
      long last = Math.max(lastDayOfMonth(year, month), 0);
      for (long x = day + 1; x <= last; x++) {
        if (weekday(year, month, x) == wd) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  /**
   * Croner's {@code findNext}: 1 when the field already matches, 2 when it was moved forward to a
   * match, 3 when none is left in its range.
   */
  private int findNext(CronPattern p, Step s) {
    long before = f[s.field()];
    int[] table = p.table(s.k());
    long size = table.length;
    long year = f[YEAR];
    long month = f[MONTH];
    long last = p.lastDayOfMonth ? lastDayOfMonth(year, month) : -2;
    long firstWeekday = !p.starDow && s.k() == Kind.DAY ? weekday(year, month, 1) : 0;
    boolean isDay = s.k() == Kind.DAY;
    for (long u = before + s.offset(); u < size; u++) {
      int matched = u >= 0 ? table[(int) u] : 0;
      long value = u - s.offset();
      if (isDay && matched == 0) {
        for (int c = 0; c < p.nearestWeekdays.length; c++) {
          if (p.nearestWeekdays[c] != 0) {
            long m = nearestWeekday(year, month, c - s.offset());
            if (m == -1) {
              continue;
            }
            if (m == value) {
              matched = 1;
              break;
            }
          }
        }
      }
      if (isDay && p.lastWeekday && value == lastWeekday(year, month)) {
        matched = 1;
      }
      if (isDay && p.lastDayOfMonth && last >= 0 && last == value) {
        matched = 1;
      }
      if (isDay && !p.starDow) {
        int bits = p.dayOfWeek[Math.floorMod(firstWeekday + (value - 1), 7)];
        if (bits != 0 && (bits & CronPattern.ANY_BITS) != 0) {
          bits = isNthWeekday(year, month, value, bits) ? 1 : 0;
        } else if (bits != 0) {
          throw new CronException("CronDate: Invalid value for dayOfWeek encountered. " + bits);
        }
        if (p.useAndLogic) {
          if (matched != 0) {
            matched = bits;
          }
        } else if (!p.starDom) {
          if (matched == 0) {
            matched = bits;
          }
        } else if (matched != 0) {
          matched = bits;
        }
      }
      if (matched != 0) {
        f[s.field()] = value;
        return before != f[s.field()] ? 2 : 1;
      }
    }
    return 3;
  }

  /**
   * Croner's {@code recurse()}, walked in a loop: each field in turn from the month down is moved
   * to its next match, a field that runs out carries into the one above and the walk starts again
   * from the month. Croner recurses a year at a time, so for a date no month has it runs out of
   * stack; the loop answers false (never) at the year croner gives up at.
   */
  private boolean recurse(CronPattern p) {
    final long years = 10_000;
    final int n = ORDER.length;
    int level = 0;
    while (true) {
      if (level == 0 && !p.starYear) {
        long y = f[YEAR];
        if (y >= 0 && y < years && !p.hasYear(y)) {
          long found = -1;
          for (long x = y + 1; x < years; x++) {
            if (p.hasYear(x)) {
              found = x;
              break;
            }
          }
          if (found < 0) {
            return false;
          }
          f[YEAR] = found;
          f[MONTH] = 0;
          f[DAY] = 1;
          f[HOUR] = 0;
          f[MINUTE] = 0;
          f[SECOND] = 0;
          f[MILLIS] = 0;
        }
        if (f[YEAR] >= years) {
          return false;
        }
      }
      // A level below 0 counts from the end, as croner's own array lookup of it does.
      Step s = ORDER[Math.floorMod(level, n)];
      int found = findNext(p, s);
      if (found > 1) {
        for (int i = level + 1; i < n; i++) {
          Step below = ORDER[Math.floorMod(i, n)];
          f[below.field()] = -below.offset();
        }
        if (found == 3) {
          f[s.above()] += 1;
          f[s.field()] = -s.offset();
          apply();
          if (level == 0 && !p.starYear) {
            while (f[YEAR] >= 0 && f[YEAR] < years && !p.hasYear(f[YEAR])) {
              f[YEAR] += 1;
            }
            if (f[YEAR] >= years) {
              return false;
            }
          }
          level = 0;
          continue;
        }
        if (apply()) {
          level -= 1;
          continue;
        }
      }
      level += 1;
      if (level >= n) {
        return true;
      }
      if ((p.starYear && f[YEAR] >= 3000) || (!p.starYear && f[YEAR] >= years)) {
        return false;
      }
    }
  }

  /** Croner's {@code increment()}: one second on, then the next match. False when there is none. */
  boolean increment(CronPattern p) {
    f[SECOND] += 1;
    f[MILLIS] = 0;
    apply();
    return recurse(p);
  }

  /** {@code getDate(false).getTime()}: the instant this wall-clock time names. */
  long timeMs(ZoneRules rules) {
    return Zones.toUtc(
            new long[] {f[YEAR], f[MONTH] + 1, f[DAY], f[HOUR], f[MINUTE], f[SECOND]}, rules)
        * 1000;
  }
}
