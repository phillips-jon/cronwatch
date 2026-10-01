package dev.cronwatch.quartz;

import static dev.cronwatch.quartz.Quartzes.await;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.JobContext;
import dev.cronwatch.JobOptions;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.store.MemoryStore;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.TimeZone;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.quartz.CronScheduleBuilder;
import org.quartz.Job;
import org.quartz.JobBuilder;
import org.quartz.JobDetail;
import org.quartz.JobExecutionContext;
import org.quartz.JobExecutionException;
import org.quartz.JobKey;
import org.quartz.Scheduler;
import org.quartz.SimpleScheduleBuilder;
import org.quartz.Trigger;
import org.quartz.Trigger.CompletedExecutionInstruction;
import org.quartz.TriggerBuilder;
import org.quartz.TriggerKey;
import org.quartz.listeners.TriggerListenerSupport;

/**
 * A real Quartz scheduler on the RAM job store, with triggers that fire at once or each second: the
 * jobs declared from their triggers, every firing a run, refires, throws, vetoes, a job deleted at
 * run time, and the check job.
 */
class CronwatchQuartzTest {
  /** What each job class saw, by the test's key in the job's data. */
  static final Map<String, AtomicInteger> CALLS = new ConcurrentHashMap<>();

  private static int call(JobExecutionContext ctx) {
    String key = ctx.getMergedJobDataMap().getString("key");
    return CALLS.computeIfAbsent(key, k -> new AtomicInteger()).incrementAndGet();
  }

  /** Logs through the current run. */
  public static final class Reports implements Job {
    @Override
    public void execute(JobExecutionContext ctx) {
      call(ctx);
      JobContext run = Cronwatch.current();
      if (run != null) {
        run.log("Report written");
      }
    }
  }

  /** Fails twice, asking Quartz to fire it again at once, then succeeds. */
  public static final class Flaky implements Job {
    @Override
    public void execute(JobExecutionContext ctx) throws JobExecutionException {
      if (call(ctx) <= 2) {
        throw new JobExecutionException("not yet", true);
      }
    }
  }

  /** Throws something Quartz wraps. */
  public static final class Boom implements Job {
    @Override
    public void execute(JobExecutionContext ctx) {
      call(ctx);
      throw new IllegalStateException("boom");
    }
  }

  private static JobDetail detail(
      Class<? extends Job> type, String name, String group, String key) {
    return JobBuilder.newJob(type)
        .withIdentity(name, group)
        .usingJobData("key", key)
        .storeDurably()
        .build();
  }

  private static Trigger once(String name) {
    return TriggerBuilder.newTrigger().withIdentity(name).startNow().build();
  }

  private static Trigger cron(String name, String expression, String zone) {
    return TriggerBuilder.newTrigger()
        .withIdentity(name)
        .withSchedule(
            CronScheduleBuilder.cronSchedule(expression).inTimeZone(TimeZone.getTimeZone(zone)))
        .build();
  }

  private static String stored(MemoryStore store, String name) throws Exception {
    StoredJob job = store.getJob(name);
    assertNotNull(job, name + " is not stored");
    return job.definition().toJson();
  }

  @Test
  void jobsAreDeclaredFromTheirTriggers() throws Exception {
    MemoryStore store = new MemoryStore();
    List<String> errors = Quartzes.errors();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, errors)) {
      scheduler.scheduleJob(
          detail(Reports.class, "nightlyReport", "DEFAULT", "a"),
          cron("t1", "0 0 2 * * ?", "Europe/London"));
      scheduler.scheduleJob(
          detail(Reports.class, "yearly", "reports", "a"), cron("t2", "0 30 1 * * ? *", "UTC"));
      // Quartz counts the days of the week from 1 for Sunday, croner from 0.
      scheduler.scheduleJob(
          detail(Reports.class, "mondays", "reports", "a"), cron("t3", "0 0 9 ? * 2", "UTC"));
      scheduler.scheduleJob(
          detail(Reports.class, "often", "reports", "a"),
          TriggerBuilder.newTrigger()
              .withIdentity("t4")
              .withSchedule(
                  SimpleScheduleBuilder.simpleSchedule().withIntervalInMinutes(90).repeatForever())
              .startAt(
                  org.quartz.DateBuilder.futureDate(1, org.quartz.DateBuilder.IntervalUnit.HOUR))
              .build());
      JobDetail twice = detail(Reports.class, "twice", "reports", "a");
      scheduler.scheduleJob(twice, cron("t5", "0 0 3 * * ?", "UTC"));
      scheduler.scheduleJob(
          cron("t6", "0 0 4 * * ?", "UTC").getTriggerBuilder().forJob(twice.getKey()).build());
      scheduler.addJob(detail(Reports.class, "untriggered", "reports", "a"), false);

      CronwatchQuartz q =
          CronwatchQuartz.watch(
              cw,
              scheduler,
              QuartzOptions.defaults()
                  .app("billing")
                  .jobDefaults(JobOptions.builder().grace("5m"))
                  .job("reports.yearly", JobOptions.builder().expect("Report written")));
      try {
        assertTrue(q.settle(Duration.ofSeconds(10)));
        assertEquals(
            "{\"grace\":\"5m\",\"schedule\":\"0 0 2 * * *\",\"timezone\":\"Europe/London\","
                + "\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"nightlyReport\"}",
            stored(store, "nightlyReport"));
        assertEquals(
            "{\"grace\":\"5m\",\"schedule\":\"0 30 1 * * *\",\"timezone\":\"UTC\","
                + "\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"reports.yearly\","
                + "\"expect\":\"contains \\\"Report written\\\"\"}",
            stored(store, "reports.yearly"));
        assertEquals(
            "{\"grace\":\"5m\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"reports.mondays\"}",
            stored(store, "reports.mondays"));
        assertEquals(
            "{\"grace\":\"5m\",\"schedule\":\"every 1h30m\",\"tags\":[\"quartz\",\"quartz:billing\"],"
                + "\"name\":\"reports.often\"}",
            stored(store, "reports.often"));
        assertEquals(
            "{\"grace\":\"5m\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"reports.twice\"}",
            stored(store, "reports.twice"));
        assertNull(store.getJob("reports.untriggered"), "a job with no trigger is not declared");
        String all = String.join("\n", errors);
        assertTrue(
            all.contains(
                "declaring Quartz job \"reports.mondays\": cronwatch: Quartz job \"reports.mondays\""
                    + " is \"0 0 9 * * 2\" in UTC, but after a run at"),
            all);
        assertTrue(
            all.contains(
                "cronwatch: \"reports.twice\" is run by 2 Quartz entries on different schedules"
                    + " (0 0 3 * * * in UTC; 0 0 4 * * * in UTC)"),
            all);
        assertEquals(2, errors.size(), all);
      } finally {
        q.close();
      }
    } finally {
      scheduler.shutdown(true);
    }
  }

  @Test
  void eachFiringIsARunWithItsOutput() throws Exception {
    MemoryStore store = new MemoryStore();
    List<String> errors = Quartzes.errors();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, errors)) {
      CronwatchQuartz q =
          CronwatchQuartz.watch(cw, scheduler, QuartzOptions.defaults().app("billing"));
      scheduler.start();
      scheduler.scheduleJob(detail(Reports.class, "fired", "DEFAULT", "fired"), once("t"));
      await("a recorded run", () -> finished(cw, "fired") == 1);
      Run run = cw.runs("fired", 1).get(0);
      assertEquals(RunStatus.OK, run.status());
      assertEquals("Report written", run.output());
      assertEquals("quartz", run.trigger());
      String instance = scheduler.getSchedulerInstanceId();
      // Not clustered, so the instance carries a random part of the watch's own.
      assertTrue(run.id().startsWith("quartz:billing:" + instance + "."), run.id());
      assertTrue(run.id().endsWith(":0"), "the refire count");
      assertTrue(errors.isEmpty(), errors.toString());
      q.close();
    } finally {
      scheduler.shutdown(true);
    }
  }

  private static long finished(Cronwatch cw, String name) {
    return cw.runs(name, 20).stream().filter(r -> !r.status().equals(RunStatus.RUNNING)).count();
  }

  @Test
  void aRefireIsANewRunAndTheSuccessRecovers() throws Exception {
    MemoryStore store = new MemoryStore();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, Quartzes.errors())) {
      CronwatchQuartz q =
          CronwatchQuartz.watch(cw, scheduler, QuartzOptions.defaults().app("billing"));
      scheduler.start();
      scheduler.scheduleJob(detail(Flaky.class, "flaky", "DEFAULT", "flaky"), once("t"));
      await("three runs", () -> finished(cw, "flaky") == 3);
      List<Run> runs = cw.runs("flaky", 3);
      assertEquals(
          List.of(RunStatus.OK, RunStatus.FAILED, RunStatus.FAILED),
          runs.stream().map(Run::status).toList());
      assertEquals("JobExecutionException: not yet", runs.get(1).error().lines().findFirst().get());
      assertTrue(runs.get(0).id().endsWith(":2") && runs.get(2).id().endsWith(":0"));
      assertFalse(
          cw.store().getState("flaky").open().containsKey(dev.cronwatch.Condition.FAILED),
          "failed opened once and recovered");
      q.close();
    } finally {
      scheduler.shutdown(true);
    }
  }

  @Test
  void aThrowIsWrittenAsTheJobsOwn() throws Exception {
    MemoryStore store = new MemoryStore();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, Quartzes.errors())) {
      CronwatchQuartz q = CronwatchQuartz.watch(cw, scheduler);
      scheduler.start();
      scheduler.scheduleJob(detail(Boom.class, "boom", "DEFAULT", "boom"), once("t"));
      await("a failed run", () -> finished(cw, "boom") == 1);
      Run run = cw.runs("boom", 1).get(0);
      assertEquals(RunStatus.FAILED, run.status());
      assertTrue(run.error().startsWith("IllegalStateException: boom\n"), run.error());
      q.close();
    } finally {
      scheduler.shutdown(true);
    }
  }

  @Test
  void aVetoedFiringOpensNothing() throws Exception {
    MemoryStore store = new MemoryStore();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, Quartzes.errors())) {
      CronwatchQuartz q = CronwatchQuartz.watch(cw, scheduler);
      AtomicInteger vetoed = new AtomicInteger();
      scheduler
          .getListenerManager()
          .addTriggerListener(
              new TriggerListenerSupport() {
                @Override
                public String getName() {
                  return "veto";
                }

                @Override
                public boolean vetoJobExecution(Trigger trigger, JobExecutionContext context) {
                  vetoed.incrementAndGet();
                  return true;
                }

                @Override
                public void triggerComplete(
                    Trigger trigger,
                    JobExecutionContext context,
                    CompletedExecutionInstruction instruction) {}
              });
      scheduler.start();
      scheduler.scheduleJob(detail(Reports.class, "vetoed", "DEFAULT", "vetoed"), once("t"));
      await("the veto", () -> vetoed.get() == 1);
      assertTrue(cw.runs("vetoed", 5).isEmpty());
      assertNull(CALLS.get("vetoed"));
      q.close();
    } finally {
      scheduler.shutdown(true);
    }
  }

  @Test
  void aJobDeletedAtRunTimeIsDeclaredAgainWithoutItsSchedule() throws Exception {
    MemoryStore store = new MemoryStore();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, Quartzes.errors())) {
      JobKey key = JobKey.jobKey("hourly", "reports");
      scheduler.scheduleJob(
          detail(Reports.class, "hourly", "reports", "hourly"), cron("t", "0 0 * * * ?", "UTC"));
      CronwatchQuartz q =
          CronwatchQuartz.watch(cw, scheduler, QuartzOptions.defaults().app("billing"));
      scheduler.start();
      assertTrue(q.settle(Duration.ofSeconds(10)));
      assertTrue(stored(store, "reports.hourly").contains("\"schedule\""));
      scheduler.deleteJob(key);
      await(
          "the job declared without its schedule",
          () -> {
            try {
              return stored(store, "reports.hourly").contains("no longer scheduled");
            } catch (Exception e) {
              return false;
            }
          });
      assertFalse(stored(store, "reports.hourly").contains("\"schedule\""));
      q.close();
    } finally {
      scheduler.shutdown(true);
    }
  }

  @Test
  void theCheckJobUnschedulesAJobTheSchedulerDropped() throws Exception {
    MemoryStore store = new MemoryStore();
    try (Cronwatch earlier = Quartzes.client(store, Quartzes.errors())) {
      earlier.job(
          "reports.dropped",
          JobOptions.builder().schedule("0 0 * * * ?").tags("quartz", "quartz:billing"));
      earlier.job(
          "reports.searchs",
          JobOptions.builder().schedule("0 0 * * * ?").tags("quartz", "quartz:search"));
      earlier.check();
    }
    Scheduler scheduler = Quartzes.ram();
    List<String> errors = Quartzes.errors();
    try (Cronwatch cw = Quartzes.client(store, errors)) {
      scheduler.scheduleJob(
          detail(Reports.class, "kept", "reports", "kept"), cron("t", "0 0 * * * ?", "UTC"));
      CronwatchQuartz q =
          CronwatchQuartz.watch(cw, scheduler, QuartzOptions.defaults().app("billing"));
      CronwatchQuartz.scheduleCheck(scheduler, Duration.ofSeconds(1));
      CronwatchQuartz.scheduleCheck(scheduler);
      scheduler.start();
      await(
          "the dropped job declared without its schedule",
          () -> {
            try {
              return stored(store, "reports.dropped").contains("no longer scheduled");
            } catch (Exception e) {
              return false;
            }
          });
      assertTrue(stored(store, "reports.searchs").contains("\"schedule\""), "another app's");
      assertTrue(stored(store, "reports.kept").contains("\"schedule\""));
      assertNull(store.getJob("cronwatch.cronwatch-check"), "the check job is never a job");
      assertTrue(cw.runs("cronwatch.cronwatch-check", 5).isEmpty());
      assertTrue(errors.isEmpty(), errors.toString());
      q.close();
    } finally {
      scheduler.shutdown(true);
    }
  }

  @Test
  void closingTakesTheListenersOff() throws Exception {
    MemoryStore store = new MemoryStore();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, Quartzes.errors())) {
      CronwatchQuartz q = CronwatchQuartz.watch(cw, scheduler);
      assertEquals(1, scheduler.getListenerManager().getJobListeners().size());
      q.close();
      assertTrue(scheduler.getListenerManager().getJobListeners().isEmpty());
      assertNull(scheduler.getContext().get(CronwatchQuartz.CONTEXT_KEY));
      scheduler.start();
      scheduler.scheduleJob(detail(Reports.class, "after", "DEFAULT", "after"), once("t"));
      await("the job ran", () -> CALLS.containsKey("after"));
      assertTrue(cw.runs("after", 5).isEmpty(), "not recorded after close");
    } finally {
      scheduler.shutdown(true);
    }
  }

  /** Set by the test that uses {@link Gated}: said when it starts, and what it waits for. */
  static volatile CountDownLatch gatedStarted = new CountDownLatch(1);

  static volatile CountDownLatch gatedGate = new CountDownLatch(1);

  /** Runs until the test lets it go. */
  public static final class Gated implements Job {
    @Override
    public void execute(JobExecutionContext ctx) throws JobExecutionException {
      call(ctx);
      gatedStarted.countDown();
      try {
        gatedGate.await();
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new JobExecutionException(e);
      }
    }
  }

  /**
   * The .NET port's case: a watch closed while a firing runs (a Spring context closing without the
   * JVM stopping) keeps its job listener until that firing ends, so its run is closed, not left to
   * be reported stuck.
   */
  @Test
  void closingWhileAFiringRunsStillClosesItsRun() throws Exception {
    gatedStarted = new CountDownLatch(1);
    gatedGate = new CountDownLatch(1);
    MemoryStore store = new MemoryStore();
    List<String> errors = Quartzes.errors();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, errors)) {
      CronwatchQuartz q = CronwatchQuartz.watch(cw, scheduler);
      scheduler.start();
      scheduler.scheduleJob(detail(Gated.class, "long", "DEFAULT", "long"), once("long"));
      gatedStarted.await();
      assertEquals(RunStatus.RUNNING, cw.runs("long", 5).get(0).status());
      q.close();
      assertEquals(
          1,
          scheduler.getListenerManager().getJobListeners().size(),
          "the listener stays while the firing runs");
      assertNull(scheduler.getContext().get(CronwatchQuartz.CONTEXT_KEY));
      gatedGate.countDown();
      await("the run closed", () -> cw.runs("long", 5).get(0).status().equals(RunStatus.OK));
      await(
          "the listener taken off",
          () -> {
            try {
              return scheduler.getListenerManager().getJobListeners().isEmpty();
            } catch (org.quartz.SchedulerException e) {
              throw new IllegalStateException(e);
            }
          });
      assertEquals(List.of(), errors);
    } finally {
      gatedGate.countDown();
      scheduler.shutdown(true);
    }
  }

  @Test
  void aFailureIsItsCauseWhenQuartzWrappedIt() {
    IllegalStateException own = new IllegalStateException("x");
    JobExecutionException wrapped =
        new JobExecutionException(new org.quartz.SchedulerException("Job threw", own), false);
    assertEquals(own, CronwatchQuartz.failureOf(wrapped));
    JobExecutionException plain = new JobExecutionException("plain");
    assertEquals(plain, CronwatchQuartz.failureOf(plain));
    assertNull(CronwatchQuartz.failureOf(null));
    assertEquals("reports.nightly", CronwatchQuartz.nameOf(JobKey.jobKey("nightly", "reports")));
    assertEquals("nightly", CronwatchQuartz.nameOf(JobKey.jobKey("nightly")));
  }

  /**
   * A job listener after this one that throws stops Quartz running the job, and Quartz then tells
   * no listener it was executed: the run opened for it was left running, current in Quartz's worker
   * thread, to be reported stuck. It is given back, as a firing that never ran.
   */
  @Test
  void aFiringAnotherListenerStoppedIsGivenBack() throws Exception {
    MemoryStore store = new MemoryStore();
    List<String> errors = Quartzes.errors();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, errors)) {
      CronwatchQuartz q = CronwatchQuartz.watch(cw, scheduler);
      AtomicInteger refused = new AtomicInteger();
      scheduler
          .getListenerManager()
          .addJobListener(
              new org.quartz.listeners.JobListenerSupport() {
                @Override
                public String getName() {
                  return "refuses";
                }

                @Override
                public void jobToBeExecuted(JobExecutionContext context) {
                  refused.incrementAndGet();
                  throw new IllegalStateException("not today");
                }
              });
      scheduler.start();
      scheduler.scheduleJob(detail(Reports.class, "stopped", "DEFAULT", "stopped"), once("t"));
      await("the refusal", () -> refused.get() == 1);
      await("the run given back", () -> cw.runs("stopped", 5).isEmpty());
      assertNull(CALLS.get("stopped"), "Quartz did not run it");
      q.close();
    } finally {
      scheduler.shutdown(true);
    }
  }

  /**
   * Quartz's own instance id is {@code NON_CLUSTERED} in every process that leaves it unset, and
   * the RAM job store counts its fire instance ids from the time it was loaded, so two processes of
   * one app started together gave two firings one run id, and the second went unrecorded.
   */
  @Test
  void twoProcessesWithQuartzsDefaultInstanceIdGiveTheirRunsTwoIds() throws Exception {
    MemoryStore store = new MemoryStore();
    Scheduler one = Quartzes.ram("NON_CLUSTERED");
    Scheduler two = Quartzes.ram("NON_CLUSTERED");
    try (Cronwatch cw = Quartzes.client(store, Quartzes.errors())) {
      CronwatchQuartz a = CronwatchQuartz.watch(cw, one, QuartzOptions.defaults().app("billing"));
      CronwatchQuartz b = CronwatchQuartz.watch(cw, two, QuartzOptions.defaults().app("billing"));
      JobExecutionContext fired =
          (JobExecutionContext)
              java.lang.reflect.Proxy.newProxyInstance(
                  JobExecutionContext.class.getClassLoader(),
                  new Class<?>[] {JobExecutionContext.class},
                  (proxy, method, args) ->
                      switch (method.getName()) {
                        case "getFireInstanceId" -> "1790000000042";
                        case "getRefireCount" -> 0;
                        default -> null;
                      });
      String first = a.runId(fired);
      String second = b.runId(fired);
      assertTrue(first.startsWith("quartz:billing:NON_CLUSTERED"), first);
      assertTrue(first.endsWith(":1790000000042:0"), first);
      assertFalse(first.equals(second), first + " and " + second);
      a.close();
      b.close();
    } finally {
      one.shutdown(true);
      two.shutdown(true);
    }
  }

  /**
   * Each read walked every cron trigger's fire times beside CronWatch's again, every minute: most
   * of a second each for a cron that fires every second in a zone with daylight saving. A trigger
   * unchanged is walked once.
   */
  @Test
  void anUnchangedCronIsWalkedOnce() throws Exception {
    MemoryStore store = new MemoryStore();
    Scheduler scheduler = Quartzes.ram();
    List<String> errors = Quartzes.errors();
    try (Cronwatch cw = Quartzes.client(store, errors)) {
      scheduler.scheduleJob(
          detail(Reports.class, "often", "reports", "a"), cron("o", "*/10 * * * * ?", "UTC"));
      CronwatchQuartz q = CronwatchQuartz.watch(cw, scheduler);
      try {
        q.sync();
        q.sync();
        assertEquals(1, q.walks.get());
        String often = stored(store, "reports.often");
        assertTrue(often.contains("\"schedule\":\"*/10 * * * * *\""), often + errors);
      } finally {
        q.close();
      }
    } finally {
      scheduler.shutdown(true);
    }
  }

  /**
   * Quartz asks for a {@code ?} in one of the day fields, which croner reads as a day field named
   * (every day, and either day field matching), not as {@code *}: declared as written, a monthly or
   * a weekly trigger was read as daily and watched without a schedule.
   */
  @Test
  void aQuestionMarkIsDeclaredAsAnyDay() throws Exception {
    MemoryStore store = new MemoryStore();
    List<String> errors = Quartzes.errors();
    Scheduler scheduler = Quartzes.ram();
    try (Cronwatch cw = Quartzes.client(store, errors)) {
      scheduler.scheduleJob(
          detail(Reports.class, "monthly", "reports", "a"), cron("m", "0 0 2 1 * ?", "UTC"));
      scheduler.scheduleJob(
          detail(Reports.class, "weekly", "reports", "a"),
          cron("w", "0 0 9 ? * MON", "Europe/London"));
      CronwatchQuartz q =
          CronwatchQuartz.watch(cw, scheduler, QuartzOptions.defaults().app("billing"));
      try {
        assertTrue(q.settle(Duration.ofSeconds(10)));
        assertEquals(
            "{\"schedule\":\"0 0 2 1 * *\",\"timezone\":\"UTC\","
                + "\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"reports.monthly\"}",
            stored(store, "reports.monthly"));
        assertEquals(
            "{\"schedule\":\"0 0 9 * * MON\",\"timezone\":\"Europe/London\","
                + "\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"reports.weekly\"}",
            stored(store, "reports.weekly"));
        assertTrue(errors.isEmpty(), errors.toString());
      } finally {
        q.close();
      }
    } finally {
      scheduler.shutdown(true);
    }
  }

  @Test
  void theDeadInstanceIsReadFromTheRecoveringTriggersName() {
    String group = Scheduler.DEFAULT_RECOVERY_GROUP;
    assertEquals("node-a", CronwatchQuartz.deadInstance(new TriggerKey("recover_node-a_0", group)));
    assertEquals(
        "host_1_1767605400000",
        CronwatchQuartz.deadInstance(new TriggerKey("recover_host_1_1767605400000_12", group)));
    assertNull(CronwatchQuartz.deadInstance(new TriggerKey("recover_node-a_0", "DEFAULT")));
    assertNull(CronwatchQuartz.deadInstance(new TriggerKey("recover_node-a_x", group)));
    assertNull(CronwatchQuartz.deadInstance(new TriggerKey("recover__0", group)));
    assertNull(CronwatchQuartz.deadInstance(new TriggerKey("nightly", group)));
    assertNull(CronwatchQuartz.deadInstance(null));
  }

  @Test
  void aRecoveryFailsOnlyTheDeadNodesRunNotALiveThirdNodesInTheSameMinute() {
    long t = 1_767_605_400_000L;
    String prefix = "quartz:billing:";
    String mine = prefix + "node-b:";
    Run dead = running(prefix + "node-a:node-a17:0", t + 1_000);
    Run third = running(prefix + "node-c:node-c4:0", t + 30_000);
    Run own = running(prefix + "node-b:node-b9:0", t + 2_000);
    Run otherApp = running("quartz:reports:node-a:node-a18:0", t);
    Run done =
        Run.of(
            prefix + "node-a:node-a16:0",
            "j",
            RunStatus.OK,
            t,
            t + 5,
            5L,
            null,
            null,
            dev.cronwatch.Metrics.empty(),
            "quartz");
    String deadPrefix = prefix + "node-a:";
    assertTrue(CronwatchQuartz.recovers(dead, prefix, mine, deadPrefix, t));
    assertFalse(
        CronwatchQuartz.recovers(third, prefix, mine, deadPrefix, t),
        "a run of a node still alive is left to finish");
    assertFalse(CronwatchQuartz.recovers(own, prefix, mine, deadPrefix, t));
    assertFalse(CronwatchQuartz.recovers(otherApp, prefix, mine, deadPrefix, t));
    assertFalse(CronwatchQuartz.recovers(done, prefix, mine, deadPrefix, t));
    assertFalse(
        CronwatchQuartz.recovers(
            running(prefix + "node-a:node-a1:0", t - 61_000), prefix, mine, deadPrefix, t),
        "outside the minute");
    // With the dead instance unknown, the rule is the minute's alone, as before.
    assertTrue(CronwatchQuartz.recovers(third, prefix, mine, null, t));
  }

  private static Run running(String id, long startedAt) {
    return Run.of(
        id,
        "j",
        RunStatus.RUNNING,
        startedAt,
        null,
        null,
        null,
        null,
        dev.cronwatch.Metrics.empty(),
        "quartz");
  }
}
