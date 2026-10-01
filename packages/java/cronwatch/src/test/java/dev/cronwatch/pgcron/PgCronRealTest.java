package dev.cronwatch.pgcron;

import static dev.cronwatch.pgcron.PgCronTest.MIN;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Alert;
import dev.cronwatch.CheckResult;
import dev.cronwatch.JobHealth;
import dev.cronwatch.JobOptions;
import dev.cronwatch.JobSummary;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.Source;
import dev.cronwatch.pgcron.PgCronTest.Kit;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Servers;
import dev.cronwatch.store.Servers.Kind;
import dev.cronwatch.store.SqlStore;
import dev.cronwatch.store.Store;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicLong;
import javax.sql.DataSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * The pg_cron source against a real pg_cron, as the SDK's {@code pgcron.test.ts} and the Go, Rust
 * and Elixir ports run it, when {@code CRONWATCH_TEST_PGCRON} is the URL of a Postgres with pg_cron
 * preloaded ({@code cron.database_name} naming that database). Waits are polls, held to 30 seconds
 * each.
 */
class PgCronRealTest {
  /** The server as its URL's own role, which may do anything. */
  private static DataSource admin() {
    return Servers.dataSource(Kind.PGCRON);
  }

  @BeforeEach
  void onlyWithPgCron() throws SQLException {
    Servers.assume(Kind.PGCRON);
    // The tests may start at once, and two CREATE EXTENSIONs race.
    try (Connection c = admin().getConnection()) {
      c.setAutoCommit(false);
      try (Statement s = c.createStatement()) {
        s.execute("SELECT pg_advisory_xact_lock(7307)");
        s.execute("CREATE EXTENSION IF NOT EXISTS pg_cron");
      }
      c.commit();
    }
  }

  private static String tag(String label) {
    return "cwjava" + label + Integer.toString(ThreadLocalRandom.current().nextInt(1 << 24), 36);
  }

  private void sql(String text, Object... params) throws SQLException {
    try (Connection c = admin().getConnection();
        PreparedStatement ps = c.prepareStatement(text)) {
      for (int i = 0; i < params.length; i++) {
        ps.setObject(i + 1, params[i]);
      }
      ps.execute();
    }
  }

  private List<Long> longs(String text, Object... params) throws SQLException {
    try (Connection c = admin().getConnection();
        PreparedStatement ps = c.prepareStatement(text)) {
      for (int i = 0; i < params.length; i++) {
        ps.setObject(i + 1, params[i]);
      }
      List<Long> out = new ArrayList<>();
      try (ResultSet rs = ps.executeQuery()) {
        while (rs.next()) {
          out.add(rs.getLong(1));
        }
      }
      return out;
    }
  }

  @FunctionalInterface
  interface Condition {
    boolean holds() throws Exception;
  }

  /** Polls every quarter second until it holds, for up to 30 seconds. */
  private static void until(String what, Condition condition) throws Exception {
    long deadline = System.nanoTime() + 30_000_000_000L;
    while (!condition.holds()) {
      if (System.nanoTime() > deadline) {
        throw new AssertionError("not so within 30 seconds: " + what);
      }
      Thread.sleep(250);
    }
  }

  private long detailCount(String name) throws SQLException {
    return longs(
            "SELECT count(*) FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE"
                + " j.jobname = ? AND d.start_time IS NOT NULL",
            name)
        .get(0);
  }

  private long statusCount(String name, String status) throws SQLException {
    return longs(
            "SELECT count(*) FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE"
                + " j.jobname = ? AND d.status = ?",
            name,
            status)
        .get(0);
  }

  private static Source source(String tag, JobOptions options, DataSource ds) {
    return PgCron.source(
        ds,
        PgCronOptions.builder()
            .pick(j -> j.jobName() != null && j.jobName().startsWith(tag))
            .options(options)
            .build());
  }

  private static JobSummary find(List<JobSummary> jobs, String name) {
    return PgCronTest.find(jobs, name);
  }

  @Test
  void theSourceAgainstARealPgCron() throws Exception {
    String tag = tag("real");
    String prefix = tag + "_";
    String ok = tag + "-ok";
    String fail = tag + "-fail";
    String sleep = tag + "-sleep";
    AtomicLong offset = new AtomicLong();
    Store store = SqlStore.postgres(admin()).prefix(prefix);
    List<Alert> alerts = new CopyOnWriteArrayList<>();
    try {
      sql("SELECT cron.schedule(?, '1 seconds', 'SELECT 1')", ok);
      sql("SELECT cron.schedule(?, '1 seconds', 'SELECT 1/0')", fail);
      sql("SELECT cron.schedule(?, '1 seconds', 'SELECT pg_sleep(3)')", sleep);
      until(
          "runs of each job",
          () -> statusCount(ok, "succeeded") >= 2 && statusCount(fail, "failed") >= 1);

      Kit k = kit(store, offset, source(tag, JobOptions.builder().grace("30s"), admin()), alerts);
      CheckResult first = k.cw.check();
      assertEquals("every 1s", find(first.jobs(), ok).definition().schedule());
      assertEquals("UTC", find(first.jobs(), ok).definition().timezone());
      List<Run> okRuns = k.cw.runs(ok, 20);
      assertTrue(okRuns.size() >= 2, "ok runs imported (" + okRuns.size() + ")");
      assertTrue(
          okRuns.stream()
              .allMatch(r -> r.id().startsWith("pgcron:") && r.trigger().equals("pg_cron")));
      assertTrue(
          okRuns.stream()
              .anyMatch(r -> r.status().equals(RunStatus.OK) && "1 row".equals(r.output())));
      assertTrue(
          k.cw.runs(fail, 20).stream()
              .anyMatch(
                  r ->
                      r.status().equals(RunStatus.FAILED)
                          && String.valueOf(r.error()).contains("division by zero")),
          "failure and its message imported");
      List<String> firstAlerts = new ArrayList<>();
      for (Alert a : first.alerts()) {
        firstAlerts.add(a.type().value() + " " + a.job());
      }
      assertEquals(List.of("failed " + fail), firstAlerts);
      assertEquals(JobHealth.HEALTHY, find(first.jobs(), ok).health());

      // A run imported while it was going is updated when it finishes.
      long[] running = {0};
      until(
          "the sleeping job running",
          () -> {
            List<Long> ids =
                longs(
                    "SELECT d.runid FROM cron.job_run_details d JOIN cron.job j USING (jobid)"
                        + " WHERE j.jobname = ? AND d.status = 'running' AND d.start_time IS NOT"
                        + " NULL",
                    sleep);
            running[0] = ids.isEmpty() ? 0 : ids.get(0);
            return !ids.isEmpty();
          });
      k.cw.check();
      Run imported = k.cw.getRun("pgcron:" + running[0]);
      assertNotNull(imported);
      assertEquals(RunStatus.RUNNING, imported.status());
      Kit current = k;
      until(
          "the sleeping run finished",
          () -> {
            current.cw.check();
            Run r = current.cw.getRun("pgcron:" + running[0]);
            return r != null && r.status().equals(RunStatus.OK);
          });
      Run slept = k.cw.getRun("pgcron:" + running[0]);
      assertNotNull(slept);
      assertTrue(
          slept.durationMs() != null && slept.durationMs() >= 2900,
          "duration " + slept.durationMs());

      // New runs keep arriving; nothing is copied twice, even by a fresh client after a restart.
      int before = k.cw.runs(ok, 500).size();
      until(
          "later runs imported",
          () -> {
            current.cw.check();
            return current.cw.runs(ok, 500).size() > before;
          });
      List<Run> after = k.cw.runs(ok, 500);
      List<String> ids = new ArrayList<>();
      for (Run r : after) {
        ids.add(r.id());
      }
      assertEquals(ids.size(), new HashSet<>(ids).size());

      // The ok job is unscheduled, and the fail job paused: neither is missed.
      sql("SELECT cron.unschedule(?)", ok);
      sql("SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = ?", fail);
      until(
          "the paused job's runs ended",
          () ->
              statusCount(fail, "running") == 0
                  && statusCount(fail, "starting") == 0
                  && statusCount(fail, "sending") == 0
                  && statusCount(fail, "connecting") == 0);
      k.close();
      k = kit(store, offset, source(tag, JobOptions.builder().grace("30s"), admin()), alerts);
      k.cw.check();
      int settled = k.cw.runs(fail, 500).size();
      k.cw.check();
      assertEquals(settled, k.cw.runs(fail, 500).size(), "re-import adds nothing");
      assertEquals(Math.min(detailCount(fail), settled), k.cw.runs(fail, 500).size());
      offset.set(2 * MIN);
      CheckResult late = k.cw.check();
      assertFalse(
          late.alerts().stream()
              .anyMatch(a -> a.type().value().equals("missed") && a.job().equals(ok)),
          "unscheduled job not missed: it is gone, not late");
      JobSummary okJob = find(late.jobs(), ok);
      assertNull(okJob.definition().schedule());
      assertTrue(
          String.valueOf(okJob.definition().description()).contains("no longer in cron.job"),
          okJob.definition().description());
      assertFalse(
          late.alerts().stream()
              .anyMatch(a -> a.job().equals(fail) && a.type().value().equals("missed")),
          "paused job not missed");
      k.close();
    } finally {
      sql("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE ?", tag + "%");
      Servers.drop(Kind.PGCRON, prefix);
    }
  }

  private static Kit kit(Store store, AtomicLong offset, Source source, List<Alert> alerts) {
    return PgCronTest.kit(store, () -> System.currentTimeMillis() + offset.get(), source, alerts);
  }

  private long insert(long jobId, String status, String times, String message) throws SQLException {
    return longs(
            "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status,"
                + " return_message, start_time, end_time) SELECT ?, nextval('cron.runid_seq'),"
                + " 'postgres', 'postgres', 'select 1', ?, ?, "
                + times
                + " RETURNING runid",
            jobId,
            status,
            message)
        .get(0);
  }

  @Test
  void restartRowsACrowdedJobFirstSightAndARename() throws Exception {
    String tag = tag("row");
    String busy = tag + "-busy";
    String quiet = tag + "-quiet";
    String hist = tag + "-hist";
    try {
      long busyId = schedulePaused(busy);
      long quietId = schedulePaused(quiet);
      long histId = schedulePaused(hist);
      // First sight of a job whose newest rows include a run cut off by a restart, and older
      // failures.
      sql(
          "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status,"
              + " return_message, start_time, end_time) SELECT ?, nextval('cron.runid_seq'),"
              + " 'postgres', 'postgres', 'select 1', 'failed', 'ERROR: old', now() - interval '3"
              + " days', now() - interval '3 days' FROM generate_series(1, 5)",
          histId);
      insert(histId, "failed", "NULL, NULL", "server restarted");
      sql(
          "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status,"
              + " return_message, start_time, end_time) SELECT ?, nextval('cron.runid_seq'),"
              + " 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() -"
              + " make_interval(mins => 30 - g), now() - make_interval(mins => 30 - g) FROM"
              + " generate_series(1, 19) g",
          histId);

      Source src =
          PgCron.source(
              admin(),
              PgCronOptions.builder()
                  .pick(j -> j.jobName() != null && j.jobName().startsWith(tag))
                  .timezone("UTC")
                  .build());
      try (Kit k = PgCronTest.kit(new MemoryStore(), null, src)) {
        k.cw.check();
        assertEquals(20, k.cw.runs(hist, 500).size(), "twenty newest copied");
        assertEquals(List.of(), k.types(), "history is never judged");
        k.cw.check();
        assertEquals(20, k.cw.runs(hist, 500).size(), "and never read again");

        // A restart cuts off a busy job's queued run; the busy job then runs past a page; then
        // the quiet job fails.
        long cut = insert(busyId, "failed", "NULL, NULL", "server restarted");
        sql(
            "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status,"
                + " return_message, start_time, end_time) SELECT ?, nextval('cron.runid_seq'),"
                + " 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() -"
                + " make_interval(secs => 600 - g), now() - make_interval(secs => 600 - g) FROM"
                + " generate_series(1, 520) g",
            busyId);
        long disk = insert(quietId, "failed", "now(), now()", "ERROR: disk full");
        for (int i = 0; i < 3; i++) {
          k.cw.check();
        }
        Run cutRun = k.cw.getRun("pgcron:" + cut);
        assertNotNull(cutRun);
        assertEquals("server restarted", cutRun.error());
        Run diskRun = k.cw.getRun("pgcron:" + disk);
        assertNotNull(diskRun);
        assertEquals(RunStatus.FAILED, diskRun.status(), "the quiet job's failure is read");
        assertTrue(
            k.alerts.stream()
                .anyMatch(a -> a.type().value().equals("failed") && a.job().equals(quiet)));

        // Renamed in pg_cron: the old name keeps its runs and loses its schedule.
        sql("UPDATE cron.job SET jobname = ? WHERE jobid = ?", quiet + "-v2", quietId);
        sql("SELECT cron.alter_job(?, active := true)", quietId);
        k.cw.check();
        List<JobSummary> jobs = k.cw.jobs();
        JobSummary old = find(jobs, quiet);
        assertNull(old.definition().schedule());
        assertTrue(String.valueOf(old.definition().description()).contains("renamed to"));
        assertEquals("0 3 * * *", find(jobs, quiet + "-v2").definition().schedule());
        assertEquals(List.of(), k.others());
      }
    } finally {
      sql("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE ?", tag + "%");
    }
  }

  /**
   * Schedules a job and pauses it, so pg_cron itself adds no rows while the test writes its own.
   */
  private long schedulePaused(String name) throws SQLException {
    long id = longs("SELECT cron.schedule(?, '0 3 * * *', 'SELECT 1')", name).get(0);
    sql("SELECT cron.alter_job(?, active := false)", id);
    return id;
  }

  /**
   * A role that may read cron's tables but not its settings: the zone is assumed and reported,
   * {@code cron.log_run} unreadable is taken as on, and a transaction the role has open on another
   * connection is never touched.
   */
  @Test
  void aRoleThatMayNotReadCronSettingsIsGivenUtcToldOnceAndItsTransactionUntouched()
      throws Exception {
    String role = tag("role");
    DataSource asRole = Servers.dataSource(Kind.PGCRON, null, role, "pw", "");
    try {
      sql("CREATE ROLE " + role + " LOGIN PASSWORD 'pw'");
      sql("GRANT USAGE ON SCHEMA cron TO " + role);
      sql("GRANT SELECT ON cron.job, cron.job_run_details TO " + role);
      try (Connection c = asRole.getConnection();
          PreparedStatement ps =
              c.prepareStatement("SELECT cron.schedule(?, '0 3 * * *', 'SELECT 1')")) {
        ps.setString(1, role + "-job");
        ps.execute();
      }
      try (Kit k =
              PgCronTest.kit(
                  new MemoryStore(), null, PgCron.source(asRole, PgCronOptions.defaults()));
          Connection app = asRole.getConnection()) {
        app.setAutoCommit(false);
        try (Statement s = app.createStatement()) {
          s.execute("SELECT 1");
        }
        CheckResult result = k.cw.check();
        try (Statement s = app.createStatement();
            ResultSet rs = s.executeQuery("SELECT 1")) {
          rs.next();
          assertEquals(1, rs.getInt(1), "the transaction is still usable");
        }
        app.rollback();
        JobSummary job = find(result.jobs(), role + "-job");
        assertEquals("UTC", job.definition().timezone(), "assumed");
        assertEquals(
            "0 3 * * *", job.definition().schedule(), "cron.log_run unreadable is taken as on");
        assertTrue(
            k.errors.stream().anyMatch(e -> e.contains("could not read cron.timezone")),
            k.errors.toString());
      }
    } finally {
      // Every job of the role goes before the role: pg_cron's scheduler stops on a job whose role
      // is gone.
      quietly(() -> sql("SELECT cron.unschedule(jobid) FROM cron.job WHERE username = ?", role));
      quietly(() -> sql("DROP OWNED BY " + role));
      quietly(() -> sql("DROP ROLE IF EXISTS " + role));
    }
  }

  @FunctionalInterface
  interface Step {
    void run() throws Exception;
  }

  private static void quietly(Step step) {
    try {
      step.run();
    } catch (Exception e) {
      // Cleaning up after a failure: the failure is what the test reports.
    }
  }
}
