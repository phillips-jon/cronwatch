package dev.cronwatch;

import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;

/**
 * What a check found and sent.
 *
 * @param checkedAt when the check looked, epoch milliseconds
 * @param jobs every job the store knows, with its health
 * @param alerts the alerts the check made (each delivered, or queued for the next check)
 * @param pruned how many old runs were deleted
 */
public record CheckResult(long checkedAt, List<JobSummary> jobs, List<Alert> alerts, long pruned) {
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
