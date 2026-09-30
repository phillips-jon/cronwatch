package dev.cronwatch.internal.duration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.internal.duration.Schedules.Expectation;
import dev.cronwatch.internal.duration.Schedules.Kind;
import dev.cronwatch.internal.duration.Schedules.ParsedSchedule;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * The SDK's schedule.test.ts and duration.test.ts, as the Rust port has them, and what only the
 * ports have: zone names in any case, fixed offsets, far starts.
 */
class ScheduleTest {
  private static final long MINUTE = 60_000;
  private static final long HOUR = 3_600_000;
  private static final long DAY = 86_400_000;

  private static long utc(long y, long mo, long d, long h, long mi, long s) {
    return Js.dateUtc(y, mo, d, h, mi, s, 0);
  }

  private static ParsedSchedule must(String schedule, @Nullable String zone) {
    return Schedules.parse(schedule, zone);
  }

  private static long due(ParsedSchedule p, @Nullable Long lastRunAt, long registeredAt, double g) {
    return Objects.requireNonNull(Schedules.expectation(p, lastRunAt, registeredAt, g)).dueAt();
  }

  private static String error(Runnable r) {
    return assertThrows(IllegalArgumentException.class, r::run).getMessage();
  }

  @Test
  void parseAcceptsCronNicknamesAndIntervals() {
    for (String s : new String[] {"0 2 * * *", "@hourly", "*/5 * * * *"}) {
      assertEquals(Kind.CRON, must(s, null).kind(), s);
    }
    ParsedSchedule every = must("every 5m", null);
    assertTrue(every.isInterval());
    assertEquals(5 * MINUTE, every.everyMs());
    assertTrue(error(() -> Schedules.parse("every 500ms", null)).contains("shorter than one"));
    assertTrue(error(() -> Schedules.parse("banana", null)).contains("not a cron expression"));
    assertTrue(error(() -> Schedules.parse("every banana", null)).contains("not a duration"));
    assertEquals(
        new ParsedSchedule(Kind.INTERVAL, "every 90s", null, 90_000), must(" every 90s ", "UTC"));
    assertEquals(new ParsedSchedule(Kind.CRON, "0 2 * * *", "UTC", 0), must("0 2 * * *", "UTC"));
  }

  @Test
  void nextFireOfCronsAndIntervals() {
    ParsedSchedule daily = must("0 2 * * *", null);
    assertEquals(
        utc(2026, 0, 6, 2, 0, 0), Schedules.nextFire(daily, utc(2026, 0, 5, 9, 30, 0), null));
    ParsedSchedule every = must("every 1h", null);
    assertEquals(500 + HOUR, Schedules.nextFire(every, 1_000, 500L));
    assertEquals(1_000 + HOUR, Schedules.nextFire(every, 1_000, null));
    // July, EDT (UTC-4): 02:00 local is 06:00Z.
    ParsedSchedule toronto = must("0 2 * * *", "America/Toronto");
    assertEquals(
        utc(2026, 6, 10, 6, 0, 0), Schedules.nextFire(toronto, utc(2026, 6, 10, 0, 0, 0), null));
    // An interval from a far start saturates rather than wrapping.
    assertEquals(Long.MAX_VALUE, Schedules.nextFire(every, 0, Long.MAX_VALUE - 5));
  }

  @Test
  void expectationForACronCountsForwardFromTheLastRun() {
    ParsedSchedule daily = must("0 2 * * *", null);
    long registered = utc(2026, 0, 4, 12, 0, 0);
    Expectation first = Schedules.expectation(daily, null, registered, 10 * MINUTE);
    assertNotNull(first);
    assertEquals(utc(2026, 0, 5, 2, 0, 0), first.dueAt());
    assertEquals((double) utc(2026, 0, 5, 2, 10, 0), first.deadline());
    assertEquals(
        utc(2026, 0, 5, 2, 0, 0),
        due(daily, null, utc(2026, 0, 5, 2, 0, 0), 0),
        "a fire at registration counts");
    // Ran at 02:00:05: the 6th is next; 30 seconds early still covers 02:00; two minutes does not.
    assertEquals(utc(2026, 0, 6, 2, 0, 0), due(daily, utc(2026, 0, 5, 2, 0, 5), registered, 0));
    assertEquals(utc(2026, 0, 6, 2, 0, 0), due(daily, utc(2026, 0, 5, 1, 59, 30), registered, 0));
    assertEquals(utc(2026, 0, 5, 2, 0, 0), due(daily, utc(2026, 0, 5, 1, 58, 0), registered, 0));
  }

  @Test
  void oneRunOfAnEveryMinuteCronCoversOneFire() {
    ParsedSchedule minutely = must("* * * * *", null);
    long t0 = utc(2026, 0, 5, 9, 0, 0);
    assertEquals(t0 + MINUTE, due(minutely, t0, t0 - HOUR, 0), "a run on 09:00 covers 09:00");
    assertEquals(
        t0 + 2 * MINUTE,
        due(minutely, t0 + 50_000, t0 - HOUR, 0),
        "a run at 09:00:50 is early for 09:01");
  }

  @Test
  void expectationForYearlyCronsAndIntervals() {
    ParsedSchedule yearly = must("0 0 1 1 *", "UTC");
    long last = utc(2026, 0, 1, 0, 0, 3);
    assertEquals(utc(2027, 0, 1, 0, 0, 0), due(yearly, last, last - DAY, 10 * MINUTE));
    ParsedSchedule leap = must("0 0 29 2 *", "UTC");
    assertEquals(utc(2028, 1, 29, 0, 0, 0), due(leap, utc(2024, 1, 29, 0, 0, 1), 0, 0));
    ParsedSchedule every = must("every 1h", null);
    long now = utc(2026, 0, 5, 9, 30, 0);
    Expectation e = Schedules.expectation(every, now - 2 * HOUR, now - DAY, 5 * MINUTE);
    assertNotNull(e);
    assertEquals(now - HOUR, e.dueAt());
    assertEquals((double) (now - HOUR + 5 * MINUTE), e.deadline());
    assertEquals(now + 30 * MINUTE, due(every, null, now - 30 * MINUTE, 5 * MINUTE));
  }

  @Test
  void springForwardRunAtTheJumpCoversAMovedFire() {
    // 2026-03-08, America/New_York: 02:00 EST jumps to 03:00 EDT at 07:00Z. croner moves the
    // nonexistent 02:30 to 03:30 EDT (07:30Z); vixie cron runs it at 03:00 EDT.
    String tz = "America/New_York";
    ParsedSchedule daily = must("30 2 * * *", tz);
    assertEquals(utc(2026, 2, 8, 7, 30, 0), due(daily, utc(2026, 2, 7, 7, 30, 0), 0, 0));
    assertEquals(utc(2026, 2, 9, 6, 30, 0), due(daily, utc(2026, 2, 8, 7, 0, 2), 0, 0), "vixie");
    assertEquals(utc(2026, 2, 9, 6, 30, 0), due(daily, utc(2026, 2, 8, 7, 30, 1), 0, 0), "croner");
    // A cron that fires at the jump itself was not moved: a run then covers only that fire.
    assertEquals(
        utc(2026, 2, 8, 7, 10, 0), due(must("*/10 * * * *", tz), utc(2026, 2, 8, 7, 0, 2), 0, 0));
    assertEquals(
        utc(2026, 2, 8, 8, 0, 0), due(must("0 * * * *", tz), utc(2026, 2, 8, 7, 0, 2), 0, 0));
  }

  @Test
  void runCoversAllowsAMinuteAtMostHalfTheGap() {
    long d = utc(2026, 0, 5, 2, 0, 0);
    assertTrue(Schedules.runCovers(d, d, null));
    assertTrue(Schedules.runCovers(d - 59_000, d, null));
    assertTrue(Schedules.runCovers(d + 5 * MINUTE, d, null));
    assertFalse(Schedules.runCovers(d - 61_000, d, null));
    assertTrue(Schedules.runCovers(d - 30_000, d, d + MINUTE));
    assertFalse(Schedules.runCovers(d - 31_000, d, d + MINUTE));
  }

  @Test
  void firesBetweenASpan() {
    ParsedSchedule hourly = must("0 * * * *", "UTC");
    long from = utc(2026, 0, 5, 9, 30, 0);
    List<Long> fires = Schedules.firesBetween(hourly, from, from + 24 * HOUR, 100);
    assertNotNull(fires);
    assertEquals(24, fires.size());
    long next = from;
    for (long fire : fires) {
      next = Objects.requireNonNull(Schedules.nextFire(hourly, next, null));
      assertEquals(next, fire, "firesBetween and nextFire disagree");
    }
    assertNull(Schedules.firesBetween(hourly, from, from + 24 * HOUR, 23), "more than the limit");
    assertEquals(List.of(), Schedules.firesBetween(must("0 3 * * *", "UTC"), from, from + HOUR, 5));
    // The night clocks go back in New York: fires only ever move forward.
    List<Long> night =
        Schedules.firesBetween(
            must("30 * * * *", "America/New_York"),
            utc(2026, 10, 1, 4, 0, 0),
            utc(2026, 10, 1, 9, 0, 0),
            20);
    assertNotNull(night);
    for (int i = 1; i < night.size(); i++) {
      assertTrue(night.get(i) > night.get(i - 1), "fires went backwards");
    }
    assertTrue(night.size() >= 4 && night.size() <= 5, night.size() + " fires in the night");
  }

  @Test
  void aDateNoMonthHasNeverFires() {
    ParsedSchedule p = must("0 0 30 2 *", "UTC");
    assertNull(Schedules.nextFire(p, utc(2026, 0, 1, 0, 0, 0), null));
    assertNull(Schedules.expectation(p, null, utc(2026, 0, 1, 0, 0, 0), 0));
  }

  @Test
  void aFarStartCountsFromTheYear1OrHasNoFireAfterIt() {
    // A foreign or damaged row's start can be any long: before the year 1 it counts from the
    // year's first millisecond, and after 9999 nothing is due. Nothing overflows, in any zone.
    long first = Js.FIRST_DATE_MS;
    for (String zone : new String[] {"UTC", "America/New_York", "Asia/Kolkata", ""}) {
      for (String schedule :
          new String[] {"0 2 * * *", "*/5 * * * *", "0 0 29 2 *", "0 0 30 2 *"}) {
        ParsedSchedule p = must(schedule, zone);
        for (long t :
            new long[] {
              Long.MIN_VALUE,
              Long.MIN_VALUE + 1,
              -8_640_000_000_000_001L,
              first - 1,
              Long.MAX_VALUE,
              Long.MAX_VALUE - 1
            }) {
          Long f = Schedules.nextFire(p, t, null);
          if (f != null) {
            assertTrue(
                t < first && f >= first && f <= Js.LAST_DATE_MS,
                schedule + " " + zone + " from " + t + ": " + f);
          }
          Schedules.expectation(p, t, t, Double.MAX_VALUE);
          Schedules.expectation(p, null, t, 0);
          Schedules.firesBetween(p, t, Long.MAX_VALUE, 50);
        }
      }
    }
    ParsedSchedule p = must("0 2 * * *", "UTC");
    assertEquals(utc(1, 0, 1, 2, 0, 0), due(p, Long.MIN_VALUE, 0, 0));
    assertNull(Schedules.expectation(p, Long.MAX_VALUE, 0, 0));
    assertEquals(
        utc(9999, 11, 31, 2, 0, 0), Schedules.nextFire(p, utc(9999, 11, 30, 12, 0, 0), null));
    assertNull(Schedules.nextFire(p, utc(9999, 11, 31, 2, 0, 0), null));
    assertEquals(utc(5000, 0, 1, 2, 0, 0), Schedules.nextFire(p, utc(5000, 0, 1, 0, 0, 0), null));
  }

  @Test
  void oneTimeDatesAreRefused() {
    assertTrue(
        error(() -> Schedules.parse("2026-12-01T00:00:00", null))
            .endsWith(": CronPattern: a one-time date is not supported by the Java port"));
    assertTrue(
        error(() -> Schedules.parse("0 2:30 * * *", null))
            .endsWith(": Invalid ISO8601 passed to timezone parser."));
  }

  @Test
  void zones() {
    assertTrue(Schedules.isZone("america/new_york"));
    assertTrue(Schedules.isZone("+05:30"));
    assertFalse(Schedules.isZone(""));
    assertFalse(Schedules.isZone("Bogus/Zone"));
    // A zone named in another case reads the same as its own spelling.
    long from = utc(2026, 6, 10, 0, 0, 0);
    ParsedSchedule lower = must("0 2 * * *", "america/new_york");
    assertEquals(utc(2026, 6, 10, 6, 0, 0), Schedules.nextFire(lower, from, null));
    assertEquals("america/new_york", lower.timezone());
    ParsedSchedule offset = must("0 2 * * *", "+05:30");
    assertEquals(
        utc(2026, 0, 1, 20, 30, 0), Schedules.nextFire(offset, utc(2026, 0, 1, 0, 0, 0), null));
    assertTrue(
        error(() -> Schedules.parse("0 2 * * *", "Bogus/Zone"))
            .startsWith("CronDate: Failed to convert date to timezone 'Bogus/Zone'"));
    // A pattern error is reported before a zone error, as croner reads the pattern first.
    assertTrue(error(() -> Schedules.parse("x", "Bogus/Zone")).startsWith("schedule \"x\""));
  }

  @Test
  void parseIsSafeFromManyThreads() throws InterruptedException {
    List<Thread> threads = new ArrayList<>();
    List<Throwable> failures = java.util.Collections.synchronizedList(new ArrayList<>());
    for (int i = 0; i < 32; i++) {
      threads.add(
          Thread.ofPlatform()
              .start(
                  () -> {
                    try {
                      for (int j = 0; j < 50; j++) {
                        ParsedSchedule p = Schedules.parse("*/15 * * * *", "Europe/London");
                        Schedules.nextFire(p, utc(2026, 9, 25, 0, 0, j), null);
                      }
                    } catch (RuntimeException e) {
                      failures.add(e);
                    }
                  }));
    }
    for (Thread t : threads) {
      t.join();
    }
    assertEquals(List.of(), failures);
  }

  @Test
  void parseDurationTextAndNumbers() {
    Object[][] good = {
      {"15m", 900_000.0},
      {"1h30m", 5_400_000.0},
      {"90s", 90_000.0},
      {"2d", 172_800_000.0},
      {"1w", 604_800_000.0},
      {"250ms", 250.0},
      {" 1h 5m ", 3_900_000.0},
      {"1.5h", 5_400_000.0},
    };
    for (Object[] c : good) {
      assertEquals(c[1], Durations.parse((String) c[0], ""), (String) c[0]);
    }
    assertEquals(1.5, Durations.parse(1.5, ""));
    for (String bad : new String[] {"", "abc", "5", "5 minutes", "-1m", "1m2"}) {
      assertTrue(error(() -> Durations.parse(bad, "")).contains("duration"), bad);
    }
    assertEquals(
        "grace must be a non-negative number of milliseconds",
        error(() -> Durations.parse(-5.0, "grace")));
  }

  @Test
  void aJsonValueIsReadAsTheSdkReadsIt() {
    assertEquals(900_000.0, Durations.parseValue("15m", "grace"));
    assertEquals(1.5, Durations.parseValue(1.5, "grace"));
    String like = " is not a duration like \"15m\", \"1h30m\" or \"90s\"";
    assertEquals("grace \"true\"" + like, error(() -> Durations.parseValue(true, "grace")));
    assertEquals("duration \"null\"" + like, error(() -> Durations.parseValue(null, "")));
    assertEquals(
        "grace \"[object Object]\"" + like,
        error(() -> Durations.parseValue(new JsObject(), "grace")));
    java.util.List<Object> list = new ArrayList<>();
    list.add(1.0);
    list.add(null);
    list.add("x");
    assertEquals("grace \"1,,x\"" + like, error(() -> Durations.parseValue(list, "grace")));
  }

  @Test
  void aDurationOver64CharactersIsRefusedQuotingItsFirst32() {
    String tooLong = "is too long for a duration (more than 64 characters)";
    assertEquals(32.0 * 60_000, Durations.parse("1m".repeat(32), ""));
    String longer = " " + "1m".repeat(32);
    assertEquals(
        "grace \"" + longer.substring(0, 32) + "...\" " + tooLong,
        error(() -> Durations.parse(longer, "grace")));
    // Characters are code points: forty emoji are eighty UTF-16 units but under the cap.
    String forty = "😀".repeat(40);
    assertEquals(
        "duration \"" + forty + "\" is not a duration like \"15m\", \"1h30m\" or \"90s\"",
        error(() -> Durations.parse(forty, "")));
    assertEquals(
        "duration \"" + "😀".repeat(32) + "...\" " + tooLong,
        error(() -> Durations.parse("😀".repeat(65), "")));
    assertEquals(
        "silence duration \"" + "1".repeat(32) + "...\" " + tooLong,
        error(() -> Durations.parse("1".repeat(1 << 20), "silence duration")));
  }

  @Test
  void formatDurationAndRelative() {
    assertEquals("500ms", Durations.format(500));
    assertEquals("1s", Durations.format(1_000));
    assertEquals("1m 30s", Durations.format(90_000));
    assertEquals("1d 2h", Durations.format(HOUR * 26 + MINUTE * 5));
    assertEquals("2m ago", Durations.formatRelative(1_000_000, 1_120_000));
    assertEquals("in 2m", Durations.formatRelative(1_120_000, 1_000_000));
    assertEquals("now", Durations.formatRelative(1_000_000, 1_002_000));
    Durations.formatRelative(Long.MIN_VALUE, Long.MAX_VALUE);
    Durations.formatRelative(Long.MAX_VALUE, Long.MIN_VALUE);
  }
}
