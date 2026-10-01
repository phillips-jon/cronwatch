package dev.cronwatch.internal.cron;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.internal.js.Js;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Objects;
import org.junit.jupiter.api.Test;

/**
 * The walk's habits, each checked against what croner answers (the parity test in the schedule
 * package checks thousands more against croner itself).
 */
class CronTest {
  private static List<String> runs(String text, String zone, int count, long from) {
    ZoneId tz = Objects.requireNonNull(Zones.find(zone));
    return Cron.parse(text, tz).nextRuns(count, from).stream().map(Js::isoString).toList();
  }

  @Test
  void cronersHabits() {
    long jan = Js.dateUtc(2026, 0, 1, 0, 0, 0, 0);
    Object[][] cases = {
      {
        "a wall-clock time in a spring-forward gap moves forward by the gap",
        "30 2 8 3 *",
        "America/New_York",
        1,
        List.of("2026-03-08T07:30:00.000Z")
      },
      {
        "a time that happens twice is the earlier one",
        "30 1 1 11 *",
        "America/New_York",
        2,
        List.of("2026-11-01T05:30:00.000Z", "2027-11-01T05:30:00.000Z")
      },
      {
        "a year field fires in that year only",
        "0 0 0 1 1 * 2030",
        "UTC",
        2,
        List.of("2030-01-01T00:00:00.000Z")
      },
      {"a fixed offset is a zone", "0 2 * * *", "+05:30", 1, List.of("2026-01-01T20:30:00.000Z")},
      {"a date no month has never fires", "0 0 30 2 *", "UTC", 1, List.of()},
      {
        "the last weekday of the month",
        "0 0 LW * *",
        "UTC",
        2,
        List.of("2026-01-30T00:00:00.000Z", "2026-02-27T00:00:00.000Z")
      },
      {
        "the nearest weekday to the first",
        "0 0 1W * *",
        "UTC",
        2,
        List.of("2026-02-02T00:00:00.000Z", "2026-03-02T00:00:00.000Z")
      },
      {
        "the second Friday",
        "0 0 * * 5#2",
        "UTC",
        2,
        List.of("2026-01-09T00:00:00.000Z", "2026-02-13T00:00:00.000Z")
      },
    };
    for (Object[] c : cases) {
      assertEquals(
          c[4], runs((String) c[1], (String) c[2], (Integer) c[3], jan), c[0] + ": " + c[1]);
    }
  }

  @Test
  void cronersMessages() {
    String[][] cases = {
      {
        "",
        "CronPattern: invalid configuration format (''), exactly five, six, or seven space"
            + " separated parts are required."
      },
      {"0 0 * * 5W", "CronPattern: configuration entry 5 (5W) contains illegal characters."},
      {"0 0 1#2 * *", "CronPattern: configuration entry 3 (1#2) contains illegal characters."},
      {"0 0 * 2L *", "CronPattern: configuration entry 4 (2L) contains illegal characters."},
      {"0 0 1-5W * *", "CronPattern: Syntax error, W is not allowed in a range."},
      {"* * * * * * 0", "CronPattern: Invalid value for year: 0 (supported range: 1-9999)"},
      {"0 0 * * 1#2.5", "CronPattern: configuration entry 5 (1#2.5) contains illegal characters."},
      {
        "@reboot",
        "CronPattern: @reboot is not supported in this environment. This is an event-based trigger"
            + " that requires system startup detection."
      },
      // Croner takes this for a one-time date; the port refuses it (see Cron).
      {"0 12:30 * * *", "Invalid ISO8601 passed to timezone parser."},
      {"2026-12-01T00:00:00", "CronPattern: a one-time date is not supported"},
    };
    for (String[] c : cases) {
      CronException e =
          assertThrows(CronException.class, () -> Cron.parse(c[0], ZoneOffset.UTC), c[0]);
      assertEquals(c[1], e.getMessage(), c[0]);
    }
  }

  @Test
  void fromTz() {
    ZoneId ny = Objects.requireNonNull(Zones.find("America/New_York"));
    // 02:30 does not exist on 2026-03-08: croner's fromTZ moves it to 03:30 EDT.
    assertEquals(
        Js.dateUtc(2026, 2, 8, 7, 30, 0, 0),
        Zones.toUtc(new long[] {2026, 3, 8, 2, 30, 0}, ny.getRules()) * 1000);
    // 01:30 happens twice on 2026-11-01: the earlier, EDT.
    assertEquals(
        Js.dateUtc(2026, 10, 1, 5, 30, 0, 0),
        Zones.toUtc(new long[] {2026, 11, 1, 1, 30, 0}, ny.getRules()) * 1000);
    assertArrayEquals(
        new long[] {2026, 7, 1, 8, 0, 0},
        Zones.wallAt(Js.dateUtc(2026, 6, 1, 12, 0, 0, 0) / 1000, ny.getRules()));
  }

  @Test
  void toNumberAndParseInt() {
    Object[][] ints = {{"5", 5.0}, {" 7x", 7.0}, {"-3", -3.0}, {"+2", 2.0}};
    for (Object[] c : ints) {
      assertEquals(c[1], CronPattern.parseInt((String) c[0]), "parseInt(" + c[0] + ")");
    }
    Object[][] numbers = {{"", 0.0}, {" 2 ", 2.0}, {"1e1", 10.0}, {"2.", 2.0}, {".5", 0.5}};
    for (Object[] c : numbers) {
      assertEquals(c[1], CronPattern.toNumber((String) c[0]), "Number(" + c[0] + ")");
    }
    for (String text : new String[] {"x", "1L", "e1", ".", "1e", "--1"}) {
      assertTrue(Double.isNaN(CronPattern.toNumber(text)), "Number(" + text + ")");
    }
  }

  @Test
  void aStartNoJavaScriptDateHoldsHasNoFires() {
    // A foreign row's time near Long.MIN_VALUE or Long.MAX_VALUE; croner is never given one.
    for (String text : new String[] {"0 * * * *", "0 0 L * ?", "0 0 * * 5#2"}) {
      for (long from :
          new long[] {
            Long.MIN_VALUE,
            Long.MIN_VALUE + 1,
            -8_640_000_000_000_001L,
            8_640_000_000_000_001L,
            Long.MAX_VALUE
          }) {
        assertEquals(List.of(), runs(text, "Europe/London", 2, from), text + " from " + from);
      }
    }
    assertEquals(
        List.of("-271820-01-01T00:00:00.000Z"),
        runs("0 0 1 1 *", "UTC", 1, -8_640_000_000_000_000L));
  }

  @Test
  void zonesAreFoundWithoutRegardToCase() {
    for (String name :
        new String[] {
          "America/New_York",
          "america/new_york",
          "AMERICA/NEW_YORK",
          "utc",
          "UTC",
          "Etc/GMT+5",
          "etc/gmt+5",
          "+05:30",
          "-0800",
          "+05"
        }) {
      assertTrue(Zones.find(name) != null, name + " should be a zone");
    }
    for (String name :
        new String[] {
          "Local",
          "local",
          "Bogus/Zone",
          "+25:00",
          "+5",
          "America/New_York/../New_York",
          "a\0b",
          "Etc/Unknown"
        }) {
      assertEquals(null, Zones.find(name), name + " should not be a zone");
    }
    assertEquals(ZoneId.systemDefault(), Zones.find(""));
  }
}
