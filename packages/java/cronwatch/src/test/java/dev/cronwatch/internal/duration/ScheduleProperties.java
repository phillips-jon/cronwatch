package dev.cronwatch.internal.duration;

import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.internal.duration.Schedules.ParsedSchedule;
import dev.cronwatch.internal.js.Js;
import net.jqwik.api.ForAll;
import net.jqwik.api.Property;
import net.jqwik.api.constraints.LongRange;

/**
 * Two doors untrusted input comes through: a cron expression (a stored definition, a source's job)
 * in nine zones, and duration text (a silence from the dashboard, a stored grace). Either is read
 * or refused with an {@link IllegalArgumentException}, never another throw; fire times each come
 * later than the last; and a duration is never negative or not finite.
 */
class ScheduleProperties {
  @Property(tries = 300)
  void cronExpressionsParseOrAreRefusedAndFireForward(
      @ForAll long seed,
      @ForAll @LongRange(min = -62_135_596_800_000L, max = 253_402_300_799_999L) long from) {
    CronFuzzer f = new CronFuzzer(seed);
    String expression = f.expression();
    for (String zone : CronFuzzer.ZONES) {
      ParsedSchedule p;
      try {
        p = Schedules.parse(expression, zone);
      } catch (IllegalArgumentException e) {
        continue;
      }
      long at = from;
      for (int i = 0; i < 4; i++) {
        Long next = Schedules.nextFire(p, at, null);
        if (next == null) {
          break;
        }
        assertTrue(next > at, expression + " in " + zone + " went back from " + at);
        assertTrue(next <= Js.LAST_DATE_MS, expression + " fired after 9999");
        at = next;
      }
    }
  }

  @Property(tries = 300)
  void anyTextIsAScheduleOrRefused(@ForAll String text, @ForAll long from) {
    try {
      ParsedSchedule p = Schedules.parse(text, null);
      Schedules.nextFire(p, from, null);
      Schedules.expectation(p, from, from, 0);
    } catch (IllegalArgumentException e) {
      // refused, as the SDK refuses it
    }
  }

  @Property(tries = 500)
  void durationTextIsReadOrRefused(@ForAll String text) {
    double ms;
    try {
      ms = Durations.parse(text, "grace");
    } catch (IllegalArgumentException e) {
      return;
    }
    assertTrue(Double.isFinite(ms) && ms >= 0, text + " read as " + ms);
  }

  @Property(tries = 300)
  void durationPartsAreReadOrRefused(
      @ForAll @LongRange(min = 0, max = 1_000_000_000L) long n, @ForAll boolean fraction) {
    String[] units = {"ms", "s", "m", "h", "d", "w", "x", ""};
    String text = n + (fraction ? ".5" : "") + units[(int) (n % units.length)];
    try {
      double ms = Durations.parse(text, "");
      assertTrue(Double.isFinite(ms) && ms >= 0, text + " read as " + ms);
    } catch (IllegalArgumentException e) {
      assertTrue(e.getMessage().startsWith("duration \""), e.getMessage());
    }
  }
}
