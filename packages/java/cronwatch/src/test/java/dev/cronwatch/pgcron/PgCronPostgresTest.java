package dev.cronwatch.pgcron;

import static dev.cronwatch.pgcron.PgCronTest.DAY;
import static dev.cronwatch.pgcron.PgCronTest.T0;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import dev.cronwatch.CheckResult;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.pgcron.PgCronTest.Kit;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Servers;
import dev.cronwatch.store.Servers.Kind;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import javax.sql.DataSource;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * The pg_cron source's SQL against a real Postgres, over a fake {@code cron} schema made in a
 * database of the test's own (so it never meets a real pg_cron, nor another test), when {@code
 * CRONWATCH_TEST_PG} is set, as the Elixir port runs it.
 */
class PgCronPostgresTest {
  private String database = "";
  private @Nullable DataSource source;

  @BeforeEach
  void aDatabaseOfItsOwn() throws SQLException {
    Servers.assume(Kind.PG);
    database = Servers.prefix() + "fake";
    Servers.exec(Kind.PG, "CREATE DATABASE " + database);
    source = Servers.dataSource(Kind.PG, database, null, null, "");
    exec(
        "CREATE SCHEMA cron",
        "CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, schedule text NOT NULL, command text"
            + " NOT NULL DEFAULT 'SELECT 1', database text NOT NULL DEFAULT 'cw', username text NOT"
            + " NULL DEFAULT 'postgres', active boolean NOT NULL DEFAULT true, jobname text)",
        "CREATE TABLE cron.job_run_details (jobid bigint, runid bigserial PRIMARY KEY, job_pid"
            + " integer, database text, username text, command text, status text, return_message"
            + " text, start_time timestamptz, end_time timestamptz)");
  }

  @AfterEach
  void dropIt() throws SQLException {
    if (!database.isEmpty()) {
      Servers.exec(Kind.PG, "DROP DATABASE IF EXISTS " + database + " WITH (FORCE)");
    }
  }

  private DataSource source() {
    DataSource ds = source;
    if (ds == null) {
      throw new IllegalStateException("no database");
    }
    return ds;
  }

  private void exec(String... statements) throws SQLException {
    try (Connection c = source().getConnection();
        Statement s = c.createStatement()) {
      for (String statement : statements) {
        s.execute(statement);
      }
    }
  }

  private long add(
      long jobId, String status, @Nullable Long start, @Nullable Long end, @Nullable String message)
      throws SQLException {
    try (Connection c = source().getConnection();
        PreparedStatement ps =
            c.prepareStatement(
                "INSERT INTO cron.job_run_details (jobid, status, return_message, start_time,"
                    + " end_time) VALUES (?, ?, ?, to_timestamp(?::bigint / 1000.0),"
                    + " to_timestamp(?::bigint / 1000.0)) RETURNING runid")) {
      ps.setLong(1, jobId);
      ps.setString(2, status);
      ps.setString(3, message);
      if (start == null) {
        ps.setNull(4, Types.BIGINT);
      } else {
        ps.setLong(4, start);
      }
      if (end == null) {
        ps.setNull(5, Types.BIGINT);
      } else {
        ps.setLong(5, end);
      }
      try (ResultSet rs = ps.executeQuery()) {
        rs.next();
        return rs.getLong(1);
      }
    }
  }

  @Test
  void theSourcesSqlAgainstPostgresHistoryCursorsArraysTimesAndARunHeld() throws Exception {
    exec(
        "INSERT INTO cron.job (jobname, schedule) VALUES ('nightly vacuum', '0 3 * * *')",
        "INSERT INTO cron.job (jobname, schedule) VALUES (NULL, '10 seconds')");
    long three = Js.dateUtc(2026, 0, 5, 3, 0, 0, 0);
    for (int i = 24; i >= 1; i--) {
      add(1, "succeeded", three - i * DAY, three - i * DAY + 5000, "VACUUM");
    }
    add(1, "failed", three + 123, three + 2123, "ERROR:  deadlock detected\n");

    AtomicLong c = new AtomicLong(T0);
    try (Kit k =
        PgCronTest.kit(new MemoryStore(), c, PgCron.source(source(), PgCronOptions.defaults()))) {
      CheckResult first = k.cw.check();
      assertEquals(List.of("nightly-vacuum", "pg_cron:2"), PgCronTest.names(first));
      assertEquals("0 3 * * *", first.jobs().get(0).definition().schedule());
      assertEquals("UTC", first.jobs().get(0).definition().timezone());

      List<Run> all = k.cw.runs("nightly-vacuum", 100);
      assertEquals(20, all.size());
      Run newest = all.get(0);
      assertEquals("pgcron:25", newest.id());
      assertEquals(three + 123, newest.startedAt());
      assertEquals(2000L, newest.durationMs());
      assertEquals("ERROR:  deadlock detected", newest.error());
      assertEquals(List.of("failed"), k.types());

      // A run going, one queued, then more than a page of runs.
      long going = add(2, "running", T0 - 3000, null, null);
      long queued = add(2, "starting", null, null, null);
      long last = 0;
      for (int i = 1; i <= 520; i++) {
        last = add(2, "succeeded", T0 - 60_000 + i, T0 - 60_000 + i + 1, "1 row");
      }
      c.addAndGet(1000);
      k.cw.check();
      k.cw.check();
      assertEquals(RunStatus.RUNNING, PgCronTest.getRun(k, "pgcron:" + going).status());
      assertNull(k.cw.getRun("pgcron:" + queued));
      // The job's newest runs are read, however many pages they take.
      assertEquals("1 row", PgCronTest.getRun(k, "pgcron:" + last).output());

      exec(
          "UPDATE cron.job_run_details SET status = 'succeeded', end_time = to_timestamp("
              + (T0 - 1000)
              + " / 1000.0) WHERE runid = "
              + going);
      k.cw.check();
      Run done = PgCronTest.getRun(k, "pgcron:" + going);
      assertEquals(RunStatus.OK, done.status());
      assertEquals(2000L, done.durationMs());
      assertEquals(List.of(), k.others());
    }
  }

  /**
   * A check made while the app holds a transaction open on the same database: the source reads on
   * connections of its own, and the app's transaction carries on.
   */
  @Test
  void theSourceNeverReadsInsideTheAppsTransaction() throws Exception {
    exec("INSERT INTO cron.job (jobname, schedule) VALUES ('nightly', '0 3 * * *')");
    add(1, "succeeded", T0 - 2000, T0 - 1000, "ok");
    try (Kit k =
            PgCronTest.kit(
                new MemoryStore(),
                new AtomicLong(T0),
                PgCron.source(source(), PgCronOptions.defaults()));
        Connection app = source().getConnection()) {
      app.setAutoCommit(false);
      try (Statement s = app.createStatement()) {
        s.execute("UPDATE cron.job SET command = 'SELECT 2'");
      }
      k.cw.check();
      try (Statement s = app.createStatement();
          ResultSet rs = s.executeQuery("SELECT 1")) {
        rs.next();
        assertEquals(1, rs.getInt(1), "the transaction is still usable");
      }
      app.rollback();
      assertEquals(1, k.cw.runs("nightly", 20).size());
    }
  }
}
