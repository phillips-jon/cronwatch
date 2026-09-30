package dev.cronwatch.quartz;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.ObservedRun;
import dev.cronwatch.Run;
import dev.cronwatch.RunHandle;
import dev.cronwatch.RunOptions;
import dev.cronwatch.RunStatus;
import dev.cronwatch.bridge.Bridge;
import dev.cronwatch.bridge.Entry;
import dev.cronwatch.bridge.FireTimes;
import dev.cronwatch.bridge.ScheduleException;
import dev.cronwatch.bridge.Watch;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.text.ParseException;
import java.time.Duration;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TimeZone;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;
import org.quartz.CalendarIntervalTrigger;
import org.quartz.CronExpression;
import org.quartz.CronTrigger;
import org.quartz.DailyTimeIntervalTrigger;
import org.quartz.JobBuilder;
import org.quartz.JobDetail;
import org.quartz.JobExecutionContext;
import org.quartz.JobExecutionException;
import org.quartz.JobKey;
import org.quartz.JobListener;
import org.quartz.ObjectAlreadyExistsException;
import org.quartz.Scheduler;
import org.quartz.SchedulerException;
import org.quartz.SimpleScheduleBuilder;
import org.quartz.SimpleTrigger;
import org.quartz.Trigger;
import org.quartz.TriggerBuilder;
import org.quartz.TriggerKey;
import org.quartz.core.JobExecutionProcessException;
import org.quartz.impl.matchers.GroupMatcher;
import org.quartz.listeners.SchedulerListenerSupport;

/**
 * CronWatch for a Quartz 2.5 {@link Scheduler}: every job the scheduler holds with a trigger is
 * declared as a CronWatch job with its schedule, and every firing is recorded as a run, so a job
 * that fails, runs late, never runs, gets stuck or runs slow is reported.
 *
 * <pre>{@code
 * Scheduler scheduler = StdSchedulerFactory.getDefaultScheduler();
 * CronwatchQuartz.watch(cw, scheduler, QuartzOptions.defaults());
 * CronwatchQuartz.scheduleCheck(scheduler);    // a check every minute, once per cluster
 * scheduler.start();
 * }</pre>
 *
 * <p>A global {@link JobListener} opens a run in the worker thread when Quartz is about to execute
 * a job (trigger {@code quartz}, id {@code quartz:<app>:<scheduler instance id>:<fire instance
 * id>:<refire count>}, the instance id given a random part of its own when the job store is not
 * clustered) and closes it when Quartz says the job was executed, failed with the {@link
 * JobExecutionException} Quartz hands it (its cause, when it has one, is what is written). {@link
 * Cronwatch#current()} and {@code job.log} work inside {@code execute}. A refire ({@code
 * refireImmediately}) is a new run. A vetoed firing, and one {@code @DisallowConcurrentExecution}
 * held back, opens nothing.
 *
 * <p>Jobs are named after their {@link JobKey}: {@code nightlyReport} in the {@code DEFAULT} group,
 * {@code reports.nightly} for {@code nightly} in {@code reports}. They are read when the
 * integration starts, again when the scheduler says a job or trigger was added or removed, and
 * every minute besides. A job with one {@link CronTrigger} is declared on its expression in the
 * trigger's zone (a {@code ?} as {@code *}, which croner reads as Quartz reads a {@code ?}),
 * checked against Quartz's own fire times ({@link Bridge#checkFires}): one Quartz reads differently
 * (nearly every expression naming a day of the week by number, since Quartz counts from 1 for
 * Sunday) is reported once and watched without a schedule. A {@link SimpleTrigger} repeating
 * forever is declared {@code every <interval>}; any other trigger, a trigger with a {@code
 * Calendar}, or several triggers on different schedules is a job without a schedule. A job removed
 * from the scheduler keeps its runs and is declared again without its schedule, so it is never
 * reported missed.
 *
 * <p>In a clustered job store, a job a node was running when it died is fired again on another node
 * with {@code isRecovering()}: that firing first finishes the earlier firing's run, if it is still
 * running, as failed with {@code Quartz recovered the job after its node stopped}.
 *
 * <p>Jobs are tagged {@code quartz} and {@code quartz:<app>}, the app named by {@link
 * QuartzOptions#app}, else {@code $CRONWATCH_APP_ID}, else the main class, so two apps sharing a
 * store never declare each other's jobs without a schedule.
 */
public final class CronwatchQuartz implements AutoCloseable {
  /** The tag every job this integration declares carries. */
  public static final String TAG = "quartz";

  /** The trigger of the runs it records. */
  public static final String TRIGGER = "quartz";

  /** The error of a run a recovered firing finishes. */
  public static final String RECOVERED = "Quartz recovered the job after its node stopped";

  /** The check job's key, whose runs are never a job. */
  public static final JobKey CHECK_JOB = JobKey.jobKey("cronwatch-check", "cronwatch");

  /** Where the scheduler's context keeps the integration, for the check job. */
  static final String CONTEXT_KEY = "dev.cronwatch.quartz.CronwatchQuartz";

  private static final String RUN_KEY = "dev.cronwatch.quartz.run";
  private static final String LISTENER = "dev.cronwatch.quartz";
  private static final String SCHEDULER = "Quartz";

  /** How far a dead node's run may have started from the firing recovered. */
  private static final long RECOVERY_SLACK_MS = 60_000;

  private final Cronwatch cw;
  private final Scheduler scheduler;
  private final QuartzOptions options;
  private final Watch watch;
  private final String instanceId;

  /**
   * The scheduler instance as run ids name it: its id, with a random part of this watch's own when
   * the job store is not clustered, since every such process that leaves the id unset has Quartz's
   * {@code NON_CLUSTERED} and the RAM job store counts its fire instance ids from the time it was
   * loaded, so two processes started together would give two firings one id. A clustered store's
   * ids are unique across the cluster, which the recovery rule needs. One too long for a run id is
   * a hash.
   */
  private final String instancePart;

  private final Listener listener = new Listener();
  private final Changes changes = new Changes();

  private final ReentrantLock lock = new ReentrantLock();
  private final Condition wake = lock.newCondition();
  private boolean dirty;
  private boolean closed;

  /**
   * Firings opening or open now, whose end the listeners must still hear: Quartz tells only the
   * listeners it holds when a job ends that it was executed, so they stay until these end.
   */
  private int firings;

  /** Whether the listeners are still on the scheduler. */
  private boolean listening = true;

  /** A cron trigger's reading as it was checked, the schedule to declare or the problem. */
  private record Checked(@Nullable String schedule, @Nullable String problem) {}

  /**
   * Each cron trigger's check against Quartz's own fire times, by the job, the expression, the zone
   * and the year, so the read every minute walks only what changed: a cron that fires each second
   * in a zone with daylight saving takes most of a second to walk. Only what the last read saw is
   * kept.
   */
  private final Map<String, Checked> checked = new ConcurrentHashMap<>();

  /** How many cron triggers were walked, for the tests. */
  final AtomicInteger walks = new AtomicInteger();

  /** How long a sync the check job starts may take; the tests shorten it. */
  volatile Duration syncTimeout = Bridge.SYNC_TIMEOUT;

  private CronwatchQuartz(
      Cronwatch cw,
      Scheduler scheduler,
      QuartzOptions options,
      String instanceId,
      boolean clustered) {
    this.cw = cw;
    this.scheduler = scheduler;
    this.options = options;
    this.instanceId = instanceId;
    this.watch = new Watch(cw, TAG, options.app, SCHEDULER);
    String part =
        clustered ? instanceId : instanceId + "." + HexFormat.of().formatHex(randomBytes(4));
    this.instancePart = part.length() > 100 ? "h" + sha256(part).substring(0, 32) : part;
  }

  private static byte[] randomBytes(int n) {
    byte[] b = new byte[n];
    ThreadLocalRandom.current().nextBytes(b);
    return b;
  }

  /**
   * Watches {@code scheduler}: its jobs are declared now, from the scheduler's triggers, and every
   * firing from now on is recorded. Call it before the scheduler starts, so no firing goes
   * unrecorded. {@link #close} stops it.
   *
   * @throws SchedulerException when the scheduler cannot be asked for its listeners or its jobs
   */
  public static CronwatchQuartz watch(Cronwatch cw, Scheduler scheduler, QuartzOptions options)
      throws SchedulerException {
    Objects.requireNonNull(cw, "cw");
    Objects.requireNonNull(options, "options");
    CronwatchQuartz q =
        new CronwatchQuartz(
            cw,
            scheduler,
            options,
            scheduler.getSchedulerInstanceId(),
            scheduler.getMetaData().isJobStoreClustered());
    q.read();
    scheduler.getListenerManager().addJobListener(q.listener);
    scheduler.getListenerManager().addSchedulerListener(q.changes);
    scheduler.getContext().put(CONTEXT_KEY, q);
    Thread.ofVirtual().name("cronwatch-quartz").start(q::readLoop);
    return q;
  }

  /** {@link #watch(Cronwatch, Scheduler, QuartzOptions)} with the default options. */
  public static CronwatchQuartz watch(Cronwatch cw, Scheduler scheduler) throws SchedulerException {
    return watch(cw, scheduler, QuartzOptions.defaults());
  }

  /**
   * Schedules {@link CronwatchCheckJob} on {@code scheduler} every minute, unless it is scheduled
   * already: a sync and a CronWatch check, once per minute across a cluster sharing a JDBC job
   * store, in place of {@link Cronwatch#start()} on every node.
   *
   * @throws SchedulerException when the scheduler refuses the job
   */
  public static void scheduleCheck(Scheduler scheduler) throws SchedulerException {
    scheduleCheck(scheduler, Duration.ofMinutes(1));
  }

  /** {@link #scheduleCheck(Scheduler)} on another interval. */
  public static void scheduleCheck(Scheduler scheduler, Duration every) throws SchedulerException {
    if (scheduler.checkExists(CHECK_JOB)) {
      return;
    }
    JobDetail job =
        JobBuilder.newJob(CronwatchCheckJob.class)
            .withIdentity(CHECK_JOB)
            .withDescription("CronWatch's check: missed and stuck runs, retries, pruning")
            .storeDurably()
            .build();
    Trigger trigger =
        TriggerBuilder.newTrigger()
            .withIdentity(TriggerKey.triggerKey(CHECK_JOB.getName(), CHECK_JOB.getGroup()))
            .forJob(CHECK_JOB)
            .startNow()
            .withSchedule(
                SimpleScheduleBuilder.simpleSchedule()
                    .withIntervalInMilliseconds(every.toMillis())
                    .repeatForever()
                    .withMisfireHandlingInstructionNextWithRemainingCount())
            .build();
    try {
      scheduler.scheduleJob(job, Set.of(trigger), false);
    } catch (ObjectAlreadyExistsException e) {
      // Another node scheduled it first.
    }
  }

  /** The watch that declares this scheduler's jobs, for an integration built on this one. */
  public Watch watchOfJobs() {
    return watch;
  }

  /** The client runs are recorded on. */
  public Cronwatch client() {
    return cw;
  }

  /**
   * Declares the scheduler's jobs as they are now, waits for the declarations to be written, and
   * declares again without its schedule each job of this app's the store holds with a schedule that
   * the scheduler no longer has. The check job runs it before each check.
   *
   * @throws CronwatchException naming what failed
   */
  public void sync() {
    try {
      watch.declare(entries());
    } catch (SchedulerException e) {
      throw new CronwatchException(
          CronwatchException.Kind.OTHER, "reading the scheduler's jobs: " + e.getMessage(), e);
    }
    watch.settle(Bridge.SYNC_TIMEOUT);
    watch.unschedule();
  }

  /**
   * Waits until what was declared has been written to the store, at most {@code timeout}, for tests
   * and a clean exit. Says whether it was.
   */
  public boolean settle(Duration timeout) {
    return watch.settle(timeout);
  }

  /** The check job's work: {@link #sync} within 30 seconds, then a check. Never throws. */
  void checkNow() {
    Bridge.syncWithin(cw, syncTimeout, "quartz", this::sync);
    try {
      cw.check();
    } catch (RuntimeException e) {
      cw.reportError(e, "quartz");
    }
  }

  /**
   * Stops watching: no firing is recorded from now on, its jobs are no longer read, and the
   * listeners are taken off the scheduler, once the firings open now have ended, so their runs are
   * still closed when their jobs end. Leaves the client and the scheduler running.
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
    try {
      if (scheduler.getContext().get(CONTEXT_KEY) == this) {
        scheduler.getContext().remove(CONTEXT_KEY);
      }
    } catch (SchedulerException e) {
      cw.reportError(e, "quartz");
    }
    letGo();
  }

  /** A firing about to open a run, unless the watch is closed: false then. */
  private boolean beginFiring() {
    lock.lock();
    try {
      if (closed) {
        return false;
      }
      firings++;
      return true;
    } finally {
      lock.unlock();
    }
  }

  /** A firing ended (or opened nothing); the listeners go once the watch is closed and none is. */
  private void endFiring() {
    lock.lock();
    try {
      firings--;
    } finally {
      lock.unlock();
    }
    letGo();
  }

  /** Takes the listeners off the scheduler once the watch is closed and no firing is open. */
  private void letGo() {
    lock.lock();
    try {
      if (!closed || firings > 0 || !listening) {
        return;
      }
      listening = false;
    } finally {
      lock.unlock();
    }
    try {
      scheduler.getListenerManager().removeJobListener(LISTENER);
      scheduler.getListenerManager().removeSchedulerListener(changes);
    } catch (SchedulerException e) {
      cw.reportError(e, "quartz");
    }
  }

  // ---- reading the scheduler's jobs

  /** A job's CronWatch name: its name in the default group, else {@code group.name}. */
  static String nameOf(JobKey key) {
    return Scheduler.DEFAULT_GROUP.equals(key.getGroup())
        ? key.getName()
        : key.getGroup() + "." + key.getName();
  }

  private static String label(String name) {
    return "Quartz job " + quote(name);
  }

  private static String quote(String s) {
    return dev.cronwatch.json.Json.quote(s);
  }

  /** The options the app gave one job, over the integration's defaults. */
  private JobOptions optionsFor(String name) {
    JobOptions given = options.jobs.get(name);
    return given == null ? JobOptions.builder() : given.copy();
  }

  /** Every job the scheduler holds with a trigger, one entry per trigger. */
  List<Entry> entries() throws SchedulerException {
    List<Entry> out = new ArrayList<>();
    Set<String> seen = new HashSet<>();
    long now = cw.now();
    for (String group : scheduler.getJobGroupNames()) {
      for (JobKey key : scheduler.getJobKeys(GroupMatcher.jobGroupEquals(group))) {
        if (key.equals(CHECK_JOB)) {
          continue;
        }
        List<? extends Trigger> triggers = scheduler.getTriggersOfJob(key);
        if (triggers.isEmpty()) {
          continue;
        }
        String name = nameOf(key);
        if (!Bridge.validName(name)) {
          watch.reportOnce(
              "cronwatch: "
                  + label(name)
                  + " is not a CronWatch job name (1 to 120 letters, digits, \".\", \"_\", \":\""
                  + " or \"-\"), so it is not watched; rename it",
              "declaring " + label(name));
          continue;
        }
        for (Trigger trigger : triggers) {
          out.add(entryOf(name, trigger, now, seen));
        }
      }
    }
    checked.keySet().retainAll(seen);
    return out;
  }

  private Entry entryOf(String name, Trigger trigger, long now, Set<String> seen) {
    String label = label(name);
    String schedule = "";
    String zone = "";
    String problem = null;
    String calendar = trigger.getCalendarName();
    String triggerName = quote(trigger.getKey().toString());
    if (calendar != null) {
      problem =
          "cronwatch: "
              + label
              + "'s trigger "
              + triggerName
              + " has the calendar "
              + quote(calendar)
              + ", which excludes times CronWatch cannot know, so it is watched without a schedule";
    } else if (trigger instanceof CronTrigger cron) {
      TimeZone tz = cron.getTimeZone() == null ? TimeZone.getDefault() : cron.getTimeZone();
      String expression = cron.getCronExpression();
      String key =
          label
              + "\0"
              + expression
              + "\0"
              + tz.getID()
              + "\0"
              + LocalDateTime.ofEpochSecond(Math.floorDiv(now, 1000), 0, ZoneOffset.UTC).getYear();
      seen.add(key);
      Checked c = checked.get(key);
      if (c == null) {
        walks.incrementAndGet();
        try {
          c = new Checked(cronOf(label, expression, tz, now), null);
        } catch (ScheduleException e) {
          c = new Checked(null, e.getMessage());
        }
        checked.put(key, c);
      }
      if (c.schedule() != null) {
        schedule = c.schedule();
        zone = tz.getID();
      } else {
        problem = c.problem();
      }
    } else if (trigger instanceof SimpleTrigger simple) {
      if (simple.getRepeatCount() == SimpleTrigger.REPEAT_INDEFINITELY) {
        long interval = simple.getRepeatInterval();
        if (interval < 1000) {
          problem =
              "cronwatch: "
                  + label
                  + " repeats every "
                  + interval
                  + "ms, more often than CronWatch's shortest schedule of one second, so it is"
                  + " watched without a schedule";
        } else {
          schedule = Bridge.everyText(Duration.ofMillis(interval));
        }
      }
    } else if (trigger instanceof CalendarIntervalTrigger
        || trigger instanceof DailyTimeIntervalTrigger) {
      problem =
          "cronwatch: "
              + label
              + "'s trigger "
              + triggerName
              + " is a "
              + (trigger instanceof CalendarIntervalTrigger
                  ? "CalendarIntervalTrigger"
                  : "DailyTimeIntervalTrigger")
              + ", which CronWatch cannot follow, so it is watched without a schedule";
    }
    return new Entry(
        name, label, schedule, zone, problem, options.jobDefaults.copy(), optionsFor(name));
  }

  /**
   * A cron trigger's expression as CronWatch reads it: Quartz's six fields as they are (croner
   * reads seconds first too) but for a {@code ?}, which is {@code *}, a seventh year field left out
   * when it is {@code *} or {@code ?}, and kept when it names years, for the check to judge; then
   * checked against Quartz's own fire times.
   */
  private static String cronOf(String label, String expression, TimeZone tz, long now)
      throws ScheduleException {
    String[] fields = expression.trim().split("\\s+");
    List<String> kept = new ArrayList<>(List.of(fields));
    if (kept.size() == 7 && isAny(kept.get(6))) {
      kept.remove(6);
    }
    // Quartz's ? is any day; croner reads a ? as a day field named, every day, so that a day of
    // the month and ? would be every day. Declared as *, which croner reads as Quartz does.
    kept.replaceAll(f -> f.equals("?") ? "*" : f);
    String expr = String.join(" ", kept);
    CronExpression quartz;
    try {
      quartz = new CronExpression(expression);
      quartz.setTimeZone(tz);
    } catch (ParseException e) {
      throw new ScheduleException(
          "cronwatch: "
              + label
              + " is "
              + quote(expression)
              + ", which Quartz cannot read: "
              + e.getMessage());
    }
    boolean daily =
        fields.length >= 6
            && isAny(fields[3])
            && isAny(fields[4])
            && isAny(fields[5])
            && (fields.length < 7 || isAny(fields[6]));
    Bridge.checkFires(
        FireTimes.walking(at -> nextAfter(quartz, at), SCHEDULER),
        expr,
        tz.getID(),
        "cronwatch: " + label,
        SCHEDULER,
        daily,
        now);
    return expr;
  }

  @SuppressWarnings("JavaUtilDate") // Quartz's API takes and answers a Date
  private static @Nullable Long nextAfter(CronExpression cron, long at) {
    java.util.Date next = cron.getNextValidTimeAfter(new java.util.Date(at));
    return next == null ? null : next.getTime();
  }

  private static boolean isAny(String field) {
    return field.equals("*") || field.equals("?");
  }

  /** Reads the scheduler's jobs and declares them; a failure is reported. */
  private void read() {
    try {
      watch.declare(entries());
    } catch (SchedulerException | RuntimeException e) {
      cw.reportError(e, "quartz");
    }
  }

  /**
   * Reads the jobs again whenever the scheduler says they changed and every {@code readEvery}
   * besides, on a thread of its own: the scheduler's own calls come from inside its locks, so they
   * only ask for a read.
   */
  private void readLoop() {
    long every = options.readEvery.toNanos();
    while (true) {
      lock.lock();
      try {
        long left = every;
        while (!dirty && !closed && left > 0) {
          left = wake.awaitNanos(left);
        }
        if (closed) {
          return;
        }
        dirty = false;
      } catch (InterruptedException e) {
        return;
      } finally {
        lock.unlock();
      }
      read();
    }
  }

  private void changed() {
    lock.lock();
    try {
      dirty = true;
      wake.signalAll();
    } finally {
      lock.unlock();
    }
  }

  // ---- runs

  /**
   * The run's id: the app, the scheduler instance and the firing, since a fire instance id is
   * unique only within one scheduler instance and a refire reuses it. One longer than a store holds
   * keeps its prefix and instance and a hash of the rest.
   */
  String runId(JobExecutionContext ctx) {
    String prefix = "quartz:" + watch.appSlug() + ":";
    String own = prefix + instancePart + ":";
    String rest = ctx.getFireInstanceId() + ":" + ctx.getRefireCount();
    if (own.length() + rest.length() <= 200) {
      return own + rest;
    }
    return own + sha256(rest).substring(0, 32);
  }

  private static String sha256(String s) {
    try {
      return HexFormat.of()
          .formatHex(
              MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }

  /** What a firing's exception writes: its cause, when Quartz wrapped the job's own throw. */
  static @Nullable Throwable failureOf(@Nullable JobExecutionException e) {
    Throwable t = e;
    while (t instanceof SchedulerException && t.getCause() != null) {
      t = t.getCause();
    }
    return t;
  }

  /**
   * A recovering firing finishes the earlier firing's run, if it is still running, as failed: a run
   * of this job and app from another scheduler instance, started within a minute of the original
   * firing.
   */
  private void recover(String name, JobExecutionContext ctx) {
    Object fired =
        ctx.getMergedJobDataMap()
            .get(Scheduler.FAILED_JOB_ORIGINAL_TRIGGER_FIRETIME_IN_MILLISECONDS);
    if (fired == null) {
      return;
    }
    long firedAt;
    try {
      firedAt = Long.parseLong(String.valueOf(fired));
    } catch (NumberFormatException e) {
      return;
    }
    String prefix = "quartz:" + watch.appSlug() + ":";
    String mine = prefix + instancePart + ":";
    try {
      for (Run run : cw.runs(name, 50)) {
        if (run.status().equals(RunStatus.RUNNING)
            && run.id().startsWith(prefix)
            && !run.id().startsWith(mine)
            && Math.abs(run.startedAt() - firedAt) <= RECOVERY_SLACK_MS) {
          RunHandle handle = cw.resumeRun(name, run.id());
          handle.fail(RECOVERED);
        }
      }
    } catch (RuntimeException e) {
      cw.reportError(e, "recovering " + name);
    }
  }

  /** The global job listener: a run opened before {@code execute} and closed after it. */
  private final class Listener implements JobListener {
    @Override
    public String getName() {
      return LISTENER;
    }

    @Override
    public void jobToBeExecuted(JobExecutionContext ctx) {
      // Counted before it opens, so a close meanwhile keeps the listener that will hear its end.
      if (!beginFiring()) {
        return;
      }
      boolean opened = false;
      // A throw here would stop Quartz running the job, so nothing leaves.
      try {
        JobKey key = ctx.getJobDetail().getKey();
        if (key.equals(CHECK_JOB)) {
          return;
        }
        String name = nameOf(key);
        if (!Bridge.validName(name)) {
          return;
        }
        Job job = watch.job(name);
        if (job == null) {
          JobOptions made = options.jobDefaults.copy().merge(optionsFor(name));
          job = watch.fallback(name, made);
          if (job == null) {
            return;
          }
        }
        if (ctx.isRecovering()) {
          recover(name, ctx);
        }
        ObservedRun run = job.open(RunOptions.trigger(TRIGGER).withId(runId(ctx)));
        ctx.put(RUN_KEY, run);
        opened = true;
      } catch (RuntimeException e) {
        cw.reportError(e, "quartz");
      } finally {
        if (!opened) {
          endFiring();
        }
      }
    }

    @Override
    public void jobExecutionVetoed(JobExecutionContext ctx) {
      // Nothing was opened for it.
    }

    @Override
    public void jobWasExecuted(JobExecutionContext ctx, @Nullable JobExecutionException e) {
      try {
        if (!(ctx.get(RUN_KEY) instanceof ObservedRun run)) {
          return;
        }
        ctx.put(RUN_KEY, null);
        try {
          run.close(failureOf(e));
        } finally {
          endFiring();
        }
      } catch (RuntimeException ex) {
        cw.reportError(ex, "quartz");
      }
    }
  }

  /** The scheduler's word that its jobs changed, which only asks for a read. */
  private final class Changes extends SchedulerListenerSupport {
    @Override
    public void jobScheduled(Trigger trigger) {
      changed();
    }

    @Override
    public void jobUnscheduled(TriggerKey triggerKey) {
      changed();
    }

    @Override
    public void triggerFinalized(Trigger trigger) {
      changed();
    }

    @Override
    public void jobAdded(JobDetail jobDetail) {
      changed();
    }

    @Override
    public void jobDeleted(JobKey jobKey) {
      changed();
    }

    @Override
    public void schedulingDataCleared() {
      changed();
    }

    /**
     * A job listener after this one that threw stops Quartz running the job, and no listener is
     * told it was executed; Quartz says so here, in the worker thread, with the firing. Its run is
     * given back, as a firing that never ran.
     */
    @Override
    public void schedulerError(String msg, SchedulerException cause) {
      try {
        if (cause instanceof JobExecutionProcessException p
            && String.valueOf(p.getMessage()).startsWith("JobListener ")
            && p.getJobExecutionContext() != null
            && p.getJobExecutionContext().get(RUN_KEY) instanceof ObservedRun run) {
          p.getJobExecutionContext().put(RUN_KEY, null);
          try {
            run.takeBack();
          } finally {
            endFiring();
          }
        }
      } catch (RuntimeException e) {
        cw.reportError(e, "quartz");
      }
    }

    @Override
    public void schedulerShutdown() {
      lock.lock();
      try {
        closed = true;
        wake.signalAll();
      } finally {
        lock.unlock();
      }
    }
  }

  @Override
  public String toString() {
    return "CronwatchQuartz[" + watch.appTag() + ", instance " + instanceId + "]";
  }
}
