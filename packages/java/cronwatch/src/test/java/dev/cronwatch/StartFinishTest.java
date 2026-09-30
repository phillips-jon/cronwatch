package dev.cronwatch;

import static dev.cronwatch.Support.HOUR;
import static dev.cronwatch.Support.MIN;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Support.Capture;
import dev.cronwatch.Support.Clock;
import dev.cronwatch.Support.Errors;
import dev.cronwatch.Support.Made;
import dev.cronwatch.Support.Wrapped;
import dev.cronwatch.jdbc.Servers;
import dev.cronwatch.jdbc.SqlStore;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.sqlite.SQLiteDataSource;

/**
 * The SDK's {@code start-finish.test.ts}, ported: runs that span calls, started with {@code start},
 * found again with {@code resume}, flushed and finished, perhaps by another client on the same
 * store: the memory store, SQLite, and Postgres when {@code CRONWATCH_TEST_PG} is set.
 */
class StartFinishTest {
  private static String last(List<String> messages) {
    return messages.get(messages.size() - 1);
  }

  @Test
  void startRecordsARunningRunAndFinishRecordsItOk() {
    Made m = Support.make();
    Job job = m.cw().job("sync", JobOptions.builder().schedule("@hourly"));
    RunHandle run = job.start(StartOptions.trigger("queue"));
    assertEquals("sync", run.job());
    assertTrue(run.isActive());
    Run stored = m.cw().getRun(run.id());
    assertEquals(RunStatus.RUNNING, stored.status());
    assertEquals("queue", stored.trigger());
    run.log("imported 12 rows");
    run.metric("rows", 12);
    m.clock().advance(90_000);
    Run finished = run.finish();
    assertEquals(RunStatus.OK, finished.status());
    assertEquals(90_000L, finished.durationMs());
    assertFalse(run.isActive());
    Run recorded = m.cw().runs("sync", 50).get(0);
    assertEquals(RunStatus.OK, recorded.status());
    assertEquals("imported 12 rows", recorded.output());
    assertEquals("{\"rows\":12}", recorded.metrics().toJson());
    assertEquals(List.of(), m.alerts().types());
    assertEquals(JobHealth.HEALTHY, m.cw().jobSummary("sync").health());
  }

  @Test
  void failRecordsAFailureAndAlertsOnce() {
    Made m = Support.make();
    Job job = m.cw().job("import", JobOptions.builder().failuresBeforeAlert(2));
    job.start().fail(new IllegalStateException("api down"));
    Run run = job.start().fail(new IllegalStateException("still down"));
    assertEquals(RunStatus.FAILED, run.status());
    assertTrue(run.error().startsWith("IllegalStateException: still down"), run.error());
    assertEquals(List.of("failed"), m.alerts().types());
    job.start(StartOptions.trigger("retry")).finish();
    assertEquals(List.of("failed", "recovered"), m.alerts().types());
  }

  @Test
  void aSecondFinishIsIgnoredAndReportedNotThrown() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("once");
    RunHandle run = job.start();
    ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor();
    Future<Run> a = pool.submit(() -> run.fail(new IllegalStateException("boom")));
    Future<Run> b = pool.submit(() -> run.finish());
    Run first = a.get();
    Run second = b.get();
    pool.close();
    // Whichever call came first records; the other is ignored.
    assertTrue((first == null) != (second == null), "exactly one recorded");
    assertNull(run.finish());
    assertEquals(1, m.cw().runs("once", 50).size());
    assertEquals(2, m.errors().entries.size());
    assertTrue(
        m.errors().messages().get(0).contains("was already finished by this handle; ignored"));
    assertEquals("finishing once", m.errors().wheres().get(0));
  }

  @Test
  void aSecondFinishOfAFailureIsIgnored() {
    Made m = Support.make();
    Job job = m.cw().job("once");
    RunHandle run = job.start();
    Run failed = run.fail(new IllegalStateException("boom"));
    assertEquals(RunStatus.FAILED, failed.status());
    assertNull(run.finish());
    assertEquals(List.of("failed"), m.alerts().types());
    assertEquals(RunStatus.FAILED, m.cw().runs("once", 1).get(0).status());
  }

  @Test
  void startWithAnIdTwiceRecordsOneRunAndReturnsAHandleOnIt() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("inngest-fn");
    ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor();
    Callable<RunHandle> start = () -> job.start(StartOptions.id("01HX-run"));
    Future<RunHandle> one = pool.submit(start);
    Future<RunHandle> two = pool.submit(start);
    assertEquals("01HX-run", one.get().id());
    assertEquals("01HX-run", two.get().id());
    pool.close();
    RunHandle again = job.start(StartOptions.id("01HX-run").withTrigger("ignored"));
    assertTrue(again.isActive());
    assertEquals(1, m.cw().runs("inngest-fn", 50).size());
    assertEquals("start", m.cw().getRun("01HX-run").trigger());
    again.finish("done");
    // Finished elsewhere: this handle's finish is a reported no-op.
    assertNull(one.get().finish());
    assertTrue(last(m.errors().messages()).contains("already finished as ok; ignored"));
    RunHandle late = job.start(StartOptions.id("01HX-run"));
    assertFalse(late.isActive());
    assertNull(late.finish());
    assertEquals(1, m.cw().runs("inngest-fn", 50).size());
    assertTrue(
        assertThrows(
                CronwatchException.class,
                () -> m.cw().job("other").start(StartOptions.id("01HX-run")))
            .getMessage()
            .contains("belongs to job \"inngest-fn\""));
    assertTrue(
        assertThrows(CronwatchException.class, () -> job.start(StartOptions.id("")))
            .getMessage()
            .contains("run id of 1 to 200 characters"));
    assertTrue(
        assertThrows(CronwatchException.class, () -> job.start(StartOptions.id("pgcron:1")))
            .getMessage()
            .contains("which the pg_cron source uses"));
    // No store could hold a NUL (Postgres refuses it), so such an id is refused wherever one is
    // taken.
    assertTrue(
        assertThrows(CronwatchException.class, () -> job.start(StartOptions.id("01HX\u0000run")))
            .getMessage()
            .contains("start() cannot take a run id containing a NUL character"));
    assertTrue(
        assertThrows(CronwatchException.class, () -> job.resume("01HX\u0000run"))
            .getMessage()
            .contains("resume() cannot take a run id containing a NUL character"));
    Run nul =
        new Run(
            "x\u0000y", "inngest-fn", RunStatus.OK, 1, 2L, 1L, null, null, Metrics.empty(), "run");
    assertTrue(
        assertThrows(CronwatchException.class, () -> m.cw().recordRun(nul))
            .getMessage()
            .contains("recordRun: run ids cannot contain a NUL character"));
    assertEquals(1, m.cw().runs("inngest-fn", 50).size());
  }

  /** Two clients over one store, or over two stores on one SQLite file. */
  private static void resumeInASecondClient(Store a, Store b) {
    Clock clock = new Clock();
    Capture alerts = new Capture();
    Errors errors = new Errors();
    try (Cronwatch first = Support.builder(clock, alerts, errors).store(a).build();
        Cronwatch second = Support.builder(clock, alerts, errors).store(b).build()) {
      RunHandle started =
          first
              .job("digest", JobOptions.builder().expect("sent").budget("emails", 100))
              .start(StartOptions.id("evt-1"));
      started.log("loaded 40 recipients");
      started.log("token=abc123");
      started.metric("recipients", 40);
      started.flush();
      Run midway = first.getRun("evt-1");
      assertEquals(RunStatus.RUNNING, midway.status());
      assertEquals("loaded 40 recipients\ntoken=[redacted]", midway.output());

      clock.advance(5 * MIN);
      second.job("digest", JobOptions.builder().expect("sent").budget("emails", 100));
      RunHandle resumed = second.resumeRun("digest", "evt-1");
      assertTrue(resumed.isActive());
      assertEquals(midway.startedAt(), resumed.startedAt());
      resumed.log("sent 40 emails");
      resumed.metric("emails", 40);
      Run run = resumed.finish();
      assertEquals(RunStatus.OK, run.status());
      assertEquals(5 * MIN, run.durationMs());
      Run stored = first.getRun("evt-1");
      assertEquals(RunStatus.OK, stored.status());
      assertEquals("loaded 40 recipients\ntoken=[redacted]\nsent 40 emails", stored.output());
      // As the SDK compares them (deepEqual): Postgres gives JSONB keys back in its own order.
      assertEquals(java.util.Map.of("recipients", 40.0, "emails", 40.0), stored.metrics().asMap());
      assertEquals(List.of(), alerts.types());
      assertEquals(List.of(), errors.wheres());
    }
  }

  @Test
  void resumeInASecondClientOnTheSameMemoryStore() {
    MemoryStore store = new MemoryStore();
    resumeInASecondClient(store, store);
  }

  @Test
  void resumeInASecondClientOnTheSameSqliteFile(@TempDir Path dir) throws Exception {
    Path file = dir.resolve("cw.db");
    Files.createDirectories(dir);
    resumeInASecondClient(sqlite(file), sqlite(file));
  }

  @Test
  void resumeInASecondClientOnTheSamePostgresTables() throws Exception {
    Servers.assume(Servers.Kind.PG);
    String prefix = Servers.prefix();
    try {
      resumeInASecondClient(
          Servers.store(Servers.Kind.PG, prefix), Servers.store(Servers.Kind.PG, prefix));
    } finally {
      Servers.drop(Servers.Kind.PG, prefix);
    }
  }

  static SqlStore sqlite(Path file) {
    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite:" + file);
    return SqlStore.sqlite(ds);
  }

  @Test
  void resumeOfAnUnknownOrFinishedRunReturnsAHandleWhoseFinishIsAReportedNoOp() {
    Made m = Support.make();
    Job job = m.cw().job("webhook");
    RunHandle missing = job.resume("nope");
    assertFalse(missing.isActive());
    assertNull(missing.startedAt());
    missing.log("dropped");
    missing.flush();
    assertNull(missing.finish());
    assertTrue(m.errors().messages().get(0).contains("run nope of webhook was not found; ignored"));
    job.call(j -> "done");
    Run done = m.cw().runs("webhook", 1).get(0);
    RunHandle finished = job.resume(done.id());
    assertFalse(finished.isActive());
    assertNull(finished.fail(new IllegalStateException("late")));
    assertTrue(m.errors().messages().get(1).contains("already finished as ok; ignored"));
    assertEquals(RunStatus.OK, m.cw().runs("webhook", 1).get(0).status());
    assertTrue(
        assertThrows(CronwatchException.class, () -> m.cw().resumeRun("undeclared", "x"))
            .getMessage()
            .contains("not declared"));
  }

  @Test
  void aRunNeverFinishedIsMarkedStuckAfterTheJobsTimeout() {
    Made m = Support.make();
    Job job = m.cw().job("callback", JobOptions.builder().timeout("30m"));
    RunHandle run = job.start();
    m.clock().advance(29 * MIN);
    m.cw().check();
    assertEquals(RunStatus.RUNNING, m.cw().getRun(run.id()).status());
    m.clock().advance(2 * MIN);
    m.cw().check();
    Run stored = m.cw().getRun(run.id());
    assertEquals(RunStatus.TIMEOUT, stored.status());
    assertTrue(stored.error().startsWith("Still running after 30m"), stored.error());
    assertEquals(List.of("stuck"), m.alerts().types());
  }

  @Test
  void aLateSuccessAfterATimeoutMarkRecoversAndALateFailureDoesNotCountTwice() {
    Made m = Support.make();
    Job job = m.cw().job("slowpoke", JobOptions.builder().timeout("10m").failuresBeforeAlert(2));
    RunHandle first = job.start();
    m.clock().advance(11 * MIN);
    m.cw().check();
    assertEquals(List.of(), m.alerts().types());
    Run failed = first.fail(new IllegalStateException("gave up"));
    assertEquals(RunStatus.FAILED, failed.status());
    assertEquals(
        "IllegalStateException: gave up",
        Support.firstLine(m.cw().getRun(first.id()).error()),
        "the run keeps its real error");
    assertEquals(List.of(), m.alerts().types(), "the late failure did not count as a second one");

    RunHandle second = job.start();
    m.clock().advance(11 * MIN);
    m.cw().check();
    assertEquals(List.of("stuck"), m.alerts().types());
    RunHandle resumed = m.cw().resumeRun("slowpoke", second.id());
    assertTrue(resumed.isActive(), "a run marked timeout can still be finished late");
    Run late = resumed.finish();
    assertEquals(RunStatus.OK, late.status());
    assertEquals(List.of("stuck", "recovered"), m.alerts().types());
    assertNull(second.finish(), "the handle that started it sees it finished elsewhere");
  }

  @Test
  void expectIsAppliedAtFinishToTheLoggedLinesOrTheStringPassed() throws Exception {
    Made m = Support.make();
    Job job = m.cw().job("export", JobOptions.builder().expectMatch("wrote \\d+ files"));
    RunHandle quiet = job.start();
    Run run = quiet.finish("nothing to do");
    assertEquals(RunStatus.FAILED, run.status());
    assertEquals("nothing to do", run.output());
    assertTrue(run.error().contains("did not match"), run.error());
    assertEquals(List.of("failed"), m.alerts().types());

    RunHandle busy = job.start();
    busy.log("wrote 3 files");
    busy.flush();
    RunHandle resumed = job.resume(busy.id());
    assertEquals(
        RunStatus.OK,
        resumed.finish("uploaded").status(),
        "lines flushed earlier count toward expect");
    assertEquals(List.of("failed", "recovered"), m.alerts().types());

    Run bad = job.start().finish(Support.httpResponse(502));
    assertEquals("HTTP 502 Bad Gateway", bad.error());
  }

  @Test
  void aStoreFailingDuringStartDoesNotThrowAndFinishRecordsOnceTheStoreIsBack() {
    Wrapped store = new Wrapped();
    store.broken.add("insertRun");
    Made m = Support.make(b -> b.store(store));
    Job job = m.cw().job("backup", JobOptions.builder().schedule("@hourly"));
    RunHandle run = job.start();
    assertTrue(run.isActive());
    assertEquals("recording backup", m.errors().wheres().get(0));
    assertNull(m.cw().getRun(run.id()));
    run.log("copied");
    run.flush(); // nothing stored to append to; kept for finish
    store.broken.clear();
    m.clock().advance(HOUR / 2);
    Run finished = run.finish();
    assertEquals(RunStatus.OK, finished.status());
    Run stored = m.cw().getRun(run.id());
    assertEquals(RunStatus.OK, stored.status());
    assertEquals("copied", stored.output());
    assertEquals(HOUR / 2, stored.durationMs());
    assertEquals(List.of(), m.alerts().types());
  }

  @Test
  void aStoreFailingAtFinishIsReportedAndTheHandleCanFinishAgain() {
    Wrapped store = new Wrapped();
    Made m = Support.make(b -> b.store(store));
    Job job = m.cw().job("flaky");
    RunHandle run = job.start();
    run.log("working");
    store.broken.addAll(List.of("getRun", "updateRun", "updateRunIf"));
    run.flush();
    assertEquals("flushing flaky", last(m.errors().wheres()));
    assertNull(run.finish(), "nothing recorded");
    assertTrue(m.errors().wheres().contains("finishing flaky"));
    assertTrue(run.isActive(), "still active, to finish again");
    // The read works but the write fails: still retryable.
    store.broken.remove("getRun");
    assertNull(run.finish());
    assertTrue(run.isActive());
    store.broken.clear();
    assertEquals(RunStatus.RUNNING, m.cw().getRun(run.id()).status(), "nothing written yet");
    Run finished = run.finish();
    assertEquals(RunStatus.OK, finished.status());
    assertEquals("working", finished.output(), "the lines logged before the failures are kept");
    assertFalse(run.isActive());
    assertNull(run.finish(), "finished once only");
  }

  /** A channel whose first send waits at {@code gate}, saying so at {@code sending}. */
  private static Channel held(
      CountDownLatch sending, CountDownLatch gate, List<String> sent, String record) {
    return new Channel() {
      @Override
      public String name() {
        return "held";
      }

      @Override
      public void send(Alert alert, ChannelContext context) throws InterruptedException {
        sending.countDown();
        gate.await();
        sent.add(record.isEmpty() ? alert.job() : record);
      }
    };
  }

  @Test
  void linesFlushedWhileACheckMarksEarlierRunsStuckAreKeptOnTheRunItMarksNext() throws Exception {
    CountDownLatch sending = new CountDownLatch(1);
    CountDownLatch gate = new CountDownLatch(1);
    List<String> sent = new CopyOnWriteArrayList<>();
    Made m = Support.make(b -> b.alerts(List.of(held(sending, gate, sent, ""))));
    RunHandle a = m.cw().job("a", JobOptions.builder().timeout("10m")).start();
    RunHandle b = m.cw().job("b", JobOptions.builder().timeout("10m")).start();
    for (RunHandle h : List.of(a, b)) {
      h.log(h.job() + " earlier");
      h.metric("n", 1);
      h.flush();
    }
    m.clock().advance(11 * MIN);
    Thread check = Support.background(() -> m.cw().check());
    // The first run's stuck alert is being sent; the other run logs, reports and flushes.
    sending.await();
    RunHandle other = m.cw().getRun(a.id()).status().equals(RunStatus.TIMEOUT) ? b : a;
    other.log(other.job() + " flushed");
    other.metric("n", 2);
    other.flush();
    gate.countDown();
    check.join();
    Run stored = m.cw().getRun(other.id());
    assertEquals(RunStatus.TIMEOUT, stored.status());
    assertEquals(other.job() + " earlier\n" + other.job() + " flushed", stored.output());
    assertEquals("{\"n\":2}", stored.metrics().toJson());
    assertEquals(2, sent.size());
  }

  @Test
  void closeWaitsForACheckUnderWayBeforeItClosesTheStore() throws Exception {
    CountDownLatch sending = new CountDownLatch(1);
    CountDownLatch gate = new CountDownLatch(1);
    List<String> order = new CopyOnWriteArrayList<>();
    MemoryStore inner = new MemoryStore();
    Store store =
        (Store)
            java.lang.reflect.Proxy.newProxyInstance(
                Store.class.getClassLoader(),
                new Class<?>[] {Store.class},
                (proxy, method, args) -> {
                  if (method.getName().equals("close")) {
                    order.add("close");
                  }
                  try {
                    return method.invoke(inner, args);
                  } catch (java.lang.reflect.InvocationTargetException e) {
                    throw e.getCause();
                  }
                });
    Clock clock = new Clock();
    Cronwatch.Builder builder =
        Support.builder(clock, new Capture(), new Errors())
            .alerts(List.of(held(sending, gate, order, "send")))
            .store(store);
    // The wait is the check's, not a timer's that could run out first.
    builder.timings.closeWaitMs = HOUR;
    Cronwatch cw = builder.build();
    cw.job("callback", JobOptions.builder().timeout("30m")).start();
    clock.advance(31 * MIN);
    Thread check = Support.background(cw::check);
    sending.await();
    Thread closing = Thread.ofVirtual().start(cw::close);
    Support.await(
        "close to wait for the check",
        () ->
            closing.getState() == Thread.State.WAITING
                || closing.getState() == Thread.State.TIMED_WAITING);
    assertEquals(List.of(), order, "the store is not closed while the check is under way");
    gate.countDown();
    closing.join();
    check.join();
    assertEquals(List.of("send", "close"), order);
  }
}
