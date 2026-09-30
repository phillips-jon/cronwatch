package dev.cronwatch.bridge;

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
}
