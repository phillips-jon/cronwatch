package dev.cronwatch;

import static dev.cronwatch.Support.HOUR;
import static dev.cronwatch.Support.MIN;
import static dev.cronwatch.Support.T0;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Support.Made;
import dev.cronwatch.internal.js.Js;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import org.junit.jupiter.api.Test;

/**
 * The SDK's {@code client.test.ts}, ported: runs, failures, expect, the checks for missed and stuck
 * runs, baselines and budgets, silence, triage, forget, and a failing channel. The handler cases
 * are in {@code web.HandlerTest}.
 */
class ClientTest {
  @Test
  void runRecordsOutputMetricsAndDurationAndReturnsTheResult() {
    Made m = Support.make();
    Job job = m.cw().job("report", JobOptions.builder().schedule("0 2 * * *"));
    String result =
        job.call(
            j -> {
              j.log("hello {\"n\":1}");
              j.metric("rows", 42);
              m.clock().advance(1500);
              return "done";
            });
    assertEquals("done", result);
    Run run = m.cw().runs("report", 50).get(0);
    assertEquals(RunStatus.OK, run.status());
    assertEquals(1500L, run.durationMs());
    assertEquals("hello {\"n\":1}", run.output());
    assertEquals("{\"rows\":42}", run.metrics().toJson());
    JobSummary summary = m.cw().jobSummary("report");
    assertEquals(JobHealth.HEALTHY, summary.health());
    assertEquals(Js.dateUtc(2026, 0, 6, 2, 0, 0, 0), summary.nextExpectedAt());
  }

  @Test
  void aThrowingJobIsRecordedAsFailedAlertsAndRethrows() {
    Made m = Support.make();
    Job job = m.cw().job("nightly");
    IllegalStateException e =
        assertThrows(
            IllegalStateException.class,
            () ->
                job.run(
                    j -> {
                      throw new IllegalStateException("db down");
                    }));
    assertEquals("db down", e.getMessage());
    Run run = m.cw().runs("nightly", 50).get(0);
    assertEquals(RunStatus.FAILED, run.status());
    assertTrue(run.error().startsWith("IllegalStateException: db down"), run.error());
    assertEquals(List.of("failed"), m.alerts().types());
    assertTrue(m.alerts().alerts.get(0).message().contains("db down"));
    assertEquals(JobHealth.FAILING, m.cw().jobSummary("nightly").health());
  }

  @Test
  void expectTurnsAQuietSuccessIntoAFailure() {
    Made m = Support.make();
    Job job = m.cw().job("export", JobOptions.builder().expect("wrote"));
    job.run(j -> j.log("wrote 12 files"));
    assertEquals(List.of(), m.alerts().types());
    m.clock().advance(HOUR);
    job.run(j -> j.log("nothing to do"));
    Run run = m.cw().runs("export", 50).get(0);
    assertEquals(RunStatus.FAILED, run.status());
    assertTrue(run.error().contains("did not contain \"wrote\""), run.error());
    assertEquals(List.of("failed"), m.alerts().types());
    // A returned string counts as output too.
    job.call(j -> "wrote 3 files");
    assertEquals(List.of("failed", "recovered"), m.alerts().types());
  }

  @Test
  void runDefinesOnFirstUseAndValidatesNamesAndSchedules() {
    Made m = Support.make();
    int one = m.cw().call("adhoc", JobOptions.builder().schedule("every 5m"), j -> 1);
    assertEquals(1, one);
    assertEquals(1, m.cw().jobs().size());
    assertTrue(
        assertThrows(CronwatchException.class, () -> m.cw().job("bad name!"))
            .getMessage()
            .contains("job name"));
    CronwatchException cron =
        assertThrows(
            CronwatchException.class, () -> m.cw().job("x", JobOptions.builder().schedule("nope")));
    assertTrue(cron.getMessage().contains("not a cron expression"), cron.getMessage());
    assertEquals(CronwatchException.Kind.INVALID, cron.kind());
    assertTrue(
        assertThrows(
                CronwatchException.class, () -> m.cw().job("x", JobOptions.builder().grace("soon")))
            .getMessage()
            .contains("grace"));
  }

  @Test
  void anHttpAnswerOf400OrMoreFailsTheRun() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("h");
    Object bad = Support.httpResponse(503);
    assertSame(bad, job.call(j -> bad), "the answer is passed through");
    assertEquals("HTTP 503 Service Unavailable", m.cw().runs("h", 1).get(0).error());
    assertEquals(List.of("failed"), m.alerts().types());
    Object fine = Support.httpResponse(204);
    job.call(j -> fine);
    assertEquals(RunStatus.OK, m.cw().runs("h", 1).get(0).status());
  }

  @Test
  void checkFindsAMissedRunOnceAndALaterRunRecovers() {
    Made m = Support.make();
    Job job = m.cw().job("sync", JobOptions.builder().schedule("every 1h").grace("10m"));
    m.cw().check(); // registers at T0
    m.clock().advance(30 * MIN);
    assertEquals(List.of(), m.cw().check().alerts());
    m.clock().set(T0 + 70 * MIN + 1);
    CheckResult r = m.cw().check();
    assertEquals(T0 + 70 * MIN + 1, r.checkedAt(), "a check of its own, not the last one's answer");
    assertEquals(List.of(AlertType.MISSED), r.alerts().stream().map(Alert::type).toList());
    assertEquals(JobHealth.LATE, r.jobs().get(0).health());
    assertEquals(List.of(), m.cw().check().alerts(), "no repeat");
    job.run(j -> {});
    assertEquals(List.of("missed", "recovered"), m.alerts().types());
    assertEquals(JobHealth.HEALTHY, m.cw().jobSummary("sync").health());
  }

  @Test
  void aJobDeclaredAgainWithoutItsScheduleClosesMissedWithARecoveryOnce() {
    Made m = Support.make();
    m.cw().job("sync", JobOptions.builder().schedule("every 1h").grace("10m"));
    m.cw().check();
    m.clock().set(T0 + 70 * MIN + 1);
    assertEquals(1, m.cw().check().alerts().size());
    Job job = m.cw().job("sync");
    m.clock().advance(MIN);
    CheckResult r = m.cw().check();
    assertEquals(1, r.alerts().size());
    Alert alert = r.alerts().get(0);
    assertEquals(AlertType.RECOVERED, alert.type());
    assertEquals("sync is no longer scheduled", alert.title());
    assertEquals(
        "Missed since 2026-01-05 10:40:00 UTC (1m ago). It has no schedule now, so nothing is"
            + " due; the missed alert is closed.",
        alert.message());
    assertEquals(
        "{\"after\":[\"missed\"],\"reason\":\"unscheduled\",\"since\":" + (T0 + 70 * MIN + 1) + "}",
        alert.details().toValue().toJson());
    assertEquals(JobHealth.NEVER_RAN, r.jobs().get(0).health());
    assertEquals(List.of(), m.cw().check().alerts(), "no repeat");
    job.run(j -> {});
    assertEquals(List.of("missed", "recovered"), m.alerts().types(), "the next run owes nothing");
  }

  @Test
  void aScheduleRemovedWhileSilencedClosesMissedQuietly() {
    Made m = Support.make();
    m.cw().job("sync", JobOptions.builder().schedule("every 1h").grace("10m"));
    m.cw().check();
    m.clock().set(T0 + 70 * MIN + 1);
    m.cw().check();
    m.cw().silence("sync", "1h");
    m.cw().job("sync");
    m.clock().advance(MIN);
    assertEquals(List.of(), m.cw().check().alerts());
    assertEquals(List.of(), m.cw().jobSummary("sync").open());
    m.clock().advance(2 * HOUR);
    assertEquals(List.of(), m.cw().check().alerts());
    assertEquals(List.of("missed"), m.alerts().types());
  }

  @Test
  void checkMarksARunThatNeverFinishedAsStuck() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("long", JobOptions.builder().timeout("5m"));
    CountDownLatch release = new CountDownLatch(1);
    Thread t = Support.background(() -> job.run(j -> release.await()));
    Support.await("the run to start", () -> m.cw().runs("long", 1).size() == 1);
    assertEquals(RunStatus.RUNNING, m.cw().runs("long", 1).get(0).status());
    m.clock().advance(4 * MIN);
    assertEquals(List.of(), m.cw().check().alerts());
    m.clock().advance(2 * MIN);
    CheckResult r = m.cw().check();
    assertEquals(List.of(AlertType.STUCK), r.alerts().stream().map(Alert::type).toList());
    assertEquals(RunStatus.TIMEOUT, m.cw().runs("long", 1).get(0).status());
    assertEquals(JobHealth.STUCK, r.jobs().get(0).health());
    assertTrue(m.alerts().alerts.get(0).message().contains("never reported finishing"));
    release.countDown();
    t.join();
  }

  @Test
  void slowAndOverBudgetAlertsComeFromTheJobsOwnBaseline() {
    Made m = Support.make();
    Job job = m.cw().job("agent", JobOptions.builder().budget("cost", 1));
    for (int i = 0; i < 5; i++) {
      job.run(
          j -> {
            m.clock().advance(1000);
            j.metric("tokens", 1000);
            j.metric("cost", 0.5);
          });
      m.clock().advance(HOUR);
    }
    assertEquals(List.of(), m.alerts().types());
    job.run(
        j -> {
          m.clock().advance(15_000);
          j.metric("tokens", 1000);
          j.metric("cost", 0.5);
        });
    assertEquals(List.of("slow"), m.alerts().types());
    m.clock().advance(HOUR);
    job.run(
        j -> {
          m.clock().advance(1000);
          j.metric("tokens", 5000);
          j.metric("cost", 1.2);
        });
    assertEquals(List.of("slow", "over_budget"), m.alerts().types());
    String message = m.alerts().alerts.get(1).message();
    assertTrue(message.contains("cost: 1.2, limit 1 (budget)"), message);
    assertTrue(
        message.contains("tokens: 5,000, limit 3,000 (three times the usual 1,000)"), message);
    m.clock().advance(HOUR);
    job.run(
        j -> {
          m.clock().advance(1000);
          j.metric("tokens", 1000);
          j.metric("cost", 0.5);
        });
    assertEquals(List.of("slow", "over_budget", "recovered"), m.alerts().types());
  }

  @Test
  void anUnderFloorAlertNamesTheMetricAndWhatItWasJudgedAgainst() {
    Made m = Support.make();
    Job job = m.cw().job("import", JobOptions.builder().floor("files", 1));
    for (int i = 0; i < 5; i++) {
      int rows = 4812 + i;
      job.run(
          j -> {
            m.clock().advance(1000);
            j.metric("rows", rows);
            j.metric("files", 2);
          });
      m.clock().advance(HOUR);
    }
    job.run(
        j -> {
          m.clock().advance(1000);
          j.metric("rows", 0);
          j.metric("files", 0);
        });
    assertEquals(List.of("under_floor"), m.alerts().types());
    Alert alert = m.alerts().alerts.get(0);
    assertEquals("import fell short", alert.title());
    assertTrue(
        alert
            .message()
            .contains("rows: 0 (the last 5 runs all reported more than 0, the lowest 4,812)"),
        alert.message());
    assertTrue(alert.message().contains("files: 0, below the floor of 1."), alert.message());
    m.clock().advance(HOUR);
    job.run(
        j -> {
          m.clock().advance(1000);
          j.metric("rows", 0);
          j.metric("files", 0);
        });
    assertEquals(List.of("under_floor"), m.alerts().types());
    m.clock().advance(HOUR);
    job.run(
        j -> {
          m.clock().advance(1000);
          j.metric("rows", 10);
          j.metric("files", 1);
        });
    assertEquals(List.of("under_floor", "recovered"), m.alerts().types());
  }

  @Test
  void aFloorMustBeAFiniteNumberAndNoHigherThanItsCeiling() {
    Made m = Support.make();
    assertTrue(
        assertThrows(
                CronwatchException.class,
                () -> m.cw().job("a", JobOptions.builder().floor("rows", Double.NaN)))
            .getMessage()
            .contains("floor.rows must be a finite number"));
    assertTrue(
        assertThrows(
                CronwatchException.class,
                () -> m.cw().job("b", JobOptions.builder().floor("cost", 3).budget("cost", 2)))
            .getMessage()
            .contains("floor.cost (3) is above budget.cost (2), so every run would alert"));
    assertTrue(
        assertThrows(
                CronwatchException.class,
                () -> m.cw().job("c", JobOptions.builder().field("floor", "rows")))
            .getMessage()
            .contains("floor must be an object of { metric: floor }"));
    m.cw().job("d", JobOptions.builder().floor("delta", -5).budget("delta", 5));
  }

  @Test
  void silenceSwallowsAlertsAndNothingOpensUnderneath() {
    Made m = Support.make();
    Job job = m.cw().job("flaky");
    m.cw().silence("flaky", "1h");
    assertThrows(
        IllegalStateException.class,
        () ->
            job.run(
                j -> {
                  throw new IllegalStateException("x");
                }));
    assertEquals(List.of(), m.alerts().types());
    assertEquals(JobHealth.SILENCED, m.cw().jobSummary("flaky").health());
    m.cw().unsilence("flaky");
    assertThrows(
        IllegalStateException.class,
        () ->
            job.run(
                j -> {
                  throw new IllegalStateException("y");
                }));
    assertEquals(List.of("failed"), m.alerts().types());
  }

  @Test
  void triageIsAttachedToFailureAlertsAndNeverBlocksThem() {
    Made m = Support.make(b -> b.triage(ctx -> "Probably " + ctx.alert().job() + "'s database."));
    assertThrows(
        IllegalStateException.class,
        () ->
            m.cw()
                .run(
                    "t",
                    j -> {
                      throw new IllegalStateException("x");
                    }));
    assertEquals("Probably t's database.", m.alerts().alerts.get(0).triage());

    Made m2 =
        Support.make(
            b ->
                b.triage(
                    ctx -> {
                      throw new IllegalStateException("api down");
                    }));
    assertThrows(
        IllegalStateException.class,
        () ->
            m2.cw()
                .run(
                    "t",
                    j -> {
                      throw new IllegalStateException("x");
                    }));
    assertEquals(List.of("failed"), m2.alerts().types());
    Alert alert = m2.alerts().alerts.get(0);
    assertNull(alert.triage());
    assertTrue(alert.triageTried(), "tried, and gave nothing");
    assertEquals(List.of("triage for t"), m2.errors().wheres());
  }

  @Test
  void forgetRemovesTheJobAndItsRuns() {
    Made m = Support.make();
    m.cw().run("gone", j -> {});
    assertEquals(1, m.cw().jobs().size());
    m.cw().forget("gone");
    assertEquals(0, m.cw().jobs().size());
    assertNull(m.cw().jobSummary("gone"));
  }

  @Test
  void aFailingAlertChannelDoesNotBreakTheRun() {
    Made m =
        Support.make(
            b ->
                b.alerts(
                    List.of(
                        Channel.of(
                            "broken",
                            (a, ctx) -> {
                              throw new IllegalStateException("no network");
                            }))));
    assertThrows(
        IllegalStateException.class,
        () ->
            m.cw()
                .run(
                    "x",
                    j -> {
                      throw new IllegalStateException("job");
                    }));
    assertEquals(List.of("alert channel broken"), m.errors().wheres());
  }
}
