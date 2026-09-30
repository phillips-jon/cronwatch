package dev.cronwatch;

import java.util.List;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * Adds a short diagnosis to every alert except recoveries. Claude triage over plain HTTP comes in a
 * later release; any function can be one. It runs on a virtual thread of the client's and is waited
 * on for 25 seconds, then interrupted; a throw, a timeout or an empty answer is no diagnosis, and
 * triage is not tried again for that alert.
 */
@FunctionalInterface
public interface Triage {
  /**
   * A few sentences on what went wrong, or null or {@code ""} for none.
   *
   * @throws Exception when triage failed, which the client reports
   */
  @Nullable String triage(Context context) throws Exception;

  /**
   * What triage is given.
   *
   * @param alert the alert to diagnose
   * @param recentRuns the job's five newest runs
   */
  record Context(Alert alert, List<Run> recentRuns) {
    /** Keeps an unmodifiable copy. */
    public Context {
      Objects.requireNonNull(alert, "alert");
      recentRuns = List.copyOf(recentRuns);
    }
  }
}
