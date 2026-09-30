package dev.cronwatch.internal.cron;

import java.time.ZoneId;
import java.time.zone.ZoneRules;
import java.util.ArrayList;
import java.util.List;

/**
 * A port of croner 10, the cron library the SDK uses: its reading of an expression (CronPattern,
 * with its checks and its messages word for word) and its walk to the next matching time
 * (CronDate), habits included: a day the month does not have rolls over, a wall-clock time in a
 * spring-forward gap moves forward by the gap, and a time that happens twice is the earlier one.
 * The names and the order of every step follow croner's source, as the Go, Python, PHP, Rust and
 * Elixir ports do, so they agree on every expression they read, every one they refuse and every
 * fire time.
 *
 * <p>Where it cannot match croner:
 *
 * <ul>
 *   <li>A date no month has ({@code 0 0 30 2 *}) makes croner, which walks by recursion a year at a
 *       time, run out of stack before the year 3000. This port walks in a loop and answers that the
 *       expression never fires.
 *   <li>Croner reads a string with a colon after its first character as a one-time date, through
 *       JavaScript's lenient {@code Date.parse}. This port refuses every such string: one that
 *       looks like an ISO date with "CronPattern: a one-time date is not supported by the Java
 *       port", anything else with the message croner gives for text {@code Date.parse} cannot read,
 *       "Invalid ISO8601 passed to timezone parser.".
 * </ul>
 *
 * <p>An expression that schedules nothing and only answers {@link #nextRuns}; safe to share between
 * threads.
 */
public final class Cron {
  /** The instants a JavaScript Date holds, in milliseconds either side of the epoch. */
  private static final long DATE_RANGE = 8_640_000_000_000_000L;

  private final CronPattern pattern;
  private final ZoneRules rules;

  private Cron(CronPattern pattern, ZoneRules rules) {
    this.pattern = pattern;
    this.rules = rules;
  }

  /**
   * Reads an expression, to be walked in {@code zone}.
   *
   * @throws CronException with croner's message when it is not one
   */
  public static Cron parse(String text, ZoneId zone) {
    if (text.length() > 1 && text.indexOf(':', 1) >= 0) {
      // Croner reads a string with a colon after its first character as a one-time date to fire
      // at, not as a cron expression.
      if (isIsoDate(text)) {
        throw new CronException("CronPattern: a one-time date is not supported by the Java port");
      }
      throw new CronException("Invalid ISO8601 passed to timezone parser.");
    }
    return new Cron(new CronPattern(text), zone.getRules());
  }

  /** {@code /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/}, the start of an ISO date and time. */
  private static boolean isIsoDate(String t) {
    if (t.length() < 16) {
      return false;
    }
    return digits(t, 0, 4)
        && t.charAt(4) == '-'
        && digits(t, 5, 7)
        && t.charAt(7) == '-'
        && digits(t, 8, 10)
        && (t.charAt(10) == 'T' || t.charAt(10) == ' ')
        && digits(t, 11, 13)
        && t.charAt(13) == ':'
        && digits(t, 14, 16);
  }

  private static boolean digits(String t, int from, int to) {
    for (int i = from; i < to; i++) {
      if (t.charAt(i) < '0' || t.charAt(i) > '9') {
        return false;
      }
    }
    return true;
  }

  /** The rules of the zone the expression is walked in. */
  public ZoneRules rules() {
    return rules;
  }

  /**
   * Croner's {@code nextRuns}: up to {@code count} fires after {@code start} (epoch ms), each found
   * from the one before. Fewer when the expression stops firing.
   */
  public List<Long> nextRuns(int count, long start) {
    List<Long> runs = new ArrayList<>(Math.max(0, count));
    // Croner is only ever given a time a JavaScript Date holds. A start outside that (a foreign
    // row's time near Long.MIN_VALUE, say) has no fire after it.
    if (start < -DATE_RANGE || start > DATE_RANGE) {
      return runs;
    }
    CronDate d = CronDate.fromMs(start, rules);
    try {
      for (int i = 0; i < count; i++) {
        if (!d.increment(pattern)) {
          break;
        }
        runs.add(d.timeMs(rules));
      }
    } catch (CronException e) {
      // Croner throws from the walk for a day-of-week bit it does not know; no fire is found.
      return runs;
    }
    return runs;
  }
}
