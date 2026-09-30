package dev.cronwatch;

import dev.cronwatch.Core.JobDef;
import dev.cronwatch.internal.core.Recorder;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.output.Output;
import dev.cronwatch.json.Json;
import java.util.List;
import java.util.Map;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;

/**
 * A run recorded by {@link Job#start} or found by {@link Job#resume}, to finish later, perhaps from
 * another process. Lines and metrics wait in the handle until {@link #flush} or {@link #finish}
 * merges them onto a fresh read of the stored run. Safe to use from any thread.
 *
 * <p>The store never fails out of a handle: a failure goes to the error handler ({@code flushing
 * <job>}, {@code finishing <job>}), and a finish the store failed leaves the handle active, its
 * lines kept, so it can be called again. {@code flush} and {@code finish} write on a thread of the
 * client's and wait for it, so a caller interrupted part way leaves the write to complete. {@link
 * #close} does nothing: a handle left unfinished is what the stuck check is for.
 */
public final class RunHandle implements AutoCloseable {
  private final Core core;
  private final Runs runs;
  private final JobDef def;
  private final String id;
  private final @Nullable Run base;
  private final boolean recorded;
  private final @Nullable String inactive;

  /** Orders {@code flush} and {@code finish}, as the SDK's {@code inTurn} queue does. */
  private final ReentrantLock turn = new ReentrantLock(true);

  private final ReentrantLock lock = new ReentrantLock();
  private Recorder recorder = new Recorder();
  private boolean finished;
  private boolean finishCalled;

  /**
   * The first 16 KB of every line flushed from this handle, unredacted, or null before the first
   * flush. The stored output keeps only the tail, so without it an expect rule at finish would miss
   * a line logged early, which {@code run} would have seen.
   */
  private @Nullable String head;

  RunHandle(
      Core core,
      Runs runs,
      JobDef def,
      String id,
      @Nullable Run base,
      boolean recorded,
      @Nullable String inactive) {
    this.core = core;
    this.runs = runs;
    this.def = def;
    this.id = id;
    this.base = base;
    this.recorded = recorded;
    this.inactive = inactive;
    this.finished = inactive != null;
  }

  /** The run's id. */
  public String id() {
    return id;
  }

  /** The job's name. */
  public String job() {
    return def.name();
  }

  /** When the run started, epoch milliseconds; null when a resumed run could not be read. */
  public @Nullable Long startedAt() {
    return base == null ? null : base.startedAt();
  }

  /**
   * False once finished, and from the start for a resumed run that already finished or does not
   * exist.
   */
  public boolean isActive() {
    lock.lock();
    try {
      return !finished;
    } finally {
      lock.unlock();
    }
  }

  private Recorder recorder() {
    lock.lock();
    try {
      return recorder;
    } finally {
      lock.unlock();
    }
  }

  /** Adds a line of output, kept in the handle until {@link #flush} or {@link #finish}. */
  public void log(String line) {
    recorder().log(line);
  }

  /**
   * Reports a number for this run. A later value for the same name replaces an earlier one.
   *
   * @throws IllegalArgumentException for a number that is not finite
   */
  public void metric(String name, double value) {
    recorder().metric(name, value);
  }

  /** Reports several numbers at once, in the map's iteration order. */
  public void metrics(Map<String, ? extends Number> values) {
    for (Map.Entry<String, ? extends Number> e : values.entrySet()) {
      metric(e.getKey(), e.getValue().doubleValue());
    }
  }

  /** Does nothing: a handle left unfinished is what the stuck check is for. */
  @Override
  public void close() {}

  private void ignored(String why) {
    core.report(
        "run " + id + " of " + def.name() + " " + why + "; ignored", "finishing " + def.name());
  }

  /** Two stretches of text as one, a line apart; either may be null. */
  private static @Nullable String joinLines(@Nullable String before, @Nullable String after) {
    if (before == null || before.isEmpty()) {
      return after;
    }
    if (after == null) {
      return before;
    }
    return before + "\n" + after;
  }

  /** Output appended to stored output, capped like any run's. */
  private static @Nullable String joinOutput(@Nullable String before, @Nullable String after) {
    String joined = joinLines(before, after);
    return joined == null ? null : Output.cap(joined);
  }

  /**
   * Appends the lines and metrics added so far to the stored run, which must still be running and
   * belong to this job. A read, change and write of the run's row, written only while it is still
   * running: two processes appending to one run at the same moment can lose one's lines, but a
   * flush never undoes a finish. Problems go to the error handler.
   */
  public void flush() {
    Core.awaitUninterruptibly(
        core.submit(
            () -> {
              flushNow();
              return null;
            }));
  }

  private void flushNow() {
    String name = def.name();
    turn.lock();
    try {
      Recorder taken;
      String lines;
      Metrics metrics;
      lock.lock();
      try {
        if (finished || !recorded) {
          return;
        }
        lines = recorder.output();
        metrics = recorder.metrics();
        if (lines == null && metrics.isEmpty()) {
          return;
        }
        // Lines logged while this waits on the store go to a new recorder.
        taken = recorder;
        recorder = new Recorder();
      } finally {
        lock.unlock();
      }
      Run stored;
      try {
        stored = Core.call(() -> core.store.getRun(id));
      } catch (RuntimeException e) {
        putBack(taken);
        core.report(e, "flushing " + name);
        return;
      }
      // Not running: the lines stay here for finish, which reports why it cannot record them.
      if (stored == null || !stored.status().equals(RunStatus.RUNNING)) {
        putBack(taken);
        return;
      }
      if (!stored.job().equals(name)) {
        putBack(taken);
        core.report(
            "run "
                + id
                + " of "
                + name
                + " belongs to job "
                + Json.quote(stored.job())
                + "; ignored",
            "flushing " + name);
        return;
      }
      String output =
          lines == null
              ? stored.output()
              : joinOutput(stored.output(), Output.stripNul(core.redact(lines)));
      Run next =
          stored.finished(
              stored.status(),
              stored.finishedAt(),
              stored.durationMs(),
              stored.error(),
              output,
              stored.metrics().merged(metrics));
      boolean wrote;
      try {
        // Only over a row still running, so a flush never undoes a finish written meanwhile.
        wrote = core.writeRunIf(next, List.of(RunStatus.RUNNING));
      } catch (RuntimeException e) {
        putBack(taken);
        core.report(e, "flushing " + name);
        return;
      }
      if (!wrote) {
        putBack(taken);
        return;
      }
      String text = taken.expectText();
      if (text != null) {
        lock.lock();
        try {
          if (head == null || head.length() < Output.OUTPUT_CAP) {
            String joined = joinLines(head, text);
            head = Js.head(joined == null ? "" : joined, Output.OUTPUT_CAP);
          }
        } finally {
          lock.unlock();
        }
      }
    } finally {
      turn.unlock();
    }
  }

  /** Puts the lines and metrics a failed flush took back, ahead of any logged since. */
  private void putBack(Recorder taken) {
    lock.lock();
    try {
      Recorder later = recorder;
      Recorder merged = new Recorder();
      for (String text : new String[] {taken.expectText(), later.expectText()}) {
        if (text != null) {
          merged.log(text);
        }
      }
      for (Map.Entry<String, Double> e :
          taken.metrics().merged(later.metrics()).asMap().entrySet()) {
        merged.metric(e.getKey(), e.getValue());
      }
      recorder = merged;
    } finally {
      lock.unlock();
    }
  }

  /**
   * Finishes the run successfully (unless an expect rule says otherwise), judges it like any other
   * and sends what that produces. Returns the run as recorded, or null when nothing was recorded:
   * the run was already finished (here or elsewhere), was not found, or belongs to another job,
   * which is reported to the error handler. When several processes finish one run, only the one
   * whose write lands judges it.
   */
  public @Nullable Run finish() {
    return finishWith(null, null);
  }

  /**
   * Finishes the run with a result, treated like the value a job's function returns: a {@code
   * String} is the output when nothing was logged (and what an expect rule checks), and an HTTP
   * answer of 400 or more fails the run.
   */
  public @Nullable Run finish(@Nullable Object result) {
    String failure = Http.failure(result);
    return finishWith(result instanceof String s ? s : null, failure);
  }

  /** Finishes the run as failed with {@code error}, written as a thrown error is. */
  public @Nullable Run fail(Throwable error) {
    return finishWith(null, Runs.errorText(error));
  }

  private @Nullable Run finishWith(@Nullable String resultText, @Nullable String failure) {
    return Core.awaitUninterruptibly(core.submit(() -> finishNow(resultText, failure)));
  }

  private @Nullable Run finishNow(@Nullable String resultText, @Nullable String failure) {
    boolean already;
    boolean wasInactive = false;
    lock.lock();
    try {
      already = finishCalled;
      if (!already) {
        finishCalled = true;
        wasInactive = finished;
        finished = true;
      }
    } finally {
      lock.unlock();
    }
    if (already) {
      ignored("was already finished by this handle");
      return null;
    }
    turn.lock();
    try {
      String name = def.name();
      if (wasInactive) {
        ignored(inactive == null ? "was already finished" : inactive);
        return null;
      }
      Run from = base;
      if (recorded) {
        try {
          Run stored = Core.call(() -> core.store.getRun(id));
          if (stored != null) {
            from = stored;
          }
        } catch (RuntimeException e) {
          return retryable(e);
        }
      }
      if (from == null) {
        ignored("was not found");
        return null;
      }
      if (!from.job().equals(name)) {
        ignored("belongs to job " + Json.quote(from.job()));
        return null;
      }
      if (from.status().equals(RunStatus.OK) || from.status().equals(RunStatus.FAILED)) {
        ignored("was already finished as " + from.status());
        return null;
      }
      Recorder rec;
      String earlier;
      lock.lock();
      try {
        rec = recorder;
        earlier = head;
      } finally {
        lock.unlock();
      }
      long finishedAt = core.now();
      String added = rec.output();
      if (added == null && resultText != null) {
        added = Output.cap(resultText);
      }
      Run run =
          from.finished(
              RunStatus.RUNNING,
              finishedAt,
              Evaluate.runDuration(from.startedAt(), finishedAt),
              null,
              joinOutput(from.output(), added),
              from.metrics().merged(rec.metrics()));
      String expected = rec.expectText();
      if (expected == null) {
        expected = resultText;
      }
      String expectText = joinLines(earlier, joinLines(from.output(), expected));
      run = runs.conclude(def, run, failure, expectText, false);
      String why;
      try {
        why = runs.recordFinish(def, run, recorded, finishedAt);
      } catch (RuntimeException e) {
        return retryable(e);
      }
      if (why != null) {
        ignored(why);
        return null;
      }
      return run;
    } finally {
      turn.unlock();
    }
  }

  /** The store failed part way and nothing was recorded, so the handle can be finished again. */
  private @Nullable Run retryable(RuntimeException e) {
    lock.lock();
    try {
      finishCalled = false;
      finished = false;
    } finally {
      lock.unlock();
    }
    core.report(e, "finishing " + def.name());
    return null;
  }

  @Override
  public String toString() {
    return "RunHandle[" + def.name() + ", run " + id + "]";
  }
}
