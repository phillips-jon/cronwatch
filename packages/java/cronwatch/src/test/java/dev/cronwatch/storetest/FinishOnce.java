package dev.cronwatch.storetest;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.JobState;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunHandle;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StartOptions;
import dev.cronwatch.store.Store;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Supplier;
import org.jspecify.annotations.Nullable;

/**
 * The SDK's {@code finish-once.test.ts} over several stores sharing one database, as several
 * processes would have them: however many processes finish a run, it is recorded and judged once. A
 * store of the app's own that shares a database between processes should pass it:
 *
 * <pre>{@code
 * FinishOnce.run(() -> new FinishOnce.Shared() {
 *   public Store open() { return new MyStore(database); }
 *   public void done() { dropTables(database); }
 * });
 * }</pre>
 *
 * <p>Each process is a {@link Cronwatch} of its own over a store {@link Shared#open} gives, racing
 * on threads of their own. It throws an {@link AssertionError} at the first thing that goes wrong,
 * and depends on no test framework.
 */
public final class FinishOnce {
  private static final long T0 = 1_767_605_400_000L;
  private static final long MIN = 60_000;

  private FinishOnce() {}

  /** Stores over one database: each {@link #open} is another store on the same data. */
  public interface Shared {
    /** Another store over the shared data, as another process would open it. */
    Store open();

    /**
     * Closes what was opened and drops the data, at the end of a scenario.
     *
     * @throws Exception when that fails
     */
    void done() throws Exception;
  }

  /**
   * One process: a client over its own store, with the alerts it sent and the errors it reported.
   */
  private static final class Worker implements AutoCloseable {
    final Cronwatch client;
    final List<String> alerts = new CopyOnWriteArrayList<>();
    final List<String> errors = new CopyOnWriteArrayList<>();

    Worker(Store store, AtomicLong clock) {
      this.client =
          Cronwatch.builder()
              .store(store)
              .alert(Channel.of("capture", (alert, ctx) -> alerts.add(alert.type().value())))
              .noCronSecret()
              .onError((where, e) -> errors.add(String.valueOf(e.getMessage())))
              .clock(clock::get)
              .noShutdownHook()
              .build();
    }

    @Override
    public void close() {
      client.close();
    }
  }

  /**
   * The three scenarios, each over a fresh database from {@code shared}.
   *
   * @throws AssertionError at the first thing that goes wrong
   */
  public static void run(Supplier<? extends Shared> shared) {
    twoProcessesFinishingOneRun(shared.get());
    twoProcessesRecordingOneFinishedRun(shared.get());
    manyProcessesStartingAndFinishingOneId(shared.get());
  }

  private static Run failed(String id, String job, long startedAt) {
    return new Run(
        id,
        job,
        RunStatus.FAILED,
        startedAt,
        startedAt + 1000,
        1000L,
        "ERROR: deadlock detected",
        null,
        Metrics.empty(),
        "pg_cron");
  }

  /** Every task at once, each on a thread of its own, and what each answered. */
  private static <T> List<T> all(List<Callable<T>> tasks) {
    try (ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      List<Future<T>> futures = new ArrayList<>();
      for (Callable<T> t : tasks) {
        futures.add(pool.submit(t));
      }
      List<T> out = new ArrayList<>();
      for (Future<T> f : futures) {
        out.add(f.get());
      }
      return out;
    } catch (ExecutionException e) {
      throw new AssertionError("a process threw: " + e.getCause(), e.getCause());
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new AssertionError("interrupted", e);
    }
  }

  private static void ensure(boolean ok, String what) {
    if (!ok) {
      throw new AssertionError(what);
    }
  }

  private static long count(List<@Nullable Run> runs) {
    return runs.stream().filter(r -> r != null).count();
  }

  private static void done(Shared s) {
    try {
      s.done();
    } catch (Exception e) {
      throw new AssertionError("done() failed: " + e, e);
    }
  }

  private static JobState state(Worker p, String job) {
    try {
      JobState s = p.client.store().getState(job);
      ensure(s != null, job + " has a state");
      return s;
    } catch (Exception e) {
      throw new AssertionError("getState failed: " + e, e);
    }
  }

  private static List<String> concat(List<String> a, List<String> b) {
    List<String> out = new ArrayList<>(a);
    out.addAll(b);
    return out;
  }

  /**
   * Two processes finishing one run: one records and judges it, the other reports it already
   * finished.
   */
  private static void twoProcessesFinishingOneRun(Shared s) {
    AtomicLong clock = new AtomicLong(T0);
    try (Worker one = new Worker(s.open(), clock);
        Worker two = new Worker(s.open(), clock)) {
      Job job = one.client.job("webhook-ingest", JobOptions.builder().failuresBeforeAlert(2));
      two.client.job("webhook-ingest", JobOptions.builder().failuresBeforeAlert(2));
      job.start(StartOptions.id("delivery-1"));
      RunHandle h1 = one.client.resumeRun("webhook-ingest", "delivery-1");
      RunHandle h2 = two.client.resumeRun("webhook-ingest", "delivery-1");
      clock.addAndGet(MIN);
      List<@Nullable Run> results =
          all(
              List.of(
                  () -> h1.fail(new IllegalStateException("upstream 502")),
                  () -> h2.fail(new IllegalStateException("upstream 502"))));
      Checks.eq("finishes recorded", count(results), 1L);
      List<String> errors = concat(one.errors, two.errors);
      ensure(
          errors.stream().anyMatch(e -> e.contains("already finished as failed; ignored")),
          "a process reported the run already finished: " + errors);
      Checks.eq("runs", one.client.runs("webhook-ingest", 50).size(), 1);
      Checks.eq("the failure counted once", state(one, "webhook-ingest").consecutiveFailures(), 1L);
      List<String> types = concat(one.alerts, two.alerts);
      ensure(types.isEmpty(), "one failure is below failuresBeforeAlert 2: " + types);
    } finally {
      done(s);
    }
  }

  /** Two processes recording one finished run from a source: it is judged once. */
  private static void twoProcessesRecordingOneFinishedRun(Shared s) {
    AtomicLong clock = new AtomicLong(T0);
    try (Worker one = new Worker(s.open(), clock);
        Worker two = new Worker(s.open(), clock)) {
      for (Worker p : List.of(one, two)) {
        p.client.job("db:rollup", JobOptions.builder().failuresBeforeAlert(2));
      }
      long at = T0 - MIN;
      Run running = Run.running("pgcron:9", "db:rollup", at, "pg_cron");
      one.client.recordRun(running);
      two.client.jobs();
      all(
          List.<Callable<List<Alert>>>of(
              () -> one.client.recordRun(failed("pgcron:9", "db:rollup", at)),
              () -> two.client.recordRun(failed("pgcron:9", "db:rollup", at))));
      Checks.eq("judged once", state(one, "db:rollup").consecutiveFailures(), 1L);
      List<String> types = concat(one.alerts, two.alerts);
      ensure(types.isEmpty(), "alerts " + types);
      // Threads may read the run after the first finish landed, and a run already finished is
      // left alone without a word; either way the only thing either process may report is that
      // finish.
      for (String e : concat(one.errors, two.errors)) {
        ensure(
            e.contains("pgcron:9 of db:rollup was already finished as failed; ignored"),
            "unexpected error: " + e);
      }
    } finally {
      done(s);
    }
  }

  /** Many processes starting and finishing one id: exactly one finish is recorded. */
  private static void manyProcessesStartingAndFinishingOneId(Shared s) {
    AtomicLong clock = new AtomicLong(T0);
    List<Worker> procs = new ArrayList<>();
    try {
      for (int i = 0; i < 6; i++) {
        procs.add(new Worker(s.open(), clock));
      }
      List<Job> jobs = new ArrayList<>();
      for (Worker p : procs) {
        jobs.add(p.client.job("ingest", JobOptions.builder()));
      }
      procs.get(0).client.check();
      for (int k = 0; k < 5; k++) {
        String id = "evt_" + k;
        List<Callable<RunHandle>> starts = new ArrayList<>();
        for (Job job : jobs) {
          starts.add(() -> job.start(StartOptions.id(id)));
        }
        List<RunHandle> handles = all(starts);
        List<Callable<@Nullable Run>> finishes = new ArrayList<>();
        for (int i = 0; i < handles.size(); i++) {
          RunHandle h = handles.get(i);
          String result = "worker " + i;
          finishes.add(() -> h.finish(result));
        }
        Checks.eq(id + ": finishes recorded", count(all(finishes)), 1L);
      }
      List<Run> runs = procs.get(0).client.runs("ingest", 500);
      Checks.eq("runs", runs.size(), 5);
      for (Run r : runs) {
        Checks.eq("run " + r.id(), r.status(), RunStatus.OK);
      }
      List<String> unexpected = new ArrayList<>();
      for (Worker p : procs) {
        for (String e : p.errors) {
          if (!e.contains("already finished")) {
            unexpected.add(e);
          }
        }
      }
      ensure(unexpected.isEmpty(), "unexpected errors: " + unexpected);
    } finally {
      for (Worker p : procs) {
        p.close();
      }
      done(s);
    }
  }
}
