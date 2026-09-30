package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Support.Capture;
import dev.cronwatch.Support.Cas;
import dev.cronwatch.Support.Clock;
import dev.cronwatch.Support.Errors;
import dev.cronwatch.Support.Wrapped;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.function.Function;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * The SDK's {@code concurrency.test.ts}, ported: two clients sharing one store, as two processes
 * do, keep each other's state updates through the version compare-and-set.
 */
class ConcurrencyTest {
  /** A store whose state reads take a while, as over a network. */
  private static Wrapped slowReads(Store store, Cas cas) {
    Wrapped w = new Wrapped(store);
    w.readDelayMs = 25;
    w.cas = cas;
    return w;
  }

  private record Raced(JobState state, List<String> types) {}

  /**
   * Two clients, as two processes sharing one store, each failing the job once at the same time.
   */
  private static Raced race(Store a, Store b, Store reader) throws Exception {
    Clock clock = new Clock();
    Capture one = new Capture();
    Capture two = new Capture();
    try (Cronwatch first = Support.builder(clock, one, new Errors()).store(a).build();
        Cronwatch second = Support.builder(clock, two, new Errors()).store(b).build()) {
      JobOptions options = JobOptions.builder().failuresBeforeAlert(2);
      first.run("shared", options, j -> {});
      second.job("shared", options);
      try (ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
        List<Future<?>> runs = new ArrayList<>();
        for (Cronwatch cw : List.of(first, second)) {
          runs.add(
              pool.submit(
                  () ->
                      assertThrows(
                          IllegalStateException.class,
                          () ->
                              cw.run(
                                  "shared",
                                  j -> {
                                    throw new IllegalStateException("x");
                                  }))));
        }
        for (Future<?> f : runs) {
          f.get();
        }
      }
      List<String> types = new ArrayList<>(one.types());
      types.addAll(two.types());
      JobState state = reader.getState("shared");
      assertNotNull(state);
      return new Raced(state, types);
    }
  }

  @Test
  void twoProcessesFailingAJobAtOnceCountBothAndAlertOnce() throws Exception {
    MemoryStore store = new MemoryStore();
    Raced r = race(slowReads(store, Cas.NORMAL), slowReads(store, Cas.NORMAL), store);
    assertEquals(2, r.state().consecutiveFailures(), "neither failure was lost");
    assertEquals(List.of(Condition.FAILED), List.copyOf(r.state().open().keySet()));
    assertEquals(List.of("failed"), r.types(), "one alert, from whichever counted the second");
    assertTrue(r.state().countedVersion() >= 3, "every write bumped the version");
  }

  @Test
  void theSameRaceThroughTwoSqliteConnectionsToOneFile(@TempDir Path dir) throws Exception {
    Path file = dir.resolve("cw.db");
    Store reader = StartFinishTest.sqlite(file);
    Raced r =
        race(
            slowReads(StartFinishTest.sqlite(file), Cas.NORMAL),
            slowReads(StartFinishTest.sqlite(file), Cas.NORMAL),
            reader);
    reader.close();
    assertEquals(2, r.state().consecutiveFailures());
    assertEquals(List.of("failed"), r.types());
  }

  @Test
  void aStoreWithoutCompareAndSetStillWorksButCannotKeepTwoProcessesApart() throws Exception {
    MemoryStore store = new MemoryStore();
    Raced r = race(slowReads(store, Cas.MISSING), slowReads(store, Cas.MISSING), store);
    // The documented caveat: the later write wins, so one failure is lost.
    assertEquals(1, r.state().consecutiveFailures());
    assertEquals(List.of(), r.types());
  }

  @Test
  void aSilenceMadeByOneProcessSurvivesAnotherProcessesRun() throws Exception {
    MemoryStore store = new MemoryStore();
    Clock clock = new Clock();
    try (Cronwatch runner =
            Support.builder(clock, new Capture(), new Errors())
                .store(slowReads(store, Cas.NORMAL))
                .build();
        Cronwatch admin =
            Support.builder(clock, new Capture(), new Errors())
                .store(slowReads(store, Cas.NORMAL))
                .build();
        ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      runner.run("s", j -> {});
      Future<?> run =
          pool.submit(
              () ->
                  assertThrows(
                      IllegalStateException.class,
                      () ->
                          runner.run(
                              "s",
                              j -> {
                                throw new IllegalStateException("x");
                              })));
      Future<?> silence = pool.submit(() -> admin.silence("s", "1h"));
      run.get();
      silence.get();
      JobState state = store.getState("s");
      assertNotNull(state.silencedUntil(), "the silence was not overwritten");
      assertEquals(1, state.consecutiveFailures(), "nor was the failure");
    }
  }

  @Test
  void anUpdateThatKeepsLosingGivesUpAndReportsAndTheRunStillFinishes() {
    Wrapped contested = new Wrapped();
    contested.cas = Cas.REFUSED;
    Support.Made m = Support.make(b -> b.store(contested));
    assertThrows(
        IllegalStateException.class,
        () ->
            m.cw()
                .run(
                    "busy",
                    j -> {
                      throw new IllegalStateException("x");
                    }));
    assertEquals(List.of("evaluating busy"), m.errors().wheres());
    assertEquals(RunStatus.FAILED, m.cw().runs("busy", 1).get(0).status());
  }

  private static JobOptions every5m() {
    return JobOptions.builder().schedule("every 5m");
  }

  /** The schedule the store holds for a job, or "null". */
  private static String schedule(Store store, String name) throws Exception {
    StoredJob job = store.getJob(name);
    assertNotNull(job, name + " is not stored");
    return String.valueOf(job.definition().schedule());
  }

  @Test
  void aHandleKeptFromAnEarlierDeclarationWritesTheOneThatStandsNotItsOwn() throws Exception {
    MemoryStore store = new MemoryStore();
    Support.Made m = Support.make(b -> b.store(store));
    Job earlier = m.cw().job("a");
    m.cw().job("a", every5m());
    earlier.run(j -> {});
    assertEquals("every 5m", schedule(store, "a"));
    m.cw().check();
    assertEquals("every 5m", schedule(store, "a"));
  }

  // The .NET port's: the declaration that stands is in the store already, and stays there.
  @Test
  void aHandleKeptFromAnEarlierDeclarationDoesNotWriteOverTheOneThatStands() throws Exception {
    MemoryStore store = new MemoryStore();
    Support.Made m = Support.make(b -> b.store(store));
    Job earlier = m.cw().job("a");
    m.cw().job("a", every5m());
    assertTrue(m.cw().syncJob("a"));
    earlier.run(j -> {});
    assertEquals("every 5m", schedule(store, "a"));
    m.cw().check();
    assertEquals("every 5m", schedule(store, "a"));
  }

  @Test
  void aHandleWhoseJobWasForgottenWritesItsOwnDefinition() throws Exception {
    MemoryStore store = new MemoryStore();
    Support.Made m = Support.make(b -> b.store(store));
    Job handle = m.cw().job("a", every5m());
    m.cw().forget("a");
    handle.run(j -> {});
    assertEquals("every 5m", schedule(store, "a"));
  }

  @Test
  void aDeclarationMadeWhileTheEarlierOneIsBeingWrittenIsStillToBeWritten() throws Exception {
    MemoryStore inner = new MemoryStore();
    Wrapped store = new Wrapped(inner);
    CountDownLatch gate = new CountDownLatch(1);
    store.upsertGate.set(gate);
    Support.Made m = Support.make(b -> b.store(store));
    Thread run = Support.background(() -> m.cw().job("a").run(j -> {}));
    store.upsertEntered.await();
    m.cw().job("a", every5m());
    gate.countDown();
    run.join();
    m.cw().check();
    assertEquals("every 5m", schedule(inner, "a"));
  }

  /**
   * A run of a job declared without a schedule, held in the write of that declaration while the job
   * is declared again with one and {@code later} is called; then the run is let go. Returns what
   * {@code later} answered and the schedule the store ends with.
   */
  private static List<Object> laterWrite(Function<Cronwatch, Object> later) throws Exception {
    MemoryStore inner = new MemoryStore();
    Wrapped store = new Wrapped(inner);
    CountDownLatch gate = new CountDownLatch(1);
    store.upsertGate.set(gate);
    Support.Made m = Support.make(b -> b.store(store));
    Thread run = Support.background(() -> m.cw().job("a").run(j -> {}));
    store.upsertEntered.await();
    m.cw().job("a", every5m());
    FutureTask<Object> answer = new FutureTask<>(() -> later.apply(m.cw()));
    Thread second = Thread.ofVirtual().start(answer);
    // Were the later write not to wait its turn, it would land here, under the earlier one.
    Support.await(
        "the later write to end or to wait its turn",
        () -> !second.isAlive() || second.getState() == Thread.State.WAITING);
    gate.countDown();
    run.join();
    return List.of(answer.get(), schedule(inner, "a"));
  }

  @Test
  void aDeclarationsWriteWaitsForTheEarlierOnesSoTheLaterOneStays() throws Exception {
    assertEquals(
        List.of("every 5m", "every 5m"),
        laterWrite(cw -> String.valueOf(cw.jobSummary("a").definition().schedule())));
  }

  @Test
  void syncJobWaitsForAnEarlierWriteOfTheDeclarationSoItsOwnStays() throws Exception {
    assertEquals(List.of(true, "every 5m"), laterWrite(cw -> cw.syncJob("a")));
  }
}
