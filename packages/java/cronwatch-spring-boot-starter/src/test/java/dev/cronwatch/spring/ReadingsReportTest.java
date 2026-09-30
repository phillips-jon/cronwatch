package dev.cronwatch.spring;

import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import com.cronutils.model.CronType;
import com.cronutils.model.definition.CronDefinitionBuilder;
import com.cronutils.model.time.ExecutionTime;
import com.cronutils.parser.CronParser;
import dev.cronwatch.bridge.Bridge;
import dev.cronwatch.bridge.FireTimes;
import dev.cronwatch.bridge.ScheduleException;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.TimeZone;
import org.junit.jupiter.api.Test;
import org.springframework.scheduling.support.CronExpression;

/**
 * A report, not a gate: generated cron expressions read by Spring's {@code CronExpression},
 * Quartz's and cron-utils', each checked against CronWatch's reading (the croner port) as the
 * integrations check a schedule ({@link Bridge#checkFires}), and how many each reads alike printed,
 * with why the rest differ. It keeps measured why CronWatch ports croner rather than depending on a
 * Java cron library (see DESIGN.md, Keeping in step), as the Rust port's report on the croner crate
 * and the Elixir port's on Oban and the crontab package do. Seeded, so the numbers repeat; the
 * generator and the zones are the Elixir report's, with a seconds field first. It takes some
 * seconds, so it runs only when asked: {@code -Dcronwatch.readings=true}.
 */
class ReadingsReportTest {
  private static final String[] ZONES = {
    "UTC", "America/New_York", "Europe/London", "Australia/Lord_Howe"
  };
  private static final int COUNT = 40;

  /** 2026-08-01 00:00 UTC, the Elixir report's start. */
  private static final long NOW = 1_785_542_400_000L;

  private long state = 20_260_929L;

  /** SplitMix64, as the Elixir report's. */
  private long next() {
    state += 0x9e3779b97f4a7c15L;
    long z = state;
    z = (z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9L;
    z = (z ^ (z >>> 27)) * 0x94d049bb133111ebL;
    return z ^ (z >>> 31);
  }

  private double chance() {
    return (next() >>> 11) / (double) (1L << 53);
  }

  private long between(long lo, long hi) {
    return lo + Long.remainderUnsigned(next(), hi - lo + 1);
  }

  /** A field in the grammar every library here shares: *, a value, a range, a step or a list. */
  private String field(long low, long high) {
    double kind = chance();
    if (kind < 0.35) {
      return "*";
    }
    if (kind < 0.6) {
      return Long.toString(between(low, high));
    }
    if (kind < 0.75) {
      long a = between(low, high);
      return a + "-" + between(a, high);
    }
    if (kind < 0.9) {
      return "*/" + between(2, Math.max(2, (high - low + 1) / 2));
    }
    List<String> values = new ArrayList<>();
    long n = between(2, 3);
    for (int i = 0; i < n; i++) {
      String v = Long.toString(between(low, high));
      if (!values.contains(v)) {
        values.add(v);
      }
    }
    return String.join(",", values);
  }

  /** The five fields every crontab has: minute, hour, day of the month, month, day of the week. */
  private String[] fields() {
    return new String[] {
      field(0, 59), field(0, 23), field(1, 28), field(1, 12), field(0, 6),
    };
  }

  /** What one library made of one expression: alike, refused, or read otherwise. */
  private enum Reading {
    ALIKE,
    REFUSED,
    OTHER
  }

  private static Reading check(FireTimes fires, String expr, String zone, boolean daily) {
    try {
      Bridge.checkFires(fires, expr, zone, "x", "the library", daily, NOW);
      return Reading.ALIKE;
    } catch (ScheduleException e) {
      return Reading.OTHER;
    }
  }

  private static Reading spring(String expr, String zone, boolean daily) {
    CronExpression cron;
    try {
      cron = CronExpression.parse(expr);
    } catch (IllegalArgumentException e) {
      return Reading.REFUSED;
    }
    ZoneId tz = ZoneId.of(zone);
    return check(
        FireTimes.walking(
            at -> {
              ZonedDateTime n = cron.next(Instant.ofEpochMilli(at).atZone(tz));
              return n == null ? null : n.toInstant().toEpochMilli();
            },
            "Spring"),
        expr,
        zone,
        daily);
  }

  @SuppressWarnings("JavaUtilDate") // Quartz's API takes and answers a Date
  private static Reading quartz(String text, String expr, String zone, boolean daily) {
    org.quartz.CronExpression cron;
    try {
      cron = new org.quartz.CronExpression(text);
    } catch (java.text.ParseException | RuntimeException e) {
      return Reading.REFUSED;
    }
    cron.setTimeZone(TimeZone.getTimeZone(zone));
    return check(
        FireTimes.walking(
            at -> {
              java.util.Date n = cron.getNextValidTimeAfter(new java.util.Date(at));
              return n == null ? null : n.getTime();
            },
            "Quartz"),
        expr,
        zone,
        daily);
  }

  private static Reading cronUtils(CronType type, String expr, String zone, boolean daily) {
    ExecutionTime time;
    try {
      time =
          ExecutionTime.forCron(
              new CronParser(CronDefinitionBuilder.instanceDefinitionFor(type)).parse(expr));
    } catch (RuntimeException e) {
      return Reading.REFUSED;
    }
    ZoneId tz = ZoneId.of(zone);
    return check(
        FireTimes.walking(
            at -> {
              Optional<ZonedDateTime> n = time.nextExecution(Instant.ofEpochMilli(at).atZone(tz));
              return n.map(z -> z.toInstant().toEpochMilli()).orElse(null);
            },
            "cron-utils"),
        expr,
        zone,
        daily);
  }

  private static boolean any(String f) {
    return f.equals("*") || f.equals("?");
  }

  /** Why a reading differs: refused, both day fields named, the day of the week named, other. */
  private static String why(Reading r, String[] f) {
    if (r == Reading.REFUSED) {
      return "refused";
    }
    if (!any(f[2]) && !any(f[4])) {
      return "both days named";
    }
    if (!any(f[4])) {
      return "day of the week named";
    }
    return "other";
  }

  private static void count(Map<String, Map<String, Integer>> tally, String lib, String what) {
    tally.computeIfAbsent(lib, k -> new LinkedHashMap<>()).merge(what, 1, Integer::sum);
  }

  @Test
  void springsQuartzsAndCronUtilsReadingsAgainstCronWatchs() {
    assumeTrue(Boolean.getBoolean("cronwatch.readings"), "a report: -Dcronwatch.readings=true");
    Map<String, Map<String, Integer>> tally = new LinkedHashMap<>();
    List<String> others = new ArrayList<>();
    for (int n = 0; n < COUNT; n++) {
      String[] f = fields();
      String zone = ZONES[n % ZONES.length];
      boolean daily = any(f[2]) && any(f[3]) && any(f[4]);
      String five = String.join(" ", f);
      // Seconds first, as Spring's and Quartz's expressions have them; croner reads six fields
      // the same way.
      String six = "0 " + five;
      // Quartz asks for a ? in one of the day fields; given where the other is *, as an app
      // writes it, and read by CronWatch as * again, as the integration declares it. Both named,
      // Quartz refuses.
      String quartzText =
          any(f[4])
              ? "0 " + f[0] + " " + f[1] + " " + f[2] + " " + f[3] + " ?"
              : any(f[2]) ? "0 " + f[0] + " " + f[1] + " ? " + f[3] + " " + f[4] : six;
      Map<String, Reading> readings = new LinkedHashMap<>();
      readings.put("Spring", spring(six, zone, daily));
      readings.put("Quartz", quartz(quartzText, six, zone, daily));
      readings.put("cron-utils (Spring 5.3)", cronUtils(CronType.SPRING53, six, zone, daily));
      readings.put("cron-utils (Unix)", cronUtils(CronType.UNIX, five, zone, daily));
      for (Map.Entry<String, Reading> e : readings.entrySet()) {
        String what = e.getValue() == Reading.ALIKE ? "alike" : why(e.getValue(), f);
        count(tally, e.getKey(), what);
        if (what.equals("other")) {
          others.add(e.getKey() + ": " + six + " in " + zone);
        }
      }
    }
    StringBuilder out =
        new StringBuilder("readings report: of " + COUNT + " expressions in four zones,");
    for (Map.Entry<String, Map<String, Integer>> e : tally.entrySet()) {
      out.append("\n  ").append(e.getKey()).append(": ").append(e.getValue());
    }
    for (String o : others) {
      out.append("\n  read otherwise: ").append(o);
    }
    System.out.println(out);
    assertTrue(tally.get("Spring").getOrDefault("alike", 0) > 0, out.toString());
  }
}
