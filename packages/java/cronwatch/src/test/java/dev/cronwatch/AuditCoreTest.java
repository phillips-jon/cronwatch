package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Support.Made;
import java.time.Duration;
import org.junit.jupiter.api.Test;

/**
 * The Java audit's cases for the core client: an app's redact or expect predicate that throws an
 * {@code Error}, or an exception whose message cannot be read, a run with many metrics, and the
 * per-job locks let go of once idle.
 */
class AuditCoreTest {
  /** An exception whose message cannot be read. */
  private static final class Mute extends RuntimeException {
    private static final long serialVersionUID = 1L;

    @Override
    public String getMessage() {
      throw new IllegalStateException("no words");
    }
  }

  @Test
  void aRedactThatThrowsAnErrorStillRecordsTheRunAndTheErrorIsThrownAgain() {
    Made m =
        Support.make(
            b ->
                b.redact(
                    s -> {
                      throw new StackOverflowError("redact went too deep");
                    }));
    Job job = m.cw().job("deep-redact");
    StackOverflowError e =
        assertThrows(StackOverflowError.class, () -> job.run(j -> j.log("fine")));
    assertEquals("redact went too deep", e.getMessage());
    Run run = m.cw().runs("deep-redact", 1).get(0);
    assertEquals(RunStatus.FAILED, run.status());
    assertTrue(run.error().startsWith("StackOverflowError: redact went too deep"), run.error());
  }

  @Test
  void anExpectPredicateThatThrowsAnErrorStillRecordsTheRun() {
    Made m = Support.make();
    Job job =
        m.cw()
            .job(
                "deep-expect",
                JobOptions.builder()
                    .expectThat(
                        out -> {
                          throw new StackOverflowError("predicate went too deep");
                        }));
    assertThrows(StackOverflowError.class, () -> job.run(j -> j.log("fine")));
    Run run = m.cw().runs("deep-expect", 1).get(0);
    assertEquals(RunStatus.FAILED, run.status());
    assertTrue(run.error().startsWith("StackOverflowError: predicate went too deep"), run.error());
  }

  @Test
  void anExpectPredicateThrowingAnExceptionWhoseMessageThrowsFailsTheRun() {
    Made m = Support.make();
    Job job =
        m.cw()
            .job(
                "mute-expect",
                JobOptions.builder()
                    .expectThat(
                        out -> {
                          throw new Mute();
                        }));
    job.run(j -> j.log("fine"));
    Run run = m.cw().runs("mute-expect", 1).get(0);
    assertEquals(RunStatus.FAILED, run.status());
    assertEquals("Output check threw: ", run.error());
  }

  @Test
  void aHandleFinishedThroughAnExpectErrorIsRecordedAndNotLeftHalfFinished() {
    Made m = Support.make();
    Job job =
        m.cw()
            .job(
                "deep-handle",
                JobOptions.builder()
                    .expectThat(
                        out -> {
                          throw new StackOverflowError("predicate went too deep");
                        }));
    RunHandle handle = job.start();
    assertThrows(StackOverflowError.class, handle::finish);
    Run run = m.cw().runs("deep-handle", 1).get(0);
    assertEquals(RunStatus.FAILED, run.status());
  }

  /** The SDK sets a metric in place; a copy of every metric per call was quadratic. */
  @Test
  void aRunWithManyMetricsIsRecordedInLinearTime() {
    Made m = Support.make();
    Job job = m.cw().job("many-metrics");
    int n = 100_000;
    assertTimeoutPreemptively(
        Duration.ofSeconds(20),
        () ->
            job.run(
                j -> {
                  for (int i = 0; i < n; i++) {
                    j.metric("m" + i, i);
                  }
                }));
    assertEquals(n, m.cw().runs("many-metrics", 1).get(0).metrics().size());
  }

  /** The SDK drops a job's update queue once it is idle; the locks are let go of the same way. */
  @Test
  void theLockOfAJobsStateUpdatesIsLetGoOfOnceIdle() {
    Made m = Support.make();
    for (int i = 0; i < 200; i++) {
      m.cw().silence("gone-" + i, "1h");
    }
    m.cw().job("kept").run(j -> j.log("ok"));
    assertEquals(0, m.cw().core.lockedJobs());
  }
}
