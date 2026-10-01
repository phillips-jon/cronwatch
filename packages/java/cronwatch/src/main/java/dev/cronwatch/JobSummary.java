package dev.cronwatch;

import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * A job and its health, as the dashboard shows it.
 *
 * <p>Build one with {@link #of}, not the canonical constructor: a record that may grow gains a
 * component in a minor release, which changes its constructor, while {@code of} keeps its
 * parameters and gives the new component its default.
 *
 * @param name the job's name
 * @param definition its stored definition
 * @param health how it looks at a glance
 * @param open the conditions open
 * @param lastRun its newest run, or null
 * @param nextExpectedAt when the schedule says the next run is due; null without a schedule
 * @param consecutiveFailures failed runs in a row
 * @param silencedUntil when a silence ends, or null
 * @param stats its last twenty runs of any status
 */
public record JobSummary(
    String name,
    Definition definition,
    JobHealth health,
    List<Condition> open,
    @Nullable Run lastRun,
    @Nullable Long nextExpectedAt,
    long consecutiveFailures,
    @Nullable Long silencedUntil,
    Stats stats) {

  /**
   * A job's last twenty runs of any status; the percentiles are over the successful ones among
   * them.
   *
   * @param runs finished runs among the twenty
   * @param okRate the share of those that succeeded, 1 when there are none
   * @param p50Ms the median duration of the successful ones, or null
   * @param p95Ms the 95th percentile duration of the successful ones, or null
   */
  public record Stats(long runs, double okRate, @Nullable Long p50Ms, @Nullable Long p95Ms) {}

  /** A summary with these fields. */
  public static JobSummary of(
      String name,
      Definition definition,
      JobHealth health,
      List<Condition> open,
      @Nullable Run lastRun,
      @Nullable Long nextExpectedAt,
      long consecutiveFailures,
      @Nullable Long silencedUntil,
      Stats stats) {
    return new JobSummary(
        name,
        definition,
        health,
        open,
        lastRun,
        nextExpectedAt,
        consecutiveFailures,
        silencedUntil,
        stats);
  }

  /** Keeps unmodifiable copies. */
  public JobSummary {
    Objects.requireNonNull(name, "name");
    Objects.requireNonNull(definition, "definition");
    Objects.requireNonNull(health, "health");
    Objects.requireNonNull(stats, "stats");
    open = List.copyOf(open);
  }

  /** The summary as the SDK writes it. */
  public JsObject toValue() {
    List<Object> conditions = new ArrayList<>();
    for (Condition c : open) {
      conditions.add(c.value());
    }
    JsObject s =
        new JsObject()
            .set("runs", stats.runs())
            .set("okRate", stats.okRate())
            .set("p50Ms", stats.p50Ms())
            .set("p95Ms", stats.p95Ms());
    return new JsObject()
        .set("name", name)
        .set("definition", definition.toObject())
        .set("health", health.value())
        .set("open", conditions)
        .set("lastRun", lastRun == null ? null : lastRun.toValue())
        .set("nextExpectedAt", nextExpectedAt)
        .set("consecutiveFailures", consecutiveFailures)
        .set("silencedUntil", silencedUntil)
        .set("stats", s);
  }

  /** The SDK's JSON. */
  public String toJson() {
    return toValue().toJson();
  }
}
