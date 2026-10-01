package dev.cronwatch;

import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;

/**
 * What a check found and sent.
 *
 * <p>Build one with {@link #of}, not the canonical constructor: a record that may grow gains a
 * component in a minor release, which changes its constructor, while {@code of} keeps its
 * parameters and gives the new component its default.
 *
 * @param checkedAt when the check looked, epoch milliseconds
 * @param jobs every job the store knows, with its health
 * @param alerts the alerts the check made (each delivered, or queued for the next check)
 * @param pruned how many old runs were deleted
 */
public record CheckResult(long checkedAt, List<JobSummary> jobs, List<Alert> alerts, long pruned) {
  /** A result with these fields. */
  public static CheckResult of(
      long checkedAt, List<JobSummary> jobs, List<Alert> alerts, long pruned) {
    return new CheckResult(checkedAt, jobs, alerts, pruned);
  }

  /** Keeps unmodifiable copies. */
  public CheckResult {
    jobs = List.copyOf(jobs);
    alerts = List.copyOf(alerts);
  }

  /** The result as the SDK writes it. */
  public JsObject toValue() {
    List<Object> js = new ArrayList<>();
    for (JobSummary j : jobs) {
      js.add(j.toValue());
    }
    List<Object> as = new ArrayList<>();
    for (Alert a : alerts) {
      as.add(a.toValue());
    }
    return new JsObject()
        .set("checkedAt", checkedAt)
        .set("jobs", js)
        .set("alerts", as)
        .set("pruned", pruned);
  }

  /** The SDK's JSON. */
  public String toJson() {
    return toValue().toJson();
  }
}
