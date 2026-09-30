package dev.cronwatch;

import dev.cronwatch.json.JsObject;
import java.util.Objects;

/**
 * One metric over its ceiling or its baseline.
 *
 * @param metric the metric's name
 * @param value what the run reported
 * @param limit the ceiling, or three times the usual value
 * @param basis {@code budget}, or how the baseline was worked out
 */
public record BudgetBreach(String metric, double value, double limit, String basis) {
  /** Checks that the components are there. */
  public BudgetBreach {
    Objects.requireNonNull(metric, "metric");
    Objects.requireNonNull(basis, "basis");
  }

  /** The breach as the SDK writes it. */
  public JsObject toValue() {
    return new JsObject()
        .set("metric", metric)
        .set("value", value)
        .set("limit", limit)
        .set("basis", basis);
  }
}
