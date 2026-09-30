package dev.cronwatch.internal.duration;

import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Gen;
import dev.cronwatch.internal.duration.Schedules.ParsedSchedule;
import dev.cronwatch.internal.js.Js;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Two doors untrusted input comes through: a cron expression (a stored definition, a source's job)
 * in nine zones, and duration text (a silence from the dashboard, a stored grace). Either is read
 * or refused with an {@link IllegalArgumentException}, never another throw; fire times each come
 * later than the last; and a duration is never negative or not finite.
 */
class ScheduleProperties {
  private static final List<String> UNITS = List.of("ms", "s", "m", "h", "d", "w", "x", "");

  @Test
  void cronExpressionsParseOrAreRefusedAndFireForward() {
    Gen.check(
        21,
        300,
        g -> {
          CronFuzzer f = new CronFuzzer(g.anyLong());
          String expression = f.expression();
          long from = g.between(Js.FIRST_DATE_MS, Js.LAST_DATE_MS);
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
        });
  }

  @Test
  void anyTextIsAScheduleOrRefused() {
    Gen.check(
        22,
        300,
        g -> {
          long from = g.anyLong();
          try {
            ParsedSchedule p = Schedules.parse(g.anyString(40), null);
            Schedules.nextFire(p, from, null);
            Schedules.expectation(p, from, from, 0);
          } catch (IllegalArgumentException e) {
            // refused, as the SDK refuses it
          }
        });
  }

  @Test
  void durationTextIsReadOrRefused() {
    Gen.check(
        23,
        500,
        g -> {
          String text = g.anyString(70);
          double ms;
          try {
            ms = Durations.parse(text, "grace");
          } catch (IllegalArgumentException e) {
            return;
          }
          assertTrue(Double.isFinite(ms) && ms >= 0, text + " read as " + ms);
        });
  }

  @Test
  void durationPartsAreReadOrRefused() {
    Gen.check(
        24,
        300,
        g -> {
          long n = g.between(0, 1_000_000_000L);
          String text = n + (g.bool() ? ".5" : "") + g.oneOf(UNITS);
          try {
            double ms = Durations.parse(text, "");
            assertTrue(Double.isFinite(ms) && ms >= 0, text + " read as " + ms);
          } catch (IllegalArgumentException e) {
            assertTrue(e.getMessage().startsWith("duration \""), e.getMessage());
          }
        });
  }
}
