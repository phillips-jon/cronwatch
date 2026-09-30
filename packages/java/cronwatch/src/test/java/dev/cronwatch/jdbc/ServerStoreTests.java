package dev.cronwatch.jdbc;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.CheckResult;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Definition;
import dev.cronwatch.Fixtures;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.JobState;
import dev.cronwatch.JobSummary;
import dev.cronwatch.Run;
import dev.cronwatch.RunHandle;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.jdbc.Servers.Kind;
import dev.cronwatch.store.Store;
import dev.cronwatch.storetest.FinishOnce;
import dev.cronwatch.storetest.ForeignRows;
import dev.cronwatch.storetest.StoreContract;
import dev.cronwatch.storetest.StoreReplay;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * The store's tests on a database server, run once per server by a subclass, and skipped, saying
 * why, when the server's variable is unset (see {@link Servers}): the contract, the {@code
 * store.json} replay with its {@code foreignVersion} cases, the finish-once scenarios over several
 * clients on one database, a client end to end, a run surviving the app's rollback, and rows of
 * another shape. Each test's tables have a prefix of their own, dropped when it ends.
 */
abstract class ServerStoreTests {
  static final long T0 = Js.dateUtc(2026, 0, 5, 9, 30, 0, 0);
  static final long MIN = 60_000;

  /** The server this subclass runs against. */
  abstract Kind kind();

  /** The dialect its store names. */
  abstract String dialect();

  private final List<String> prefixes = new CopyOnWriteArrayList<>();
  private final List<String> tables = new CopyOnWriteArrayList<>();

  @BeforeEach
  void onlyWithTheServer() {
    Servers.assume(kind());
  }

  @AfterEach
  void dropTables() throws SQLException {
    for (String p : prefixes) {
      Servers.drop(kind(), p);
    }
    for (String t : tables) {
      Servers.exec(kind(), "DROP TABLE IF EXISTS " + t);
    }
  }

  /** A prefix of this test's own, dropped when it ends. */
  String prefix() {
    String p = Servers.prefix();
    prefixes.add(p);
    return p;
  }

  /** A store on tables of a prefix of this test's own. */
  SqlStore store() {
    return Servers.store(kind(), prefix());
  }

  /** A table beside the store's, dropped when the test ends. */
  String table(String name) {
    String t = prefix() + name;
    tables.add(t);
    return t;
  }

  void exec(String... statements) throws SQLException {
    Servers.exec(kind(), statements);
  }

  /** The first column of every row of a query, as text. */
  List<String> column(String query) throws SQLException {
    List<String> out = new ArrayList<>();
    try (Connection c = Servers.dataSource(kind()).getConnection();
        Statement s = c.createStatement();
        ResultSet rs = s.executeQuery(query)) {
      while (rs.next()) {
        out.add(rs.getString(1));
      }
    }
    return out;
  }

  static String fixture() throws IOException {
    return Files.readString(
        Fixtures.conformanceDir().resolve("store.json"), StandardCharsets.UTF_8);
  }

  /** A client over {@code store} on a clock the test moves, sending to {@code alerts}. */
  static Cronwatch client(Store store, AtomicLong clock, List<Alert> alerts, List<String> errors) {
    return Cronwatch.builder()
        .store(store)
        .alert(Channel.of("capture", (alert, ctx) -> alerts.add(alert)))
        .noCronSecret()
        .onError((where, e) -> errors.add(where + ": " + e.getMessage()))
        .clock(clock::get)
        .noShutdownHook()
        .build();
  }

  static List<String> types(List<Alert> alerts) {
    List<String> out = new ArrayList<>();
    for (Alert a : alerts) {
      out.add(a.type().value());
    }
    return out;
  }

  @Test
  void theStoreNamesItsDialect() {
    assertEquals(dialect(), SqlStore.of(Servers.dataSource(kind())).dialect());
    assertEquals(dialect(), store().dialect());
  }

  @Test
  void theStorePassesTheContract() {
    StoreContract.run(store());
  }

  @Test
  void theStoreReplaysStoreJson() throws IOException {
    assertEquals(26, StoreReplay.run(fixture(), this::store));
  }

  @Test
  void theStoreCountsAForeignStatesVersionAsTheSdkDoes() throws Exception {
    String p = prefix();
    boolean pg = kind() == Kind.PG || kind() == Kind.PGCRON;
    try (SqlStore s = Servers.store(kind(), p)) {
      int cases =
          StoreReplay.foreignVersions(
              fixture(),
              s,
              text -> {
                try (Connection c = Servers.dataSource(kind()).getConnection();
                    PreparedStatement ps =
                        c.prepareStatement(
                            "INSERT INTO "
                                + p
                                + "state (job, state) VALUES ('v', "
                                + (pg ? "CAST(? AS jsonb)" : "?")
                                + ")")) {
                  ps.setString(1, text);
                  ps.executeUpdate();
                }
              });
      assertEquals(16, cases);
    }
  }

  @Test
  void aRunIsFinishedOnceAcrossProcesses() {
    FinishOnce.run(
        () -> {
          String p = prefix();
          List<Store> opened = new ArrayList<>();
          return new FinishOnce.Shared() {
            @Override
            public Store open() {
              Store s = Servers.store(kind(), p);
              opened.add(s);
              return s;
            }

            @Override
            public void done() throws Exception {
              for (Store s : opened) {
                s.close();
              }
              Servers.drop(kind(), p);
            }
          };
        });
  }

  /**
   * A client from end to end: jobs declared, runs that succeed and fail, a check that finds a stuck
   * run and a missed one, the alerts sent and the state's version moving on every write; then
   * another process reads it all back.
   */
  @Test
  void aClientRecordsAndChecks() throws Exception {
    String p = prefix();
    SqlStore store = Servers.store(kind(), p);
    AtomicLong clock = new AtomicLong(T0);
    List<Alert> alerts = new CopyOnWriteArrayList<>();
    List<String> errors = new CopyOnWriteArrayList<>();
    try (Cronwatch cw = client(store, clock, alerts, errors)) {
      Job nightly =
          cw.job("nightly", JobOptions.builder().schedule("every 5m").grace("1m").timeout("2m"));
      cw.job("hourly", JobOptions.builder().schedule("every 1h").grace("1m"));
      nightly.run(
          j -> {
            j.log("rows: 12");
            j.metric("rows", 12);
          });
      clock.addAndGet(MIN);
      assertThrows(
          IllegalStateException.class,
          () ->
              nightly.run(
                  j -> {
                    throw new IllegalStateException("boom");
                  }));
      JobState st = store.getState("nightly");
      assertNotNull(st);
      assertEquals(1, st.consecutiveFailures());
      long before = st.countedVersion();
      assertTrue(before >= 2, "version " + before);

      clock.addAndGet(MIN);
      RunHandle handle = nightly.start();
      handle.log("started");
      handle.flush();
      // Past nightly's timeout, then past hourly's hour and grace.
      clock.addAndGet(3 * MIN);
      CheckResult first = cw.check();
      clock.addAndGet(61 * MIN);
      CheckResult second = cw.check();

      List<String> types = types(alerts);
      for (String want : List.of("failed", "missed", "stuck")) {
        assertTrue(types.contains(want), "no " + want + " among " + types);
      }
      List<Run> runs = cw.runs("nightly", 10);
      List<String> statuses = new ArrayList<>();
      for (Run r : runs) {
        statuses.add(r.status().value());
      }
      assertEquals(List.of("timeout", "failed", "ok"), statuses);
      assertEquals("started", runs.get(0).output());
      assertEquals("rows: 12", runs.get(2).output());
      assertEquals("{\"rows\":12}", runs.get(2).metrics().toJson());
      JobState after = store.getState("nightly");
      assertNotNull(after);
      assertTrue(after.countedVersion() > before, "the version did not move");
      assertEquals(2, first.jobs().size());
      assertEquals(2, second.jobs().size());
      assertEquals(List.of(), errors);
    }

    // Another process reads it all back.
    try (Cronwatch two =
        client(Servers.store(kind(), p), clock, new ArrayList<>(), new ArrayList<>())) {
      JobSummary summary = two.jobSummary("nightly");
      assertNotNull(summary);
      assertEquals(2, summary.consecutiveFailures(), "the failure and the stuck run");
      assertEquals(3, two.runs("nightly", 10).size());
    }
  }

  /**
   * A run recorded while the app has a transaction open survives the app's rollback: the store's
   * statements run on a connection of their own, never inside the app's transaction.
   */
  @Test
  void aRunSurvivesTheAppsRollback() throws Exception {
    String orders = table("orders");
    exec("CREATE TABLE " + orders + " (id INT PRIMARY KEY)");
    AtomicLong clock = new AtomicLong(T0);
    try (Cronwatch cw = client(store(), clock, new ArrayList<>(), new ArrayList<>());
        Connection app = Servers.dataSource(kind()).getConnection()) {
      app.setAutoCommit(false);
      try (Statement s = app.createStatement()) {
        s.execute("INSERT INTO " + orders + " VALUES (1)");
      }
      assertEquals("imported", cw.call("import", j -> "imported"));
      app.rollback();
      assertEquals(List.of("0"), column("SELECT COUNT(*) FROM " + orders));
      List<Run> runs = cw.runs("import", 10);
      assertEquals(1, runs.size(), "the run was lost with the app's rollback");
      assertEquals("imported", runs.get(0).output());
    }
  }

  /**
   * A row another writer (or a hand edit) left in a shape of its own, valid JSON but not what the
   * SDK writes, is read as the SDK reads it rather than failing every read it is part of.
   */
  @Test
  void aRowOfAnotherShapeDoesNotBlindTheChecks() throws Exception {
    String p = prefix();
    SqlStore store = Servers.store(kind(), p);
    store.init();
    store.insertRun(StoreContract.newRun("good", "a", RunStatus.RUNNING, 1));
    store.upsertJob(Definition.fromJson("{\"name\":\"a\",\"schedule\":\"0 * * * *\"}"), 1);
    exec(
        "INSERT INTO "
            + p
            + "runs (id, job, status, started_at, metrics) VALUES ('bad', 'b', 'running', 2,"
            + " '{\"rows\":\"12\",\"n\":3}')",
        "INSERT INTO "
            + p
            + "jobs (name, definition, created_at, updated_at) VALUES ('b', '[]', 1, 1)");
    List<Run> running = store.runningRuns();
    assertEquals(2, running.size());
    Run bad = running.stream().filter(r -> r.id().equals("bad")).findFirst().orElseThrow();
    assertEquals("{\"n\":3}", bad.metrics().toJson(), "the numbers are kept");
    List<StoredJob> jobs = store.listJobs();
    assertEquals(2, jobs.size());
    List<String> errors = new ArrayList<>();
    try (Cronwatch cw = client(store, new AtomicLong(T0), new ArrayList<>(), errors)) {
      cw.check();
    }
    assertEquals(List.of(), errors);
  }

  @Test
  void aCheckOverARunThatStartedAtTheLowestBigint() {
    String p = prefix();
    ForeignRows.checkOverForeignRows(Servers.store(kind(), p), p, sql -> exec(sql));
  }

  @Test
  void aCheckAndTheDashboardsReadsOverACronJobWhoseLastRunStartedFarOff() {
    for (String startedAt : ForeignRows.FAR_STARTS) {
      String p = prefix();
      ForeignRows.cronOverForeignRow(Servers.store(kind(), p), p, startedAt, sql -> exec(sql));
    }
  }
}
