package dev.cronwatch.jobrunr;

import dev.cronwatch.JobOptions;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import org.jspecify.annotations.Nullable;

/**
 * Options for {@link CronwatchJobRunr#watch}. Immutable; each method returns a new value.
 *
 * <pre>{@code
 * CronwatchJobRunr.watch(cw, storageProvider, JobRunrOptions.defaults()
 *     .app("billing")
 *     .job("nightly-report", JobOptions.builder().expect("Report written"))
 *     .watchJob("send-invoice"));
 * }</pre>
 */
public final class JobRunrOptions {
  private static final JobRunrOptions DEFAULT =
      new JobRunrOptions(null, JobOptions.builder(), Map.of(), Set.of(), Duration.ofMinutes(1));

  final @Nullable String app;
  final JobOptions jobDefaults;
  final Map<String, JobOptions> jobs;
  final Set<String> watched;
  final Duration readEvery;

  private JobRunrOptions(
      @Nullable String app,
      JobOptions jobDefaults,
      Map<String, JobOptions> jobs,
      Set<String> watched,
      Duration readEvery) {
    this.app = app;
    this.jobDefaults = jobDefaults;
    this.jobs = jobs;
    this.watched = watched;
    this.readEvery = readEvery;
  }

  /**
   * No options: the app named by {@code $CRONWATCH_APP_ID}, else the main class, only recurring
   * jobs watched, and the recurring jobs read again every minute.
   */
  public static JobRunrOptions defaults() {
    return DEFAULT;
  }

  /**
   * Names the app in its tag ({@code jobrunr:<app>}) and in its runs' ids, so two apps sharing a
   * store never declare each other's jobs without a schedule. Every server of one app needs the
   * same.
   */
  public JobRunrOptions app(String app) {
    return new JobRunrOptions(
        Objects.requireNonNull(app, "app"), jobDefaults, jobs, watched, readEvery);
  }

  /** Job options for every job, before its schedule and its own options. */
  public JobRunrOptions jobDefaults(JobOptions options) {
    return new JobRunrOptions(app, options.copy(), jobs, watched, readEvery);
  }

  /**
   * Job options for one job, by its CronWatch name (a recurring job's id, or the name {@link
   * #watchJob} gives), after its schedule, so a schedule given here replaces the recurring job's.
   */
  public JobRunrOptions job(String name, JobOptions options) {
    Map<String, JobOptions> more = new LinkedHashMap<>(jobs);
    more.put(Objects.requireNonNull(name, "name"), options.copy());
    return new JobRunrOptions(app, jobDefaults, Map.copyOf(more), watched, readEvery);
  }

  /**
   * Watches jobs that are not recurring whose JobRunr name ({@code @Job(name = "...")}) is {@code
   * name}, each attempt a run of the CronWatch job of that name, with no schedule. Recurring jobs
   * are watched without it.
   */
  public JobRunrOptions watchJob(String name) {
    Set<String> more = new TreeSet<>(watched);
    more.add(Objects.requireNonNull(name, "name"));
    return new JobRunrOptions(app, jobDefaults, jobs, Set.copyOf(more), readEvery);
  }

  /** How often the recurring jobs are read again. */
  public JobRunrOptions readEvery(Duration every) {
    if (every.isNegative() || every.isZero()) {
      throw new IllegalArgumentException("readEvery must be longer than zero");
    }
    return new JobRunrOptions(app, jobDefaults, jobs, watched, every);
  }

  @Override
  public String toString() {
    return "JobRunrOptions[app="
        + (app == null ? "default" : app)
        + ", jobs="
        + jobs.keySet()
        + ", watched="
        + watched
        + "]";
  }
}
