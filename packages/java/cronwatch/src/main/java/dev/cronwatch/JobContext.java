package dev.cronwatch;

import dev.cronwatch.internal.core.CurrentRun;
import dev.cronwatch.internal.core.Mdc;
import dev.cronwatch.internal.core.Recorder;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.Executor;
import java.util.concurrent.locks.ReentrantLock;

/**
 * What a job's function is given: its run, where it logs output and reports metrics, and whether
 * its timeout has passed. Safe to use from any thread. {@link Cronwatch#current()} answers it for
 * the thread the function runs in; {@link #wrap(Runnable)} carries it to another.
 */
public final class JobContext {
  private final String name;
  private final String runId;
  private final long startedAt;
  private final Recorder recorder;
  private final Executor callbacks;
  private final ReentrantLock lock = new ReentrantLock();
  private final List<Runnable> onCancel = new ArrayList<>();
  private volatile boolean cancelled;

  JobContext(String name, String runId, long startedAt, Recorder recorder, Executor callbacks) {
    this.name = name;
    this.runId = runId;
    this.startedAt = startedAt;
    this.recorder = recorder;
    this.callbacks = callbacks;
  }

  /** The job's name. */
  public String name() {
    return name;
  }

  /** The run's id. */
  public String runId() {
    return runId;
  }

  /** When the run started, epoch milliseconds. */
  public long startedAt() {
    return startedAt;
  }

  /**
   * Appends a line of output. Kept with the run (the last 16 KB), shown in alerts and on the
   * dashboard, and what an expect rule checks.
   */
  public void log(String line) {
    recorder.log(line);
  }

  /**
   * Reports a number for this run: tokens, cost, rows, anything. Watched against budgets and
   * baselines. A later value for the same name replaces an earlier one.
   *
   * @throws IllegalArgumentException for a number that is not finite ({@code metric "cost" must be
   *     a finite number}), which fails the run unless the function handles it
   */
  public void metric(String name, double value) {
    recorder.metric(name, value);
  }

  /** Reports several numbers at once, in the map's iteration order. */
  public void metrics(Map<String, ? extends Number> values) {
    for (Map.Entry<String, ? extends Number> e : values.entrySet()) {
      metric(e.getKey(), e.getValue().doubleValue());
    }
  }

  /**
   * Whether the job's timeout has passed: the SDK's {@code signal.aborted}. The function decides
   * what to do, as a JavaScript function decides what to do with an aborted signal; nothing is
   * stopped unless the run was given {@link RunOptions#interruptAtTimeout()}.
   */
  public boolean cancelled() {
    return cancelled;
  }

  /**
   * Calls {@code callback} when the job's timeout passes (the signal's {@code abort} event), on a
   * thread of the client's, or at once on one when it has already passed. Never called for a run
   * that ends in time.
   */
  public void onCancel(Runnable callback) {
    boolean now;
    lock.lock();
    try {
      now = cancelled;
      if (!now) {
        onCancel.add(callback);
      }
    } finally {
      lock.unlock();
    }
    if (now) {
      callbacks.execute(callback);
    }
  }

  /** Marks the run cancelled and calls what {@link #onCancel} registered. */
  void cancel() {
    List<Runnable> toCall;
    lock.lock();
    try {
      if (cancelled) {
        return;
      }
      cancelled = true;
      toCall = List.copyOf(onCancel);
      onCancel.clear();
    } finally {
      lock.unlock();
    }
    for (Runnable r : toCall) {
      callbacks.execute(r);
    }
  }

  /** Drops the callbacks of a run that has ended. */
  void end() {
    lock.lock();
    try {
      onCancel.clear();
    } finally {
      lock.unlock();
    }
  }

  Recorder recorder() {
    return recorder;
  }

  /**
   * {@code task} with this run current while it runs, for work the job hands to another thread
   * ({@link Cronwatch#current()} there answers this run, and its logs go to it). The thread's own
   * run, if any, is put back after.
   */
  public Runnable wrap(Runnable task) {
    return () -> {
      JobContext previous = CurrentRun.set(this);
      Mdc.Saved saved = Mdc.put(name, runId);
      try {
        task.run();
      } finally {
        Mdc.restore(saved);
        CurrentRun.restore(previous);
      }
    };
  }

  /** {@link #wrap(Runnable)} for a task that returns a value. */
  public <V> Callable<V> wrap(Callable<V> task) {
    return () -> {
      JobContext previous = CurrentRun.set(this);
      Mdc.Saved saved = Mdc.put(name, runId);
      try {
        return task.call();
      } finally {
        Mdc.restore(saved);
        CurrentRun.restore(previous);
      }
    };
  }

  @Override
  public String toString() {
    return "JobContext[" + name + ", run " + runId + "]";
  }
}
