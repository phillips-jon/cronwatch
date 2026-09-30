package dev.cronwatch;

import dev.cronwatch.Core.JobDef;
import dev.cronwatch.internal.core.CurrentRun;
import dev.cronwatch.internal.core.Mdc;
import dev.cronwatch.internal.core.Recorder;
import dev.cronwatch.internal.duration.Durations;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.evaluate.Evaluate.AlertDraft;
import dev.cronwatch.internal.evaluate.Evaluate.Evaluation;
import dev.cronwatch.internal.evaluate.Expect;
import dev.cronwatch.internal.output.Output;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;

/**
 * Running a job: the recorded run around a function ({@code execute}), how a finished run is judged
 * ({@code conclude}), how its finish is written once however many processes finish it ({@code
 * recordFinish}, {@code claimFinish}), runs recorded from elsewhere ({@code recordRun}), and the
 * shutdown hook's record of runs a stopping JVM leaves open.
 */
final class Runs {
  /** Runs read for a baseline, and the most read when failures crowd out the successes. */
  private static final int HISTORY_PAGE = Evaluate.BASELINE_WINDOW + 5;

  private static final int HISTORY_MAX = 200;

  /** The error of a run the shutdown hook records. */
  static final String SHUTDOWN_ERROR = "Shutdown: the JVM stopped while the run was in progress";

  private final Core core;
  private final Delivery delivery;

  Runs(Core core, Delivery delivery) {
    this.core = core;
    this.delivery = delivery;
  }

  /** A run whose function is running in this process, for the shutdown hook. */
  static final class OpenRun {
    final JobDef def;
    final Run run;
    final Recorder recorder;
    final boolean recorded;

    /** The recording once the function has returned, which the hook waits for rather than fail. */
    volatile @Nullable Future<Run> recording;

    OpenRun(JobDef def, Run run, Recorder recorder, boolean recorded) {
      this.def = def;
      this.run = run;
      this.recorder = recorder;
      this.recorded = recorded;
    }
  }

  /** A run once recorded, and what its function returned. */
  record Executed<T>(Run run, @Nullable T value) {}

  /** What a job's function is, whether it returns a value or not. */
  @FunctionalInterface
  interface Body<T> {
    @Nullable T call(JobContext job) throws Throwable;
  }

  /** A job's timeout in milliseconds, or the default when its stored one cannot be read. */
  private static double timeoutOrDefault(Definition def) {
    try {
      return Evaluate.timeoutMs(def);
    } catch (RuntimeException e) {
      return Evaluate.DEFAULT_TIMEOUT_MS;
    }
  }

  /** A stuck run's error: {@code Still running after 30m; marked as timed out}. */
  static String timeoutText(Definition def) {
    return "Still running after "
        + Durations.format(timeoutOrDefault(def))
        + "; marked as timed out";
  }

  /** Throws any throwable, checked or not, as it came. */
  @SuppressWarnings("unchecked")
  static <X extends Throwable> RuntimeException sneakyThrow(Throwable t) throws X {
    throw (X) t;
  }

  /**
   * Runs {@code body} as a recorded run in the calling thread. The function always runs, whatever
   * the store is doing: store failures go to the error handler. Everything after the function
   * returns runs on a virtual thread of the client's that this waits for, however often the caller
   * is interrupted meanwhile. What the function threw is thrown again as it came.
   */
  <T> Executed<T> execute(JobDef def, RunOptions options, Body<T> body) {
    long startedAt = core.now();
    Run run = Run.running(UUID.randomUUID().toString(), def.name(), startedAt, options.trigger);
    // The start is written on the client's thread: an interrupt of the caller cannot cut it.
    boolean recorded = Core.awaitUninterruptibly(core.submit(() -> beginRun(def, run)));
    // Closing missed and stuck happens beside the job, which never waits on it.
    Future<?> closing = recorded ? core.submit(() -> closeOnStart(def.name())) : null;

    Recorder recorder = new Recorder();
    JobContext context =
        new JobContext(
            def.name(),
            run.id(),
            startedAt,
            recorder,
            task -> core.spawn(task, "cancelling " + def.name()));
    Thread thread = Thread.currentThread();
    ReentrantLock running = new ReentrantLock();
    boolean[] inFunction = {true};
    boolean[] interruptedAtTimeout = {false};
    double timeout = timeoutOrDefault(def.stored());
    long delay = (long) Math.min(Math.max(0, timeout), Evaluate.MAX_DURATION_MS);
    ScheduledFuture<?> timer =
        core.timer.schedule(
            () -> {
              context.cancel();
              if (options.interruptAtTimeout) {
                running.lock();
                try {
                  if (inFunction[0]) {
                    interruptedAtTimeout[0] = true;
                    thread.interrupt();
                  }
                } finally {
                  running.unlock();
                }
              }
            },
            delay,
            TimeUnit.MILLISECONDS);
    OpenRun open = new OpenRun(def, run, recorder, recorded);
    core.open.put(run.id(), open);

    T value = null;
    Throwable thrown = null;
    JobContext previous = CurrentRun.set(context);
    Mdc.Saved saved = Mdc.put(def.name(), run.id());
    try {
      value = body.call(context);
    } catch (Throwable t) {
      thrown = t;
    } finally {
      running.lock();
      try {
        inFunction[0] = false;
      } finally {
        running.unlock();
      }
      timer.cancel(false);
      context.end();
      Mdc.restore(saved);
      CurrentRun.restore(previous);
    }
    boolean timedOut = interruptedAtTimeout[0];
    if (timedOut && thrown == null) {
      // The function returned though it was interrupted: the interrupt was ours, so it is not
      // left for the caller's own code.
      Thread.interrupted();
    }

    String failure;
    String resultText = null;
    if (thrown != null) {
      failure = timedOut ? timeoutText(def.stored()) : errorText(thrown);
    } else {
      failure = Http.failure(value);
      if (value instanceof String s) {
        resultText = s;
      }
    }
    String text = resultText;
    boolean markTimeout = timedOut && thrown != null;
    Future<Run> recording =
        core.submit(
            () ->
                finishExecuted(def, run, recorder, text, failure, markTimeout, recorded, closing));
    open.recording = recording;
    Run finished;
    try {
      finished = Core.awaitUninterruptibly(recording);
    } catch (RuntimeException e) {
      core.report(e, "recording " + def.name());
      finished = run;
    } finally {
      core.open.remove(run.id());
    }
    if (thrown != null) {
      if (thrown instanceof InterruptedException) {
        // Well-behaved code restores the interrupt status of a thread it was interrupted in.
        Thread.currentThread().interrupt();
      }
      throw Runs.<RuntimeException>sneakyThrow(thrown);
    }
    return new Executed<>(finished, value);
  }

  /** A throwable as a failed run's error: {@code Name: message} and five frames, capped. */
  static String errorText(Throwable t) {
    try {
      return Output.errorMessage(t);
    } catch (RuntimeException e) {
      // A throwable whose getMessage throws must not leave its run running.
      return Output.errorMessage(t.getClass().getSimpleName(), "", List.of());
    }
  }

  /**
   * The start of a run: the definition synced and the row inserted. Says whether it was written.
   */
  private boolean beginRun(JobDef def, Run run) {
    try {
      core.sync(def);
      Core.call(
          () -> {
            core.store.insertRun(run);
            return null;
          });
      return true;
    } catch (RuntimeException e) {
      core.report(e, "recording " + def.name());
      return false;
    }
  }

  /** Closes missed and stuck for a run that has started. Never throws. */
  @Nullable Void closeOnStart(String name) {
    try {
      core.updateState(name, s -> new Core.Changed<>(Evaluate.onRunStart(s), Boolean.TRUE));
    } catch (RuntimeException e) {
      core.report(e, "starting " + name);
    }
    return null;
  }

  /**
   * The end of a run: its fields set from how it went, judged, written once the start's state
   * update is done, and evaluated. Never throws; the store's failures are reported.
   */
  private Run finishExecuted(
      JobDef def,
      Run run,
      Recorder recorder,
      @Nullable String resultText,
      @Nullable String failure,
      boolean timedOut,
      boolean recorded,
      @Nullable Future<?> closing) {
    String name = def.name();
    long finishedAt = core.now();
    String output = recorder.output();
    if (output == null && failure == null && resultText != null) {
      output = Output.cap(resultText);
    }
    String expectText = recorder.expectText();
    if (expectText == null && failure == null) {
      expectText = resultText;
    }
    Run finished =
        run.finished(
            RunStatus.RUNNING,
            finishedAt,
            Evaluate.runDuration(run.startedAt(), finishedAt),
            null,
            output,
            recorder.metrics());
    finished = conclude(def, finished, failure, expectText, timedOut);
    if (closing != null) {
      try {
        Core.awaitUninterruptibly(closing);
      } catch (RuntimeException e) {
        core.report(e, "starting " + name);
      }
    }
    try {
      String why = recordFinish(def, finished, recorded, finishedAt);
      if (why != null) {
        core.report(
            "run " + finished.id() + " of " + name + " " + why + "; ignored", "finishing " + name);
      }
    } catch (RuntimeException e) {
      core.report(e, "recording " + name);
    }
    return finished;
  }

  /**
   * Sets a finished run's status and error from how it ended, then redacts its output and error.
   * {@code failure} is the error text of a function that failed; with {@code timedOut}, the run is
   * marked as a check would mark a stuck one.
   */
  Run conclude(
      JobDef def,
      Run run,
      @Nullable String failure,
      @Nullable String expectText,
      boolean timedOut) {
    RunStatus status;
    String error;
    if (timedOut) {
      status = RunStatus.TIMEOUT;
      error = failure;
    } else if (failure != null) {
      status = RunStatus.FAILED;
      error = failure;
    } else {
      String unmet = Expect.checkExpectation(def.expect(), expectText);
      status = unmet == null ? RunStatus.OK : RunStatus.FAILED;
      error = unmet;
    }
    // Redacted after the expect check, so a rule can still match what was logged. NULs go last,
    // so not even a custom redact can store one.
    String output = run.output();
    return run.finished(
        status,
        run.finishedAt(),
        run.durationMs(),
        error == null ? null : Output.stripNul(core.redact(error)),
        output == null ? null : Output.stripNul(core.redact(output)),
        run.metrics());
  }

  /**
   * Writes a finished run and evaluates it. {@code recorded} says whether its start was written; if
   * not, it is inserted now. Returns why nothing was recorded (another process finished the run
   * first, say), or null. Throws the store's failure, so a handle can be finished again.
   */
  @Nullable String recordFinish(JobDef def, Run run, boolean recorded, long finishedAt) {
    if (!recorded) {
      // The start was never written; the store may be back by now.
      core.sync(def);
      try {
        Core.call(
            () -> {
              core.store.insertRun(run);
              return null;
            });
        finishRun(def.stored(), run, finishedAt);
        return null;
      } catch (CronwatchException e) {
        // Another process may have recorded a run with this id meanwhile.
        Run stored;
        try {
          stored = Core.call(() -> core.store.getRun(run.id()));
        } catch (RuntimeException again) {
          throw e;
        }
        if (stored == null) {
          throw e;
        }
        if (!stored.job().equals(run.job())) {
          return "belongs to job " + dev.cronwatch.json.Json.quote(stored.job());
        }
      }
    }
    Claim claim = claimFinish(run);
    if (claim.ignored() != null) {
      return claim.ignored();
    }
    if (!claim.late() || run.status().equals(RunStatus.OK)) {
      finishRun(def.stored(), run, finishedAt);
    }
    return null;
  }

  /**
   * Whether a check already counted the run as a stuck failure ({@code late}), or why nothing was
   * written ({@code ignored}).
   */
  record Claim(boolean late, @Nullable String ignored) {}

  /**
   * Writes a finished run over its stored row, only while that row is still running, or else still
   * marked timeout by a check. Only the process whose write lands goes on to evaluate the run.
   * {@code late} means a check already counted the run as a stuck failure: a late failure must not
   * count twice, while a late success still closes stuck and recovers.
   */
  Claim claimFinish(Run run) {
    if (core.writeRunIf(run, List.of(RunStatus.RUNNING))) {
      return new Claim(false, null);
    }
    if (core.writeRunIf(run, List.of(RunStatus.TIMEOUT))) {
      return new Claim(true, null);
    }
    Run stored = Core.call(() -> core.store.getRun(run.id()));
    return new Claim(
        false, stored == null ? "was not found" : "was already finished as " + stored.status());
  }

  /**
   * Evaluates a finished run (ok, failed, or timed out by a check), already written, against the
   * job's state, and sends what that produces. Never throws: problems go to the error handler.
   */
  List<Alert> finishRun(Definition def, Run run, long now) {
    List<AlertDraft> drafts;
    try {
      drafts =
          core.<List<Run>, List<AlertDraft>>updateState(
                  run.job(),
                  () -> history(run),
                  (previous, history) -> {
                    Evaluation settled =
                        Evaluate.applySilence(
                            previous, Evaluate.onRunFinish(def, run, previous, history, now), now);
                    return new Core.Changed<>(settled.state(), settled.alerts());
                  })
              .result();
    } catch (RuntimeException e) {
      core.report(e, "evaluating " + run.job());
      return List.of();
    }
    return delivery.dispatch(drafts, def, now);
  }

  /**
   * The runs before {@code run}, newest first, with up to twenty successful ones when the store has
   * them: one small read normally, a larger one only when failures crowd the successes out.
   */
  private List<Run> history(Run run) throws Exception {
    List<Run> page = core.store.listRuns(run.job(), HISTORY_PAGE);
    List<Run> runs = without(page, run);
    boolean full = page.size() == HISTORY_PAGE;
    long ok = runs.stream().filter(r -> r.status().equals(RunStatus.OK)).count();
    if (full && ok < Evaluate.BASELINE_WINDOW) {
      runs = without(core.store.listRuns(run.job(), HISTORY_MAX), run);
    }
    return runs;
  }

  private static List<Run> without(List<Run> runs, Run run) {
    List<Run> out = new ArrayList<>(runs.size());
    for (Run r : runs) {
      if (!r.id().equals(run.id())) {
        out.add(r);
      }
    }
    return out;
  }

  /**
   * Records a run that happened outside this process, for a {@link Source}: see {@link
   * Cronwatch#recordRun(Run, boolean)}.
   */
  List<Alert> recordRun(Run input, boolean evaluate) {
    JobDef def = core.declared(input.job());
    if (def == null) {
      throw CronwatchException.invalid(
          "recordRun: job "
              + dev.cronwatch.json.Json.quote(input.job())
              + " is not declared; call job first");
    }
    core.sync(def);
    Run run = input;
    if (run.status().equals(RunStatus.OK)) {
      String unmet = Expect.checkExpectation(def.expect(), run.output());
      if (unmet != null) {
        run = run.withStatus(RunStatus.FAILED).withError(unmet);
      }
    }
    String output = run.output();
    String error = run.error();
    run =
        run.withOutput(output == null ? null : Output.stripNul(core.redact(Output.cap(output))))
            .withError(error == null ? null : Output.stripNul(core.redact(Output.cap(error))));
    Run toWrite = run;
    Run stored = Core.call(() -> core.store.getRun(toWrite.id()));
    if (stored != null) {
      return recordOver(def.stored(), stored, run, evaluate);
    }
    try {
      Core.call(
          () -> {
            core.store.insertRun(toWrite);
            return null;
          });
    } catch (CronwatchException e) {
      // Another process recorded it first.
      Run again;
      try {
        again = Core.call(() -> core.store.getRun(toWrite.id()));
      } catch (RuntimeException ignored) {
        throw e;
      }
      if (again == null) {
        throw e;
      }
      return recordOver(def.stored(), again, run, evaluate);
    }
    if (!evaluate) {
      return List.of();
    }
    core.updateState(run.job(), s -> new Core.Changed<>(Evaluate.onRunStart(s), Boolean.TRUE));
    if (run.status().equals(RunStatus.RUNNING)) {
      return List.of();
    }
    return finishRun(def.stored(), run, core.now());
  }

  /** {@code recordRun} for a run already stored. */
  private List<Alert> recordOver(Definition def, Run stored, Run run, boolean evaluate) {
    String where = "recording " + run.job();
    if (!stored.job().equals(run.job())) {
      core.report(
          "run "
              + run.id()
              + " of "
              + run.job()
              + " belongs to job "
              + dev.cronwatch.json.Json.quote(stored.job())
              + "; ignored",
          where);
      return List.of();
    }
    boolean open =
        stored.status().equals(RunStatus.RUNNING) || stored.status().equals(RunStatus.TIMEOUT);
    if (!open || run.status().equals(RunStatus.RUNNING)) {
      return List.of();
    }
    Claim claim = claimFinish(run);
    if (claim.ignored() != null) {
      core.report(
          "run " + run.id() + " of " + run.job() + " " + claim.ignored() + "; ignored", where);
      return List.of();
    }
    if (!evaluate || (claim.late() && !run.status().equals(RunStatus.OK))) {
      return List.of();
    }
    return finishRun(def, run, core.now());
  }

  /**
   * The shutdown hook's work: each run whose function is still running in this process is recorded
   * failed ({@link #SHUTDOWN_ERROR}), written only over a row still running so a function that
   * finishes on its own meanwhile wins, and judged; a run whose function has returned has its
   * recording waited for. All at once, within the shutdown budget.
   */
  void shutdown() {
    long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(core.timings.shutdownMs);
    List<Future<?>> work = new ArrayList<>();
    for (OpenRun o : core.open.values()) {
      Future<Run> recording = o.recording;
      if (recording != null) {
        work.add(recording);
        continue;
      }
      if (!o.recorded) {
        continue;
      }
      work.add(core.submit(() -> failOpen(o)));
    }
    for (Future<?> f : work) {
      try {
        f.get(Math.max(0, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
      } catch (TimeoutException e) {
        return;
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        return;
      } catch (java.util.concurrent.ExecutionException e) {
        core.report(e.getCause() == null ? e : e.getCause(), "shutdown");
      }
    }
  }

  private @Nullable Void failOpen(OpenRun o) {
    String name = o.def.name();
    long now = core.now();
    Run run = o.run;
    String output = o.recorder.output();
    Run failed =
        run.finished(
            RunStatus.FAILED,
            now,
            Evaluate.runDuration(run.startedAt(), now),
            Output.stripNul(core.redact(SHUTDOWN_ERROR)),
            output == null ? null : Output.stripNul(core.redact(output)),
            o.recorder.metrics());
    try {
      if (core.writeRunIf(failed, List.of(RunStatus.RUNNING))) {
        finishRun(o.def.stored(), failed, now);
      }
    } catch (RuntimeException e) {
      core.report(e, "recording " + name);
    }
    return null;
  }
}
