package dev.cronwatch;

import dev.cronwatch.alerts.Transport;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.evaluate.Expect;
import dev.cronwatch.internal.output.Output;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.store.Store;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.BiFunction;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import java.util.function.UnaryOperator;
import org.jspecify.annotations.Nullable;

/**
 * What a client holds and what its parts share: the configuration, the declared jobs, the threads,
 * and the store calls every part makes (the SDK's {@code client.ts} fields and its {@code sync},
 * {@code serial}, {@code updateState} and {@code writeState}).
 */
final class Core {
  /**
   * Reads and writes of one job's state before an update gives up on a store that keeps changing
   * under it.
   */
  static final int STATE_ATTEMPTS = 10;

  /**
   * A declared job: its stored definition, and the live expect rule the stored one only describes.
   * Compared by identity: declaring a name again is a new declaration, to be written again.
   */
  static final class JobDef {
    private final String name;
    private final Definition stored;
    private final @Nullable Expect expect;

    JobDef(String name, Definition stored, @Nullable Expect expect) {
      this.name = name;
      this.stored = stored;
      this.expect = expect;
    }

    String name() {
      return name;
    }

    Definition stored() {
      return stored;
    }

    @Nullable Expect expect() {
      return expect;
    }
  }

  /** A state as written, and what the change that made it answered. */
  record Changed<R>(JobState state, R result) {}

  /** The timeouts the tests shorten; the SDK's everywhere else. */
  static final class Timings {
    long channelMs = 15_000;
    long triageMs = 25_000;
    long retryBudgetMs = 20_000;
    long closeWaitMs = 5_000;
    long shutdownMs = 5_000;
    long firstCheckMs = 1_000;
    long minIntervalMs = 5_000;
  }

  final Store store;
  final boolean defaultStore;

  /** The builder's environment (the Spring starter's profile), read after the variables. */
  final @Nullable String environmentFallback;

  final List<Channel> channels;
  final @Nullable Triage triage;

  /** Where channels and triage send, unless their options name a transport of their own. */
  final Transport transport;

  final List<Source> sources;
  final @Nullable String cronSecret;
  final boolean secretOptOut;
  final double retentionMs;
  final JsObject defaults;
  private final @Nullable UnaryOperator<String> redact;
  private final boolean redactOff;
  final boolean deferDelivery;
  private final ErrorHandler onError;
  private final LongSupplier clock;
  final Timings timings;

  final ExecutorService executor;
  final ScheduledThreadPoolExecutor timer;

  private final ReentrantLock declaredLock = new ReentrantLock();
  private final LinkedHashMap<String, JobDef> definitions = new LinkedHashMap<>();
  private final Set<String> synced = new HashSet<>();

  /** Starts with an id still in flight, so two at once in this process record one run. */
  final ConcurrentHashMap<String, CompletableFuture<RunHandle>> starting =
      new ConcurrentHashMap<>();

  /** A job's update lock and how many callers hold it or wait for it. */
  private static final class JobLock {
    final ReentrantLock lock = new ReentrantLock(true);
    int users;
  }

  /**
   * Each job's update lock while anyone holds it or waits for it: let go of once idle, as the SDK
   * drops a job's queue, so names that come and go (a silence of any name, pg_cron's jobs) do not
   * keep a lock each for good.
   */
  private final ConcurrentHashMap<String, JobLock> jobLocks = new ConcurrentHashMap<>();

  /** Each job's lock for the writes of its declaration, kept as {@link #jobLocks} are. */
  private final ConcurrentHashMap<String, JobLock> syncLocks = new ConcurrentHashMap<>();

  private final ReentrantLock readyLock = new ReentrantLock();
  private boolean ready;

  final AtomicReference<@Nullable CompletableFuture<CheckResult>> checking =
      new AtomicReference<>();

  /** The thread the check in flight runs on, so a close from inside it does not wait for itself. */
  volatile @Nullable Thread checkThread;

  /** Set by {@code close()} before it waits for the check: no check starts after it. */
  final AtomicBoolean closed = new AtomicBoolean();

  /** Set while a task of this client's runs on one of its threads (see {@link #ownsThread}). */
  private static final ThreadLocal<@Nullable Core> RUNNING_FOR = new ThreadLocal<>();

  /**
   * Whether the calling thread is running a task of this client's: the check, a channel's send,
   * triage, or an error handler called from one of them. A close from such a thread cannot wait for
   * the check, which may be waiting on it.
   */
  boolean ownsThread() {
    return RUNNING_FOR.get() == this || Thread.currentThread().equals(checkThread);
  }

  /** {@code task} marked as this client's while it runs, the mark the caller had put back after. */
  private <T> Callable<T> owned(Callable<T> task) {
    return () -> {
      Core before = RUNNING_FOR.get();
      RUNNING_FOR.set(this);
      try {
        return task.call();
      } finally {
        RUNNING_FOR.set(before);
      }
    };
  }

  final AtomicLong lastPruneAt = new AtomicLong(0);

  /** Runs whose function is running in this process, by id, for the shutdown hook. */
  final ConcurrentHashMap<String, Runs.OpenRun> open = new ConcurrentHashMap<>();

  Core(
      Store store,
      boolean defaultStore,
      List<Channel> channels,
      @Nullable Triage triage,
      Transport transport,
      List<Source> sources,
      @Nullable String cronSecret,
      boolean secretOptOut,
      double retentionMs,
      JsObject defaults,
      @Nullable UnaryOperator<String> redact,
      boolean redactOff,
      boolean deferDelivery,
      ErrorHandler onError,
      LongSupplier clock,
      Timings timings,
      @Nullable String environmentFallback) {
    this.environmentFallback = environmentFallback;
    this.store = store;
    this.defaultStore = defaultStore;
    this.channels = List.copyOf(channels);
    this.triage = triage;
    this.transport = transport;
    this.sources = List.copyOf(sources);
    this.cronSecret = cronSecret;
    this.secretOptOut = secretOptOut;
    this.retentionMs = retentionMs;
    this.defaults = defaults;
    this.redact = redact;
    this.redactOff = redactOff;
    this.deferDelivery = deferDelivery;
    this.onError = onError;
    this.clock = clock;
    this.timings = timings;
    this.executor =
        Executors.newThreadPerTaskExecutor(Thread.ofVirtual().name("cronwatch-", 0).factory());
    this.timer =
        new ScheduledThreadPoolExecutor(
            1,
            r -> {
              Thread t = new Thread(r, "cronwatch-timer");
              t.setDaemon(true);
              return t;
            });
    this.timer.setRemoveOnCancelPolicy(true);
  }

  long now() {
    return clock.getAsLong();
  }

  /** Calls the error handler, carrying on whatever it does. */
  void report(Throwable error, String where) {
    try {
      onError.handle(where, error);
    } catch (Throwable t) {
      // Nothing more can be done with it.
    }
  }

  /** Reports a message of the client's own. */
  void report(String message, String where) {
    report(new CronwatchException(CronwatchException.Kind.OTHER, message), where);
  }

  /** The client's redaction applied to a run's output or error. */
  String redact(String text) {
    if (redactOff) {
      return text;
    }
    UnaryOperator<String> custom = redact;
    if (custom == null) {
      return Output.redactSecrets(text);
    }
    try {
      String out = custom.apply(text);
      if (out == null) {
        throw new IllegalStateException("redact must return a string, not null");
      }
      return out;
    } catch (RuntimeException e) {
      // A broken redact must not stop the run finishing, nor leak what it was given.
      report(e, "redact");
      return Output.redactSecrets(text);
    }
  }

  // ---- declared jobs

  void declare(JobDef def) {
    declaredLock.lock();
    try {
      definitions.put(def.name(), def);
      synced.remove(def.name());
    } finally {
      declaredLock.unlock();
    }
  }

  @Nullable JobDef declared(String name) {
    declaredLock.lock();
    try {
      return definitions.get(name);
    } finally {
      declaredLock.unlock();
    }
  }

  List<JobDef> declaredAll() {
    declaredLock.lock();
    try {
      return new ArrayList<>(definitions.values());
    } finally {
      declaredLock.unlock();
    }
  }

  void undeclare(String name) {
    declaredLock.lock();
    try {
      definitions.remove(name);
      synced.remove(name);
    } finally {
      declaredLock.unlock();
    }
  }

  // ---- the store

  /** A store call that may throw anything. */
  @FunctionalInterface
  interface StoreCall<T> {
    T call() throws Exception;
  }

  /** A store call, its failure a {@link CronwatchException} of kind STORE. */
  static <T> T call(StoreCall<T> c) {
    try {
      return c.call();
    } catch (CronwatchException | UnsupportedOperationException e) {
      // An optional store method the store does not have is the caller's to fall back from.
      throw e;
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw CronwatchException.store(e);
    } catch (Exception e) {
      throw CronwatchException.store(e);
    }
  }

  /** Initializes the store once; one that fails is tried again on the next call. */
  void ensureReady() {
    readyLock.lock();
    try {
      if (ready) {
        return;
      }
      call(
          () -> {
            store.init();
            return null;
          });
      ready = true;
      if (defaultStore && Env.environment(environmentFallback).equals("production")) {
        Env.LOGGER.log(
            System.Logger.Level.WARNING,
            "[cronwatch] using the in-memory store: runs and state are lost on restart. Pass a"
                + " store with Cronwatch.builder().store(...), such as SqlStore over the app's"
                + " database.");
      }
    } finally {
      readyLock.unlock();
    }
  }

  /**
   * Writes the declaration of {@code def}'s name as it stands, unless the store has it, once per
   * declaration: a handle kept from an earlier declaration writes the one that replaced it, never
   * its own over it, and one forgotten since writes its own. A name is marked as written only while
   * that same declaration stands, so a forget that lands during the write (deleting the row after
   * it) leaves the name to be written again, as does one forgotten before it.
   */
  void sync(JobDef def) {
    sync(def, false);
  }

  /**
   * {@link #sync(JobDef)}, and with {@code confirm}, as a run starts, a name already written is
   * read back: another process may have forgotten the job since, and a job still declared here
   * comes back on its next run.
   */
  void sync(JobDef def, boolean confirm) {
    ensureReady();
    String name = def.name();
    if (standing(name, def) == null) {
      if (!confirm || call(() -> store.getJob(name)) != null) {
        return;
      }
      unmark(name);
    }
    inTurn(
        name,
        () -> {
          JobDef standing = standing(name, def);
          if (standing == null) {
            return false;
          }
          call(
              () -> {
                store.upsertJob(standing.stored(), now());
                return null;
              });
          markSynced(standing);
          return true;
        });
  }

  /** The declaration of {@code name} still to be written, {@code def} without one, or null. */
  private @Nullable JobDef standing(String name, JobDef def) {
    declaredLock.lock();
    try {
      return synced.contains(name) ? null : definitions.getOrDefault(name, def);
    } finally {
      declaredLock.unlock();
    }
  }

  /**
   * Runs {@code write} in turn with every other write of {@code name}'s declaration (a fair lock of
   * its own, apart from the one its state updates take), so two declarations of one name reach the
   * store in the order they were made and the later one stays.
   */
  <T> T inTurn(String name, Supplier<T> write) {
    JobLock held = hold(syncLocks, name);
    held.lock.lock();
    try {
      return write.get();
    } finally {
      held.lock.unlock();
      release(syncLocks, name);
    }
  }

  void markSynced(JobDef def) {
    declaredLock.lock();
    try {
      if (definitions.get(def.name()) == def) {
        synced.add(def.name());
      }
    } finally {
      declaredLock.unlock();
    }
  }

  /** Leaves {@code name} to be written again, its row found gone. */
  void unmark(String name) {
    declaredLock.lock();
    try {
      synced.remove(name);
    } finally {
      declaredLock.unlock();
    }
  }

  JobState readState(String job) {
    return Evaluate.normalizeState(call(() -> store.getState(job)), job);
  }

  /**
   * Every read-modify-write of a job's state. In turn with this process's other updates to the job
   * (a fair lock, the SDK's {@code serial()} queue), it runs {@code prepare} once, reads the state,
   * asks {@code change} for the next one, and writes it with the version one higher, only if the
   * stored version is still the one read. When another process wrote in between, the write is
   * refused and it starts again from a fresh read, up to {@link #STATE_ATTEMPTS} times. So {@code
   * change} may run more than once and must only compute. Nothing is written when the state is
   * unchanged. Returns the state as stored and the result.
   */
  <P, R> Changed<R> updateState(
      String job, StoreCall<P> prepare, BiFunction<JobState, P, Changed<R>> change) {
    ReentrantLock lock = hold(jobLocks, job).lock;
    lock.lock();
    try {
      P prepared = call(prepare);
      for (int attempt = 1; ; attempt++) {
        JobState current = readState(job);
        Changed<R> next = change.apply(current, prepared);
        if (next.state().toJson().equals(current.toJson())) {
          return new Changed<>(current, next.result());
        }
        long version = current.countedVersion();
        JobState written = next.state().withVersion(version + 1);
        if (writeState(written, version)) {
          return new Changed<>(written, next.result());
        }
        if (attempt >= STATE_ATTEMPTS) {
          throw new CronwatchException(
              CronwatchException.Kind.OTHER,
              "the state of "
                  + job
                  + " changed under "
                  + STATE_ATTEMPTS
                  + " attempts in a row to update it; gave up");
        }
      }
    } finally {
      lock.unlock();
      release(jobLocks, job);
    }
  }

  /** One user more of a job's lock in {@code locks}, made if it has none. */
  private static JobLock hold(ConcurrentHashMap<String, JobLock> locks, String job) {
    return locks.compute(
        job,
        (k, l) -> {
          JobLock out = l == null ? new JobLock() : l;
          out.users++;
          return out;
        });
  }

  /** One user fewer of a job's lock in {@code locks}, dropped once it has none. */
  private static void release(ConcurrentHashMap<String, JobLock> locks, String job) {
    locks.computeIfPresent(job, (k, l) -> --l.users == 0 ? null : l);
  }

  /** How many jobs' update locks are held or waited on now. */
  int lockedJobs() {
    return jobLocks.size();
  }

  /** {@link #updateState} with nothing to prepare. */
  <R> Changed<R> updateState(String job, java.util.function.Function<JobState, Changed<R>> change) {
    return updateState(job, () -> Boolean.TRUE, (s, unused) -> change.apply(s));
  }

  /** A conditional write, or for a store without it, a plain one that always succeeds. */
  private boolean writeState(JobState state, long expected) {
    try {
      return call(() -> store.compareAndSetState(state, expected));
    } catch (UnsupportedOperationException e) {
      call(
          () -> {
            store.setState(state);
            return null;
          });
      return true;
    }
  }

  /** A conditional write of a run, or for a store without it, a read then a plain write. */
  boolean writeRunIf(Run run, List<RunStatus> from) {
    try {
      return call(() -> store.updateRunIf(run, from));
    } catch (UnsupportedOperationException e) {
      Run stored = call(() -> store.getRun(run.id()));
      if (stored == null || !from.contains(stored.status())) {
        return false;
      }
      call(
          () -> {
            store.updateRun(run);
            return null;
          });
      return true;
    }
  }

  // ---- threads

  /**
   * Runs {@code task} on a virtual thread of the client's, or in the caller after {@code close()}.
   */
  <T> Future<T> submit(Callable<T> task) {
    try {
      return executor.submit(owned(task));
    } catch (RejectedExecutionException e) {
      FutureTask<T> inline = new FutureTask<>(task);
      inline.run();
      return inline;
    }
  }

  /**
   * Runs {@code task} on a virtual thread of the client's without waiting for it, or in the caller
   * after {@code close()}; a throw in it is reported as {@code where}.
   */
  void spawn(Runnable task, String where) {
    Runnable guarded =
        () -> {
          try {
            task.run();
          } catch (RuntimeException e) {
            report(e, where);
          }
        };
    try {
      Callable<@Nullable Void> marked =
          owned(
              () -> {
                guarded.run();
                return null;
              });
      executor.execute(
          () -> {
            try {
              marked.call();
            } catch (Exception impossible) {
              // guarded reports what task throws.
            }
          });
    } catch (RejectedExecutionException e) {
      guarded.run();
    }
  }

  /**
   * Waits for {@code future} however often the caller is interrupted, then sets the caller's
   * interrupt status again: the work runs to its end on its own thread, and the caller's own code
   * sees the interrupt. A throw in the work is thrown here.
   */
  static <T> T awaitUninterruptibly(Future<T> future) {
    boolean interrupted = false;
    try {
      while (true) {
        try {
          return future.get();
        } catch (InterruptedException e) {
          interrupted = true;
        } catch (ExecutionException e) {
          Throwable cause = e.getCause();
          if (cause instanceof RuntimeException r) {
            throw r;
          }
          if (cause instanceof Error err) {
            throw err;
          }
          throw new CronwatchException(CronwatchException.Kind.OTHER, String.valueOf(cause), cause);
        }
      }
    } finally {
      if (interrupted) {
        Thread.currentThread().interrupt();
      }
    }
  }

  /** The declared definitions, in the order first declared. */
  List<Definition> definedJobs() {
    List<Definition> out = new ArrayList<>();
    for (JobDef d : declaredAll()) {
      out.add(d.stored());
    }
    return out;
  }
}
