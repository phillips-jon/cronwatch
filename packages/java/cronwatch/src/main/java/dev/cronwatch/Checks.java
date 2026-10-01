package dev.cronwatch;

import dev.cronwatch.Core.JobDef;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.evaluate.Evaluate.CheckOutcome;
import dev.cronwatch.internal.evaluate.Evaluate.Evaluation;
import dev.cronwatch.internal.evaluate.MutableState;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.Consumer;
import org.jspecify.annotations.Nullable;

/**
 * Checks, reads and the interval (the SDK's {@code check()}, {@code jobs()}, {@code silence()},
 * {@code startChecking()}).
 */
final class Checks {
  /** How often a check prunes old runs. */
  private static final long PRUNE_INTERVAL_MS = 60 * 60_000;

  /** The longest interval {@code start} checks on, the SDK's: setInterval's longest delay. */
  static final long TIMER_MAX_MS = (1L << 31) - 1;

  private final Cronwatch owner;
  private final Core core;
  private final Runs runs;
  private final Delivery delivery;
  private final ReentrantLock intervalLock = new ReentrantLock();
  private @Nullable ScheduledFuture<?> firstTick;
  private @Nullable ScheduledFuture<?> ticks;
  private boolean warnedDeferredStart;

  Checks(Cronwatch owner, Core core, Runs runs, Delivery delivery) {
    this.owner = owner;
    this.core = core;
    this.runs = runs;
    this.delivery = delivery;
  }

  /**
   * Joins the check in flight or starts one, on a thread of its own, and waits for its answer.
   * Every caller waiting gets the same answer, so a caller that is interrupted neither fails the
   * check for the others nor leaves a job half checked; a throw in the check is that check's, and
   * the next call starts a new one.
   */
  CheckResult check() {
    CompletableFuture<CheckResult> mine = new CompletableFuture<>();
    CompletableFuture<CheckResult> shared = core.checking.compareAndExchange(null, mine);
    if (shared == null) {
      shared = mine;
      // The check is let go of before anyone is answered, as the SDK's is: a caller that asks
      // again once answered starts a check of its own rather than joining this finished one.
      core.spawn(
          () -> {
            core.checkThread = Thread.currentThread();
            try {
              CheckResult result = runCheck();
              core.checking.compareAndSet(mine, null);
              mine.complete(result);
            } catch (Throwable t) {
              core.checking.compareAndSet(mine, null);
              mine.completeExceptionally(t);
            } finally {
              core.checkThread = null;
            }
          },
          "check");
    }
    try {
      return shared.get();
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new CronwatchException(
          CronwatchException.Kind.OTHER, "interrupted while waiting for the check", e);
    } catch (ExecutionException e) {
      Throwable cause = e.getCause();
      if (cause instanceof CronwatchException c) {
        throw c;
      }
      if (cause instanceof Error err) {
        throw err;
      }
      throw new CronwatchException(
          CronwatchException.Kind.OTHER, "the check failed: " + cause, cause);
    }
  }

  private CheckResult runCheck() {
    core.ensureReady();
    List<Alert> alerts = new ArrayList<>();
    for (Source source : core.sources) {
      try {
        List<Alert> found = source.sync(owner);
        if (found != null) {
          alerts.addAll(found);
        }
      } catch (Exception e) {
        core.report(e, "source " + source.name());
      }
    }
    for (JobDef def : core.declaredAll()) {
      core.sync(def);
    }
    long now = core.now();

    // Runs that never reported back. One that cannot be judged (its job's stored timeout no
    // longer parses, say) is reported and skipped.
    for (Run run : Core.call(core.store::runningRuns)) {
      try {
        checkRunning(run, now, alerts::addAll);
      } catch (RuntimeException e) {
        core.report(e, "checking " + run.job());
      }
    }

    // Each job on its own: one that cannot be evaluated is reported, shown as failing and does
    // not stop the others.
    List<JobSummary> jobs = new ArrayList<>();
    Delivery.Budget budget = new Delivery.Budget();
    for (StoredJob job : storedJobs()) {
      try {
        jobs.add(checkJob(job, now, budget, alerts::addAll));
      } catch (RuntimeException e) {
        core.report(e, "checking " + job.name());
        jobs.add(unevaluable(job, now));
      }
    }

    long pruned = 0;
    if (now - core.lastPruneAt.get() > PRUNE_INTERVAL_MS) {
      core.lastPruneAt.set(now);
      try {
        long before = (long) (now - core.retentionMs);
        pruned = Core.call(() -> core.store.prune(before));
      } catch (RuntimeException e) {
        core.report(e, "pruning");
      }
    }
    return new CheckResult(now, jobs, alerts, pruned);
  }

  /** A running run marked timed out once it has gone on past its job's timeout, and judged. */
  private void checkRunning(Run listed, long now, Consumer<List<Alert>> alerts) {
    JobDef declared = core.declared(listed.job());
    Definition def;
    if (declared != null) {
      def = declared.stored();
    } else {
      StoredJob stored = Core.call(() -> core.store.getJob(listed.job()));
      if (stored == null) {
        return;
      }
      def = stored.definition();
    }
    if (!Evaluate.isStuck(def, listed, now)) {
      return;
    }
    // Read again just before the write: lines and metrics flushed since the list was read (while
    // earlier stuck runs were sent, say) are kept.
    Run run = Core.call(() -> core.store.getRun(listed.id()));
    if (run == null || !run.status().equals(RunStatus.RUNNING) || !run.job().equals(listed.job())) {
      return;
    }
    Run marked =
        run.finished(
            RunStatus.TIMEOUT,
            now,
            Evaluate.runDuration(run.startedAt(), now),
            Runs.timeoutText(def),
            run.output(),
            run.metrics());
    // Only over a row still running: a finish that landed meanwhile wins.
    if (core.writeRunIf(marked, List.of(RunStatus.RUNNING))) {
      alerts.accept(runs.finishRun(def, marked, now));
    }
  }

  /** One job's part of a check: missed, then retries and sends. */
  private JobSummary checkJob(
      StoredJob job, long now, Delivery.Budget budget, Consumer<List<Alert>> alerts) {
    List<Run> recent = Core.call(() -> core.store.listRuns(job.name(), Evaluate.BASELINE_WINDOW));
    Run last = recent.isEmpty() ? null : recent.get(0);
    Long[] nextExpectedAt = {null};
    Core.Changed<Delivery.Held> out =
        core.updateState(
            job.name(),
            previous -> {
              CheckOutcome o = Evaluate.onCheck(job.definition(), job, last, previous, now);
              nextExpectedAt[0] = o.nextExpectedAt();
              Evaluation settled = Evaluate.applySilence(previous, o.evaluation(), now);
              // Alerts a process stopped sending part way go back to the retry queue.
              Evaluate.Queued released = Evaluate.releaseSending(settled.state(), core.now());
              Core.Changed<Delivery.Held> held =
                  delivery.outbox(released.state(), settled.alerts(), job.definition(), now);
              return new Core.Changed<>(
                  held.state(),
                  new Delivery.Held(
                      held.result().alerts(), released.dropped() + held.result().dropped()));
            });
    delivery.reportDropped(job.name(), out.result().dropped());
    alerts.accept(delivery.retryUndelivered(job.name(), out.state(), now, budget));
    alerts.accept(delivery.dispatch(job.name(), out.result().alerts(), now));
    return Evaluate.summarize(job, recent, out.state(), nextExpectedAt[0], now);
  }

  /** A job's summary and its newest runs, without alerting. */
  private JobWithRuns snapshot(StoredJob job, long now, int limit) {
    List<Run> recent = List.of();
    try {
      recent =
          Core.call(
              () -> core.store.listRuns(job.name(), Math.max(limit, Evaluate.BASELINE_WINDOW)));
      JobState state = core.readState(job.name());
      CheckOutcome o =
          Evaluate.onCheck(
              job.definition(), job, recent.isEmpty() ? null : recent.get(0), state, now);
      JobSummary summary = Evaluate.summarize(job, recent, state, o.nextExpectedAt(), now);
      return new JobWithRuns(summary, recent.subList(0, Math.min(limit, recent.size())));
    } catch (RuntimeException e) {
      core.report(e, "reading " + job.name());
      return new JobWithRuns(
          unevaluable(job, now), recent.subList(0, Math.min(limit, recent.size())));
    }
  }

  /** The summary of a job whose evaluation failed, from whatever can still be read. */
  private JobSummary unevaluable(StoredJob job, long now) {
    List<Run> recent;
    try {
      recent = Core.call(() -> core.store.listRuns(job.name(), Evaluate.BASELINE_WINDOW));
    } catch (RuntimeException e) {
      recent = List.of();
    }
    JobState state;
    try {
      state = core.readState(job.name());
    } catch (RuntimeException e) {
      state = Evaluate.emptyState(job.name());
    }
    return Evaluate.unevaluableSummary(job, recent, state, now);
  }

  /** A whole number from {@code min} to 500. */
  static int clampLimit(int limit, int min) {
    return Math.min(500, Math.max(min, limit));
  }

  /**
   * Every stored job, once each declaration has been written. A job declared here that the store no
   * longer has was forgotten by another process after this one wrote it: it is written again, as
   * its next run would, so it is checked and shown while any process still declares it.
   */
  private List<StoredJob> storedJobs() {
    for (JobDef def : core.declaredAll()) {
      core.sync(def);
    }
    List<StoredJob> jobs = Core.call(core.store::listJobs);
    Set<String> listed = new HashSet<>();
    for (StoredJob job : jobs) {
      listed.add(job.name());
    }
    boolean missing = false;
    for (JobDef def : core.declaredAll()) {
      if (listed.contains(def.name())) {
        continue;
      }
      missing = true;
      // Not one forgotten here meanwhile.
      if (core.declared(def.name()) != def) {
        continue;
      }
      core.unmark(def.name());
      core.sync(def);
    }
    return missing ? Core.call(core.store::listJobs) : jobs;
  }

  List<JobWithRuns> jobsWithRuns(int limit) {
    core.ensureReady();
    List<StoredJob> jobs = storedJobs();
    long now = core.now();
    List<JobWithRuns> out = new ArrayList<>();
    for (StoredJob job : jobs) {
      out.add(snapshot(job, now, clampLimit(limit, 0)));
    }
    return out;
  }

  @Nullable JobSummary jobSummary(String name) {
    core.ensureReady();
    JobDef def = core.declared(name);
    if (def != null) {
      core.sync(def, true);
    }
    StoredJob stored = Core.call(() -> core.store.getJob(name));
    return stored == null ? null : snapshot(stored, core.now(), 0).job();
  }

  List<Run> runs(String name, int limit) {
    core.ensureReady();
    return Core.call(() -> core.store.listRuns(name, clampLimit(limit, 1)));
  }

  @Nullable Run getRun(String id) {
    core.ensureReady();
    return Core.call(() -> core.store.getRun(id));
  }

  /**
   * Silences a job for {@code ms} milliseconds. The end is a whole millisecond, held at 2^53 - 1
   * ({@link Evaluate#silenceEnd}).
   */
  JobState silence(String name, double ms) {
    long until = Evaluate.silenceEnd(core.now(), ms);
    return patchState(name, s -> s.silencedUntil = until);
  }

  JobState unsilence(String name) {
    return patchState(name, s -> s.silencedUntil = null);
  }

  /** Reads, changes and writes one job's state, in turn with every other update to it. */
  private JobState patchState(String name, Consumer<MutableState> change) {
    core.ensureReady();
    return core.updateState(
            name,
            current -> {
              MutableState next = MutableState.of(Evaluate.normalizeState(current, name));
              change.accept(next);
              return new Core.Changed<>(next.toState(), Boolean.TRUE);
            })
        .state();
  }

  /**
   * Removes a job and its runs from the store; a job still declared in code comes back: on its next
   * run, or at the next check or dashboard read of a process that declares it.
   */
  void forget(String name) {
    core.ensureReady();
    core.undeclare(name);
    Core.call(
        () -> {
          core.store.deleteJob(name);
          return null;
        });
  }

  /**
   * Checks on an interval: the first check a second from now, then every {@code everyMs} (five
   * seconds at least, at most 2^31 - 1 ms). Each tick asks for a check without waiting on it, as
   * setInterval does: a tick while a long check runs shares that check, and the ticks it outlasted
   * are not run back to back after it. A second {@code start} does nothing.
   */
  void start(double everyMs) {
    intervalLock.lock();
    try {
      if (ticks != null) {
        return;
      }
      long ms =
          (long) Math.min(TIMER_MAX_MS, Math.max((double) core.timings.minIntervalMs, everyMs));
      if (core.deferDelivery && !warnedDeferredStart) {
        warnedDeferredStart = true;
        Env.LOGGER.log(
            System.Logger.Level.WARNING,
            "[cronwatch] startChecking() was called with Deliver.AT_CHECK, so these checks send no"
                + " alerts."
                + " Another process must run checks with Deliver.NOW (the default) to send them.");
      }
      Runnable tick = () -> core.spawn(this::check, "check");
      try {
        firstTick = core.timer.schedule(tick, core.timings.firstCheckMs, TimeUnit.MILLISECONDS);
        ticks = core.timer.scheduleAtFixedRate(tick, ms, ms, TimeUnit.MILLISECONDS);
      } catch (RejectedExecutionException e) {
        // The client was closed: there is nothing to check on.
        firstTick = null;
        ticks = null;
      }
    } finally {
      intervalLock.unlock();
    }
  }

  /** Stops the interval {@link #start} began; a check in flight finishes on its own thread. */
  void stop() {
    intervalLock.lock();
    try {
      if (firstTick != null) {
        firstTick.cancel(false);
      }
      if (ticks != null) {
        ticks.cancel(false);
      }
      firstTick = null;
      ticks = null;
    } finally {
      intervalLock.unlock();
    }
  }
}
