package dev.cronwatch.internal.core;

import dev.cronwatch.JobContext;
import org.jspecify.annotations.Nullable;

/**
 * The run the calling thread is in, for {@code Cronwatch.current()}: set when a run's function
 * starts and removed in {@code finally} when it ends, so no pooled thread keeps a run that has
 * finished. A thread the job starts has none of its own; {@code JobContext.wrap} and Micrometer's
 * context propagation carry it across.
 */
public final class CurrentRun {
  private static final ThreadLocal<@Nullable JobContext> CURRENT = new ThreadLocal<>();

  private CurrentRun() {}

  /** The calling thread's run, or null. */
  public static @Nullable JobContext get() {
    return CURRENT.get();
  }

  /**
   * Makes {@code context} the calling thread's run, returning the one it replaces (a run nested
   * inside another), to give back to {@link #restore}.
   */
  public static @Nullable JobContext set(@Nullable JobContext context) {
    JobContext previous = CURRENT.get();
    if (context == null) {
      CURRENT.remove();
    } else {
      CURRENT.set(context);
    }
    return previous;
  }

  /** Puts back the run {@link #set} replaced, removing the entry when there was none. */
  public static void restore(@Nullable JobContext previous) {
    if (previous == null) {
      CURRENT.remove();
    } else {
      CURRENT.set(previous);
    }
  }
}
