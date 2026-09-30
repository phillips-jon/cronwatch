package dev.cronwatch.quartz;

import dev.cronwatch.JobOptions;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * Options for {@link CronwatchQuartz#watch}. Immutable; each method returns a new value.
 *
 * <pre>{@code
 * CronwatchQuartz.watch(cw, scheduler, QuartzOptions.defaults()
 *     .app("billing")
 *     .jobDefaults(JobOptions.builder().grace("5m"))
 *     .job("reports.nightly", JobOptions.builder().expect("Report written")));
 * }</pre>
 */
public final class QuartzOptions {
  private static final QuartzOptions DEFAULT =
      new QuartzOptions(null, JobOptions.builder(), Map.of(), Duration.ofMinutes(1));

  final @Nullable String app;
  final JobOptions jobDefaults;
  final Map<String, JobOptions> jobs;
  final Duration readEvery;

  private QuartzOptions(
      @Nullable String app,
      JobOptions jobDefaults,
      Map<String, JobOptions> jobs,
      Duration readEvery) {
    this.app = app;
    this.jobDefaults = jobDefaults;
    this.jobs = jobs;
    this.readEvery = readEvery;
  }

  /**
   * No options: the app named by {@code $CRONWATCH_APP_ID}, else the main class, no job options,
   * and the scheduler's jobs read again every minute besides whenever it says they changed.
   */
  public static QuartzOptions defaults() {
    return DEFAULT;
  }

  /**
   * Names the app in its tag ({@code quartz:<app>}) and in its runs' ids, so two apps sharing a
   * store never declare each other's jobs without a schedule. Every node of one app needs the same.
   */
  public QuartzOptions app(String app) {
    return new QuartzOptions(Objects.requireNonNull(app, "app"), jobDefaults, jobs, readEvery);
  }

  /** Job options for every job, before its schedule and its own options. */
  public QuartzOptions jobDefaults(JobOptions options) {
    return new QuartzOptions(app, options.copy(), jobs, readEvery);
  }

  /**
   * Job options for one job, by its CronWatch name ({@code nightlyReport} for a job in the {@code
   * DEFAULT} group, {@code reports.nightly} for {@code nightly} in {@code reports}), after its
   * schedule, so a schedule given here replaces the trigger's.
   */
  public QuartzOptions job(String name, JobOptions options) {
    Map<String, JobOptions> more = new LinkedHashMap<>(jobs);
    more.put(Objects.requireNonNull(name, "name"), options.copy());
    return new QuartzOptions(app, jobDefaults, Map.copyOf(more), readEvery);
  }

  /** How often the scheduler's jobs are read again besides when it says they changed. */
  public QuartzOptions readEvery(Duration every) {
    if (every.isNegative() || every.isZero()) {
      throw new IllegalArgumentException("readEvery must be longer than zero");
    }
    return new QuartzOptions(app, jobDefaults, jobs, every);
  }

  @Override
  public String toString() {
    return "QuartzOptions[app="
        + (app == null ? "default" : app)
        + ", jobs="
        + jobs.keySet()
        + ", readEvery="
        + readEvery
        + "]";
  }
}
