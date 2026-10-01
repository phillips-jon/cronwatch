package dev.cronwatch.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.CronwatchException;
import dev.cronwatch.Definition;
import dev.cronwatch.Fixtures;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.storetest.StoreContract;
import dev.cronwatch.storetest.StoreReplay;
import dev.cronwatch.storetest.TestRuns;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.sqlite.SQLiteDataSource;

/**
 * The SQL store on SQLite: the store contract, the store.json replay, the SDK's schema, the
 * pragmas, and rows of other shapes.
 */
class SqliteStoreTest {
  @TempDir Path dir;

  /** A data source over a SQLite file, or {@code :memory:}. */
  static SQLiteDataSource source(String path) {
    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite:" + path);
    return ds;
  }

  static SqlStore store(Path file, String prefix) {
    return SqlStore.sqlite(source(file.toString())).prefix(prefix);
  }

  static String fixture() throws IOException {
    return Files.readString(
        Fixtures.conformanceDir().resolve("store.json"), StandardCharsets.UTF_8);
  }

  /** Runs statements on a connection of its own, as another process would. */
  static void exec(Path file, String... statements) throws SQLException {
    try (Connection c = source(file.toString()).getConnection();
        Statement s = c.createStatement()) {
      for (String statement : statements) {
        s.execute(statement);
      }
    }
  }

  /** The first column of every row of a query, as text. */
  static List<String> column(Path file, String query) throws SQLException {
    List<String> out = new ArrayList<>();
    try (Connection c = source(file.toString()).getConnection();
        Statement s = c.createStatement();
        ResultSet rs = s.executeQuery(query)) {
      while (rs.next()) {
        out.add(rs.getString(1));
      }
    }
    return out;
  }

  @Test
  void theSqliteStorePassesTheContractInMemory() {
    StoreContract.run(SqlStore.sqlite(source(":memory:")));
  }

  @Test
  void theSqliteStorePassesTheContractOnAFileWithAPrefix() {
    StoreContract.run(store(dir.resolve("contract.db"), "cw_"));
  }

  @Test
  void theSqliteStoreReplaysStoreJson() throws IOException {
    assertEquals(32, StoreReplay.run(fixture(), () -> SqlStore.sqlite(source(":memory:"))));
    int[] n = {0};
    assertEquals(
        32,
        StoreReplay.run(
            fixture(), () -> store(dir.resolve("replay-" + n[0]++ + ".db"), "cronwatch_")));
  }

  @Test
  void theSqliteStoreCountsAForeignStatesVersionAsTheSdkDoes() throws Exception {
    Path file = dir.resolve("foreign-version.db");
    try (SqlStore s = store(file, "cronwatch_")) {
      int cases =
          StoreReplay.foreignVersions(
              fixture(),
              s,
              text -> {
                try (Connection c = source(file.toString()).getConnection();
                    PreparedStatement ps =
                        c.prepareStatement(
                            "INSERT INTO cronwatch_state (job, state) VALUES ('v', ?)")) {
                  ps.setString(1, text);
                  ps.executeUpdate();
                }
              });
      assertEquals(16, cases);
    }
  }

  @Test
  void aBadPrefixIsRefusedWithTheSdksMessage() {
    CronwatchException e =
        assertThrows(
            CronwatchException.class, () -> SqlStore.sqlite(source(":memory:")).prefix("Bad-"));
    assertEquals(CronwatchException.Kind.INVALID, e.kind());
    assertEquals(
        "cronwatch: invalid table prefix \"Bad-\". Use lowercase letters, digits and underscores,"
            + " not starting with a digit, at most 47 characters.",
        e.getMessage());
    assertThrows(CronwatchException.class, () -> SqlStore.sqlite(source(":memory:")).prefix("9x"));
    assertThrows(CronwatchException.class, () -> SqlStore.sqlite(source(":memory:")).prefix(""));
    assertThrows(
        CronwatchException.class, () -> SqlStore.sqlite(source(":memory:")).prefix("a".repeat(48)));
    SqlStore s = SqlStore.sqlite(source(":memory:"));
    assertEquals("cronwatch_", s.tablePrefix());
    assertEquals("a".repeat(47), s.prefix("a".repeat(47)).tablePrefix());
    assertEquals("SqlStore(sqlite, prefix cw_)", s.prefix("cw_").toString());
  }

  @Test
  void ofAsksTheDatabaseWhatItIs() {
    SqlStore s = SqlStore.of(source(":memory:"));
    assertEquals("sqlite", s.dialect());
  }

  @Test
  void theTablesAreTheSdksAndTheConnectionIsInWalMode() throws Exception {
    Path file = dir.resolve("schema.db");
    try (SqlStore s = store(file, "cw_")) {
      s.init();
      s.init();
    }
    List<String> sql =
        column(
            file,
            "SELECT sql FROM sqlite_master WHERE name LIKE 'cw_%' AND sql IS NOT NULL ORDER BY name");
    assertEquals(5, sql.size(), sql.toString());
    assertTrue(
        sql.contains("CREATE INDEX cw_runs_running ON cw_runs (status) WHERE status = 'running'"),
        sql.toString());
    assertEquals(List.of("wal"), column(file, "PRAGMA journal_mode"));
  }

  @Test
  void theStoresConnectionHasTheSdksPragmas() throws Exception {
    try (SqlStore s = store(dir.resolve("pragmas.db"), "cronwatch_")) {
      s.init();
      assertEquals("wal", s.pragma("journal_mode"));
      assertEquals("5000", s.pragma("busy_timeout"));
      assertEquals("1", s.pragma("synchronous"), "NORMAL");
    }
  }

  @Test
  void aBusyDatabaseIsRetriedWhileSwitchingToWal() throws Exception {
    Path file = dir.resolve("busy.db");
    exec(file, "CREATE TABLE t (x INTEGER)");
    // Another connection holds a write lock for a moment; switching the journal mode is busy
    // until it lets go, and the store retries rather than fail.
    try (Connection other = source(file.toString()).getConnection()) {
      other.setAutoCommit(false);
      try (Statement st = other.createStatement()) {
        st.execute("INSERT INTO t VALUES (1)");
      }
      Thread release =
          Thread.ofPlatform()
              .start(
                  () -> {
                    try {
                      Thread.sleep(300);
                      other.commit();
                    } catch (InterruptedException | SQLException e) {
                      throw new IllegalStateException(e);
                    }
                  });
      try (SqlStore s = store(file, "cronwatch_")) {
        s.init();
      }
      release.join();
    }
    assertEquals(List.of("wal"), column(file, "PRAGMA journal_mode"));
  }

  @Test
  void busyCodesAreRecognised() {
    assertTrue(
        SqlStore.busy(new SQLException("[SQLITE_BUSY] The database file is locked", null, 5)));
    assertTrue(SqlStore.busy(new SQLException("x", null, 5 + 256)));
    assertTrue(SqlStore.busy(new SQLException("database table is locked", null, 0)));
    assertTrue(!SqlStore.busy(new SQLException("no such table", null, 1)));
  }

  @Test
  void runsThatStartedTogetherKeepTheirInsertionOrder() throws Exception {
    try (SqlStore s = SqlStore.sqlite(source(":memory:"))) {
      s.init();
      for (String id : List.of("b", "a", "c")) {
        s.insertRun(TestRuns.newRun(id, "j", RunStatus.RUNNING, 1000));
      }
      List<String> newest = new ArrayList<>();
      for (Run r : s.listRuns("j", 10)) {
        newest.add(r.id());
      }
      assertEquals(List.of("c", "a", "b"), newest);
      List<String> oldest = new ArrayList<>();
      for (Run r : s.runningRuns()) {
        oldest.add(r.id());
      }
      assertEquals(List.of("b", "a", "c"), oldest);
    }
  }

  @Test
  void namesSortByByteNotLocale() throws Exception {
    try (SqlStore s = SqlStore.sqlite(source(":memory:"))) {
      s.init();
      for (String name : List.of("b", "é", "B", "a", "_z", "Z")) {
        s.upsertJob(Definition.fromJson("{\"name\":\"" + name + "\"}"), 1);
      }
      List<String> names = new ArrayList<>();
      for (StoredJob j : s.listJobs()) {
        names.add(j.name());
      }
      assertEquals(List.of("B", "Z", "_z", "a", "b", "é"), names);
    }
  }

  @Test
  void textDropsNulsAndALoneSurrogateIsWrittenAsTheReplacementCharacter() throws Exception {
    Path file = dir.resolve("text.db");
    try (SqlStore s = store(file, "cronwatch_")) {
      s.init();
      Run run =
          new Run(
              "t1",
              "j",
              RunStatus.OK,
              1,
              2L,
              1L,
              "a\u0000b",
              "x\ud83dy 😀",
              Metrics.empty(),
              "run");
      s.insertRun(run);
      Run back = s.getRun("t1");
      assertNotNull(back);
      assertEquals("ab", back.error(), "no NUL, as on Postgres");
      assertEquals("x�y 😀", back.output());
    }
    // The bytes the file holds are the ones better-sqlite3 writes for the same string.
    assertEquals(
        List.of("78EFBFBD7920F09F9880"),
        column(file, "SELECT hex(output) FROM cronwatch_runs WHERE id = 't1'"));
  }

  @Test
  void rowsOfAnotherShapeAreReadAsTheSdkReadsThem() throws Exception {
    Path file = dir.resolve("foreign.db");
    try (SqlStore s = store(file, "cronwatch_")) {
      s.init();
      exec(
          file,
          "INSERT INTO cronwatch_jobs (name, definition, created_at, updated_at) VALUES ('odd',"
              + " '[1]', 1, 2)",
          "INSERT INTO cronwatch_runs (id, job, status, started_at, metrics) VALUES ('x', 'odd',"
              + " 'running', 5.0, '{\"a\":\"text\",\"b\":2}')");
      StoredJob job = s.getJob("odd");
      assertNotNull(job);
      assertEquals(
          "{\"name\":\"odd\"}",
          job.definition().toJson(),
          "a definition that is not an object is its name alone");
      assertEquals(2, job.updatedAt());
      List<Run> running = s.runningRuns();
      assertEquals(1, running.size());
      assertEquals("{\"b\":2}", running.get(0).metrics().toJson(), "metrics keep the numbers");
      assertEquals(5, running.get(0).startedAt());
      assertEquals("run", running.get(0).trigger());

      // Text that is not UTF-8 reads with U+FFFD rather than failing every read of the job's
      // runs.
      exec(
          file,
          "INSERT INTO cronwatch_runs (id, job, status, started_at, output, trigger) VALUES ('y',"
              + " 'odd', 'ok', 6, CAST(x'61ff62' AS TEXT), 'run')");
      List<Run> runs = s.listRuns("odd", 10);
      assertEquals("a�b", runs.get(0).output());

      // A start at the lowest BIGINT, and times and durations stored as text or real, read as
      // whole numbers held at the ends of the range.
      exec(
          file,
          "INSERT INTO cronwatch_runs (id, job, status, started_at, finished_at, duration_ms,"
              + " trigger) VALUES ('far', 'odd', 'ok', -9223372036854775808, ' 7 ', 1e300, 'run')");
      Run far = s.getRun("far");
      assertNotNull(far);
      assertEquals(Long.MIN_VALUE, far.startedAt());
      assertEquals(7L, far.finishedAt());
      assertEquals(Long.MAX_VALUE, far.durationMs());
      assertEquals(Metrics.empty(), far.metrics());
    }
  }

  @Test
  void aStateThatIsNotJsonOrNotAnObjectReadsAsNone() throws Exception {
    Path file = dir.resolve("state.db");
    try (SqlStore s = store(file, "cronwatch_")) {
      s.init();
      exec(
          file,
          "INSERT INTO cronwatch_state (job, state) VALUES ('bad', 'not json'), ('five', '5')");
      assertEquals(null, s.getState("bad"));
      assertEquals(null, s.getState("five"));
      assertEquals(null, s.getState("other"));
      s.setState(dev.cronwatch.JobState.empty("ok"));
      assertNotNull(s.getState("ok"));
    }
  }

  @Test
  void theStoreOpensAgainAfterClose() throws Exception {
    Path file = dir.resolve("reopen.db");
    SqlStore s = store(file, "cronwatch_");
    s.init();
    s.upsertJob(Definition.fromJson("{\"name\":\"a\"}"), 1);
    s.close();
    assertEquals("a", s.listJobs().get(0).name(), "read after a close");
    s.close();
  }
}
