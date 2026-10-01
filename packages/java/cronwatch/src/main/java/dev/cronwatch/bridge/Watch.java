package dev.cronwatch.bridge;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.Definition;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.core.Access;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;

/**
 * What an integration keeps for one scheduler: the jobs it declared, by name, the jobs gone from
 * it, the jobs a worker runs that another process declared, and the problems it reported. The Go
 * port's {@code bridge/watch.go} and {@code Fallback} through the Rust port's {@code Watch}, with
 * their audits' fixes. Safe to use from many threads at once.
 */
public final class Watch {
  /** Bounds one write of a declaration to the store, so a store that hangs holds nothing. */
  static final long SAVE_TIMEOUT_MS = 30_000;

  private final Cronwatch cw;
  private final String tag;
  private final String appTag;
  private final String scheduler;

  /**
   * Holds one declaration at a time ({@code declare}, the end of {@code fallback}, {@code
   * unschedule}'s declarations), so one never takes another's entries for gone or leaves the client
   * holding a job without its schedule.
   */
  private final ReentrantLock declaring = new ReentrantLock();

  private final ReentrantLock lock = new ReentrantLock();
  private final Condition settledChanged = lock.newCondition();
  private final Map<String, Declared> jobs = new HashMap<>();

  /** Jobs declared for runs of jobs this watch did not declare. */
  private final Map<String, Job> fallback = new HashMap<>();

  private final Set<String> reported = new HashSet<>();

  /**
   * Whether this process ever declared an entry: until it has, it takes no job for one the
   * scheduler dropped (a process that runs a check and no scheduler must not unschedule the app's
   * jobs).
   */
  private boolean seen;

  /** Names declared and not yet written to the store, which one thread at a time writes. */
  private final TreeSet<String> pending = new TreeSet<>();

  private boolean saving;

  /** How long one write of a declaration may take; the tests shorten it. */
  volatile long saveTimeoutMs = SAVE_TIMEOUT_MS;

  private static final class Declared {
    Job job;

    /** The definition's JSON, to tell a changed declaration. */
    String key;

    /** The entry is still in the scheduler. */
    boolean current;

    Declared(Job job, String key, boolean current) {
      this.job = job;
      this.key = key;
      this.current = current;
    }
  }

  /**
   * A watch for one scheduler: {@code tag} is the integration's ({@code quartz}), {@code app} the
   * app's name for its tag (null for {@link SchedulerBridge#appName()}), and {@code scheduler} how
   * messages name the scheduler ({@code Quartz}).
   */
  public Watch(Cronwatch cw, String tag, @Nullable String app, String scheduler) {
    this.cw = Objects.requireNonNull(cw, "cw");
    this.tag = Objects.requireNonNull(tag, "tag");
    String name = app == null || app.isEmpty() ? SchedulerBridge.appName() : app;
    this.appTag = SchedulerBridge.appTag(tag, name);
    this.scheduler = Objects.requireNonNull(scheduler, "scheduler");
  }

  /** The client the watch declares jobs on. */
  public Cronwatch client() {
    return cw;
  }

  /** The integration's tag. */
  public String tag() {
    return tag;
  }

  /** The app's tag under the integration's. */
  public String appTag() {
    return appTag;
  }

  /**
   * The app's part of its tag ({@code billing} of {@code quartz:billing}), for run ids that must
   * not collide with another app's on a shared store.
   */
  public String appSlug() {
    return appTag.substring(tag.length() + 1);
  }

  /**
   * Hands {@code message} to the client's error handler the first time this watch sees it for that
   * {@code where}.
   */
  public void reportOnce(String message, String where) {
    boolean first;
    lock.lock();
    try {
      first = reported.add(where + "\0" + message);
    } finally {
      lock.unlock();
    }
    if (first) {
      cw.reportError(new CronwatchException(CronwatchException.Kind.OTHER, message), where);
    }
  }

  /** The job declared under {@code name}, or one declared for a run of it ({@link #fallback}). */
  public @Nullable Job job(String name) {
    lock.lock();
    try {
      Declared d = jobs.get(name);
      return d != null ? d.job : fallback.get(name);
    } finally {
      lock.unlock();
    }
  }

  /** Whether {@code name} was declared from a scheduler entry by this watch. */
  public boolean declares(String name) {
    lock.lock();
    try {
      return jobs.containsKey(name);
    } finally {
      lock.unlock();
    }
  }

  /**
   * Declares every entry the scheduler has now, one job per name, and declares again without its
   * schedule a job this watch declared whose entries are all gone. Several entries of one name on
   * different schedules are one job without a schedule, reported once. Each job is tagged with the
   * integration's tag and the app's. A declaration that has not changed is left alone; one the
   * client refuses is reported, as is each entry's problem, once. What is declared is written to
   * the store on a thread of its own ({@link #settle} waits for it), since a process that only
   * schedules neither runs nor checks, and a declaration kept in memory would never reach the
   * processes that do.
   */
  public void declare(List<Entry> entries) {
    declaring.lock();
    try {
      Map<String, List<Entry>> byName = new LinkedHashMap<>();
      for (Entry e : entries) {
        byName.computeIfAbsent(e.name(), k -> new ArrayList<>()).add(e);
      }
      lock.lock();
      try {
        if (!entries.isEmpty()) {
          seen = true;
        }
        for (Declared d : jobs.values()) {
          d.current = false;
        }
      } finally {
        lock.unlock();
      }

      for (Map.Entry<String, List<Entry>> group : byName.entrySet()) {
        String name = group.getKey();
        List<Entry> list = group.getValue();
        Entry first = list.get(0);
        String sched = first.schedule();
        String zone = first.timezone();
        List<String> times = new ArrayList<>();
        for (Entry e : list) {
          String problem = e.problem();
          if (problem != null) {
            reportOnce(problem, "declaring " + e.label());
          }
          String text = e.schedule();
          if (!e.timezone().isEmpty()) {
            text = text + " in " + e.timezone();
          }
          if (text.isEmpty()) {
            text = "no schedule";
          }
          if (!times.contains(text)) {
            times.add(text);
          }
        }
        if (times.size() > 1) {
          sched = "";
          zone = "";
          reportOnce(
              "cronwatch: "
                  + SchedulerBridge.quote(name)
                  + " is run by "
                  + list.size()
                  + " "
                  + scheduler
                  + " entries on different schedules ("
                  + String.join("; ", times)
                  + "), so it is watched without a schedule; give each a name of its own",
              "declaring " + first.label());
        }
        JobOptions options = first.defaults().copy();
        if (!sched.isEmpty()) {
          options.schedule(sched);
          if (!zone.isEmpty()) {
            options.timezone(zone);
          }
        }
        options.merge(first.options().copy());
        declareOne(name, first.label(), tagged(name, options), true);
      }

      // Jobs whose entries are gone keep their runs and lose their schedule.
      TreeSet<String> goneNames = new TreeSet<>();
      Map<String, Definition> gone = new HashMap<>();
      lock.lock();
      try {
        for (Map.Entry<String, Declared> e : jobs.entrySet()) {
          Definition def = e.getValue().job.definition();
          String schedule = def.schedule();
          if (!e.getValue().current && schedule != null && !schedule.isEmpty()) {
            goneNames.add(e.getKey());
            gone.put(e.getKey(), def);
          }
        }
      } finally {
        lock.unlock();
      }
      for (String name : goneNames) {
        declareOne(
            name,
            SchedulerBridge.quote(name),
            SchedulerBridge.unscheduled(Objects.requireNonNull(gone.get(name))),
            false);
      }
    } finally {
      declaring.unlock();
    }
  }

  /** {@code options} with the integration's and the app's tags added to the ones it gives. */
  public JobOptions tagged(String name, JobOptions options) {
    List<String> tags = Access.client().tags(options);
    for (String t : List.of(tag, appTag)) {
      if (!tags.contains(t)) {
        tags.add(t);
      }
    }
    return options.tags(tags);
  }

  private void declareOne(String name, String label, JobOptions options, boolean current) {
    String key;
    try {
      key = SchedulerBridge.definition(cw, name, options).toJson();
    } catch (CronwatchException e) {
      reportOnce(Objects.requireNonNullElse(e.getMessage(), "invalid"), "declaring " + label);
      return;
    }
    lock.lock();
    try {
      Declared d = jobs.get(name);
      if (d != null && d.key.equals(key)) {
        d.current = d.current || current;
        return;
      }
    } finally {
      lock.unlock();
    }
    Job job;
    try {
      job = cw.job(name, options);
    } catch (CronwatchException e) {
      reportOnce(Objects.requireNonNullElse(e.getMessage(), "invalid"), "declaring " + label);
      return;
    }
    lock.lock();
    try {
      fallback.remove(name);
      Declared d = jobs.get(name);
      if (d == null) {
        jobs.put(name, new Declared(job, key, current));
      } else {
        d.job = job;
        d.key = key;
        d.current = d.current || current;
      }
    } finally {
      lock.unlock();
    }
    save(name);
  }

  /**
   * Writes {@code name}'s declaration to the store on a thread of its own, one thread at a time,
   * each write the client's declaration as it is then.
   */
  private void save(String name) {
    lock.lock();
    try {
      pending.add(name);
      if (saving) {
        return;
      }
      saving = true;
    } finally {
      lock.unlock();
    }
    try {
      Thread.ofVirtual().name("cronwatch-declare").start(this::saveAll);
    } catch (RuntimeException | OutOfMemoryError e) {
      done();
      throw e;
    }
  }

  /** Marks the writer finished, whatever ended it, so the next declaration starts another. */
  private void done() {
    lock.lock();
    try {
      saving = false;
      settledChanged.signalAll();
    } finally {
      lock.unlock();
    }
  }

  private void saveAll() {
    try {
      while (true) {
        List<String> names;
        lock.lock();
        try {
          if (pending.isEmpty()) {
            return;
          }
          names = new ArrayList<>(pending);
          pending.clear();
        } finally {
          lock.unlock();
        }
        Set<String> defined = defined();
        for (String name : names) {
          if (!defined.contains(name)) {
            continue; // forgotten since
          }
          try {
            syncJob(name);
          } catch (RuntimeException e) {
            // A store that throws is that declaration's failure, not the end of every one after.
            cw.reportError(e, "declaring " + name);
          }
        }
      }
    } finally {
      done();
    }
  }

  /**
   * {@link Cronwatch#syncJob} within the save deadline, on a thread of its own: a store that hangs
   * keeps that thread, not the caller, which gives up.
   */
  boolean syncJob(String name) {
    CompletableFuture<Boolean> written = new CompletableFuture<>();
    Thread.ofVirtual()
        .name("cronwatch-declare")
        .start(
            () -> {
              try {
                written.complete(cw.syncJob(name));
              } catch (Throwable t) {
                written.completeExceptionally(t);
              }
            });
    try {
      return written.get(saveTimeoutMs, TimeUnit.MILLISECONDS);
    } catch (TimeoutException e) {
      throw new CronwatchException(
          CronwatchException.Kind.OTHER,
          "writing the declaration of "
              + SchedulerBridge.quote(name)
              + " took longer than "
              + saveTimeoutMs / 1000
              + " seconds; gave up");
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new CronwatchException(
          CronwatchException.Kind.OTHER,
          "interrupted while writing the declaration of " + SchedulerBridge.quote(name),
          e);
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

  private Set<String> defined() {
    Set<String> out = new HashSet<>();
    for (Definition d : cw.definedJobs()) {
      out.add(d.name());
    }
    return out;
  }

  /**
   * Waits until what {@link #declare} declared has been written to the store, at most {@code
   * timeout}, for tests and a clean exit. Says whether it was.
   */
  public boolean settle(Duration timeout) {
    long deadline = System.nanoTime() + timeout.toNanos();
    lock.lock();
    try {
      while (saving || !pending.isEmpty()) {
        long left = deadline - System.nanoTime();
        if (left <= 0) {
          return false;
        }
        settledChanged.awaitNanos(left);
      }
      return true;
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return false;
    } finally {
      lock.unlock();
    }
  }

  /**
   * The job a run in this process belongs to when this process has not declared it from a scheduler
   * of its own (a worker whose app schedules the job in another process): declared again from the
   * definition the store holds, when that is this app's (tagged with its app tag), so the schedule
   * another process stored is kept, else with {@code options} and this watch's tags. Declared once
   * per name in this process. Null, with the reason reported, when the client refuses it or the
   * store cannot be read (the run then goes unrecorded, and the next one asks again), since a
   * declaration made without the stored one would write over its schedule. A job {@link #declare}
   * has declared is {@code declare}'s.
   */
  public @Nullable Job fallback(String name, JobOptions options) {
    Job known = job(name);
    if (known != null) {
      return known;
    }
    StoredJob stored;
    try {
      Access.client().ensureReady(cw);
      stored = cw.store().getJob(name);
    } catch (Exception e) {
      if (e instanceof InterruptedException) {
        Thread.currentThread().interrupt();
      }
      cw.reportError(
          e instanceof CronwatchException ? e : CronwatchException.store(e), "declaring " + name);
      return null;
    }
    JobOptions made =
        stored != null && stored.definition().tags().contains(appTag)
            ? SchedulerBridge.optionsOf(stored.definition())
            : tagged(name, options.copy());
    // In turn with declare, and after looking again: a job declared from a scheduler entry
    // meanwhile is that one, so the client never ends up holding the declaration without the
    // schedule.
    declaring.lock();
    try {
      Job again = job(name);
      if (again != null) {
        return again;
      }
      Job job;
      try {
        job = cw.job(name, made);
      } catch (CronwatchException e) {
        reportOnce(Objects.requireNonNullElse(e.getMessage(), "invalid"), "declaring " + name);
        return null;
      }
      lock.lock();
      try {
        fallback.put(name, job);
      } finally {
        lock.unlock();
      }
      return job;
    } finally {
      declaring.unlock();
    }
  }

  /**
   * Declares again without its schedule every job of this app's (tagged with its app tag) that the
   * store holds with a schedule and this process has not declared: a scheduler entry taken out
   * since the job was declared, by this process or an earlier one, so it is never reported missed
   * and a missed alert already open closes. Call it just before a check. It first writes back this
   * process's own declarations wherever the store holds something else (an older release still up
   * during a deploy may have taken the schedule out of a job it does not run). A process that never
   * declared an entry of its scheduler leaves every job alone. Everything is written before it
   * returns. Returns the names declared again.
   *
   * @throws CronwatchException naming every write or read that failed, after doing the rest
   */
  public List<String> unschedule() {
    boolean everSeen;
    List<String> mine;
    lock.lock();
    try {
      everSeen = seen;
      mine = new ArrayList<>(new TreeSet<>(jobs.keySet()));
    } finally {
      lock.unlock();
    }
    if (!everSeen) {
      return List.of();
    }
    List<String> failed = new ArrayList<>();
    Set<String> defined = defined();
    for (String name : mine) {
      if (!defined.contains(name)) {
        continue;
      }
      try {
        syncJob(name);
      } catch (RuntimeException e) {
        failed.add("declaring " + name + ": " + e.getMessage());
      }
    }
    List<StoredJob> stored;
    try {
      Access.client().ensureReady(cw);
      stored = cw.store().listJobs();
    } catch (Exception e) {
      if (e instanceof InterruptedException) {
        Thread.currentThread().interrupt();
      }
      failed.add((e instanceof CronwatchException ? e : CronwatchException.store(e)).getMessage());
      throw new CronwatchException(CronwatchException.Kind.OTHER, String.join("\n", failed));
    }
    // In turn with declare and fallback, and with what is declared read again: a job declared
    // since the first read (a scheduler entry added while the store was read) keeps its schedule.
    List<String> names = new ArrayList<>();
    declaring.lock();
    try {
      Set<String> now = defined();
      for (StoredJob job : stored) {
        Definition def = job.definition();
        String schedule = def.schedule();
        if (now.contains(job.name())
            || schedule == null
            || schedule.isEmpty()
            || !def.tags().contains(appTag)) {
          continue;
        }
        try {
          cw.job(job.name(), SchedulerBridge.unscheduled(def));
          names.add(job.name());
        } catch (CronwatchException e) {
          failed.add("declaring " + job.name() + ": " + e.getMessage());
        }
      }
    } finally {
      declaring.unlock();
    }
    // Written before returning, and in order with this call's other writes: a process that never
    // checks would otherwise leave the schedule in the store, and a write left to run behind could
    // land after another process has put the schedule back. syncJob writes what is declared at
    // the time, so a job declared again since keeps its schedule.
    for (String name : names) {
      try {
        syncJob(name);
      } catch (RuntimeException e) {
        failed.add("declaring " + name + ": " + e.getMessage());
      }
    }
    if (!failed.isEmpty()) {
      throw new CronwatchException(CronwatchException.Kind.OTHER, String.join("\n", failed));
    }
    return names;
  }

  @Override
  public String toString() {
    return "Watch[" + tag + ", " + appTag + "]";
  }
}
