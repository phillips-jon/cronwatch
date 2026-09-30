package dev.cronwatch.internal.evaluate;

import dev.cronwatch.Alert;
import dev.cronwatch.AlertDetails;
import dev.cronwatch.AlertType;
import dev.cronwatch.BudgetBreach;
import dev.cronwatch.Condition;
import dev.cronwatch.Definition;
import dev.cronwatch.JobHealth;
import dev.cronwatch.JobState;
import dev.cronwatch.JobSummary;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.duration.Durations;
import dev.cronwatch.internal.duration.Schedules;
import dev.cronwatch.internal.duration.Schedules.ParsedSchedule;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * Pure decisions about a job's health (the SDK's {@code evaluate.ts}). Each function takes the
 * current state and returns the new state plus the alerts that should go out. Nothing here touches
 * a store or a network, which is what makes it testable, and what lets {@code
 * conformance/evaluate.json} replay a job's life through it event by event.
 *
 * <p>A stored definition may hold anything another writer put there, so a field that cannot be read
 * throws {@link IllegalArgumentException} with the message the SDK's code would have thrown; the
 * client reports it and shows the job as it would an unevaluable one.
 */
public final class Evaluate {
  private Evaluate() {}

  /** The default grace: ten minutes. */
  public static final double DEFAULT_GRACE_MS = 10 * 60_000;

  /** The default timeout: an hour. */
  public static final double DEFAULT_TIMEOUT_MS = 60 * 60_000;

  /** Runs faster than this are never called slow, whatever the baseline says. */
  static final double SLOW_FLOOR_MS = 10_000;

  /** How many earlier runs a baseline needs before it is trusted. */
  static final int BASELINE_MIN_RUNS = 5;

  /** How many successful runs a baseline looks at, and how many runs a summary covers. */
  public static final int BASELINE_WINDOW = 20;

  /** The longest duration written: 2^53 - 1, which every port and store reads back unchanged. */
  public static final long MAX_DURATION_MS = Js.MAX_SAFE_INTEGER;

  /** An alert before it has a title and message. */
  public record AlertDraft(AlertType type, @Nullable Run run, AlertDetails details) {
    /** The draft as the SDK writes one. */
    public JsObject toValue() {
      return new JsObject()
          .set("type", type.value())
          .set("run", run == null ? null : run.toValue())
          .set("details", details.toValue());
    }
  }

  /** A state worked out, and the alerts it owes. */
  public record Evaluation(JobState state, List<AlertDraft> alerts) {
    /** Keeps an unmodifiable copy of the alerts. */
    public Evaluation {
      alerts = List.copyOf(alerts);
    }
  }

  /** What {@link #onCheck} found besides the evaluation. */
  public record CheckOutcome(
      Evaluation evaluation, @Nullable Long nextExpectedAt, @Nullable Long dueAt) {}

  /**
   * How long a run took, from {@code startedAt} to {@code finishedAt}: 0 when it started later, and
   * never more than {@link #MAX_DURATION_MS}. A foreign row's start near a 64-bit limit must not
   * make a duration no store can write.
   */
  public static long runDuration(long startedAt, long finishedAt) {
    long ms;
    try {
      ms = Math.subtractExact(finishedAt, startedAt);
    } catch (ArithmeticException e) {
      ms = finishedAt > startedAt ? Long.MAX_VALUE : Long.MIN_VALUE;
    }
    return ms > 0 ? Math.min(ms, MAX_DURATION_MS) : 0;
  }

  /**
   * The version a stored state's {@code version} value counts as for {@code compareAndSetState}: a
   * JSON number that is a whole number from 0 to 2^53 - 1, else 0.
   */
  public static long stateVersion(@Nullable Object version) {
    if (version instanceof Number n) {
      double d = n.doubleValue();
      if (Js.isInteger(d) && d >= 0 && d <= MAX_DURATION_MS) {
        return (long) d;
      }
    }
    return 0;
  }

  /** a - b, held at the ends of the range. */
  static long saturatingSub(long a, long b) {
    try {
      return Math.subtractExact(a, b);
    } catch (ArithmeticException e) {
      return a > b ? Long.MAX_VALUE : Long.MIN_VALUE;
    }
  }

  /** A fresh state: nothing open, no failures, empty lists. */
  public static JobState emptyState(String job) {
    return JobState.empty(job);
  }

  /**
   * A stored state with every field present, or a fresh one. State written by an older version
   * lacks the newer fields.
   */
  public static JobState normalizeState(@Nullable JobState state, String job) {
    if (state == null) {
      return emptyState(job);
    }
    MutableState s = MutableState.of(state);
    if (s.job.isEmpty()) {
      s.job = job;
    }
    s.pending();
    s.queued();
    return s.toState();
  }

  private static MutableState cloneState(JobState s) {
    return MutableState.of(normalizeState(s, s.job()));
  }

  private static boolean openCondition(MutableState s, Condition c, long now) {
    if (s.open.containsKey(c)) {
      return false;
    }
    s.open.put(c, now);
    return true;
  }

  /**
   * Closes {@code c}. Every open condition has alerted, so closing one owes a recovered message; it
   * is remembered until a successful run leaves nothing open and sends it.
   */
  private static boolean closeCondition(MutableState s, Condition c) {
    if (s.open.remove(c) == null) {
      return false;
    }
    List<Condition> pending = s.pending();
    if (!pending.contains(c)) {
      pending.add(c);
    }
    return true;
  }

  /** The conditions open, in the order they opened. */
  public static List<Condition> openConditions(JobState s) {
    return List.copyOf(s.open().keySet());
  }

  /** A duration option of a definition, or the default when it is absent. */
  private static double durationField(Definition def, String key, double fallback) {
    return def.has(key) ? Durations.parseValue(def.get(key), key) : fallback;
  }

  /** The job's grace in milliseconds. */
  public static double graceMs(Definition def) {
    return durationField(def, "grace", DEFAULT_GRACE_MS);
  }

  /** The job's timeout in milliseconds. */
  public static double timeoutMs(Definition def) {
    return durationField(def, "timeout", DEFAULT_TIMEOUT_MS);
  }

  /** The slow threshold for a successful run and its basis. */
  record Threshold(double ms, String basis) {}

  /** The slow threshold, or null when there is nothing to compare against yet. */
  static @Nullable Threshold slowThreshold(Definition def, List<Run> history) {
    if (def.has("maxDuration")) {
      return new Threshold(
          Durations.parseValue(def.get("maxDuration"), "maxDuration"), "maxDuration");
    }
    List<Double> durations = new ArrayList<>();
    for (Run r : history) {
      if (durations.size() >= BASELINE_WINDOW) {
        break;
      }
      if (r.status().equals(RunStatus.OK) && r.durationMs() != null) {
        durations.add((double) r.durationMs());
      }
    }
    if (durations.size() < BASELINE_MIN_RUNS) {
      return null;
    }
    Double p95 = Stats.percentile(durations, 95);
    double p = p95 == null ? 0 : p95;
    return new Threshold(
        Math.max(2 * p, SLOW_FLOOR_MS),
        "twice the p95 of the last " + durations.size() + " runs (" + Durations.format(p) + ")");
  }

  /** The run's metrics over their ceiling, or, without one, over three times the usual value. */
  static List<BudgetBreach> budgetBreaches(Definition def, Run run, List<Run> history) {
    List<BudgetBreach> breaches = new ArrayList<>();
    JsObject budget = def.get("budget") instanceof JsObject b ? b : null;
    for (Map.Entry<String, Double> e : run.metrics().asMap().entrySet()) {
      String name = e.getKey();
      double value = e.getValue();
      if (budget != null && budget.has(name)) {
        double ceiling = jsNumber(budget.get(name));
        if (value > ceiling) {
          breaches.add(new BudgetBreach(name, value, ceiling, "budget"));
        }
        continue;
      }
      List<Double> past = new ArrayList<>();
      for (Run r : history) {
        if (past.size() >= BASELINE_WINDOW) {
          break;
        }
        Double v = r.metrics().get(name);
        if (r.status().equals(RunStatus.OK) && v != null) {
          past.add(v);
        }
      }
      if (past.size() < BASELINE_MIN_RUNS) {
        continue;
      }
      Double median = Stats.median(past);
      double usual = median == null ? 0 : median;
      if (usual > 0 && value > 3 * usual) {
        breaches.add(
            new BudgetBreach(
                name, value, 3 * usual, "three times the usual " + Format.formatNumber(usual)));
      }
    }
    return breaches;
  }

  /**
   * JavaScript's {@code Number(v)} for a JSON value, as a comparison with {@code >} coerces one.
   */
  static double jsNumber(@Nullable Object v) {
    return switch (v) {
      case null -> 0;
      case Number n -> n.doubleValue();
      case Boolean b -> b ? 1 : 0;
      case String s -> {
        String text = Js.trim(s);
        yield text.isEmpty() ? 0 : stringToNumber(text);
      }
      default -> Double.NaN;
    };
  }

  /**
   * {@code Number(text)} for trimmed, non-empty text: decimal, {@code Infinity}, and the {@code
   * 0x}, {@code 0o} and {@code 0b} integer forms; anything else is NaN.
   */
  static double stringToNumber(String text) {
    double sign = 1;
    String body = text;
    if (text.charAt(0) == '-') {
      sign = -1;
      body = text.substring(1);
    } else if (text.charAt(0) == '+') {
      body = text.substring(1);
    }
    if (body.equals("Infinity")) {
      return sign * Double.POSITIVE_INFINITY;
    }
    int radix = 10;
    if (body.length() >= 2) {
      String prefix = body.substring(0, 2);
      if (prefix.equals("0x") || prefix.equals("0X")) {
        radix = 16;
      } else if (prefix.equals("0o") || prefix.equals("0O")) {
        radix = 8;
      } else if (prefix.equals("0b") || prefix.equals("0B")) {
        radix = 2;
      }
    }
    if (radix != 10) {
      // A sign is not allowed before a prefixed integer.
      if (body.length() != text.length() || body.length() == 2) {
        return Double.NaN;
      }
      double acc = 0;
      for (int i = 2; i < body.length(); i++) {
        int d = Character.digit(body.charAt(i), radix);
        if (d < 0 || body.charAt(i) > 'z') {
          return Double.NaN;
        }
        acc = acc * radix + d;
      }
      return acc;
    }
    boolean digit = false;
    for (int i = 0; i < body.length(); i++) {
      char c = body.charAt(i);
      if (c >= '0' && c <= '9') {
        digit = true;
      } else if (c != '.' && c != 'e' && c != 'E' && c != '+' && c != '-') {
        return Double.NaN;
      }
    }
    if (body.isEmpty() || !digit || body.charAt(0) == '+' || body.charAt(0) == '-') {
      return Double.NaN;
    }
    try {
      return sign * Double.parseDouble(body);
    } catch (NumberFormatException e) {
      return Double.NaN;
    }
  }

  /**
   * Called when a run starts. Missed and stuck are about the absence of a run, so a run starting
   * closes them without an alert; the recovered message waits for a successful finish.
   */
  public static JobState onRunStart(JobState state) {
    MutableState next = cloneState(state);
    closeCondition(next, Condition.MISSED);
    closeCondition(next, Condition.STUCK);
    return next.toState();
  }

  /** {@code Math.max(1, def.failuresBeforeAlert ?? 1)}. */
  private static double failuresBeforeAlert(Definition def) {
    Object v = def.get("failuresBeforeAlert");
    if (v == null) {
      return 1;
    }
    double n = jsNumber(v);
    return Double.isNaN(n) ? n : Math.max(n, 1);
  }

  /**
   * Called when a run finishes with status ok, failed or timeout. {@code history} is the job's
   * earlier runs, newest first, not including this one.
   */
  public static Evaluation onRunFinish(
      Definition def, Run run, JobState state, List<Run> history, long now) {
    MutableState next = cloneState(state);
    List<AlertDraft> alerts = new ArrayList<>();

    if (run.status().equals(RunStatus.OK)) {
      next.consecutiveFailures = 0;
      closeCondition(next, Condition.MISSED);
      closeCondition(next, Condition.STUCK);
      closeCondition(next, Condition.FAILED);

      Threshold slow = slowThreshold(def, history);
      Long duration = run.durationMs();
      if (slow != null && duration != null && duration > slow.ms()) {
        if (openCondition(next, Condition.SLOW, now)) {
          alerts.add(
              new AlertDraft(
                  AlertType.SLOW, run, new AlertDetails.Slow(duration, slow.ms(), slow.basis())));
        }
      } else {
        closeCondition(next, Condition.SLOW);
      }

      List<BudgetBreach> breaches = budgetBreaches(def, run, history);
      if (!breaches.isEmpty()) {
        if (openCondition(next, Condition.OVER_BUDGET, now)) {
          alerts.add(
              new AlertDraft(AlertType.OVER_BUDGET, run, new AlertDetails.OverBudget(breaches)));
        }
      } else {
        closeCondition(next, Condition.OVER_BUDGET);
      }

      List<Condition> pending = next.pending();
      if (!pending.isEmpty() && next.open.isEmpty()) {
        List<Condition> after = List.copyOf(pending);
        pending.clear();
        alerts.add(
            new AlertDraft(
                AlertType.RECOVERED, run, new AlertDetails.Recovered(after, null, null)));
      }
      return new Evaluation(next.toState(), alerts);
    }

    // failed or timeout
    next.consecutiveFailures += 1;
    closeCondition(next, Condition.MISSED);
    double threshold = failuresBeforeAlert(def);
    boolean timedOut = run.status().equals(RunStatus.TIMEOUT);
    Condition condition = timedOut ? Condition.STUCK : Condition.FAILED;
    if (next.consecutiveFailures >= threshold && openCondition(next, condition, now)) {
      alerts.add(
          new AlertDraft(
              timedOut ? AlertType.STUCK : AlertType.FAILED,
              run,
              new AlertDetails.Failure(next.consecutiveFailures, Js.toLong(threshold))));
    }
    return new Evaluation(next.toState(), alerts);
  }

  /** JavaScript's truthiness of a JSON value. */
  public static boolean truthy(@Nullable Object v) {
    return switch (v) {
      case null -> false;
      case Boolean b -> b;
      case Number n -> n.doubleValue() != 0 && !Double.isNaN(n.doubleValue());
      case String s -> !s.isEmpty();
      default -> true;
    };
  }

  /**
   * {@code parseSchedule(def.schedule, def.timezone)} for a stored definition, which may hold
   * anything another writer put there.
   *
   * @throws IllegalArgumentException when the schedule cannot be read
   */
  public static ParsedSchedule parsedSchedule(Definition def) {
    if (!(def.get("schedule") instanceof String text)) {
      throw new IllegalArgumentException("schedule.trim is not a function");
    }
    Object tz = def.get("timezone");
    String zone;
    if (tz == null) {
      zone = null;
    } else if (tz instanceof String s) {
      zone = s.isEmpty() ? null : s;
    } else {
      throw new IllegalArgumentException(
          "timezone " + Json.stringify(tz) + " is not an IANA timezone");
    }
    return Schedules.parse(text, zone);
  }

  /**
   * Called by a check. It decides whether the schedule has been missed: the run the schedule wants
   * next has not started and its grace has run out. {@code lastRun} is the most recent run of any
   * status. A job with no schedule is never missed, and one whose schedule was removed while missed
   * was open gets a recovered alert (reason {@code unscheduled}) for missed alone.
   */
  public static CheckOutcome onCheck(
      Definition def, StoredJob stored, @Nullable Run lastRun, JobState state, long now) {
    MutableState next = cloneState(state);
    List<AlertDraft> alerts = new ArrayList<>();
    if (!truthy(def.get("schedule"))) {
      Long since = next.open.get(Condition.MISSED);
      if (since != null) {
        // The schedule went away while missed was open (the job was declared again without one,
        // or a source retired it), so nothing is due any more. Missed closes now with a recovery
        // of its own; other open conditions keep their own rules. Missed is taken out of the
        // pending recovery too, so the next successful run does not name it again.
        next.open.remove(Condition.MISSED);
        next.pending().removeIf(c -> c.equals(Condition.MISSED));
        alerts.add(
            new AlertDraft(
                AlertType.RECOVERED,
                lastRun,
                new AlertDetails.Recovered(List.of(Condition.MISSED), "unscheduled", since)));
      }
      return new CheckOutcome(new Evaluation(next.toState(), alerts), null, null);
    }

    ParsedSchedule parsed = parsedSchedule(def);
    double grace = graceMs(def);
    Long lastRunAt = lastRun == null ? null : lastRun.startedAt();
    Schedules.Expectation exp = Schedules.expectation(parsed, lastRunAt, stored.createdAt(), grace);
    boolean interval = parsed.kind() == Schedules.Kind.INTERVAL;
    Long nextExpectedAt =
        interval
            ? Schedules.nextFire(parsed, stored.createdAt(), lastRunAt)
            : Schedules.nextFire(parsed, now, null);
    if (exp == null) {
      return new CheckOutcome(new Evaluation(next.toState(), alerts), nextExpectedAt, null);
    }

    // An interval's next run is due a period after the last one started. If that run is still
    // going, the job is busy, not late; stuck covers one that never ends.
    if (interval && lastRun != null && lastRun.status().equals(RunStatus.RUNNING)) {
      return new CheckOutcome(new Evaluation(next.toState(), alerts), nextExpectedAt, exp.dueAt());
    }

    if (now > exp.deadline()) {
      if (openCondition(next, Condition.MISSED, now)) {
        alerts.add(
            new AlertDraft(
                AlertType.MISSED,
                lastRun,
                new AlertDetails.Missed(exp.dueAt(), exp.deadline(), grace, lastRunAt)));
      }
    } else {
      // A run has started since it opened, or the grace was widened.
      closeCondition(next, Condition.MISSED);
    }
    return new CheckOutcome(new Evaluation(next.toState(), alerts), nextExpectedAt, exp.dueAt());
  }

  /** Whether a running run has gone on longer than the job's timeout. */
  public static boolean isStuck(Definition def, Run run, long now) {
    if (!run.status().equals(RunStatus.RUNNING)) {
      return false;
    }
    return (double) saturatingSub(now, run.startedAt()) > timeoutMs(def);
  }

  /**
   * {@code next} with nothing opened that was not open in {@code previous}. While a job is silenced
   * nothing new is recorded as an incident: conditions may close (so a job that recovered during
   * the silence shows as healthy) but none may open, so the first problem after the silence ends
   * alerts normally.
   */
  public static JobState muteOpens(JobState previous, JobState next) {
    MutableState muted = cloneState(next);
    muted.open.keySet().removeIf(c -> previous.openAt(c) == null);
    return muted.toState();
  }

  /** Whether a silence is in force at {@code now}. */
  public static boolean isSilenced(JobState state, long now) {
    Long until = state.silencedUntil();
    return until != null && until > now;
  }

  /**
   * An evaluation as it is saved and sent: while the job was silenced when it began, nothing opens
   * and nothing is sent.
   */
  public static Evaluation applySilence(JobState previous, Evaluation e, long now) {
    if (!isSilenced(previous, now)) {
      return e;
    }
    return new Evaluation(muteOpens(previous, e.state()), List.of());
  }

  /**
   * Whether an alert waiting to be retried no longer describes the job, so it is dropped rather
   * than sent late. An alert for a condition is stale once that condition has closed, or has closed
   * and opened again (it opened at a time other than the alert's). A recovery is stale when any
   * condition it names is open again; while they all stay closed it is kept.
   */
  public static boolean staleAlert(Alert alert, JobState state) {
    if (alert.type().equals(AlertType.RECOVERED)) {
      if (!(alert.details() instanceof AlertDetails.Recovered r)) {
        return false;
      }
      for (Condition c : r.after()) {
        if (state.openAt(c) != null) {
          return true;
        }
      }
      return false;
    }
    Long openedAt = state.openAt(Condition.of(alert.type().value()));
    return openedAt == null || openedAt != alert.at();
  }

  /** How a job looks at a glance. Silence wins, then stuck, failing and late. */
  public static JobHealth jobHealth(
      Definition def, @Nullable Run lastRun, JobState state, long now) {
    List<Condition> open = openConditions(state);
    if (isSilenced(state, now)) {
      return JobHealth.SILENCED;
    }
    if (open.contains(Condition.STUCK)) {
      return JobHealth.STUCK;
    }
    if (lastRun != null && isStuck(def, lastRun, now)) {
      return JobHealth.STUCK;
    }
    if (open.contains(Condition.FAILED)
        || (lastRun != null
            && (lastRun.status().equals(RunStatus.FAILED)
                || lastRun.status().equals(RunStatus.TIMEOUT)))) {
      return JobHealth.FAILING;
    }
    if (open.contains(Condition.MISSED)) {
      return JobHealth.LATE;
    }
    return lastRun == null ? JobHealth.NEVER_RAN : JobHealth.HEALTHY;
  }

  /**
   * A job's summary from its most recent runs (newest first; the first {@link #BASELINE_WINDOW} are
   * used) and its state. Stats cover runs of any status; the percentiles are over the successful
   * ones among them.
   */
  public static JobSummary summarize(
      StoredJob stored, List<Run> recent, JobState state, @Nullable Long nextExpectedAt, long now) {
    Run last = recent.isEmpty() ? null : recent.get(0);
    JobHealth health = jobHealth(stored.definition(), last, state, now);
    return summary(stored, recent, state, nextExpectedAt, health);
  }

  /**
   * The summary of a job that could not be evaluated, say because its stored schedule no longer
   * parses. It reads nothing from the definition. The job shows as failing (or silenced, while it
   * is), since it needs a look, and nothing is known about when it is next due.
   */
  public static JobSummary unevaluableSummary(
      StoredJob stored, List<Run> recent, JobState state, long now) {
    JobHealth health = isSilenced(state, now) ? JobHealth.SILENCED : JobHealth.FAILING;
    return summary(stored, recent, state, null, health);
  }

  private static JobSummary summary(
      StoredJob stored,
      List<Run> recent,
      JobState state,
      @Nullable Long nextExpectedAt,
      JobHealth health) {
    List<Run> window = recent.subList(0, Math.min(recent.size(), BASELINE_WINDOW));
    long finished = 0;
    long ok = 0;
    List<Double> okDurations = new ArrayList<>();
    for (Run r : window) {
      if (!r.status().equals(RunStatus.RUNNING)) {
        finished++;
      }
      if (r.status().equals(RunStatus.OK)) {
        ok++;
        if (r.durationMs() != null) {
          okDurations.add((double) r.durationMs());
        }
      }
    }
    Double p50 = Stats.percentile(okDurations, 50);
    Double p95 = Stats.percentile(okDurations, 95);
    return new JobSummary(
        stored.name(),
        stored.definition(),
        health,
        openConditions(state),
        window.isEmpty() ? null : window.get(0),
        nextExpectedAt,
        state.consecutiveFailures(),
        state.silencedUntil(),
        new JobSummary.Stats(
            finished,
            finished > 0 ? (double) ok / finished : 1,
            p50 == null ? null : Js.toLong(p50),
            p95 == null ? null : Js.toLong(p95)));
  }
}
