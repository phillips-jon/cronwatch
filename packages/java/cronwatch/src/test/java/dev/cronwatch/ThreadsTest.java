package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Support.Made;
import dev.cronwatch.Support.Wrapped;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * The JVM's own cases (packages/java/DESIGN.md, Runs): interrupts inside a run's function and while
 * its run is recorded, {@code interruptAtTimeout}, the current run across threads and on a pooled
 * thread afterwards, many runs on virtual threads, and checks shared by their callers.
 */
class ThreadsTest {
  @Test
  void aRunWhoseThreadIsInterruptedFailsAndThrowsWithTheInterruptStatusSet() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("sleepy");
    CountDownLatch sleeping = new CountDownLatch(1);
    AtomicReference<Throwable> thrown = new AtomicReference<>();
    AtomicBoolean interruptedAfter = new AtomicBoolean();
    Thread t =
        Thread.ofPlatform()
            .start(
                () -> {
                  try {
                    job.run(
                        j -> {
                          sleeping.countDown();
                          Thread.sleep(60_000);
                        });
                  } catch (InterruptedException e) {
                    thrown.set(e);
                    interruptedAfter.set(Thread.currentThread().isInterrupted());
                  }
                });
    sleeping.await();
    t.interrupt();
    t.join(30_000);
    assertTrue(thrown.get() instanceof InterruptedException, String.valueOf(thrown.get()));
    assertTrue(interruptedAfter.get(), "the interrupt status is set again");
    Run run = m.cw().runs("sleepy", 1).get(0);
    assertEquals(RunStatus.FAILED, run.status());
    assertTrue(run.error().startsWith("InterruptedException: sleep interrupted"), run.error());
    assertEquals(List.of("failed"), m.alerts().types());
  }

  @Test
  void aCallerInterruptedWhileItsRunIsRecordedLeavesTheRecordingToComplete() throws Exception {
    Wrapped store = new Wrapped();
    CountDownLatch entered = new CountDownLatch(1);
    CountDownLatch gate = new CountDownLatch(1);
    store.entered = entered;
    store.gate = gate;
    Made m = Support.make(b -> b.store(store));
    Job job = m.cw().job("recorded");
    AtomicBoolean interruptedAfter = new AtomicBoolean();
    AtomicReference<String> result = new AtomicReference<>();
    Thread caller =
        Thread.ofPlatform()
            .start(
                () -> {
                  result.set(job.call(j -> "done"));
                  interruptedAfter.set(Thread.currentThread().isInterrupted());
                });
    entered.await(); // the recording is writing the finish
    caller.interrupt();
    Thread.sleep(50);
    assertTrue(caller.isAlive(), "the caller still waits for the recording");
    store.entered = null;
    store.gate = null;
    gate.countDown();
    caller.join(30_000);
    assertEquals("done", result.get());
    assertTrue(interruptedAfter.get(), "the caller's interrupt status is set again");
    Run run = m.cw().runs("recorded", 1).get(0);
    assertEquals(RunStatus.OK, run.status());
    assertEquals("done", run.output());
  }

  @Test
  void interruptAtTimeoutRecordsTheRunAsACheckWouldMarkItAndSendsTheStuckAlert() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("runaway", JobOptions.builder().timeout(200));
    AtomicBoolean cancelledSeen = new AtomicBoolean();
    AtomicInteger callbacks = new AtomicInteger();
    InterruptedException e =
        assertThrows(
            InterruptedException.class,
            () ->
                job.run(
                    RunOptions.interruptingAtTimeout(),
                    j -> {
                      j.onCancel(callbacks::incrementAndGet);
                      try {
                        Thread.sleep(60_000);
                      } finally {
                        cancelledSeen.set(j.cancelled());
                      }
                    }));
    assertNotNull(e);
    assertTrue(Thread.interrupted(), "the interrupt status is set again, and cleared here");
    assertTrue(cancelledSeen.get());
    Support.await("the cancel callback", () -> callbacks.get() == 1);
    Run run = m.cw().runs("runaway", 1).get(0);
    assertEquals(RunStatus.TIMEOUT, run.status());
    assertEquals("Still running after 200ms; marked as timed out", run.error());
    assertEquals(List.of("stuck"), m.alerts().types());
  }

  @Test
  void withoutInterruptAtTimeoutTheFunctionIsOnlyMarkedCancelled() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("patient", JobOptions.builder().timeout(100));
    AtomicInteger callbacks = new AtomicInteger();
    boolean cancelled =
        job.call(
            j -> {
              j.onCancel(callbacks::incrementAndGet);
              long deadline = System.nanoTime() + 30_000_000_000L;
              while (!j.cancelled() && System.nanoTime() < deadline) {
                Thread.sleep(10);
              }
              return j.cancelled();
            });
    assertTrue(cancelled);
    assertFalse(Thread.currentThread().isInterrupted());
    Support.await("the cancel callback", () -> callbacks.get() == 1);
    assertEquals(RunStatus.OK, m.cw().runs("patient", 1).get(0).status());
    // A callback registered after the timeout is called at once.
    AtomicInteger late = new AtomicInteger();
    job.run(
        j -> {
          while (!j.cancelled()) {
            Thread.sleep(10);
          }
          j.onCancel(late::incrementAndGet);
        });
    Support.await("the late callback", () -> late.get() == 1);
  }

  @Test
  void theCurrentRunCrossesWrapAndIsGoneFromAPooledThreadAfterward() throws Exception {
    Made m = Support.make();
    ExecutorService pool = Executors.newSingleThreadExecutor();
    try {
      Future<JobContext[]> seen =
          pool.submit(
              () -> {
                JobContext[] out = new JobContext[3];
                m.cw()
                    .run(
                        "pooled",
                        j -> {
                          out[0] = Cronwatch.current();
                          Thread other =
                              Thread.ofPlatform()
                                  .start(
                                      j.wrap(
                                          () -> {
                                            out[1] = Cronwatch.current();
                                            Cronwatch.current().log("from another thread");
                                          }));
                          other.join();
                          try (ExecutorService virtual =
                              Executors.newVirtualThreadPerTaskExecutor()) {
                            out[2] = virtual.submit(j.wrap(() -> Cronwatch.current())).get();
                          }
                        });
                return out;
              });
      JobContext[] got = seen.get();
      assertNotNull(got[0]);
      assertSame(got[0], got[1]);
      assertSame(got[0], got[2]);
      assertEquals("from another thread", m.cw().runs("pooled", 1).get(0).output());
      assertNull(pool.submit(Cronwatch::current).get(), "no run left on the pooled thread");
    } finally {
      pool.shutdown();
    }
    // A thread the job starts without wrap has no run of its own.
    AtomicReference<JobContext> bare = new AtomicReference<>();
    m.cw()
        .run(
            "bare",
            j -> {
              Thread t = Thread.ofVirtual().start(() -> bare.set(Cronwatch.current()));
              t.join();
            });
    assertNull(bare.get());
  }

  @Test
  void nestedRunsPutTheOuterRunBack() {
    Made m = Support.make();
    List<String> seen = new ArrayList<>();
    m.cw()
        .run(
            "outer",
            j -> {
              m.cw().run("inner", k -> seen.add(Cronwatch.current().name()));
              seen.add(Cronwatch.current().name());
            });
    assertEquals(List.of("inner", "outer"), seen);
    assertNull(Cronwatch.current());
  }

  @Test
  void manyRunsAtOnceOnVirtualThreadsAreEachRecorded() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("wide");
    int n = 200;
    try (ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      List<Future<String>> runs = new ArrayList<>();
      for (int i = 0; i < n; i++) {
        String text = "run " + i;
        runs.add(
            pool.submit(
                () ->
                    job.call(
                        j -> {
                          Thread.sleep(5);
                          return text;
                        })));
      }
      for (Future<String> f : runs) {
        assertTrue(f.get().startsWith("run "));
      }
    }
    List<Run> recorded = m.cw().runs("wide", 500);
    assertEquals(n, recorded.size());
    assertTrue(recorded.stream().allMatch(r -> r.status().equals(RunStatus.OK)));
    assertEquals(List.of(), m.errors().wheres());
  }

  /** A source a check blocks on until the test lets it go, counting the checks. */
  private static final class Held implements Source {
    final CountDownLatch entered = new CountDownLatch(1);
    final CountDownLatch release = new CountDownLatch(1);
    final AtomicInteger syncs = new AtomicInteger();

    @Override
    public String name() {
      return "held";
    }

    @Override
    public List<Alert> sync(Cronwatch cronwatch) throws InterruptedException {
      syncs.incrementAndGet();
      entered.countDown();
      release.await();
      return List.of();
    }
  }

  @Test
  void callersShareOneCheckAndAnInterruptedCallerLeavesItToTheOthers() throws Exception {
    Held held = new Held();
    Made m = Support.make(b -> b.source(held));
    try (ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      Future<CheckResult> a = pool.submit(() -> m.cw().check());
      held.entered.await();
      AtomicReference<@Nullable Thread> second = new AtomicReference<>();
      Future<CheckResult> b =
          pool.submit(
              () -> {
                second.set(Thread.currentThread());
                return m.cw().check();
              });
      AtomicReference<Throwable> interrupted = new AtomicReference<>();
      AtomicBoolean statusSet = new AtomicBoolean();
      Thread waiting =
          Thread.ofPlatform()
              .start(
                  () -> {
                    try {
                      m.cw().check();
                    } catch (CronwatchException e) {
                      interrupted.set(e);
                      statusSet.set(Thread.currentThread().isInterrupted());
                    }
                  });
      // Both callers are waiting on the check before it is let go, not merely started.
      Support.await("the second caller to join the check", () -> parked(second.get()));
      Support.await("the third caller to join the check", () -> parked(waiting));
      waiting.interrupt();
      waiting.join(30_000);
      assertTrue(interrupted.get() instanceof CronwatchException);
      assertTrue(statusSet.get(), "the waiting caller's interrupt status is set again");
      held.release.countDown();
      assertSame(a.get(), b.get(), "one check, one answer");
    }
    assertEquals(1, held.syncs.get());
    m.cw().check();
    assertEquals(2, held.syncs.get(), "the next call runs a new check");
  }

  /** Whether {@code t} has started and is parked, as a caller waiting on a shared check is. */
  private static boolean parked(@Nullable Thread t) {
    return t != null && t.getState() == Thread.State.WAITING;
  }

  @Test
  void aCheckThatThrowsIsThatChecksAndTheNextOneRunsAgain() {
    Wrapped store = new Wrapped();
    Made m = Support.make(b -> b.store(store));
    m.cw().job("j");
    store.broken.add("runningRuns");
    CronwatchException e = assertThrows(CronwatchException.class, () -> m.cw().check());
    assertEquals(CronwatchException.Kind.STORE, e.kind());
    assertTrue(e.getMessage().contains("store down: runningRuns"), e.getMessage());
    store.broken.clear();
    assertEquals(1, m.cw().check().jobs().size());
  }

  /** What the shutdown hook does as the JVM stops, run here without stopping it. */
  private static void runTheShutdownHook(Cronwatch cw) throws ReflectiveOperationException {
    java.lang.reflect.Field field = Cronwatch.class.getDeclaredField("runs");
    field.setAccessible(true);
    ((Runs) field.get(cw)).shutdown();
  }

  /**
   * The .NET port's case: a run id given again while its first run is open (a message delivered
   * twice) leaves the first on the shutdown hook's list, whichever function returns first.
   */
  @Test
  void aRunIdGivenAgainWhileItsFirstRunIsOpenLeavesTheFirstForTheShutdownHook() throws Exception {
    for (boolean secondEndsFirst : List.of(false, true)) {
      Wrapped store = new Wrapped();
      Made m = Support.make(b -> b.store(store));
      Job job = m.cw().job("dup");
      RunOptions same = RunOptions.trigger("queue").withId("same");
      CountDownLatch entered = new CountDownLatch(1);
      CountDownLatch enteredAgain = new CountDownLatch(1);
      CountDownLatch gate = new CountDownLatch(1);
      CountDownLatch secondGate = new CountDownLatch(1);
      Thread first =
          Support.background(
              () ->
                  job.run(
                      same,
                      j -> {
                        entered.countDown();
                        gate.await();
                      }));
      entered.await();
      Thread second =
          Support.background(
              () ->
                  job.run(
                      same,
                      j -> {
                        enteredAgain.countDown();
                        secondGate.await();
                      }));
      enteredAgain.await();
      if (secondEndsFirst) {
        // Its finish is written over the first's row; the first stays listed all the same.
        secondGate.countDown();
        second.join();
        java.lang.reflect.Field field = Cronwatch.class.getDeclaredField("core");
        field.setAccessible(true);
        Runs.OpenRun listed = ((Core) field.get(m.cw())).open.get("same");
        assertNotNull(listed, "the first run is still listed");
        assertTrue(listed.begun.get(), "and it is the first, whose row was written");
      } else {
        runTheShutdownHook(m.cw());
        Run run = store.inner.getRun("same");
        assertNotNull(run);
        assertEquals(RunStatus.FAILED, run.status());
        assertEquals(Runs.SHUTDOWN_ERROR, run.error());
      }
      gate.countDown();
      secondGate.countDown();
      first.join();
      second.join();
    }
  }
}
