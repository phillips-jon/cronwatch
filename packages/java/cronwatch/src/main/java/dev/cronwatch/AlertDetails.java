package dev.cronwatch;

import dev.cronwatch.Run.Values;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * What an alert carries beyond its title and message, one record per kind of alert: {@link Missed},
 * {@link Failure} (for failed and stuck), {@link Slow}, {@link OverBudget} and {@link Recovered}.
 */
public sealed interface AlertDetails
    permits AlertDetails.Missed,
        AlertDetails.Failure,
        AlertDetails.Slow,
        AlertDetails.OverBudget,
        AlertDetails.Recovered {

  /** The details as the SDK writes them. */
  JsObject toValue();

  /**
   * Which run was missed.
   *
   * @param dueAt when the run was due
   * @param deadline when the grace ran out
   * @param graceMs the grace
   * @param lastRunAt when the last run started, or null
   */
  record Missed(long dueAt, double deadline, double graceMs, @Nullable Long lastRunAt)
      implements AlertDetails {
    @Override
    public JsObject toValue() {
      return new JsObject()
          .set("dueAt", dueAt)
          .set("deadline", deadline)
          .set("graceMs", graceMs)
          .set("lastRunAt", lastRunAt);
    }
  }

  /**
   * The failures behind a failed or stuck alert.
   *
   * @param consecutiveFailures failures in a row
   * @param threshold the job's {@code failuresBeforeAlert}
   */
  record Failure(long consecutiveFailures, long threshold) implements AlertDetails {
    @Override
    public JsObject toValue() {
      return new JsObject()
          .set("consecutiveFailures", consecutiveFailures)
          .set("threshold", threshold);
    }
  }

  /**
   * How slow a run was.
   *
   * @param durationMs how long it took
   * @param thresholdMs the limit
   * @param basis {@code maxDuration}, or how the baseline was worked out
   */
  record Slow(long durationMs, double thresholdMs, String basis) implements AlertDetails {
    /** Checks that the basis is there. */
    public Slow {
      Objects.requireNonNull(basis, "basis");
    }

    @Override
    public JsObject toValue() {
      return new JsObject()
          .set("durationMs", durationMs)
          .set("thresholdMs", thresholdMs)
          .set("basis", basis);
    }
  }

  /**
   * The metrics over their limits.
   *
   * @param breaches each metric over its limit
   */
  record OverBudget(List<BudgetBreach> breaches) implements AlertDetails {
    /** Keeps an unmodifiable copy. */
    public OverBudget {
      breaches = List.copyOf(breaches);
    }

    @Override
    public JsObject toValue() {
      List<Object> list = new ArrayList<>();
      for (BudgetBreach b : breaches) {
        list.add(b.toValue());
      }
      return new JsObject().set("breaches", list);
    }
  }

  /**
   * The conditions that closed. A recovery with reason {@code unscheduled} closes missed alone
   * because the job no longer has a schedule; {@code since} is when missed opened. Without a
   * reason, a successful run closed everything that was open.
   *
   * @param after the conditions that closed
   * @param reason {@code unscheduled}, or null
   * @param since when missed opened, for an unscheduled recovery
   */
  record Recovered(List<Condition> after, @Nullable String reason, @Nullable Long since)
      implements AlertDetails {
    /** Keeps an unmodifiable copy. */
    public Recovered {
      after = List.copyOf(after);
    }

    @Override
    public JsObject toValue() {
      List<Object> list = new ArrayList<>();
      for (Condition c : after) {
        list.add(c.value());
      }
      JsObject o = new JsObject().set("after", list);
      if (reason != null && !reason.isEmpty()) {
        o.set("reason", reason);
      }
      if (since != null) {
        o.set("since", since);
      }
      return o;
    }
  }

  /**
   * The details of an alert of this type, as the SDK's JSON holds them: a field of another type
   * reads as the SDK's code would treat it, and an alert type this release does not know reads as
   * {@link Failure}.
   */
  static AlertDetails fromValue(AlertType type, JsObject o) {
    if (type.equals(AlertType.MISSED)) {
      return new Missed(
          Values.integer(o, "dueAt"),
          Values.number(o, "deadline"),
          Values.number(o, "graceMs"),
          Values.nullableInteger(o, "lastRunAt"));
    }
    if (type.equals(AlertType.SLOW)) {
      return new Slow(
          Values.integer(o, "durationMs"),
          Values.number(o, "thresholdMs"),
          Values.string(o, "basis"));
    }
    if (type.equals(AlertType.OVER_BUDGET)) {
      List<BudgetBreach> breaches = new ArrayList<>();
      if (o.get("breaches") instanceof List<?> list) {
        for (Object b : list) {
          JsObject bo = b instanceof JsObject x ? x : new JsObject();
          breaches.add(
              new BudgetBreach(
                  Values.string(bo, "metric"),
                  Values.number(bo, "value"),
                  Values.number(bo, "limit"),
                  Values.string(bo, "basis")));
        }
      }
      return new OverBudget(breaches);
    }
    if (type.equals(AlertType.RECOVERED)) {
      List<Condition> after = new ArrayList<>();
      if (o.get("after") instanceof List<?> list) {
        for (Object c : list) {
          if (c instanceof String s) {
            after.add(Condition.of(s));
          }
        }
      }
      return new Recovered(
          after, Values.nullableString(o, "reason"), Values.nullableInteger(o, "since"));
    }
    return new Failure(Values.integer(o, "consecutiveFailures"), Values.integer(o, "threshold"));
  }
}
