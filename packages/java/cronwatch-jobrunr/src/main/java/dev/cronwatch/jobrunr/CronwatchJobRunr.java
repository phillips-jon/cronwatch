package dev.cronwatch.jobrunr;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.JobOptions;
import dev.cronwatch.ObservedRun;
import dev.cronwatch.RunOptions;
import dev.cronwatch.bridge.Entry;
import dev.cronwatch.bridge.FireTimes;
import dev.cronwatch.bridge.ScheduleException;
import dev.cronwatch.bridge.SchedulerBridge;
import dev.cronwatch.bridge.Watch;
import dev.cronwatch.json.Json;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.UndeclaredThrowableException;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;
import org.jobrunr.jobs.Job;
import org.jobrunr.jobs.RecurringJob;
import org.jobrunr.jobs.filters.JobServerFilter;
import org.jobrunr.jobs.states.ProcessingState;
import org.jobrunr.scheduling.JobScheduler;
import org.jobrunr.scheduling.Schedule;
import org.jobrunr.storage.StorageProvider;
import org.jspecify.annotations.Nullable;

/**
 * CronWatch for JobRunr 8: every recurring job is declared as a CronWatch job with its schedule,
 * and every attempt is recorded as a run, so a job that fails, runs late, never runs, gets stuck or
 * runs slow is reported. It is a {@link JobServerFilter}: give it to the background job server.
 *
 * <pre>{@code
 * CronwatchJobRunr watcher = CronwatchJobRunr.watch(cw, storageProvider, JobRunrOptions.defaults());
 * JobScheduler scheduler = JobRunr.configure()
 *     .useStorageProvider(storageProvider)
 *     .withJobFilter(watcher)                   // before the server, as JobRunr asks
 *     .useBackgroundJobServer()
 *     .initialize()
 *     .getJobScheduler();
 * CronwatchJobRunr.scheduleCheck(scheduler);   // a check every minute, once per cluster
 * }</pre>
 *
 * <p>JobRunr calls a server filter's {@code onProcessing} in the worker thread just before the job
 * runs, and {@code onProcessingSucceeded} or {@code onProcessingFailed} (with the exception) there
 * just after, so a run is opened and closed around the job in its own thread: {@link
 * Cronwatch#current()} and {@code job.log} work inside it. Each attempt is a run (trigger {@code
 * jobrunr}, id {@code jobrunr:<app>:<job id>:<attempt>}), so a retry is a run of its own, as the
 * gem's Sidekiq rules have it: failing attempts open one failed alert and the one that succeeds
 * closes it. Recurring jobs are the CronWatch jobs named by their ids; a job that is not recurring
 * is watched only when its JobRunr name is given to {@link JobRunrOptions#watchJob}.
 *
 * <p>A recurring job's cron is read in its zone and checked against JobRunr's own fire times
 * ({@link SchedulerBridge#checkFires}); one JobRunr reads differently is reported once and watched
 * without a schedule. An interval ({@code Duration}) is declared {@code every <interval>}. The
 * recurring jobs are read when the integration starts and every minute besides, and a recurring job
 * deleted is declared again without its schedule, so it is never reported missed. Jobs are tagged
 * {@code jobrunr} and {@code jobrunr:<app>}.
 */
public final class CronwatchJobRunr implements JobServerFilter, AutoCloseable {
  /** The tag every job this integration declares carries. */
  public static final String TAG = "jobrunr";

  /** The trigger of the runs it records. */
  public static final String TRIGGER = "jobrunr";

  /** The check's recurring job's id, whose runs are never a job. */
  public static final String CHECK_ID = "cronwatch-check";

  private static final String SCHEDULER = "JobRunr";

  /** The integration the check job runs, the one watched last in this JVM. */
  private static volatile @Nullable CronwatchJobRunr current;

  private final Cronwatch cw;
  private final StorageProvider storage;
  private final JobRunrOptions options;
  private final Watch watch;
  private final Map<UUID, ObservedRun> open = new ConcurrentHashMap<>();

  private final ReentrantLock lock = new ReentrantLock();
  private final Condition wake = lock.newCondition();
  private boolean closed;

  /** A cron's reading as it was checked: whether it was refused, and the problem. */
  private record Checked(@Nullable String problem) {}

  /**
   * Each recurring job's cron checked against JobRunr's own fire times, by the job, the cron, the
   * zone and the year, so the read every minute walks only what changed: a cron that fires often in
   * a zone with daylight saving takes most of a second to walk. Only what the last read saw is
   * kept.
   */
  private final Map<String, Checked> checked = new ConcurrentHashMap<>();

  /** How many crons were walked, for the tests. */
  final AtomicInteger walks = new AtomicInteger();

  /** How long a sync the check job starts may take; the tests shorten it. */
  volatile Duration syncTimeout = SchedulerBridge.SYNC_TIMEOUT;

  private CronwatchJobRunr(Cronwatch cw, StorageProvider storage, JobRunrOptions options) {
    this.cw = cw;
    this.storage = storage;
    this.options = options;
    this.watch = new Watch(cw, TAG, options.app, SCHEDULER);
  }

  /**
   * Watches the recurring jobs {@code storage} holds: they are declared now, and read again every
   * minute. Give the returned filter to the background job server, so each attempt is recorded.
   * {@link #close} stops it.
   */
  public static CronwatchJobRunr watch(
      Cronwatch cw, StorageProvider storage, JobRunrOptions options) {
    CronwatchJobRunr w = new CronwatchJobRunr(cw, storage, options);
    w.read();
    current = w;
    Thread.ofVirtual().name("cronwatch-jobrunr").start(w::readLoop);
    return w;
  }

  /** {@link #watch(Cronwatch, StorageProvider, JobRunrOptions)} with the default options. */
  public static CronwatchJobRunr watch(Cronwatch cw, StorageProvider storage) {
    return watch(cw, storage, JobRunrOptions.defaults());
  }

  /**
   * Schedules the check as a recurring job of its own, every minute: a sync and a CronWatch check,
   * once per minute across the servers sharing the storage provider, in place of {@link
   * Cronwatch#start()} on each. Scheduling it again changes nothing.
   */
  public static void scheduleCheck(JobScheduler scheduler) {
    scheduler.scheduleRecurrently(CHECK_ID, "* * * * *", CronwatchJobRunr::runCheck);
  }

  /**
   * The check job's work, run by JobRunr: {@link #sync} within 30 seconds, then a check, on the
   * integration watched in this JVM. Never throws, and is never retried.
   */
  @org.jobrunr.jobs.annotations.Job(name = "CronWatch check", retries = 0)
  public static void runCheck() {
    CronwatchJobRunr w = current;
    if (w != null && !w.isClosed()) {
      w.checkNow();
    }
  }

  void checkNow() {
    SchedulerBridge.syncWithin(cw, syncTimeout, "jobrunr", this::sync);
    try {
      cw.check();
    } catch (RuntimeException e) {
      cw.reportError(e, "jobrunr");
    }
  }

  /** The watch that declares the recurring jobs, for an integration built on this one. */
  public Watch watchOfJobs() {
    return watch;
  }

  /**
   * Declares the recurring jobs as they are now, waits for the declarations to be written, and
   * declares again without its schedule each job of this app's the store holds with a schedule that
   * no recurring job has. The check job runs it before each check.
   *
   * @throws CronwatchException naming what failed
   */
  public void sync() {
    watch.declare(entries());
    watch.settle(SchedulerBridge.SYNC_TIMEOUT);
    watch.unschedule();
  }

  /**
   * Waits until what was declared has been written to the store, at most {@code timeout}, for tests
   * and a clean exit. Says whether it was.
   */
  public boolean settle(Duration timeout) {
    return watch.settle(timeout);
  }

  /**
   * Stops watching: no attempt is recorded from now on, and the recurring jobs are no longer read.
   * A run open now is still closed when its attempt ends.
   */
  @Override
  public void close() {
    lock.lock();
    try {
      closed = true;
      wake.signalAll();
    } finally {
      lock.unlock();
    }
    if (current == this) {
      current = null;
    }
  }

  private boolean isClosed() {
    lock.lock();
    try {
      return closed;
    } finally {
      lock.unlock();
    }
  }

  // ---- the recurring jobs

  private static String label(String name) {
    return "JobRunr recurring job " + Json.stringify(name);
  }

  private JobOptions optionsFor(String name) {
    JobOptions given = options.jobs.get(name);
    return given == null ? JobOptions.builder() : given.copy();
  }

  /** Every recurring job but the check's, one entry each. */
  List<Entry> entries() {
    List<Entry> out = new ArrayList<>();
    Set<String> seen = new HashSet<>();
    long now = cw.now();
    for (RecurringJob job : storage.getRecurringJobs()) {
      String name = job.getId();
      if (CHECK_ID.equals(name)) {
        continue;
      }
      if (!SchedulerBridge.validName(name)) {
        watch.reportOnce(
            "cronwatch: "
                + label(name)
                + " is not a CronWatch job name (1 to 120 letters, digits, \".\", \"_\", \":\""
                + " or \"-\"), so it is not watched; give it an id that is",
            "declaring " + label(name));
        continue;
      }
      out.add(entryOf(name, job, now, seen));
    }
    checked.keySet().retainAll(seen);
    return out;
  }

  private Entry entryOf(String name, RecurringJob job, long now, Set<String> seen) {
    String label = label(name);
    String schedule = "";
    String zone = "";
    String problem = null;
    Schedule s = job.getSchedule();
    if (s.isCarbonAware()) {
      problem =
          "cronwatch: "
              + label
              + " is carbon aware, so JobRunr moves its runs within a margin CronWatch cannot"
              + " know, and it is watched without a schedule";
    } else if (s.getClass().getName().equals("org.jobrunr.scheduling.interval.Interval")) {
      Duration every = s.durationBetweenSchedules();
      if (every.toMillis() < 1000) {
        problem =
            "cronwatch: "
                + label
                + " runs every "
                + every.toMillis()
                + "ms, more often than CronWatch's shortest schedule of one second, so it is"
                + " watched without a schedule";
      } else {
        schedule = SchedulerBridge.everyText(every);
      }
    } else {
      String expr = job.getScheduleExpression();
      String tz = job.getZoneId() == null ? "" : job.getZoneId();
      String key =
          label
              + "\0"
              + expr
              + "\0"
              + tz
              + "\0"
              + LocalDateTime.ofEpochSecond(Math.floorDiv(now, 1000), 0, ZoneOffset.UTC).getYear();
      seen.add(key);
      Checked c = checked.get(key);
      if (c == null) {
        walks.incrementAndGet();
        try {
          check(label, s, job.getCreatedAt(), expr, tz, now);
          c = new Checked(null);
        } catch (ScheduleException e) {
          c = new Checked(e.getMessage());
        }
        checked.put(key, c);
      }
      if (c.problem() == null) {
        schedule = expr;
        zone = tz;
      } else {
        problem = c.problem();
      }
    }
    return new Entry(
        name, label, schedule, zone, problem, options.jobDefaults.copy(), optionsFor(name));
  }

  /** Checks a recurring job's cron against JobRunr's own fire times in its zone. */
  private static void check(
      String label, Schedule schedule, Instant createdAt, String expr, String zone, long now)
      throws ScheduleException {
    ZoneId tz;
    try {
      tz = zone.isEmpty() ? ZoneId.systemDefault() : ZoneId.of(zone);
    } catch (RuntimeException e) {
      throw new ScheduleException(
          "cronwatch: " + label + ": the zone " + Json.stringify(zone) + " is not one Java reads");
    }
    Instant created = createdAt == null ? Instant.EPOCH : createdAt;
    FireTimes fires =
        FireTimes.walking(
            at -> {
              // Asked from a millisecond on, so a fire at exactly that instant is never answered
              // again, whichever way JobRunr reads "next".
              Instant next = schedule.next(created, Instant.ofEpochMilli(at + 1), tz);
              if (next == null) {
                return null;
              }
              long ms = next.toEpochMilli();
              return ms > at ? ms : null;
            },
            SCHEDULER);
    String[] fields = expr.trim().split("\\s+", -1);
    int day = fields.length == 6 ? 3 : 2;
    boolean daily =
        fields.length >= 5
            && fields.length <= 6
            && any(fields[day])
            && any(fields[day + 1])
            && any(fields[day + 2]);
    SchedulerBridge.checkFires(fires, expr, zone, "cronwatch: " + label, SCHEDULER, daily, now);
  }

  private static boolean any(String field) {
    return field.equals("*") || field.equals("?");
  }

  private void read() {
    try {
      watch.declare(entries());
    } catch (RuntimeException e) {
      cw.reportError(e, "jobrunr");
    }
  }

  private void readLoop() {
    long every = options.readEvery.toNanos();
    while (true) {
      lock.lock();
      try {
        long left = every;
        while (!closed && left > 0) {
          left = wake.awaitNanos(left);
        }
        if (closed) {
          return;
        }
      } catch (InterruptedException e) {
        return;
      } finally {
        lock.unlock();
      }
      read();
    }
  }

  // ---- attempts

  /** The CronWatch job an attempt is a run of, or null when it is not watched. */
  private @Nullable String nameOf(Job job) {
    String recurring = job.getRecurringJobId().orElse(null);
    if (recurring != null) {
      return CHECK_ID.equals(recurring) || !SchedulerBridge.validName(recurring) ? null : recurring;
    }
    String jobName = job.getJobName();
    return jobName != null
            && options.watched.contains(jobName)
            && SchedulerBridge.validName(jobName)
        ? jobName
        : null;
  }

  @Override
  public void onProcessing(Job job) {
    // A throw here would stop JobRunr running the job, so nothing leaves.
    try {
      if (isClosed()) {
        return;
      }
      String name = nameOf(job);
      if (name == null) {
        return;
      }
      dev.cronwatch.Job cwJob = watch.job(name);
      if (cwJob == null) {
        cwJob = watch.fallback(name, options.jobDefaults.copy().merge(optionsFor(name)));
        if (cwJob == null) {
          return;
        }
      }
      long attempt = job.getJobStatesOfType(ProcessingState.class).count();
      String id = "jobrunr:" + watch.appSlug() + ":" + job.getId() + ":" + Math.max(1, attempt);
      open.put(job.getId(), cwJob.open(RunOptions.trigger(TRIGGER).withId(id)));
    } catch (RuntimeException e) {
      cw.reportError(e, "jobrunr");
    }
  }

  @Override
  public void onProcessingSucceeded(Job job) {
    ObservedRun run = open.remove(job.getId());
    if (run == null) {
      return;
    }
    try {
      run.close(null);
    } catch (RuntimeException e) {
      cw.reportError(e, "jobrunr");
    }
  }

  @Override
  public void onProcessingFailed(Job job, Exception e) {
    ObservedRun run = open.remove(job.getId());
    if (run == null) {
      return;
    }
    try {
      run.close(unwrap(e));
    } catch (RuntimeException ex) {
      cw.reportError(ex, "jobrunr");
    }
  }

  /** The job's own throwable, from inside the wrappers reflection and JobRunr put around it. */
  static Throwable unwrap(Throwable e) {
    Throwable t = e;
    for (int depth = 0; depth < 8; depth++) {
      Throwable inner =
          t instanceof InvocationTargetException i
              ? i.getTargetException()
              : t instanceof UndeclaredThrowableException u
                  ? u.getUndeclaredThrowable()
                  : t.getClass().getName().equals("org.jobrunr.JobRunrException")
                      ? t.getCause()
                      : null;
      if (inner == null) {
        return t;
      }
      t = inner;
    }
    return t;
  }

  @Override
  public String toString() {
    return "CronwatchJobRunr[" + watch.appTag() + "]";
  }
}
