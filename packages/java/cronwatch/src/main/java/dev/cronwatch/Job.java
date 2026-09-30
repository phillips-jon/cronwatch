package dev.cronwatch;

import dev.cronwatch.Core.JobDef;
import org.jspecify.annotations.Nullable;

/**
 * A declared job's handle, from {@link Cronwatch#job}. Safe to share and use from any thread.
 *
 * <pre>{@code
 * nightly.run(job -> {
 *   reports.build(job);          // an IOException thrown here is thrown from run()
 *   job.log("Report written");
 * });
 * Path path = nightly.call(job -> reports.build(job));
 * }</pre>
 */
public final class Job {
  private final Cronwatch cronwatch;
  private final JobDef def;

  Job(Cronwatch cronwatch, JobDef def) {
    this.cronwatch = cronwatch;
    this.def = def;
  }

  JobDef def() {
    return def;
  }

  /** The job's name. */
  public String name() {
    return def.name();
  }

  /** The job's definition as it is stored. */
  public Definition definition() {
    return def.stored();
  }

  /** The client the job was declared on. */
  public Cronwatch cronwatch() {
    return cronwatch;
  }

  /**
   * Runs {@code fn} now, in the calling thread, as a recorded run. The run is recorded however the
   * store is doing: store failures go to the error handler, never to the caller. Anything {@code
   * fn} throws fails the run and is then thrown again as it came, its type and stack intact; an
   * {@link InterruptedException} is thrown again with the interrupt status restored.
   *
   * @throws E what {@code fn} throws
   */
  public <E extends Exception> void run(JobRunnable<E> fn) throws E {
    run(RunOptions.defaults(), fn);
  }

  /**
   * {@link #run(JobRunnable)} with options: another trigger, or {@link
   * RunOptions#interruptAtTimeout()}.
   *
   * @throws E what {@code fn} throws
   */
  public <E extends Exception> void run(RunOptions options, JobRunnable<E> fn) throws E {
    cronwatch.runs.execute(
        def,
        options,
        job -> {
          fn.run(job);
          return null;
        });
  }

  /**
   * Runs {@code fn} now as a recorded run and returns what it returns: {@link #run(JobRunnable)}
   * for a function with a value. A {@code String} returned is the run's output when nothing was
   * logged (and what an expect rule checks); an HTTP answer of 400 or more fails the run.
   *
   * @throws E what {@code fn} throws
   */
  public <T extends @Nullable Object, E extends Exception> T call(JobCallable<T, E> fn) throws E {
    return call(RunOptions.defaults(), fn);
  }

  /**
   * {@link #call(JobCallable)} with options.
   *
   * @throws E what {@code fn} throws
   */
  public <T extends @Nullable Object, E extends Exception> T call(
      RunOptions options, JobCallable<T, E> fn) throws E {
    return cronwatch.runs.execute(def, options, fn::call).value();
  }

  /**
   * Records a running run now, to finish later with the handle, perhaps from another process (see
   * {@link #resume}). Store failures go to the error handler. A run that is never finished is
   * marked stuck by the first check after the job's timeout.
   *
   * @throws CronwatchException for an invalid run id, or one that belongs to another job
   */
  public RunHandle start(StartOptions options) {
    return cronwatch.startRun(def, options);
  }

  /** {@link #start(StartOptions)} with the defaults: trigger {@code start}, a new id. */
  public RunHandle start() {
    return start(StartOptions.defaults());
  }

  /**
   * A handle on a run this job started elsewhere, by its id, so this process can log to it and
   * finish it.
   *
   * @throws CronwatchException for an invalid run id, or one that belongs to another job
   */
  public RunHandle resume(String runId) {
    return cronwatch.resumeHandle(def, runId);
  }

  @Override
  public String toString() {
    return "Job[" + def.name() + "]";
  }
}
