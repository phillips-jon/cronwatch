package dev.cronwatch.internal.duration;

import java.util.ArrayList;
import java.util.List;

/**
 * Cron expressions for the parity check and the properties: valid and not, nicknames, names,
 * ranges, steps, lists, L, W, LW, #, ?, +, six and seven fields. The generator is the Go, Python,
 * PHP and Rust ports', over SplitMix64, so a seed gives the same expressions in every port.
 */
final class CronFuzzer {
  static final String[] ZONES = {
    "",
    "UTC",
    "America/New_York",
    "Europe/London",
    "Australia/Lord_Howe",
    "America/Santiago",
    "Asia/Kolkata",
    "Pacific/Chatham",
    "Europe/Berlin",
  };
  private static final String[] MONTHS = {
    "jan", "FEB", "Mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
  };
  private static final String[] DAYS = {"sun", "MON", "Tue", "wed", "thu", "fri", "sat"};
  private static final String[] NICKNAMES = {
    "@yearly",
    "@annually",
    "@monthly",
    "@weekly",
    "@daily",
    "@midnight",
    "@hourly",
    "@HOURLY",
    "@reboot",
    "@every"
  };

  private long state;

  CronFuzzer(long seed) {
    this.state = seed;
  }

  /** SplitMix64: small, seeded and the same on every platform. */
  long next() {
    state += 0x9e3779b97f4a7c15L;
    long z = state;
    z = (z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9L;
    z = (z ^ (z >>> 27)) * 0x94d049bb133111ebL;
    return z ^ (z >>> 31);
  }

  double chance() {
    return (next() >>> 11) / (double) (1L << 53);
  }

  long between(long lo, long hi) {
    return lo + Long.remainderUnsigned(next(), hi - lo + 1);
  }

  <T> T pick(T[] items) {
    return items[(int) Long.remainderUnsigned(next(), items.length)];
  }

  long pick(long[] items) {
    return items[(int) Long.remainderUnsigned(next(), items.length)];
  }

  /** One cron field: mostly valid, sometimes out of range or malformed. */
  String field(long low, long high, String[] names) {
    long size = high - low + 1;
    double kind = chance();
    if (kind < 0.3) {
      return "*";
    }
    if (kind < 0.45) {
      return value(low, high, names);
    }
    if (kind < 0.6) {
      long[] ab = pair(low, high);
      if (chance() < 0.05) {
        ab = new long[] {ab[1] + 1, ab[0]};
      }
      return ab[0] + "-" + ab[1];
    }
    if (kind < 0.75) {
      return "*/" + pick(new long[] {1, 2, 3, 5, 7, 10, 15, 30, size, size + 1, 0});
    }
    if (kind < 0.85) {
      long[] ab = pair(low, high);
      long step = between(1, Math.max(size / 2, 1));
      return ab[0] + "-" + ab[1] + "/" + step;
    }
    if (kind < 0.97) {
      long n = between(2, 4);
      List<String> values = new ArrayList<>();
      for (long i = 0; i < n; i++) {
        values.add(value(low, high, names));
      }
      return String.join(",", values);
    }
    return pick(new String[] {"?", "x", "", "5/15", "/5", "1-", "-1"});
  }

  private String value(long low, long high, String[] names) {
    if (names.length > 0 && chance() < 0.3) {
      return pick(names);
    }
    if (chance() < 0.05) {
      return Long.toString(pick(new long[] {high + 1, low - 1, 99}));
    }
    return Long.toString(between(low, high));
  }

  private long[] pair(long low, long high) {
    long a = between(low, high);
    long b = between(low, high);
    return a > b ? new long[] {b, a} : new long[] {a, b};
  }

  private String dayOfMonth() {
    double kind = chance();
    if (kind < 0.1) {
      return pick(new String[] {"L", "LW", "15W", "1W", "31W", "5L", "L,15"});
    }
    if (kind < 0.2) {
      return "?";
    }
    return field(1, 31, new String[0]);
  }

  private String dayOfWeek() {
    double kind = chance();
    if (kind < 0.1) {
      long a = between(0, 7);
      long b = between(0, 6);
      return a + "#" + b;
    }
    if (kind < 0.18) {
      return between(0, 6) + "L";
    }
    if (kind < 0.24) {
      return "+" + field(0, 7, DAYS);
    }
    if (kind < 0.3) {
      String a = pick(DAYS);
      String b = pick(DAYS);
      return a + "-" + b;
    }
    return field(0, 7, DAYS);
  }

  /** A cron expression. */
  String expression() {
    if (chance() < 0.05) {
      return pick(NICKNAMES);
    }
    List<String> parts = new ArrayList<>();
    parts.add(field(0, 59, new String[0]));
    parts.add(field(0, 23, new String[0]));
    parts.add(dayOfMonth());
    parts.add(field(1, 12, MONTHS));
    parts.add(dayOfWeek());
    if (chance() < 0.25) {
      parts.add(0, field(0, 59, new String[0]));
    }
    if (chance() < 0.02) {
      parts.add("*");
    }
    return String.join(" ", parts);
  }
}
