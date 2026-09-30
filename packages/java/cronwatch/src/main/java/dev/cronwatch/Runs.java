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
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.Predicate;
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
    Caught<T> caught = executeCaught(def, options, body);
    Throwable thrown = caught.thrown();
    if (thrown != null) {
      throw Runs.<RuntimeException>sneakyThrow(thrown);
    }
    return new Executed<>(caught.run(), caught.value());
  }

  /** A run once recorded, what its function returned, and what it threw. */
  record Caught<T>(Run run, @Nullable T value, @Nullable Throwable thrown) {}

  /**
   * {@link #execute}, handing back what the function threw rather than throwing it, for a job's
   * handler, which answers a throw with the run. An {@link InterruptedException} leaves the
   * interrupt status restored.
   */
  <T> Caught<T> executeCaught(JobDef def, RunOptions options, Body<T> body) {
    Opened o = open(def, options);
    T value = null;
    Throwable thrown = null;
    try {
      value = body.call(o.context);
    } catch (Throwable t) {
      thrown = t;
    } finally {
      endFunction(o);
    }
    Run finished = close(o, value, thrown);
    if (thrown instanceof InterruptedException) {
      // Well-behaved code restores the interrupt status of a thread it was interrupted in.
      Thread.currentThread().interrupt();
    }
    return new Caught<>(finished, value, thrown);
  }

  /**
   * A run opened and not yet closed: the first half of {@link #execute}, for a run whose function
   * is seen from outside (a scheduler's listener told of its start and end).
   */
  static final class Opened {
    final JobDef def;
    final RunOptions options;
    final Run run;
    final boolean recorded;
    final @Nullable Future<?> closing;
    final Recorder recorder;
    final JobContext context;
    final Thread thread;
    final ReentrantLock lock = new ReentrantLock();
    boolean inFunction = true;
    boolean interruptedAtTimeout;
    boolean closed;
    @Nullable ScheduledFuture<?> timer;
    @Nullable OpenRun open;
    @Nullable JobContext previous;
    Mdc.@Nullable Saved saved;

    Opened(
        JobDef def,
        RunOptions options,
        Run run,
        boolean recorded,
        @Nullable Future<?> closing,
        Recorder recorder,
        JobContext context) {
      this.def = def;
      this.options = options;
      this.run = run;
      this.recorded = recorded;
      this.closing = closing;
      this.recorder = recorder;
      this.context = context;
      this.thread = Thread.currentThread();
    }

    /** Marks the run closed, and says whether it was open until now. */
    boolean claim() {
      lock.lock();
      try {
        if (closed) {
          return false;
        }
        closed = true;
        return true;
      } finally {
        lock.unlock();
      }
    }

    boolean isClosed() {
      lock.lock();
      try {
        return closed;
      } finally {
        lock.unlock();
      }
    }
  }

  /**
   * Opens a run in the calling thread: its row inserted (a store failure goes to the error handler
   * and the run goes on unrecorded), the run made current with its MDC keys, its timeout timer set,
   * and the shutdown hook told of it. Missed and stuck are closed beside it, or at its close when
   * it may be given back.
   *
   * @throws CronwatchException for a run id no store could hold
   */
  Opened open(JobDef def, RunOptions options) {
    String id = options.id;
    if (id != null) {
      Cronwatch.checkRunId(def.name(), id, "run");
    }
    long startedAt = core.now();
    Run run =
        Run.running(
            id == null ? UUID.randomUUID().toString() : id, def.name(), startedAt, options.trigger);
    // The start is written on the client's thread: an interrupt of the caller cannot cut it.
    boolean recorded = Core.awaitUninterruptibly(core.submit(() -> beginRun(def, run)));
    // Closing missed and stuck happens beside the job, which never waits on it. A run that may be
    // given back closes them only once it is known not to be: one taken back must leave the state
    // as it was, or a job overdue would have missed closed by each attempt given back and opened
    // again by the next check, an alert each time.
    Future<?> closing =
        recorded && !options.mayTakeBack ? core.submit(() -> closeOnStart(def.name())) : null;

    Recorder recorder = new Recorder();
    JobContext context =
        new JobContext(
            def.name(),
            run.id(),
            startedAt,
            recorder,
            task -> core.spawn(task, "cancelling " + def.name()));
    Opened o = new Opened(def, options, run, recorded, closing, recorder, context);
    double timeout = timeoutOrDefault(def.stored());
    long delay = (long) Math.min(Math.max(0, timeout), Evaluate.MAX_DURATION_MS);
    Runnable atTimeout =
        () -> {
          context.cancel();
          if (options.interruptAtTimeout) {
            o.lock.lock();
            try {
              if (o.inFunction) {
                o.interruptedAtTimeout = true;
                o.thread.interrupt();
              }
            } finally {
              o.lock.unlock();
            }
          }
        };
    try {
      o.timer = core.timer.schedule(atTimeout, delay, TimeUnit.MILLISECONDS);
    } catch (RejectedExecutionException e) {
      // The client was closed: the run is still recorded, with no timeout of its own.
      o.timer = null;
    }
    OpenRun open = new OpenRun(def, run, recorder, recorded);
    o.open = open;
    core.open.put(run.id(), open);
    o.previous = CurrentRun.set(context);
    o.saved = Mdc.put(def.name(), run.id());
    return o;
  }

  /**
   * Ends the part of a run in which its function runs: the timer is cancelled, and in the thread
   * that opened it the current run and the MDC keys are put back as they were. Once only.
   */
  void endFunction(Opened o) {
    o.lock.lock();
    try {
      if (!o.inFunction) {
        return;
      }
      o.inFunction = false;
    } finally {
      o.lock.unlock();
    }
    ScheduledFuture<?> timer = o.timer;
    if (timer != null) {
      timer.cancel(false);
    }
    o.context.end();
    if (Thread.currentThread().equals(o.thread)) {
      Mdc.restore(o.saved);
      CurrentRun.restore(o.previous);
    }
  }

  /**
   * The second half of {@link #execute}: judges and records a run whose function returned {@code
   * value} or threw {@code thrown}, on a virtual thread of the client's that this waits for, and
   * returns it as recorded. A run {@code discardWhen} answers true for is taken back instead.
   * Throws nothing; a second close does nothing and returns the run as it opened.
   */
  Run close(Opened o, @Nullable Object value, @Nullable Throwable thrown) {
    endFunction(o);
    if (!o.claim()) {
      return o.run;
    }
    JobDef def = o.def;
    Run run = o.run;
    boolean timedOut = o.interruptedAtTimeout;
    if (timedOut && thrown == null && Thread.currentThread().equals(o.thread)) {
      // The function returned though it was interrupted: the interrupt was ours, so it is not
      // left for the caller's own code.
      Thread.interrupted();
    }
    Predicate<? super Throwable> discard = o.options.discardWhen;
    if (discard != null
        && thrown != null
        && !(thrown instanceof Error)
        && !timedOut
        && givenBack(def.name(), discard, thrown)
        && takeBackNow(o)) {
      return run;
    }
    Future<?> closing = o.closing;
    if (o.recorded && o.options.mayTakeBack) {
      closing = core.submit(() -> closeOnStart(def.name()));
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
    Future<?> started = closing;
    Future<Run> recording =
        core.submit(
            () ->
                finishExecuted(
                    def, run, o.recorder, text, failure, markTimeout, o.recorded, started));
    OpenRun open = o.open;
    if (open != null) {
      open.recording = recording;
    }
    try {
      return Core.awaitUninterruptibly(recording);
    } catch (RuntimeException e) {
      core.report(e, "recording " + def.name());
      return run;
    } finally {
      core.open.remove(run.id());
    }
  }

  /**
   * Gives an open run back rather than judge it: its running row is deleted, nothing is judged or
   * alerted and the job's state is left as it was. Says whether it was taken back; when the store
   * cannot take it back, nothing is changed and the caller records it as it ended. A run already
   * closed is left as it is (true).
   */
  boolean takeBack(Opened o) {
    endFunction(o);
    if (o.isClosed()) {
      return true;
    }
    if (!takeBackNow(o)) {
      return false;
    }
    o.claim();
    return true;
  }

  /** Deletes a run's running row, for {@link #takeBack}; false when it must be recorded instead. */
  private boolean takeBackNow(Opened o) {
    boolean back = true;
    if (o.recorded) {
      back = Core.awaitUninterruptibly(core.submit(() -> discardRun(o.run)));
    }
    if (back) {
      core.open.remove(o.run.id());
    }
    return back;
  }

  /** {@code discard(thrown)}, a throw in it reported and the run not given back. */
  private boolean givenBack(String name, Predicate<? super Throwable> discard, Throwable thrown) {
    try {
      return discard.test(thrown);
    } catch (RuntimeException e) {
      core.report(e, "discarding " + name);
      return false;
    }
  }

  /**
   * Takes back a run still running and says whether the caller is done with it. A store without
   * {@code deleteRunIf}, or one that fails, is reported and the run is recorded as it ended, so it
   * is not left running to be reported stuck; a row no longer running (a check marked it stuck
   * meanwhile) is reported and left as it is.
   */
  private boolean discardRun(Run run) {
    String where = "discarding " + run.job();
    boolean deleted;
    try {
      deleted = Core.call(() -> core.store.deleteRunIf(run.id(), run.job(), RunStatus.RUNNING));
    } catch (UnsupportedOperationException e) {
      core.report(
          "the store cannot take back a run (it has no deleteRunIf); recorded as it ended", where);
      return false;
    } catch (RuntimeException e) {
      core.report(e, where);
      return false;
    }
    if (!deleted) {
      core.report(
          "run " + run.id() + " of " + run.job() + " is no longer running; left as it is", where);
    }
    return true;
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
