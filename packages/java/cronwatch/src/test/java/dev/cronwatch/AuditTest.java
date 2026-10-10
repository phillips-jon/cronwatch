package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Support.Made;
import dev.cronwatch.Support.Wrapped;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

/**
 * The Rust audit's cases for the core client (packages/rust/cronwatch/tests/audit.rs), in their
 * Java form: an exception whose message throws, an expect check that throws, a store that throws
 * while recording, the interval's bounds and a long check, a foreign row's far times, every channel
 * given kept, and defaults refusing a field set by name.
 */
class AuditTest {
  /** An exception whose message cannot be read. */
  private static final class Grumpy extends RuntimeException {
    private static final long serialVersionUID = 1L;

    @Override
    public String getMessage() {
      throw new IllegalStateException("no words");
    }
  }

  @Test
  void anExceptionWhoseMessageThrowsStillFailsItsRun() {
    Made m = Support.make();
    Job job = m.cw().job("grumpy");
    assertThrows(
        Grumpy.class,
        () ->
            job.run(
                j -> {
                  throw new Grumpy();
                }));
    Run run = m.cw().runs("grumpy", 1).get(0);
    assertEquals(RunStatus.FAILED, run.status());
    assertTrue(run.error().startsWith("Grumpy"), run.error());
  }

  @Test
  void anExpectCheckThatThrowsFailsTheRun() {
    Made m = Support.make();
    Job job =
        m.cw()
            .job(
                "picky",
                JobOptions.builder()
                    .expectThat(
                        out -> {
                          throw new IllegalStateException("cannot read it");
                        }));
    job.call(j -> "output");
    Run run = m.cw().runs("picky", 1).get(0);
    assertEquals(RunStatus.FAILED, run.status());
    assertEquals("Output check threw: cannot read it", run.error());
    assertEquals("custom function", job.definition().expect());
  }

  @Test
  void aStoreThatThrowsWhileRecordingIsReported() {
    Wrapped store = new Wrapped();
    Made m = Support.make(b -> b.store(store));
    Job job = m.cw().job("x");
    store.broken.add("updateRunIf");
    job.run(j -> {});
    assertTrue(m.errors().wheres().contains("recording x"), m.errors().wheres().toString());
    assertTrue(m.errors().messages().contains("store down: updateRunIf"));
  }

  /** A source that counts checks and can hold the first one. */
  private static final class Counting implements Source {
    final AtomicInteger syncs = new AtomicInteger();
    final CountDownLatch release = new CountDownLatch(1);
    final CountDownLatch entered = new CountDownLatch(1);
    volatile boolean hold;

    @Override
    public String name() {
      return "counting";
    }

    @Override
    public List<Alert> sync(Cronwatch cronwatch) throws InterruptedException {
      syncs.incrementAndGet();
      entered.countDown();
      if (hold) {
        release.await();
      }
      return List.of();
    }
  }

  @Test
  void startHoldsItsIntervalAtTheSdksLongest() throws Exception {
    Counting source = new Counting();
    Made m =
        Support.make(
            b -> {
              b.source(source);
              b.timings.firstCheckMs = 20;
            });
    try (Cronwatch cw = m.cw()) {
      cw.startChecking(Duration.ofDays(100_000));
      Support.await("the first check", () -> source.syncs.get() == 1);
    }
  }

  @Test
  void aLongCheckIsNotFollowedByTheTicksItMissed() throws Exception {
    Counting source = new Counting();
    source.hold = true;
    Made m =
        Support.make(
            b -> {
              b.source(source);
              b.timings.firstCheckMs = 20;
              b.timings.minIntervalMs = 100;
            });
    try (Cronwatch cw = m.cw()) {
      cw.startChecking(Duration.ofMillis(100));
      source.entered.await();
      // The first check waits on the source through several ticks, which share it.
      TimeUnit.MILLISECONDS.sleep(600);
      assertEquals(1, source.syncs.get());
      source.hold = false;
      long released = System.nanoTime();
      source.release.countDown();
      TimeUnit.MILLISECONDS.sleep(50);
      int syncs = source.syncs.get();
      // One tick per interval that has really passed (a slow machine sleeps longer than asked),
      // where the ticks it missed would all come at once.
      long intervals = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - released) / 100;
      assertTrue(syncs <= 2 + intervals, "no burst of the ticks it missed: " + syncs);
      Support.await("the next tick on the interval", () -> source.syncs.get() >= 2);
      cw.stop();
    }
  }

  @Test
  void aForeignRowsFarTimesDoNotFailTheCheck() throws Exception {
    Made m = Support.make();
    m.cw().job("far", JobOptions.builder().schedule("every 5m")).run(j -> {});
    m.cw().job("old").run(j -> {});
    Run far = m.cw().runs("far", 1).get(0);
    m.cw()
        .store()
        .insertRun(
            new Run(
                "far-future",
                "far",
                RunStatus.OK,
                Long.MAX_VALUE - 1,
                far.finishedAt(),
                far.durationMs(),
                null,
                null,
                Metrics.empty(),
                "run"));
    m.cw().store().insertRun(Run.running("long-ago", "old", Long.MIN_VALUE + 1, "run"));
    CheckResult result = m.cw().check();
    assertEquals(2, result.jobs().size());
    assertEquals(List.of("stuck"), m.alerts().types(), "the stuck alert is sent");
    assertTrue(m.alerts().alerts.get(0).message().contains("before 0001-01-01 00:00:00 UTC"));
    // The check's prune then takes the run away, as it is older than the retention.
    Run marked = m.alerts().alerts.get(0).run();
    assertEquals(RunStatus.TIMEOUT, marked.status());
    assertEquals(9_007_199_254_740_991L, marked.durationMs());
    assertEquals(2, m.cw().jobs().size());
    assertEquals(List.of(), m.errors().wheres());
  }

  @Test
  void alertKeepsEveryChannelGiven() throws Exception {
    List<String> seen = new CopyOnWriteArrayList<>();
    try (Cronwatch cw =
        Cronwatch.builder()
            .alert(Channel.of("console", (a, ctx) -> seen.add("console")))
            .alert(Channel.of("second", (a, ctx) -> seen.add("second")))
            .noShutdownHook()
            .build()) {
      assertThrows(
          IllegalStateException.class,
          () ->
              cw.run(
                  "two",
                  j -> {
                    throw new IllegalStateException("down");
                  }));
      Support.await("both channels", () -> seen.size() == 2);
      assertEquals(List.of("console", "second"), seen.stream().sorted().toList());
    }
  }

  @Test
  void defaultsRefuseAFieldSetByName() {
    CronwatchException e =
        assertThrows(
            CronwatchException.class,
            () ->
                Cronwatch.builder()
                    .defaults(JobOptions.builder().field("schedule", "@hourly"))
                    .build());
    assertEquals(
        "defaults takes grace, timeout, timezone, and failuresBeforeAlert, not schedule",
        e.getMessage());
    Cronwatch.builder()
        .defaults(JobOptions.builder().field("grace", "5m"))
        .noShutdownHook()
        .build()
        .close();
  }
}
