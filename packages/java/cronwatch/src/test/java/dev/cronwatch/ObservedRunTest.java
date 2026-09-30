package dev.cronwatch;

import static dev.cronwatch.Support.HOUR;
import static dev.cronwatch.Support.MIN;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * A run opened and closed from outside its function ({@link Job#open}), and a run given back
 * ({@link RunOptions#withDiscardWhen}, {@link ObservedRun#takeBack}): the Go port's {@code
 * DiscardWhen} rules and the Elixir port's {@code Exec.open/2} and {@code close/2}.
 */
class ObservedRunTest {
  @Test
  void anOpenedRunIsARunUntilItCloses() throws Exception {
    Support.Made m = Support.make();
    try (Cronwatch cw = m.cw()) {
      Job job = cw.job("listened", JobOptions.builder());
      ObservedRun run = job.open(RunOptions.trigger("quartz").withId("quartz:app:1"));
      assertEquals("quartz:app:1", run.id());
      assertSame(run.context(), Cronwatch.current(), "current in the opening thread");
      assertEquals(RunStatus.RUNNING, cw.getRun("quartz:app:1").status());
      Cronwatch.current().log("working");
      m.clock().advance(2000);
      Run done = run.close(null);
      assertNull(Cronwatch.current(), "put back as it was");
      assertFalse(run.isOpen());
      assertEquals(RunStatus.OK, done.status());
      assertEquals("working", done.output());
      assertEquals("quartz", done.trigger());
      assertEquals(2000L, done.durationMs());
      Run again = run.close(new IOException("late"));
      assertEquals(RunStatus.RUNNING, again.status(), "a second close does nothing");
      assertEquals(RunStatus.OK, cw.getRun("quartz:app:1").status());
    }
  }

  @Test
  void aClosedFailureIsJudged() throws Exception {
    Support.Made m = Support.make();
    try (Cronwatch cw = m.cw()) {
      Job job = cw.job("listened", JobOptions.builder());
      Run done = job.open(RunOptions.defaults()).close(new IOException("disk full"));
      assertEquals(RunStatus.FAILED, done.status());
      assertTrue(done.error().startsWith("IOException: disk full"), done.error());
      assertEquals(List.of("failed"), m.alerts().types());
    }
  }

  @Test
  void aRunIdNoStoreCouldHoldIsRefused() {
    Support.Made m = Support.make();
    try (Cronwatch cw = m.cw()) {
      Job job = cw.job("x", JobOptions.builder());
      CronwatchException e =
          assertThrows(
              CronwatchException.class, () -> job.open(RunOptions.defaults().withId("pgcron:1")));
      assertTrue(
          e.getMessage().contains("run() cannot take a run id starting with"), e.getMessage());
      assertThrows(
          CronwatchException.class, () -> job.run(RunOptions.defaults().withId(""), ctx -> {}));
    }
  }

  /** A job overdue with missed open, its alert sent. */
  private static Job overdue(Support.Made m) {
    Job job = m.cw().job("hourly", JobOptions.builder().schedule("0 * * * *").grace("5m"));
    m.cw().check();
    m.clock().advance(2 * HOUR);
    m.cw().check();
    assertEquals(List.of("missed"), m.alerts().types());
    return job;
  }

  @Test
  void aRunGivenBackLeavesNothingBehind() throws Exception {
    Support.Made m = Support.make();
    try (Cronwatch cw = m.cw()) {
      Job job = overdue(m);
      ObservedRun run = job.open(RunOptions.trigger("scheduled").mayTakeBack());
      String id = run.id();
      assertEquals(RunStatus.RUNNING, cw.getRun(id).status());
      assertTrue(run.takeBack());
      assertNull(cw.getRun(id), "the running row is deleted");
      assertNull(Cronwatch.current());
      assertEquals(List.of("missed"), m.alerts().types(), "missed stays open");
      assertTrue(
          cw.store().getState("hourly").open().containsKey(Condition.MISSED),
          "the state is as it was");
      assertTrue(run.takeBack(), "once only");
    }
  }

  @Test
  void aRunThatMayBeGivenBackClosesMissedWhenItCloses() throws Exception {
    Support.Made m = Support.make();
    try (Cronwatch cw = m.cw()) {
      Job job = overdue(m);
      ObservedRun run = job.open(RunOptions.defaults().mayTakeBack());
      assertTrue(
          cw.store().getState("hourly").open().containsKey(Condition.MISSED),
          "not closed at the start");
      run.close(null);
      assertFalse(cw.store().getState("hourly").open().containsKey(Condition.MISSED));
      assertEquals(List.of("missed", "recovered"), m.alerts().types());
    }
  }

  @Test
  void discardWhenTakesBackARunAndThrowsAsItCame() throws Exception {
    Support.Made m = Support.make();
    try (Cronwatch cw = m.cw()) {
      Job job = overdue(m);
      RunOptions options = RunOptions.discardWhen(e -> e instanceof IllegalStateException);
      IllegalStateException e =
          assertThrows(
              IllegalStateException.class,
              () ->
                  job.run(
                      options,
                      ctx -> {
                        throw new IllegalStateException("lock not taken");
                      }));
      assertEquals("lock not taken", e.getMessage());
      assertTrue(cw.runs("hourly", 10).isEmpty(), "no run left behind");
      assertEquals(List.of("missed"), m.alerts().types(), "nothing judged");
      assertTrue(cw.store().getState("hourly").open().containsKey(Condition.MISSED));

      // Anything else is judged as usual.
      assertThrows(
          IOException.class,
          () ->
              job.run(
                  options,
                  ctx -> {
                    throw new IOException("disk full");
                  }));
      assertEquals(RunStatus.FAILED, cw.runs("hourly", 1).get(0).status());
      assertEquals(List.of("missed", "failed"), m.alerts().types());
    }
  }

  @Test
  void aDiscardPredicateThatThrowsIsReportedAndTheRunRecorded() throws Exception {
    Support.Made m = Support.make();
    try (Cronwatch cw = m.cw()) {
      Job job = cw.job("x", JobOptions.builder());
      RunOptions options =
          RunOptions.discardWhen(
              e -> {
                throw new IllegalArgumentException("predicate broke");
              });
      assertThrows(
          IOException.class,
          () ->
              job.run(
                  options,
                  ctx -> {
                    throw new IOException("disk full");
                  }));
      assertEquals(List.of("discarding x"), m.errors().wheres());
      assertEquals(RunStatus.FAILED, cw.runs("x", 1).get(0).status());
    }
  }

  @Test
  void aStoreThatCannotTakeARunBackRecordsItAsItEnded() throws Exception {
    Support.Wrapped store = new Support.Wrapped();
    Support.Made m = Support.make(b -> b.store(store));
    try (Cronwatch cw = m.cw()) {
      Job job = cw.job("x", JobOptions.builder());
      ObservedRun run = job.open(RunOptions.defaults().mayTakeBack());
      assertFalse(run.takeBack());
      assertEquals(List.of("discarding x"), m.errors().wheres());
      assertTrue(m.errors().messages().get(0).contains("the store cannot take back a run"));
      assertEquals(RunStatus.OK, cw.runs("x", 1).get(0).status(), "recorded as it ended");
    }
  }

  @Test
  void aRowAlreadyMarkedStuckIsLeftAsItIs() throws Exception {
    Support.Made m = Support.make();
    try (Cronwatch cw = m.cw()) {
      Job job = cw.job("x", JobOptions.builder().timeout("1m"));
      ObservedRun run = job.open(RunOptions.defaults().mayTakeBack());
      run.endFunction();
      m.clock().advance(5 * MIN);
      cw.check();
      assertEquals(RunStatus.TIMEOUT, cw.getRun(run.id()).status());
      assertTrue(run.takeBack());
      assertEquals(RunStatus.TIMEOUT, cw.getRun(run.id()).status(), "left as it is");
      assertTrue(
          m.errors().messages().get(0).endsWith("is no longer running; left as it is"),
          m.errors().messages().toString());
    }
  }
}
