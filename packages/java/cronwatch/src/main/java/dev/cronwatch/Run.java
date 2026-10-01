package dev.cronwatch;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * One execution of a job, as a store keeps it. Times are epoch milliseconds.
 *
 * <p>Build one with {@link #of}, not the canonical constructor: a record that may grow gains a
 * component in a minor release, which changes its constructor, while {@code of} keeps its
 * parameters and gives the new component its default.
 *
 * @param id the run's id: a UUID, or one the app gave {@code start}
 * @param job the job's name
 * @param status where the run stands
 * @param startedAt when it started
 * @param finishedAt when it finished, or null while it runs
 * @param durationMs how long it ran, from 0 to 2^53 - 1, or null while it runs
 * @param error the error, when it failed
 * @param output lines logged, or the string the job returned; capped at 16 KB
 * @param metrics numbers the run reported
 * @param trigger what started the run: {@code run}, {@code handler}, {@code start} or a value of
 *     the app's
 */
public record Run(
    String id,
    String job,
    RunStatus status,
    long startedAt,
    @Nullable Long finishedAt,
    @Nullable Long durationMs,
    @Nullable String error,
    @Nullable String output,
    Metrics metrics,
    String trigger) {

  /** Checks that the required components are there. */
  public Run {
    Objects.requireNonNull(id, "id");
    Objects.requireNonNull(job, "job");
    Objects.requireNonNull(status, "status");
    Objects.requireNonNull(metrics, "metrics");
    Objects.requireNonNull(trigger, "trigger");
  }

  /** A run, as a store reads one back: every field the SDK's run has, in its order. */
  public static Run of(
      String id,
      String job,
      RunStatus status,
      long startedAt,
      @Nullable Long finishedAt,
      @Nullable Long durationMs,
      @Nullable String error,
      @Nullable String output,
      Metrics metrics,
      String trigger) {
    return new Run(
        id, job, status, startedAt, finishedAt, durationMs, error, output, metrics, trigger);
  }

  /** A run that has just started: running, with nothing recorded yet. */
  public static Run running(String id, String job, long startedAt, String trigger) {
    return new Run(
        id, job, RunStatus.RUNNING, startedAt, null, null, null, null, Metrics.empty(), trigger);
  }

  /** This run with another status. */
  public Run withStatus(RunStatus status) {
    return new Run(
        id, job, status, startedAt, finishedAt, durationMs, error, output, metrics, trigger);
  }

  /** This run with the fields a finish writes. */
  public Run finished(
      RunStatus status,
      @Nullable Long finishedAt,
      @Nullable Long durationMs,
      @Nullable String error,
      @Nullable String output,
      Metrics metrics) {
    return new Run(
        id, job, status, startedAt, finishedAt, durationMs, error, output, metrics, trigger);
  }

  /** This run with another error. */
  public Run withError(@Nullable String error) {
    return new Run(
        id, job, status, startedAt, finishedAt, durationMs, error, output, metrics, trigger);
  }

  /** This run with another output. */
  public Run withOutput(@Nullable String output) {
    return new Run(
        id, job, status, startedAt, finishedAt, durationMs, error, output, metrics, trigger);
  }

  /** The run as the SDK writes it. */
  public JsObject toValue() {
    return new JsObject()
        .set("id", id)
        .set("job", job)
        .set("status", status.value())
        .set("startedAt", startedAt)
        .set("finishedAt", finishedAt)
        .set("durationMs", durationMs)
        .set("error", error)
        .set("output", output)
        .set("metrics", metrics.toValue())
        .set("trigger", trigger);
  }

  /** The SDK's JSON. */
  public String toJson() {
    return toValue().toJson();
  }

  /**
   * Reads the SDK's JSON.
   *
   * @throws Json.JsonException when it is not a run
   */
  public static Run fromJson(String text) {
    return fromValue(Json.parse(text));
  }

  /**
   * Reads the SDK's JSON value: a field of another type reads as the SDK's code would treat it (a
   * string field that is not a string is empty, a time that is not a number is 0).
   *
   * @throws Json.JsonException when it is not an object, or its metrics are not numbers
   */
  public static Run fromValue(@Nullable Object v) {
    if (!(v instanceof JsObject o)) {
      throw new Json.JsonException("a run must be an object, not " + Js.typeOf(v));
    }
    return new Run(
        Values.string(o, "id"),
        Values.string(o, "job"),
        RunStatus.of(Values.string(o, "status")),
        Values.integer(o, "startedAt"),
        Values.nullableInteger(o, "finishedAt"),
        Values.nullableInteger(o, "durationMs"),
        Values.nullableString(o, "error"),
        Values.nullableString(o, "output"),
        Metrics.fromValue(o.get("metrics")),
        Values.string(o, "trigger"));
  }

  /** What the records share for reading JSON fields. */
  static final class Values {
    private Values() {}

    static String string(JsObject o, String key) {
      return o.get(key) instanceof String s ? s : "";
    }

    static @Nullable String nullableString(JsObject o, String key) {
      return o.get(key) instanceof String s ? s : null;
    }

    static long integer(JsObject o, String key) {
      return o.get(key) instanceof Number n ? Js.toLong(n.doubleValue()) : 0;
    }

    static @Nullable Long nullableInteger(JsObject o, String key) {
      return o.get(key) instanceof Number n ? Js.toLong(n.doubleValue()) : null;
    }

    static double number(JsObject o, String key) {
      return o.get(key) instanceof Number n ? n.doubleValue() : Double.NaN;
    }
  }
}
