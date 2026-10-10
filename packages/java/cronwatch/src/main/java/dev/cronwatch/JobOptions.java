package dev.cronwatch;

import dev.cronwatch.internal.evaluate.Expect;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.jsre.Regexp;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.Predicate;
import org.jspecify.annotations.Nullable;

/**
 * A job's options: when it runs and what counts as trouble. Each setter appends its field in the
 * order called (a setter called twice keeps its first place and its last value, as a JavaScript
 * object does), so the stored definition is the one a Node process writes for an object literal in
 * that order.
 *
 * <pre>{@code
 * cw.job("nightly-report", JobOptions.builder()
 *     .schedule("0 2 * * *").timezone("UTC")
 *     .grace("15m").timeout(Duration.ofMinutes(30))
 *     .expect("Report written").budget("cost", 2));
 * }</pre>
 *
 * <p>Durations take the SDK's text ({@code "15m"}, {@code "1h30m"}, stored as written), a {@link
 * Duration}, or milliseconds (stored as a number). Options are checked when the job is declared
 * ({@link Cronwatch#job}), with the SDK's messages. A {@code JobOptions} is not safe for use from
 * several threads at once; {@link Cronwatch#job} copies it.
 */
public final class JobOptions {
  final JsObject fields;
  @Nullable Expect expect;

  private JobOptions(JsObject fields, @Nullable Expect expect) {
    this.fields = fields;
    this.expect = expect;
  }

  /** No options yet. */
  public static JobOptions builder() {
    return new JobOptions(new JsObject(), null);
  }

  /** A copy of these options, to change without changing these. */
  public JobOptions copy() {
    return new JobOptions(fields.copy(), expect);
  }

  private JobOptions put(String key, @Nullable Object value) {
    fields.set(key, value);
    return this;
  }

  /**
   * When the job is supposed to run: a five or six field cron expression ({@code "0 2 * * *"}), a
   * nickname ({@code "@hourly"}), or an interval ({@code "every 5m"}). Leave it out for a job with
   * no fixed cadence: failures, duration, and budgets are still watched, but nothing is ever
   * missed.
   */
  public JobOptions schedule(String expression) {
    return put("schedule", expression);
  }

  /**
   * The IANA zone the cron expression is read in. The default is the JVM's ({@code TZ}, {@code
   * /etc/localtime}, or {@code -Duser.timezone}). Vercel and GitHub Actions run their crons in UTC.
   */
  public JobOptions timezone(String zone) {
    return put("timezone", zone);
  }

  /** How late a run may start before it counts as missed, as the SDK's text. Default 10m. */
  public JobOptions grace(String duration) {
    return put("grace", duration);
  }

  /** How late a run may start before it counts as missed. Default 10m. */
  public JobOptions grace(Duration duration) {
    return put("grace", millis(duration, "grace"));
  }

  /** How late a run may start before it counts as missed, in milliseconds. Default 10m. */
  public JobOptions grace(double ms) {
    return put("grace", ms);
  }

  /**
   * How long a run may go on before it is treated as stuck and marked timeout (a failure), as the
   * SDK's text. Default 1h. {@link JobContext#cancelled()} turns true when it passes. Not {@link
   * #maxDuration}, which flags a run that finished successfully but slowly: set this well above it.
   */
  public JobOptions timeout(String duration) {
    return put("timeout", duration);
  }

  /** How long a run may go on before it is treated as stuck. Default 1h. */
  public JobOptions timeout(Duration duration) {
    return put("timeout", millis(duration, "timeout"));
  }

  /** How long a run may go on before it is treated as stuck, in milliseconds. Default 1h. */
  public JobOptions timeout(double ms) {
    return put("timeout", ms);
  }

  /**
   * Alerts when a successful run takes longer, as the SDK's text. Without it, a run is slow when it
   * takes more than twice the p95 of recent runs (and over 10s), once there are five runs to
   * compare against.
   */
  public JobOptions maxDuration(String duration) {
    return put("maxDuration", duration);
  }

  /** Alerts when a successful run takes longer. */
  public JobOptions maxDuration(Duration duration) {
    return put("maxDuration", millis(duration, "maxDuration"));
  }

  /** Alerts when a successful run takes longer, in milliseconds. */
  public JobOptions maxDuration(double ms) {
    return put("maxDuration", ms);
  }

  /**
   * A ceiling for a metric reported with {@link JobContext#metric}: {@code budget("cost", 2)}
   * alerts when a run reports cost above 2. Give it once per metric; the ceilings keep the order
   * given. Metrics without a ceiling alert when a run reports more than three times the recent
   * median, once there are five runs to compare against.
   */
  public JobOptions budget(String metric, double ceiling) {
    JsObject budget = fields.get("budget") instanceof JsObject b ? b : new JsObject();
    budget.set(metric, ceiling);
    return put("budget", budget);
  }

  /** Every ceiling at once, in the map's iteration order, replacing any given before. */
  public JobOptions budget(Map<String, ? extends Number> ceilings) {
    JsObject budget = new JsObject();
    for (Map.Entry<String, ? extends Number> e : ceilings.entrySet()) {
      budget.set(e.getKey(), e.getValue().doubleValue());
    }
    return put("budget", budget);
  }

  /**
   * A floor for a metric reported with {@link JobContext#metric}: {@code floor("rows", 1)} alerts
   * when a run reports rows below 1. Give it once per metric; the floors keep the order given.
   * Metrics without a floor alert when a run reports 0 or less and the five to twenty successful
   * runs before it all reported more than 0. Catches the job that ran cleanly and wrote nothing. A
   * floor of 0 lets a metric reach 0 without alerting.
   */
  public JobOptions floor(String metric, double floor) {
    JsObject floors = fields.get("floor") instanceof JsObject f ? f : new JsObject();
    floors.set(metric, floor);
    return put("floor", floors);
  }

  /** Every floor at once, in the map's iteration order, replacing any given before. */
  public JobOptions floor(Map<String, ? extends Number> floors) {
    JsObject floor = new JsObject();
    for (Map.Entry<String, ? extends Number> e : floors.entrySet()) {
      floor.set(e.getKey(), e.getValue().doubleValue());
    }
    return put("floor", floor);
  }

  /**
   * Makes a successful run fail unless its output contains {@code text}. Catches the job that exits
   * cleanly and did nothing. Stored as {@code contains "text"}.
   */
  public JobOptions expect(String text) {
    this.expect = new Expect.Contains(text);
    return this;
  }

  /**
   * Makes a successful run fail unless the JavaScript pattern {@code /source/flags} matches its
   * output somewhere. It is run by the port's own engine with JavaScript's semantics, so a stored
   * pattern reads the same in every port; a pattern the engine does not implement is refused here.
   * Stored as {@code matches /source/flags}. A match that runs past the engine's step budget (a
   * pattern that backtracks over an output it does not match) fails the run.
   *
   * @throws CronwatchException when the pattern cannot be read
   */
  public JobOptions expectMatch(String source, String flags) {
    try {
      this.expect = new Expect.Matches(Regexp.compile(source, flags));
    } catch (IllegalArgumentException e) {
      throw CronwatchException.invalid(
          "expect: /"
              + source
              + "/"
              + flags
              + " is not a pattern CronWatch can read: "
              + e.getMessage());
    }
    return this;
  }

  /** {@link #expectMatch(String, String)} with no flags. */
  public JobOptions expectMatch(String source) {
    return expectMatch(source, "");
  }

  /**
   * Makes a successful run fail unless {@code check} answers true for its output. A throw in it
   * fails the run with {@code Output check threw: <message>}. Stored as {@code custom function}.
   */
  public JobOptions expectThat(Predicate<String> check) {
    this.expect = new Expect.That(check);
    return this;
  }

  /** Alerts on the nth consecutive failure rather than the first. Default 1. */
  public JobOptions failuresBeforeAlert(int n) {
    return put("failuresBeforeAlert", n);
  }

  /** Describes the job on the dashboard. */
  public JobOptions description(String text) {
    return put("description", text);
  }

  /** Labels for the job. */
  public JobOptions tags(String... tags) {
    return tags(List.of(tags));
  }

  /** Labels for the job. */
  public JobOptions tags(List<String> tags) {
    return put("tags", new ArrayList<Object>(tags));
  }

  /**
   * Sets any field of the stored definition, as a JSON value ({@code null}, a Boolean, a Number, a
   * String, a List, or a {@link JsObject}), for a field this release has no setter for.
   */
  public JobOptions field(String key, @Nullable Object value) {
    Json.stringify(value);
    return put(key, Js.copyJson(value));
  }

  /**
   * These options followed by {@code other}'s, as JavaScript spreads two option objects into one
   * ({@code {...these, ...other}}): a field both set keeps its place here and takes {@code other}'s
   * value, and {@code other}'s expect rule, when it has one, replaces this one's. A source uses it
   * to put an app's options between its own.
   */
  public JobOptions merge(JobOptions other) {
    for (Map.Entry<String, @Nullable Object> e : other.fields.entries()) {
      fields.set(e.getKey(), Js.copyJson(e.getValue()));
    }
    if (other.expect != null) {
      expect = other.expect;
    }
    return this;
  }

  /**
   * The definition these options declare under {@code name}, before the client's defaults: the
   * fields in the order given, then the name, then the expect rule as it is stored ({@code contains
   * "..."}, {@code matches /.../}, {@code custom function}). A source compares it with the one it
   * declared last, to declare a job again only when it changed, as the Go port's {@code
   * DescribeJob}. The options are not checked here; {@link Cronwatch#job} checks them.
   */
  public Definition describe(String name) {
    JsObject out = fields.copy();
    out.set("name", name);
    return Expect.toStored(out, expect);
  }

  /** The fields given, as the definition would hold them before defaults and the name. */
  @Override
  public String toString() {
    return "JobOptions" + fields.toJson();
  }

  /** A {@link Duration} as the milliseconds it holds, fractions kept. */
  static double millis(Duration d, String label) {
    if (d.isNegative()) {
      throw CronwatchException.invalid(label + " must be a non-negative number of milliseconds");
    }
    double ms = d.getSeconds() * 1000.0 + d.getNano() / 1e6;
    if (ms > 9_007_199_254_740_991.0) {
      throw CronwatchException.invalid(label + " must be a non-negative number of milliseconds");
    }
    return ms;
  }
}
