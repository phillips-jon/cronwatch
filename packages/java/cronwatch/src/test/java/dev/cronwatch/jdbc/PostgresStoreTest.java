package dev.cronwatch.jdbc;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Alert;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.jdbc.Servers.Kind;
import dev.cronwatch.json.Json;
import dev.cronwatch.storetest.StoreContract;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Test;

/**
 * The store on Postgres, when {@code CRONWATCH_TEST_PG} is set: the shared server tests and the
 * SDK's {@code stores.test.ts} own, as the Go, Rust and Elixir ports have them.
 */
class PostgresStoreTest extends ServerStoreTests {
  @Override
  Kind kind() {
    return Kind.PG;
  }

  @Override
  String dialect() {
    return "postgres";
  }

  private static JobState state(String text) {
    return JobState.fromJson(text);
  }

  @Test
  void theSchemaIsTheSdks() throws Exception {
    String p = prefix();
    SqlStore store = Servers.store(kind(), p);
    store.init();
    store.init();
    List<String> columns =
        column(
            "SELECT table_name || '.' || column_name || ' ' || data_type || ' ' ||"
                + " coalesce(column_default, '') FROM information_schema.columns WHERE table_name"
                + " LIKE '"
                + p
                + "%' ORDER BY table_name, ordinal_position");
    List<String> runs = new ArrayList<>();
    for (String c : columns) {
      if (c.startsWith(p + "runs.")) {
        runs.add(c.substring((p + "runs.").length(), c.indexOf(" ")));
      }
    }
    assertEquals(
        List.of(
            "seq",
            "id",
            "job",
            "status",
            "started_at",
            "finished_at",
            "duration_ms",
            "error",
            "output",
            "metrics",
            "trigger"),
        runs);
    for (String want :
        List.of(
            p + "runs.seq bigint nextval(",
            p + "runs.started_at bigint ",
            p + "runs.metrics jsonb '{}'::jsonb",
            p + "runs.trigger text 'run'::text",
            p + "jobs.definition jsonb ",
            p + "state.state jsonb ")) {
      assertTrue(
          columns.stream().anyMatch(c -> c.startsWith(want)), "no " + want + " among " + columns);
    }
    assertEquals(
        List.of(
            p + "jobs_pkey",
            p + "runs_job_started",
            p + "runs_pkey",
            p + "runs_running",
            p + "state_pkey"),
        column(
            "SELECT indexname FROM pg_indexes WHERE indexname LIKE '"
                + p
                + "%' ORDER BY indexname"));
    List<String> partial =
        column("SELECT indexdef FROM pg_indexes WHERE indexname = '" + p + "runs_running'");
    assertTrue(partial.get(0).endsWith("WHERE (status = 'running'::text)"), partial.toString());
  }

  @Test
  void jsonbKeepsNumbersAndOrdersKeysAsPostgresDoes() throws Exception {
    String p = prefix();
    SqlStore store = Servers.store(kind(), p);
    store.init();
    Run run =
        new Run(
            "r1",
            "nightly",
            RunStatus.OK,
            T0,
            T0 + 1000,
            1000L,
            null,
            "tab\tand \"quotes\" 😀",
            Metrics.fromValue(
                Json.parse("{\"ratio\":0.30000000000000004,\"tiny\":1e-7,\"huge\":1e21}")),
            "run");
    store.insertRun(run);
    Run read = store.getRun("r1");
    assertNotNull(read);
    assertEquals(T0, read.startedAt());
    assertEquals(1000L, read.durationMs());
    assertEquals(run.output(), read.output());
    // JSONB as Postgres orders it: keys by length, then bytes.
    assertEquals(
        "{\"huge\":1e+21,\"tiny\":1e-7,\"ratio\":0.30000000000000004}", read.metrics().toJson());
    // Postgres keeps JSONB numbers as numeric, and writes them out in full.
    assertEquals(
        List.of(
            "{\"huge\": 1000000000000000000000, \"tiny\": 0.0000001, \"ratio\": 0.30000000000000004}"),
        column("SELECT metrics::text FROM " + p + "runs WHERE id = 'r1'"));
    // Bound untyped, the JSON is inferred as jsonb: no cast in the statement, none needed.
    assertEquals(
        List.of("jsonb"), column("SELECT pg_typeof(metrics)::text FROM " + p + "runs LIMIT 1"));

    store.upsertJob(
        Definition.fromJson("{\"name\":\"a\",\"schedule\":\"every 5m\",\"tags\":[\"x\"]}"), 1);
    StoredJob j = store.getJob("a");
    assertNotNull(j);
    assertEquals(
        "{\"name\":\"a\",\"tags\":[\"x\"],\"schedule\":\"every 5m\"}", j.definition().toJson());
  }

  @Test
  void tiesKeepInsertionOrderAndNamesSortByByte() throws Exception {
    SqlStore store = store();
    store.init();
    for (String id : List.of("t1", "t2", "t3")) {
      store.insertRun(StoreContract.newRun(id, "ties", RunStatus.OK, 5));
    }
    List<String> ties = new ArrayList<>();
    for (Run r : store.listRuns("ties", 10)) {
      ties.add(r.id());
    }
    assertEquals(List.of("t3", "t2", "t1"), ties);
    for (String name : List.of("b", "B", "_c", "a", "é")) {
      store.upsertJob(Definition.fromJson("{\"name\":\"" + name + "\"}"), 1);
    }
    List<String> names = new ArrayList<>();
    for (StoredJob job : store.listJobs()) {
      names.add(job.name());
    }
    assertEquals(List.of("B", "_c", "a", "b", "é"), names);
  }

  @Test
  void nulCharactersAreStillRecorded() throws Exception {
    SqlStore store = store();
    List<Alert> alerts = new CopyOnWriteArrayList<>();
    List<String> errors = new CopyOnWriteArrayList<>();
    try (Cronwatch cw = client(store, new AtomicLong(T0), alerts, errors)) {
      assertThrows(
          IllegalStateException.class,
          () ->
              cw.run(
                  "nul",
                  j -> {
                    j.log("before\u0000after");
                    throw new IllegalStateException("bad\u0000byte");
                  }));
      List<Run> runs = cw.runs("nul", 10);
      assertEquals(1, runs.size());
      assertEquals(RunStatus.FAILED, runs.get(0).status());
      assertEquals("beforeafter", runs.get(0).output());
      assertTrue(
          String.valueOf(runs.get(0).error()).startsWith("IllegalStateException: badbyte"),
          runs.get(0).error());
      JobState st = store.getState("nul");
      assertNotNull(st);
      assertEquals(1, st.consecutiveFailures(), "the state, with its alert, was written too");
      // So are a trigger, metric names and a definition's text.
      cw.job(
              "nul2",
              dev.cronwatch.JobOptions.builder()
                  .description("a\u0000b")
                  .tags("t\u0000")
                  .budget("c\u0000", 5))
          .run(
              dev.cronwatch.RunOptions.defaults().withTrigger("cr\u0000on"),
              j -> j.metric("ro\u0000ws", 2));
      Run second = cw.runs("nul2", 10).get(0);
      assertEquals(RunStatus.OK, second.status());
      assertEquals("cron", second.trigger());
      assertEquals(java.util.Map.of("rows", 2.0), second.metrics().asMap());
      StoredJob stored = store.getJob("nul2");
      assertNotNull(stored);
      Definition def = stored.definition();
      assertEquals("ab", def.description());
      assertEquals(List.of("t"), def.tags());
      assertEquals("{\"c\":5}", Json.stringify(def.get("budget")));
      assertEquals(List.of(), errors);
    }
  }

  @Test
  void twoStoresRacingOnOneJobsStateExactlyOneWriteWins() throws Exception {
    String p = prefix();
    SqlStore one = Servers.store(kind(), p);
    SqlStore two = Servers.store(kind(), p);
    one.init();
    two.init();
    ExecutorService pool = Executors.newFixedThreadPool(2);
    try {
      long[][] cases = {{1, 1, 2, 0}, {2, 3, 4, 1}};
      for (long[] c : cases) {
        JobState a =
            state(
                "{\"job\":\"r\",\"open\":{},\"consecutiveFailures\":"
                    + c[1]
                    + ",\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":"
                    + c[0]
                    + "}");
        JobState b =
            state(
                "{\"job\":\"r\",\"open\":{},\"consecutiveFailures\":"
                    + c[2]
                    + ",\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":"
                    + c[0]
                    + "}");
        long expected = c[3];
        Callable<Boolean> ca = () -> one.compareAndSetState(a, expected);
        Callable<Boolean> cb = () -> two.compareAndSetState(b, expected);
        Future<Boolean> fa = pool.submit(ca);
        Future<Boolean> fb = pool.submit(cb);
        assertNotEquals(fa.get(60, TimeUnit.SECONDS), fb.get(60, TimeUnit.SECONDS));
      }
    } finally {
      pool.shutdownNow();
    }
    JobState st = one.getState("r");
    assertNotNull(st);
    assertEquals(2L, st.version());
  }

  @Test
  void manyStoresInitAtOnce() throws Exception {
    String p = prefix();
    List<SqlStore> stores = new ArrayList<>();
    for (int i = 0; i < 8; i++) {
      stores.add(Servers.store(kind(), p));
    }
    ExecutorService pool = Executors.newFixedThreadPool(8);
    try {
      List<Future<?>> inits = new ArrayList<>();
      for (SqlStore s : stores) {
        inits.add(
            pool.submit(
                () -> {
                  s.init();
                  return null;
                }));
      }
      for (Future<?> f : inits) {
        f.get(60, TimeUnit.SECONDS);
      }
    } finally {
      pool.shutdownNow();
    }
    stores.get(0).upsertJob(Definition.fromJson("{\"name\":\"a\"}"), 1);
    StoredJob job = stores.get(7).getJob("a");
    assertNotNull(job);
    assertEquals(1, job.createdAt());
  }
}
