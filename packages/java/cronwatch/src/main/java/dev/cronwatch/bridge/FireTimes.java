package dev.cronwatch.bridge;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * A scheduler's own fire times, from its own code, for {@link Bridge#checkFires}: given {@code
 * start} and {@code end} in epoch milliseconds, the one at or before {@code start} and every one
 * after it up to the first past {@code end}, or {@link Bridge#SAMPLE_RUNS} of them after that first
 * one when {@code end} is null, ascending. A schedule that never fires again answers {@link
 * ScheduleException#neverFires}.
 */
@FunctionalInterface
public interface FireTimes {
  /** The fire times around {@code start}, as described above. */
  List<Long> between(long start, @Nullable Long end) throws ScheduleException;

  /** A scheduler's next fire time strictly after an instant, epoch milliseconds, or null. */
  @FunctionalInterface
  interface Next {
    /** The first fire strictly after {@code at}, or null when there is none. */
    @Nullable Long after(long at);
  }

  /**
   * The fire times of a scheduler that can only be asked for the next one (Spring's and Quartz's
   * {@code CronExpression}): the one at or before a time is found by asking from a window before it
   * that grows from a second until it holds one, so a cron that fires every second walks a few
   * fires and a yearly one a few steps, up to twelve years back. {@code scheduler} names it in the
   * answer for a schedule that never fires.
   */
  static FireTimes walking(Next next, String scheduler) {
    long longestBack = 12L * 366 * 86_400_000L;
    return (start, end) -> {
      List<Long> out = new ArrayList<>();
      long at = start;
      for (long back = 1000; back <= longestBack; back *= 8) {
        Long found = next.after(start - back - 1);
        if (found != null && found <= start) {
          at = found;
          while (true) {
            Long following = next.after(at);
            if (following == null || following > start) {
              break;
            }
            at = following;
          }
          out.add(at);
          break;
        }
      }
      while (true) {
        Long following = next.after(at);
        if (following == null) {
          if (out.isEmpty()) {
            throw ScheduleException.neverFires(
                scheduler + " finds no fire time after " + Instant.ofEpochMilli(start));
          }
          return out;
        }
        out.add(following);
        at = following;
        if ((end == null && out.size() > Bridge.SAMPLE_RUNS) || (end != null && following > end)) {
          return out;
        }
      }
    };
  }
}
