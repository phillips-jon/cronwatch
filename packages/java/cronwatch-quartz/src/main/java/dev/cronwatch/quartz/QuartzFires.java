package dev.cronwatch.quartz;

import dev.cronwatch.bridge.Bridge;
import dev.cronwatch.bridge.FireTimes;
import dev.cronwatch.bridge.ScheduleException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.TimeZone;
import org.jspecify.annotations.Nullable;
import org.quartz.CronExpression;

/** Quartz's own fire times for a cron trigger's expression, for {@link Bridge#checkFires}. */
final class QuartzFires implements FireTimes {
  /** How far back the fire at or before a time is looked for: past a leap day's eight years. */
  private static final long LONGEST_BACK_MS = 12L * 366 * 86_400_000L;

  private final CronExpression cron;

  QuartzFires(CronExpression cron) {
    this.cron = cron;
  }

  /** The expression read as Quartz reads it, in {@code zone}. */
  static CronExpression parse(String expression, TimeZone zone) throws java.text.ParseException {
    CronExpression cron = new CronExpression(expression);
    cron.setTimeZone(zone);
    return cron;
  }

  @SuppressWarnings("JavaUtilDate") // Quartz's API takes and answers a Date
  private @Nullable Long after(long at) {
    Date next = cron.getNextValidTimeAfter(new Date(at));
    return next == null ? null : next.getTime();
  }

  /**
   * The last fire at or before {@code start}, looked for over a window that grows from a second
   * until one is found, so a cron that fires every second walks a few fires and a yearly one a few
   * steps. Null when there is none within twelve years.
   */
  private @Nullable Long atOrBefore(long start) {
    for (long back = 1000; back <= LONGEST_BACK_MS; back *= 8) {
      Long found = after(start - back - 1);
      if (found != null && found <= start) {
        long at = found;
        while (true) {
          Long next = after(at);
          if (next == null || next > start) {
            return at;
          }
          at = next;
        }
      }
    }
    return null;
  }

  @Override
  public List<Long> between(long start, @Nullable Long end) throws ScheduleException {
    List<Long> out = new ArrayList<>();
    Long first = atOrBefore(start);
    long at = start;
    if (first != null) {
      out.add(first);
      at = first;
    }
    while (true) {
      Long next = after(at);
      if (next == null) {
        if (out.isEmpty()) {
          throw ScheduleException.neverFires(
              "Quartz finds no fire time after " + Instant.ofEpochMilli(start));
        }
        return out;
      }
      out.add(next);
      at = next;
      if ((end == null && out.size() > Bridge.SAMPLE_RUNS) || (end != null && next > end)) {
        return out;
      }
    }
  }
}
