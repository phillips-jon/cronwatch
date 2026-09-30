package dev.cronwatch;

import java.util.List;
import java.util.Objects;

/**
 * A job's summary and its newest runs, read together: what the dashboard shows.
 *
 * @param job the summary
 * @param runs the newest runs, newest first
 */
public record JobWithRuns(JobSummary job, List<Run> runs) {
  /** Keeps an unmodifiable copy. */
  public JobWithRuns {
    Objects.requireNonNull(job, "job");
    runs = List.copyOf(runs);
  }
}
