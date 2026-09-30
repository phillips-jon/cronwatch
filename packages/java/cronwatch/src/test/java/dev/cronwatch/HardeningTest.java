package dev.cronwatch;

import static dev.cronwatch.Support.HOUR;
import static dev.cronwatch.Support.MIN;
import static dev.cronwatch.Support.T0;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Support.Capture;
import dev.cronwatch.Support.Clock;
import dev.cronwatch.Support.Errors;
import dev.cronwatch.Support.Made;
import dev.cronwatch.Support.Wrapped;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.logging.Handler;
import java.util.logging.LogRecord;
import java.util.logging.Logger;
import org.junit.jupiter.api.Test;

/**
 * The SDK's {@code client-hardening.test.ts}, ported: missed with a short period, store outages, a
 * store that initialises late, a hung channel and triage, the retry queue and its budget, deliver
 * at check, overlapping runs, refused options, capped output, an error named once, the baseline, a
 * job that cannot be evaluated, and the interval's bounds. The handler case is phase 3's; {@code
 * deliver} taking only its two values and {@code execute} being private are the type system's in
 * Java.
 */
class HardeningTest {
  private static void fail(Cronwatch cw, String name, String message) {
    assertThrows(
        IllegalStateException.class,
        () ->
            cw.run(
                name,
                j -> {
                  throw new IllegalStateException(message);
                }));
  }

  /** A job's stored state. */
  private static JobState state(Cronwatch cw, String job) {
    try {
      JobState s = cw.store().getState(job);
      assertNotNull(s, "a state for " + job);
      return s;
    } catch (Exception e) {
      throw new AssertionError(e);
    }
  }

  private static List<String> queuedTypes(Cronwatch cw, String job) {
    List<String> out = new ArrayList<>();
    for (Alert a : state(cw, job).undelivered()) {
      out.add(a.type().value());
    }
    return out;
  }

  @Test
  void aCronFiringMoreOftenThanItsGraceIsStillMissed() {
    Made m = Support.make();
    Job job = m.cw().job("often", JobOptions.builder().schedule("*/5 * * * *"));
    job.run(j -> {}); // 09:30
    m.clock().advance(14 * MIN);
    assertEquals(List.of(), m.cw().check().alerts(), "09:35 is due, grace runs to 09:45");
    m.clock().advance(2 * MIN);
    assertEquals(
        List.of(AlertType.MISSED), m.cw().check().alerts().stream().map(Alert::type).toList());
    job.run(j -> {});
    assertEquals(List.of("missed", "recovered"), m.alerts().types());
  }

  @Test
  void aMissedRunWhoseNextRunFailsBelowTheThresholdStillRecoversLater() {
    Made m = Support.make();
    Job job = m.cw().job("quiet", JobOptions.builder().schedule("every 1h").failuresBeforeAlert(3));
    m.cw().check();
    m.clock().advance(2 * HOUR);
    m.cw().check();
    fail(m.cw(), "quiet", "x");
    assertEquals(List.of("missed"), m.alerts().types());
    job.run(j -> {});
    assertEquals(List.of("missed", "recovered"), m.alerts().types());
    assertTrue(m.alerts().alerts.get(1).message().contains("after: missed"));
  }

  @Test
  void aStoreOutageNeverStopsTheJobAndStoreErrorsGoToOnError() {
    Wrapped store = new Wrapped();
    store.broken.addAll(
        List.of("upsertJob", "insertRun", "getState", "setState", "updateRun", "listRuns"));
    Made m = Support.make(b -> b.store(store));
    AtomicInteger ran = new AtomicInteger();
    int seven =
        m.cw()
            .call(
                "s",
                j -> {
                  ran.incrementAndGet();
                  return 7;
                });
    assertEquals(7, seven);
    assertThrows(
        IllegalStateException.class,
        () ->
            m.cw()
                .run(
                    "s",
                    j -> {
                      ran.incrementAndGet();
                      throw new IllegalStateException("the job's own");
                    }));
    assertEquals(2, ran.get());
    List<String> wheres = m.errors().wheres();
    assertTrue(
        !wheres.isEmpty() && wheres.stream().allMatch("recording s"::equals), wheres.toString());
    store.broken.clear();
    m.cw().call("s", j -> "back");
    assertEquals(1, m.cw().runs("s", 50).size());
  }

  @Test
  void aStoreThatFailsToInitialiseIsTriedAgainOnTheNextCall() {
    Wrapped store = new Wrapped();
    store.initFailures = 1;
    Made m = Support.make(b -> b.store(store));
    assertEquals(1, (int) m.cw().call("i", j -> 1));
    assertEquals(List.of("recording i"), m.errors().wheres());
    // The finished run was written on the retry, once init went through.
    assertEquals(2, store.inits.get());
    m.cw().call("i", j -> 2);
    assertEquals(2, store.inits.get());
    assertEquals(2, m.cw().runs("i", 50).size());
  }

  @Test
  void dispatchDoesNotOverwriteASilenceMadeWhileAnAlertWasBeingSent() throws Exception {
    Cronwatch[] ref = new Cronwatch[1];
    Channel silencer = Channel.of("silencer", (a, ctx) -> ref[0].silence("loud", "1h"));
    Made m = Support.make(b -> b.alerts(List.of(silencer)));
    ref[0] = m.cw();
    fail(m.cw(), "loud", "x");
    JobState state = m.cw().store().getState("loud");
    assertNotNull(state.silencedUntil(), "the silence survived");
    assertEquals(Map.of(Condition.FAILED, T0), state.open());
    assertEquals(T0, state.lastAlertAt());
  }

  @Test
  void aHungChannelTimesOutWithoutHoldingUpTheOthers() throws Exception {
    Capture good = new Capture();
    AtomicBoolean interrupted = new AtomicBoolean();
    Channel hung =
        Channel.of(
            "hung",
            (a, ctx) -> {
              try {
                new CountDownLatch(1).await();
              } catch (InterruptedException e) {
                interrupted.set(true);
                throw e;
              }
            });
    Made m =
        Support.make(
            b -> {
              b.alerts(List.of(hung, good));
              b.timings.channelMs = 300;
            });
    fail(m.cw(), "h", "x");
    assertEquals(List.of("failed"), good.types(), "the other channel has it");
    assertEquals(List.of("alert channel hung"), m.errors().wheres());
    assertTrue(m.errors().messages().get(0).contains("timed out after 300ms"));
    assertEquals(List.of(), m.cw().store().getState("h").undelivered(), "delivered once");
    Support.await("the hung send to be interrupted", interrupted::get);
  }

  @Test
  void triageIsInterruptedWhenTheClientStopsWaitingForIt() throws Exception {
    AtomicBoolean interrupted = new AtomicBoolean();
    Made m =
        Support.make(
            b -> {
              b.triage(
                  ctx -> {
                    try {
                      new CountDownLatch(1).await();
                    } catch (InterruptedException e) {
                      interrupted.set(true);
                      throw e;
                    }
                    return "never";
                  });
              b.timings.triageMs = 300;
            });
    fail(m.cw(), "t", "x");
    Support.await("triage to be interrupted", interrupted::get);
    assertEquals(List.of("triage for t"), m.errors().wheres());
    assertEquals(List.of("failed"), m.alerts().types());
    assertNull(m.alerts().alerts.get(0).triage());
  }

  @Test
  void anAlertNoChannelTookIsRetriedOncePerCheckUntilOneDoes() {
    AtomicBoolean down = new AtomicBoolean(true);
    AtomicInteger attempts = new AtomicInteger();
    List<Alert> got = new CopyOnWriteArrayList<>();
    Channel flaky =
        Channel.of(
            "flaky",
            (a, ctx) -> {
              attempts.incrementAndGet();
              if (down.get()) {
                throw new IOException("down");
              }
              got.add(a);
            });
    Made m = Support.make(b -> b.alerts(List.of(flaky)));
    fail(m.cw(), "r", "x");
    JobState state = state(m.cw(), "r");
    assertEquals(1, state.undelivered().size());
    assertNull(state.lastAlertAt(), "nothing was delivered");
    m.clock().advance(MIN);
    m.cw().check();
    assertEquals(2, attempts.get(), "one retry per check");
    down.set(false);
    m.clock().advance(MIN);
    CheckResult result = m.cw().check();
    assertEquals(List.of(AlertType.FAILED), result.alerts().stream().map(Alert::type).toList());
    assertEquals(1, got.size());
    assertEquals(T0, got.get(0).at(), "the same alert, not a new one");
    state = state(m.cw(), "r");
    assertEquals(List.of(), state.undelivered());
    assertEquals(T0 + 2 * MIN, state.lastAlertAt());
    m.cw().check();
    assertEquals(3, attempts.get(), "not sent again");
  }

  @Test
  void deliverAtCheckQueuesAlertsForAnotherProcessesCheckWhichSendsThemWithTriage() {
    Clock clock = new Clock();
    MemoryStore store = new MemoryStore();
    Capture unused = new Capture();
    AtomicInteger triaged = new AtomicInteger();
    Capture sent = new Capture();
    // The recording process: no network, so it sends nothing itself. The web server can send,
    // and has not declared the job.
    try (Cronwatch recorder =
            Support.builder(clock, unused, new Errors())
                .store(store)
                .deliver(Deliver.AT_CHECK)
                .triage(ctx -> "never asked")
                .build();
        Cronwatch server =
            Support.builder(clock, sent, new Errors())
                .store(store)
                .triage(
                    ctx -> {
                      triaged.incrementAndGet();
                      return "The disk is full.";
                    })
                .build()) {
      Job job = recorder.job("backup", JobOptions.builder().schedule("40 3 * * *").timezone("UTC"));
      fail(recorder, "backup", "disk full");
      assertEquals(List.of(), unused.types(), "nothing sent from the recording process");
      assertEquals(List.of("failed"), queuedTypes(recorder, "backup"));
      assertNull(state(recorder, "backup").lastAlertAt());
      assertEquals(List.of(), recorder.check().alerts(), "its own check does not send either");

      clock.advance(MIN);
      CheckResult result = server.check();
      assertEquals(List.of(AlertType.FAILED), result.alerts().stream().map(Alert::type).toList());
      assertEquals(List.of("failed"), sent.types());
      assertEquals("The disk is full.", sent.alerts.get(0).triage());
      assertEquals(T0, sent.alerts.get(0).at(), "the alert from the run, not a new one");
      assertEquals(1, triaged.get());
      assertEquals(List.of(), state(server, "backup").undelivered());
      assertEquals(T0 + MIN, state(server, "backup").lastAlertAt());
      server.check();
      assertEquals(List.of("failed"), sent.types(), "sent once");

      // The recovery takes the same route.
      job.run(j -> {});
      server.check();
      assertEquals(List.of("failed", "recovered"), sent.types());
      assertEquals(1, triaged.get(), "recoveries are not triaged");
    }
  }

  @Test
  void overlappingRunsOfOneJobShareItsStateWithoutLosingUpdates() throws Exception {
    Made m = Support.make();
    m.cw().job("par", JobOptions.builder().failuresBeforeAlert(2));
    try (ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      List<Future<?>> runs = new ArrayList<>();
      for (int i = 0; i < 3; i++) {
        runs.add(pool.submit(() -> fail(m.cw(), "par", "x")));
      }
      for (Future<?> f : runs) {
        f.get();
      }
    }
    assertEquals(3, state(m.cw(), "par").consecutiveFailures());
    assertEquals(List.of("failed"), m.alerts().types(), "one alert, not one per run");
  }

  private static void refused(Cronwatch cw, JobOptions options, String field) {
    CronwatchException e =
        assertThrows(CronwatchException.class, () -> cw.job("a", options), options.toString());
    assertTrue(e.getMessage().contains(field), e.getMessage());
    assertEquals(CronwatchException.Kind.INVALID, e.kind());
  }

  @Test
  void jobRefusesNumbersThatWouldQuietlyTurnACheckOff() {
    Made m = Support.make();
    Cronwatch cw = m.cw();
    refused(
        cw, JobOptions.builder().field("failuresBeforeAlert", Double.NaN), "failuresBeforeAlert");
    refused(cw, JobOptions.builder().failuresBeforeAlert(0), "failuresBeforeAlert");
    refused(cw, JobOptions.builder().field("failuresBeforeAlert", 1.5), "failuresBeforeAlert");
    refused(cw, JobOptions.builder().budget("cost", Double.NaN), "budget.cost");
    refused(cw, JobOptions.builder().budget("cost", Double.POSITIVE_INFINITY), "budget.cost");
    refused(cw, JobOptions.builder().budget("cost", -1), "budget.cost");
    refused(cw, JobOptions.builder().grace(Double.NaN), "grace");
    refused(cw, JobOptions.builder().timeout(0), "timeout");
    refused(cw, JobOptions.builder().maxDuration("0s"), "maxDuration");
    refused(cw, JobOptions.builder().schedule("0 2 * * *").timezone("Mars/Olympus"), "timezone");
    try (Cronwatch withDefaults =
        Cronwatch.builder()
            .defaults(JobOptions.builder().field("failuresBeforeAlert", Double.NaN))
            .noShutdownHook()
            .build()) {
      assertTrue(
          assertThrows(CronwatchException.class, () -> withDefaults.job("a"))
              .getMessage()
              .contains("failuresBeforeAlert"));
    }
    assertTrue(
        assertThrows(
                CronwatchException.class,
                () ->
                    Cronwatch.builder().defaults(JobOptions.builder().schedule("@hourly")).build())
            .getMessage()
            .contains("not schedule"));
    cw.job("a", JobOptions.builder().budget("errors", 0).failuresBeforeAlert(2).timeout("5m"));
  }

  @Test
  void aReturnedStringIsCappedLikeLoggedOutput() {
    Made m = Support.make();
    m.cw().call("big", j -> "x".repeat(40_000));
    String output = m.cw().runs("big", 1).get(0).output();
    assertTrue(output.length() < 17 * 1024);
    assertTrue(output.startsWith("[earlier output trimmed]"));
  }

  @Test
  void runsTakesAWholeNumberOfRunsInRange() {
    Made m = Support.make();
    for (int i = 0; i < 3; i++) {
      m.cw().run("n", j -> {});
    }
    assertEquals(2, m.cw().runs("n", 2).size());
    assertEquals(1, m.cw().runs("n", -4).size());
    assertEquals(3, m.cw().runs("n", 50).size());
    JobWithRuns entry = m.cw().jobsWithRuns(2).get(0);
    assertEquals(2, entry.runs().size());
    assertEquals(entry.job().lastRun().id(), entry.runs().get(0).id());
    assertEquals(0, m.cw().jobsWithRuns(-1).get(0).runs().size());
  }

  @Test
  void anErrorWhoseTextAlreadyNamesItIsNotLabelledTwice() {
    Made m = Support.make();
    assertThrows(
        IOException.class,
        () ->
            m.cw()
                .run(
                    "db",
                    j -> {
                      IOException e = new IOException("connect ECONNREFUSED 10.0.0.12:5432");
                      e.setStackTrace(
                          new StackTraceElement[] {
                            new StackTraceElement("sun.nio.ch.Net", "connect", "Net.java", 589)
                          });
                      throw e;
                    }));
    assertEquals(
        "IOException: connect ECONNREFUSED 10.0.0.12:5432\n"
            + "    at sun.nio.ch.Net.connect (Net.java:589)",
        m.cw().runs("db", 1).get(0).error());
    String message = m.alerts().alerts.get(0).message();
    assertFalse(message.contains("Error: IOException"));
    assertTrue(message.lines().anyMatch(l -> l.startsWith("IOException: connect ECONNREFUSED")));
    fail(m.cw(), "db", "two\nlines");
    assertTrue(
        m.cw()
            .runs("db", 1)
            .get(0)
            .error()
            .startsWith("IllegalStateException: two\nlines\n    at "));
  }

  @Test
  void theBaselineReadsPastRecentFailuresToTwentySuccessfulRuns() {
    Made m = Support.make();
    Job job = m.cw().job("base");
    List<long[]> plan = new ArrayList<>();
    for (int i = 0; i < 5; i++) {
      plan.add(new long[] {100_000, 0});
    }
    for (int i = 0; i < 15; i++) {
      plan.add(new long[] {1_000, 0});
    }
    for (int i = 0; i < 10; i++) {
      plan.add(new long[] {1_000, 1});
    }
    // Fifteen 1s runs alone would make 10s the limit; with the five 100s runs, p95 is 100s.
    plan.add(new long[] {30_000, 0});
    for (long[] p : plan) {
      try {
        job.run(
            j -> {
              m.clock().advance(p[0]);
              if (p[1] == 1) {
                throw new IllegalStateException("x");
              }
            });
      } catch (IllegalStateException e) {
        // A planned failure.
      }
      m.clock().advance(MIN);
    }
    assertEquals(List.of("failed", "recovered"), m.alerts().types());
  }

  /** A failure queued by a process that delivers at check, for a check elsewhere to send. */
  private static void queued(Store store, Clock clock, String name) {
    try (Cronwatch recorder =
        Support.builder(clock, new Capture(), new Errors())
            .store(store)
            .deliver(Deliver.AT_CHECK)
            .build()) {
      fail(recorder, name, "disk full");
    }
  }

  @Test
  void aDiagnosisMadeOnARetryIsKeptWithTheQueuedAlertAndTriageRunsOncePerAlert() {
    Clock clock = new Clock();
    MemoryStore store = new MemoryStore();
    queued(store, clock, "backup");
    AtomicInteger asked = new AtomicInteger();
    AtomicBoolean down = new AtomicBoolean(true);
    List<Alert> sent = new CopyOnWriteArrayList<>();
    Channel flaky =
        Channel.of(
            "flaky",
            (a, ctx) -> {
              if (down.get()) {
                throw new IOException("down");
              }
              sent.add(a);
            });
    try (Cronwatch server =
        Support.builder(clock, new Capture(), new Errors())
            .store(store)
            .alerts(List.of(flaky))
            .triage(
                ctx -> {
                  asked.incrementAndGet();
                  return "The disk is full.";
                })
            .build()) {
      server.check();
      assertEquals(1, asked.get());
      assertEquals(
          "The disk is full.",
          state(server, "backup").undelivered().get(0).triage(),
          "the stored copy has it");
      server.check();
      server.check();
      assertEquals(1, asked.get(), "not asked again on later retries");
      down.set(false);
      server.check();
      assertEquals(1, sent.size());
      assertEquals(AlertType.FAILED, sent.get(0).type());
      assertEquals("The disk is full.", sent.get(0).triage());
    }
  }

  @Test
  void aTriageThatThrowsOrAnswersNothingIsTriedOnceRecordedAsNull() {
    List<Triage> answers =
        List.of(
            ctx -> {
              throw new IOException("api down");
            },
            ctx -> "",
            ctx -> null);
    for (Triage answer : answers) {
      Clock clock = new Clock();
      MemoryStore store = new MemoryStore();
      queued(store, clock, "backup");
      AtomicInteger asked = new AtomicInteger();
      Channel down =
          Channel.of(
              "down",
              (a, ctx) -> {
                throw new IOException("down");
              });
      try (Cronwatch server =
          Support.builder(clock, new Capture(), new Errors())
              .store(store)
              .alerts(List.of(down))
              .triage(
                  ctx -> {
                    asked.incrementAndGet();
                    return answer.triage(ctx);
                  })
              .build()) {
        for (int i = 0; i < 3; i++) {
          server.check();
        }
        assertEquals(1, asked.get());
        Alert queued = state(server, "backup").undelivered().get(0);
        assertNull(queued.triage());
        assertTrue(queued.triageTried());
        assertTrue(queued.toJson().contains("\"triage\":null"));
      }
    }
  }

  @Test
  void retriesStopOnceACheckHasSpentItsBudgetAndTheRestWait() {
    Clock clock = new Clock();
    MemoryStore store = new MemoryStore();
    for (String name : List.of("a", "b", "c")) {
      queued(store, clock, name);
    }
    List<String> tried = new CopyOnWriteArrayList<>();
    // Each attempt takes half a second of wall clock and fails; the budget covers two.
    Channel slow =
        Channel.of(
            "slow",
            (a, ctx) -> {
              tried.add(a.job());
              Thread.sleep(500);
              throw new IOException("timed out");
            });
    Cronwatch.Builder b =
        Support.builder(clock, new Capture(), new Errors()).store(store).alerts(List.of(slow));
    b.timings.retryBudgetMs = 800;
    try (Cronwatch server = b.build()) {
      server.check();
      assertEquals(List.of("a", "b"), tried, "the budget covers two attempts");
      assertEquals(1, state(server, "c").undelivered().size(), "c is still queued");
      tried.clear();
      server.check();
      assertEquals(List.of("a", "b"), tried, "each check has a fresh budget");
    }
  }

  private static Channel downUntil(AtomicBoolean down, List<String> sent) {
    return Channel.of(
        "flaky",
        (a, ctx) -> {
          if (down.get()) {
            throw new IOException("down");
          }
          sent.add(a.type() + "@" + a.at());
        });
  }

  @Test
  void anAlertWhoseConditionClosedIsDroppedAndARecoveryWhoseConditionsStayClosedIsSent() {
    AtomicBoolean down = new AtomicBoolean(true);
    List<String> sent = new CopyOnWriteArrayList<>();
    Made m = Support.make(b -> b.alerts(List.of(downUntil(down, sent))));
    fail(m.cw(), "s", "x");
    m.clock().advance(MIN);
    m.cw().run("s", j -> {});
    assertEquals(List.of("failed", "recovered"), queuedTypes(m.cw(), "s"));
    down.set(false);
    m.clock().advance(MIN);
    m.cw().check();
    assertEquals(List.of("recovered@" + (T0 + MIN)), sent, "only the recovery goes");
    assertEquals(List.of(), state(m.cw(), "s").undelivered());
  }

  @Test
  void anAlertWhoseConditionOpenedAgainIsDroppedAndSoIsARecoveryItUndoes() {
    AtomicBoolean down = new AtomicBoolean(true);
    List<String> sent = new CopyOnWriteArrayList<>();
    Made m = Support.make(b -> b.alerts(List.of(downUntil(down, sent))));
    fail(m.cw(), "s", "x");
    m.clock().advance(MIN);
    m.cw().run("s", j -> {});
    m.clock().advance(MIN);
    fail(m.cw(), "s", "again");
    assertEquals(List.of("failed", "recovered", "failed"), queuedTypes(m.cw(), "s"));
    down.set(false);
    m.clock().advance(MIN);
    m.cw().check();
    assertEquals(List.of("failed@" + (T0 + 2 * MIN)), sent);
  }

  @Test
  void aJobThatCannotBeEvaluatedIsReportedAndShownAsFailingAndTheOthersAreChecked()
      throws Exception {
    Made m = Support.make();
    Job good = m.cw().job("good", JobOptions.builder().schedule("every 1h"));
    good.run(j -> {});
    Store store = m.cw().store();
    store.upsertJob(
        Definition.of(new JsObject().set("name", "bad").set("schedule", "not a schedule")), T0);
    store.upsertJob(Definition.of(new JsObject().set("name", "odd").set("timeout", "soon")), T0);
    store.insertRun(Run.running("hung", "odd", T0, "run"));
    m.clock().advance(2 * HOUR);
    CheckResult result = m.cw().check();
    assertEquals(
        List.of("good:missed"),
        result.alerts().stream().map(a -> a.job() + ":" + a.type()).toList());
    Map<String, String> health = new TreeMap<>();
    for (JobSummary j : result.jobs()) {
      health.put(j.name(), j.health().value());
    }
    assertEquals(Map.of("bad", "failing", "good", "late", "odd", "failing"), health);
    assertEquals(List.of("checking odd", "checking bad", "checking odd"), m.errors().wheres());
    assertEquals(List.of("missed"), m.alerts().types());

    m.errors().entries.clear();
    List<String> jobs = new ArrayList<>();
    for (JobSummary j : m.cw().jobs()) {
      jobs.add(j.name() + " " + j.health() + " " + (j.nextExpectedAt() == null));
    }
    assertEquals(List.of("bad failing true", "good late false", "odd failing true"), jobs);
    assertEquals(List.of("reading bad", "reading odd"), m.errors().wheres());
    assertEquals(JobHealth.FAILING, m.cw().jobSummary("bad").health());
    m.cw().silence("bad", "1h");
    assertEquals(JobHealth.SILENCED, m.cw().jobSummary("bad").health());
  }

  @Test
  void trimmingTheUndeliveredQueuePastTwentyIsReported() {
    Made m = Support.make(b -> b.deliver(Deliver.AT_CHECK));
    for (int i = 0; i < 10; i++) {
      fail(m.cw(), "q", "x");
      m.cw().run("q", j -> {});
    }
    assertEquals(20, state(m.cw(), "q").undelivered().size());
    assertEquals(List.of(), m.errors().wheres());
    fail(m.cw(), "q", "x");
    assertEquals(20, state(m.cw(), "q").undelivered().size());
    assertEquals(List.of("alert queue for q"), m.errors().wheres());
  }

  @Test
  void startWithDeliverAtCheckSaysOnceThatAnotherProcessMustSend() {
    List<String> warnings = new CopyOnWriteArrayList<>();
    Logger logger = Logger.getLogger("dev.cronwatch");
    Handler handler =
        new Handler() {
          @Override
          public void publish(LogRecord r) {
            warnings.add(r.getMessage());
          }

          @Override
          public void flush() {}

          @Override
          public void close() {}
        };
    logger.addHandler(handler);
    try (Cronwatch deferred =
            Cronwatch.builder().deliver(Deliver.AT_CHECK).noShutdownHook().build();
        Cronwatch delivering = Cronwatch.builder().noShutdownHook().build()) {
      deferred.start();
      deferred.stop();
      deferred.start();
      deferred.stop();
      assertEquals(1, warnings.size(), warnings.toString());
      String warning = warnings.get(0);
      assertTrue(
          warning.contains("Deliver.AT_CHECK")
              && warning.contains("send no alerts")
              && warning.contains("Another process"),
          warning);
      delivering.start();
      delivering.stop();
      assertEquals(1, warnings.size(), "a delivering client says nothing");
    } finally {
      logger.removeHandler(handler);
    }
  }

  @Test
  void aLongTimeoutDoesNotCancelTheJobAtOnce() throws InterruptedException {
    Made m = Support.make();
    Job job = m.cw().job("monthly", JobOptions.builder().timeout("30d"));
    boolean cancelled =
        job.call(
            j -> {
              Thread.sleep(20);
              return j.cancelled();
            });
    assertFalse(cancelled);
  }

  @Test
  void startAgainAfterStopChecksAndALongIntervalDoesNotCheckEveryMillisecond() throws Exception {
    AtomicInteger checks = new AtomicInteger();
    Source counter =
        new Source() {
          @Override
          public String name() {
            return "counter";
          }

          @Override
          public List<Alert> sync(Cronwatch cronwatch) {
            checks.incrementAndGet();
            return List.of();
          }
        };
    Made m =
        Support.make(
            b -> {
              b.source(counter);
              b.timings.firstCheckMs = 50;
            });
    try (Cronwatch cw = m.cw()) {
      cw.start("30d");
      Support.await("the first check", () -> checks.get() == 1);
      TimeUnit.MILLISECONDS.sleep(300);
      assertEquals(1, checks.get(), "no more soon after");
      cw.stop();
      cw.start();
      Support.await("the first check after starting again", () -> checks.get() == 2);
    }
  }
}
