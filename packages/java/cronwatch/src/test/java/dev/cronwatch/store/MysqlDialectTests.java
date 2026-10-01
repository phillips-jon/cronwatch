package dev.cronwatch.store;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.json.Json;
import dev.cronwatch.storetest.TestRuns;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Test;

/**
 * MySQL's and MariaDB's own tests (the PHP port's {@code MysqlStoreTest}, as the Go, Rust and
 * Elixir ports have them), run once per server by a subclass.
 */
abstract class MysqlDialectTests extends ServerStoreTests {
  @Override
  String dialect() {
    return "mysql";
  }

  private static JobState state(String text) {
    return JobState.fromJson(text);
  }

  private static JobState version(String job, long version, long failures) {
    return state(
        "{\"job\":\""
            + job
            + "\",\"open\":{},\"consecutiveFailures\":"
            + failures
            + ",\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":"
            + version
            + "}");
  }

  @Test
  void theSdksJsonIsKeptByteForByte() throws Exception {
    String p = prefix();
    SqlStore store = Servers.store(kind(), p);
    store.init();
    store.init();
    List<String> columns =
        column(
            "SELECT CONCAT(TABLE_NAME, '.', COLUMN_NAME, ' ', DATA_TYPE, ' ',"
                + " COALESCE(COLLATION_NAME, '')) FROM information_schema.COLUMNS WHERE"
                + " TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE '"
                + p
                + "%' ORDER BY TABLE_NAME, ORDINAL_POSITION");
    for (String want :
        List.of(
            // text, never the JSON type, which rewrites what it holds
            p + "jobs.definition longtext utf8mb4_bin",
            p + "runs.metrics longtext utf8mb4_bin",
            p + "state.state longtext utf8mb4_bin",
            // names compare as bytes: "b" and "B" are two jobs
            p + "jobs.name varchar utf8mb4_bin")) {
      assertTrue(columns.contains(want), "no " + want + " among " + columns);
    }
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

    Definition definition =
        Definition.fromJson(
            "{\"grace\":\"15m\",\"schedule\":\"0 2 * * *\",\"budget\":{\"cost\":2},"
                + "\"tags\":[\"café ☃ 😀\"],\"name\":\"nightly\"}");
    store.upsertJob(definition, 1);
    Run run =
        new Run(
            "r1",
            "nightly",
            RunStatus.OK,
            1,
            2L,
            1L,
            null,
            "tab\tand \"quotes\" 😀",
            Metrics.fromValue(
                Json.parse(
                    "{\"ratio\":0.30000000000000004,\"tiny\":1e-7,\"huge\":1e21,\"üml\":7}")),
            "run");
    store.insertRun(run);
    JobState st =
        state(
            "{\"job\":\"nightly\",\"open\":{\"failed\":5},\"consecutiveFailures\":1,"
                + "\"silencedUntil\":null,\"lastAlertAt\":null,\"pendingRecovery\":[\"missed\"],"
                + "\"undelivered\":[],\"version\":3}");
    store.setState(st);
    assertEquals(List.of(definition.toJson()), column("SELECT definition FROM " + p + "jobs"));
    assertEquals(
        List.of("{\"ratio\":0.30000000000000004,\"tiny\":1e-7,\"huge\":1e+21,\"üml\":7}"),
        column("SELECT metrics FROM " + p + "runs"));
    assertEquals(List.of(st.toJson()), column("SELECT state FROM " + p + "state"));
    Run read = store.getRun("r1");
    assertNotNull(read);
    assertEquals(run.toJson(), read.toJson());
  }

  /**
   * MySQL answers how many rows an UPDATE changed, not how many it matched, unless the connection
   * asks for found rows (Connector/J's and MariaDB's drivers do by default). Neither may make a
   * conditional write that landed read as refused.
   */
  @Test
  void conditionalWritesDoNotLeanOnHowRowsAreCounted() throws Exception {
    for (SqlStore store : List.of(store(), changedRows())) {
      store.init();
      assertTrue(store.compareAndSetState(version("j", 1, 0), 0), "first");
      assertFalse(
          store.compareAndSetState(version("j", 1, 9), 0), "a write from a stale read is refused");
      assertFalse(store.compareAndSetState(version("j", 3, 0), 2), "another version");
      assertTrue(store.compareAndSetState(version("j", 2, 1), 1), "the version read");
      JobState j = store.getState("j");
      assertNotNull(j);
      assertEquals(2L, j.version());

      store.setState(
          state(
              "{\"job\":\"old\",\"open\":{},\"consecutiveFailures\":3,\"silencedUntil\":null,"
                  + "\"lastAlertAt\":null}"));
      assertTrue(
          store.compareAndSetState(version("old", 1, 4), 0),
          "state written before versions counts as 0");
      JobState zero =
          state(
              "{\"job\":\"zero\",\"open\":{},\"consecutiveFailures\":0,\"silencedUntil\":null,"
                  + "\"lastAlertAt\":null}");
      store.setState(zero);
      assertTrue(
          store.compareAndSetState(zero, 0), "a write of what version 0 already holds still wrote");
      // A write from version 0 whose insert landed but whose answer was lost: the row holding
      // exactly what was sent is the write's own.
      JobState landed = version("landed", 1, 0);
      store.setState(landed);
      assertTrue(store.compareAndSetState(landed, 0), "a landed write is counted as written");

      // A flush that writes what the row already holds still wrote.
      Run run = TestRuns.newRun("r", "j", RunStatus.RUNNING, 1).withOutput("same");
      store.insertRun(run);
      assertTrue(store.updateRunIf(run, List.of(RunStatus.RUNNING)));
      assertFalse(store.updateRunIf(run, List.of(RunStatus.TIMEOUT)));
    }
  }

  /**
   * A store whose connections count the rows an UPDATE changed, not the rows it matched ({@code
   * useAffectedRows=true}, which both drivers take).
   */
  SqlStore changedRows() {
    return SqlStore.mysql(Servers.dataSource(kind(), "useAffectedRows=true")).prefix(prefix());
  }

  /**
   * MySQL's trigger column is {@code VARCHAR(255)}: a longer trigger is cut to 255 characters to
   * fit rather than lose the whole run.
   */
  @Test
  void aRunWithALongTriggerIsKept() throws Exception {
    SqlStore store = store();
    store.init();
    Run run = TestRuns.newRun("r", "j", RunStatus.RUNNING, 1);
    store.insertRun(
        new Run(
            run.id(),
            run.job(),
            run.status(),
            run.startedAt(),
            null,
            null,
            null,
            null,
            Metrics.empty(),
            "é".repeat(254) + "😀😀"));
    Run read = store.getRun("r");
    assertNotNull(read);
    assertEquals("é".repeat(254) + "😀", read.trigger());
  }

  /**
   * State rows a damaged or hand-edited row could hold in the {@code LONGTEXT} column: text that is
   * not JSON, JSON that is not an object, and objects whose version is not a number. A check, a
   * silence and a second check answer with no error, and the silence replaces each row (it counts
   * as version 0, as on SQLite).
   */
  @Test
  void aDamagedStateRowIsReplaced() throws Exception {
    List<String> damaged =
        List.of(
            "{",
            "not json",
            "5",
            "\"x\"",
            "[]",
            "null",
            "{\"version\":\"x\"}",
            "{\"version\":true}",
            "{\"version\":{\"a\":1}}",
            "{\"version\":[1]}");
    String p = prefix();
    SqlStore store = Servers.store(kind(), p);
    store.init();
    for (int i = 0; i < damaged.size(); i++) {
      store.upsertJob(Definition.fromJson("{\"name\":\"dmg" + i + "\"}"), 1);
      exec(
          "INSERT INTO "
              + p
              + "state (job, state) VALUES ('dmg"
              + i
              + "', '"
              + damaged.get(i)
              + "')");
    }
    List<String> errors = new ArrayList<>();
    try (Cronwatch cw = client(store, new AtomicLong(T0), new ArrayList<>(), errors)) {
      cw.check();
      for (int i = 0; i < damaged.size(); i++) {
        String name = "dmg" + i;
        String over = "silencing over " + damaged.get(i);
        JobState silenced = assertDoesNotThrow(() -> cw.silence(name, "1h"), over);
        assertEquals(Long.valueOf(T0 + 3_600_000), silenced.silencedUntil(), over);
        JobState stored = store.getState(name);
        assertNotNull(stored, over);
        assertEquals(Long.valueOf(T0 + 3_600_000), stored.silencedUntil(), over);
      }
      cw.check();
    }
    assertEquals(List.of(), errors);
  }

  @Test
  void namesSortByByte() throws Exception {
    SqlStore store = store();
    store.init();
    for (String name : List.of("b", "B", "_c", "a", "é")) {
      store.upsertJob(Definition.fromJson("{\"name\":\"" + name + "\"}"), 1);
    }
    List<String> names = new ArrayList<>();
    for (StoredJob job : store.listJobs()) {
      names.add(job.name());
    }
    assertEquals(List.of("B", "_c", "a", "b", "é"), names);
  }
}
