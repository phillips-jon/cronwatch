package dev.cronwatch;

import static dev.cronwatch.Support.MIN;
import static dev.cronwatch.Support.T0;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Support.Clock;
import dev.cronwatch.Support.Made;
import dev.cronwatch.internal.duration.Schedules;
import dev.cronwatch.internal.evaluate.Evaluate.AlertDraft;
import dev.cronwatch.internal.evaluate.Format;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

/**
 * The SDK's {@code correctness.test.ts}, ported: state an alert in flight cannot overwrite,
 * pruning, expect, runs a check marks stuck, the interval stopped before its first check, fire
 * times around the autumn clock change, and an error named once. The routes' 404 case is phase 3's.
 */
class CorrectnessTest {
  @Test
  void anAlertStillBeingSentCannotOverwriteWhatARunDidMeanwhile() throws Exception {
    List<String> sent = new CopyOnWriteArrayList<>();
    CountDownLatch inFlight = new CountDownLatch(1);
    CountDownLatch release = new CountDownLatch(1);
    Channel slowForMissed =
        Channel.of(
            "slow-for-missed",
            (a, ctx) -> {
              if (a.type().equals(AlertType.MISSED)) {
                inFlight.countDown();
                release.await();
              }
              sent.add(a.type().value());
            });
    Made m = Support.make(b -> b.alerts(List.of(slowForMissed)));
    Job job = m.cw().job("sync", JobOptions.builder().schedule("every 5m").grace("1m"));
    job.run(j -> {});
    m.clock().advance(7 * MIN);
    try (ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      Future<CheckResult> checking = pool.submit(() -> m.cw().check());
      inFlight.await();
      job.run(j -> {}); // the job turns up while the missed alert is in flight
      release.countDown();
      checking.get();
    }
    assertEquals(List.of("recovered", "missed"), sent);
    assertEquals(0, m.cw().store().getState("sync").open().size(), "missed stays closed");
    m.clock().advance(MIN);
    job.run(j -> {});
    assertEquals(List.of("recovered", "missed"), sent, "no second recovered");
  }

  @Test
  void pruningKeepsEachJobsNewestRunSoAMonthlyJobIsNotReportedMissed() {
    Clock clock = new Clock(Js.dateUtc(2026, 0, 1, 0, 0, 0, 0));
    Support.Capture alerts = new Support.Capture();
    try (Cronwatch cw =
        Support.builder(clock, alerts, new Support.Errors()).retention("30d").build()) {
      Job monthly = cw.job("monthly", JobOptions.builder().schedule("0 0 1 * *").timezone("UTC"));
      monthly.run(j -> {});
      clock.set(Js.dateUtc(2026, 0, 31, 12, 0, 0, 0));
      assertEquals(0, cw.check().pruned());
      clock.advance(2 * 60 * MIN);
      cw.check();
      assertEquals(List.of(), alerts.types());
      assertEquals(JobHealth.HEALTHY, cw.jobSummary("monthly").health());
    }
  }

  @Test
  void anExpectPatternWithTheGFlagGivesTheSameAnswerEveryRun() {
    Made m = Support.make();
    Job job = m.cw().job("g", JobOptions.builder().expectMatch("done", "g"));
    for (int i = 0; i < 4; i++) {
      job.run(j -> j.log("done"));
    }
    assertEquals(
        List.of(RunStatus.OK, RunStatus.OK, RunStatus.OK, RunStatus.OK),
        m.cw().runs("g", 50).stream().map(Run::status).toList());
  }

  @Test
  void expectSeesALineLoggedEarlyEvenAfterTheStoredOutputHasDroppedIt() {
    Made m = Support.make();
    m.cw()
        .run(
            "report",
            JobOptions.builder().expect("Report written"),
            j -> {
              j.log("Report written: /tmp/r.pdf");
              for (int i = 0; i < 3000; i++) {
                j.log("row " + i + " " + "x".repeat(40));
              }
            });
    Run run = m.cw().runs("report", 1).get(0);
    assertEquals(RunStatus.OK, run.status());
    assertFalse(run.output().contains("Report written"), "the stored output is still the tail");
  }

  @Test
  void anIntervalJobWhoseRunIsStillGoingIsBusyNotMissed() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("long", JobOptions.builder().schedule("every 5m").grace("2m"));
    CountDownLatch finish = new CountDownLatch(1);
    Thread running = Support.background(() -> job.run(j -> finish.await()));
    Support.await("the run to start", () -> m.cw().runs("long", 1).size() == 1);
    m.clock().advance(8 * MIN);
    m.cw().check();
    assertEquals(List.of(), m.alerts().types());
    finish.countDown();
    running.join();
    assertEquals(List.of(), m.alerts().types(), "and no recovered for a miss that never was");
  }

  @Test
  void aRunACheckMarkedStuckThatThenFailsCountsOnce() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("slowpoke", JobOptions.builder().timeout("1m").failuresBeforeAlert(2));
    CountDownLatch fail = new CountDownLatch(1);
    Thread running =
        Support.background(
            () ->
                job.run(
                    j -> {
                      fail.await();
                      throw new IllegalStateException("gave up");
                    }));
    Support.await("the run to start", () -> m.cw().runs("slowpoke", 1).size() == 1);
    m.clock().advance(2 * MIN);
    m.cw().check();
    assertEquals(1, m.cw().store().getState("slowpoke").consecutiveFailures());
    fail.countDown();
    running.join();
    assertEquals(1, m.cw().store().getState("slowpoke").consecutiveFailures());
    assertEquals(List.of(), m.alerts().types(), "one run is one failure, under the threshold");
    assertEquals(
        "IllegalStateException: gave up",
        Support.firstLine(m.cw().runs("slowpoke", 1).get(0).error()),
        "the run keeps its real error");
  }

  @Test
  void aLateSuccessAfterAStuckMarkClosesStuckAndRecovers() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("late", JobOptions.builder().timeout("30s"));
    CountDownLatch finish = new CountDownLatch(1);
    Thread running = Support.background(() -> job.run(j -> finish.await()));
    Support.await("the run to start", () -> m.cw().runs("late", 1).size() == 1);
    m.clock().advance(MIN);
    List<Alert> fromCheck = m.cw().check().alerts();
    assertTrue(fromCheck.get(0).run().error().startsWith("Still running after 30s;"));
    finish.countDown();
    running.join();
    assertEquals(List.of("stuck", "recovered"), m.alerts().types());
  }

  @Test
  void stopCancelsTheFirstCheckStartScheduled() throws Exception {
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
    Made m = Support.make(b -> b.source(counter));
    try (Cronwatch cw = m.cw()) {
      // The interval's first check comes a second after start; stop() comes first.
      cw.start();
      cw.stop();
      Thread.sleep(1_300);
      assertEquals(0, checks.get());
    }
  }

  @Test
  void fireTimesAroundTheAutumnClockChangeAreNeverInThePast() {
    Object[][] zones = {
      {"Europe/London", Js.dateUtc(2026, 9, 24, 22, 0, 0, 0)},
      {"America/New_York", Js.dateUtc(2026, 10, 1, 3, 0, 0, 0)}
    };
    for (Object[] z : zones) {
      String tz = (String) z[0];
      long day = (long) z[1];
      for (String expr : List.of("*/15 * * * *", "30 1 * * *", "0 * * * *")) {
        Schedules.ParsedSchedule p = Schedules.parse(expr, tz);
        for (long t = day; t < day + 8 * 3_600_000L; t += 5 * MIN) {
          Long next = Schedules.nextFire(p, t, null);
          assertTrue(next != null && next > t, tz + " " + expr + " after " + Js.isoString(t));
        }
      }
    }
  }

  @Test
  void aFailedAlertNamesTheErrorOnce() {
    for (String[] c :
        new String[][] {
          {"IOException: connect ECONNREFUSED 10.0.0.12:5432", "IOException: connect ECONNREFUSED"},
          {"TypeError: x is undefined", "TypeError: x is undefined"},
          {"Output did not contain \"wrote\"", "Error: Output did not contain \"wrote\""},
          {"HTTP 503 Service Unavailable", "Error: HTTP 503"}
        }) {
      Run run = new Run("r", "j", RunStatus.FAILED, T0, T0, 5L, c[0], null, Metrics.empty(), "run");
      String message =
          Format.composeAlert(
                  new AlertDraft(AlertType.FAILED, run, new AlertDetails.Failure(1, 1)),
                  Definition.of(new JsObject().set("name", "j")),
                  T0)
              .message();
      assertTrue(message.lines().anyMatch(l -> l.startsWith(c[1])), message);
      assertFalse(message.contains("Error: Error:") || message.contains("Error: IOException"));
    }
  }

  @Test
  void anExpectPatternTheEngineCannotReadIsRefusedWhenDeclared() {
    Made m = Support.make();
    assertThrows(
        CronwatchException.class,
        () -> m.cw().job("p", JobOptions.builder().expectMatch("(?<=a)+", "")));
  }
}
