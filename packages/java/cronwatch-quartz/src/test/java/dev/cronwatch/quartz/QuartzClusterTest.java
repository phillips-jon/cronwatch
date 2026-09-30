package dev.cronwatch.quartz;

import static dev.cronwatch.quartz.Quartzes.await;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.store.MemoryStore;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;
import org.quartz.Job;
import org.quartz.JobBuilder;
import org.quartz.JobDetail;
import org.quartz.JobExecutionContext;
import org.quartz.Scheduler;
import org.quartz.TriggerBuilder;

/**
 * Quartz clustered over a JDBC job store on Postgres, when {@code CRONWATCH_TEST_PG} is set: a job
 * a node was running when it stopped is recovered on another node, and the recovering firing
 * finishes the earlier firing's run as failed.
 */
class QuartzClusterTest {
  static final CountDownLatch RELEASE = new CountDownLatch(1);

  /** Runs until the test lets it go. */
  public static final class Blocking implements Job {
    @Override
    public void execute(JobExecutionContext ctx) {
      try {
        RELEASE.await();
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }
  }

  /** Quartz's own Postgres tables, from its jar, statement by statement. */
  private static List<String> statements() throws IOException {
    try (InputStream in =
        Scheduler.class.getResourceAsStream("/org/quartz/impl/jdbcjobstore/tables_postgres.sql")) {
      assertNotNull(in, "Quartz's tables_postgres.sql");
      StringBuilder sql = new StringBuilder();
      for (String line : new String(in.readAllBytes(), StandardCharsets.UTF_8).lines().toList()) {
        if (!line.trim().startsWith("--")) {
          sql.append(line).append('\n');
        }
      }
      List<String> out = new ArrayList<>();
      for (String s : sql.toString().split(";", -1)) {
        String t = s.trim();
        if (!t.isEmpty() && !t.equalsIgnoreCase("COMMIT")) {
          out.add(t);
        }
      }
      return out;
    }
  }

  private static void run(List<String> sql, boolean dropsOnly) throws SQLException {
    try (Connection c = Quartzes.pg();
        Statement s = c.createStatement()) {
      for (String statement : sql) {
        if (!dropsOnly || statement.toUpperCase(java.util.Locale.ROOT).startsWith("DROP")) {
          s.execute(statement);
        }
      }
    }
  }

  private static @Nullable Run first(Cronwatch cw, String name) {
    List<Run> runs = cw.runs(name, 10);
    return runs.isEmpty() ? null : runs.get(runs.size() - 1);
  }

  @Test
  void aJobRecoveredOnAnotherNodeFailsTheEarlierRun() throws Exception {
    assumeTrue(Quartzes.pgUrl() != null, "CRONWATCH_TEST_PG is not set");
    List<String> sql = statements();
    run(sql, false);
    MemoryStore store = new MemoryStore();
    Scheduler a = Quartzes.clustered("cw-cluster", "node-a");
    // One JVM keeps one scheduler per name, and a cluster's nodes share theirs: node b is made
    // once node a has stopped.
    Scheduler b = null;
    try (Cronwatch cwA = Quartzes.client(store, Quartzes.errors());
        Cronwatch cwB = Quartzes.client(store, Quartzes.errors())) {
      CronwatchQuartz.watch(cwA, a, QuartzOptions.defaults().app("billing"));
      JobDetail job =
          JobBuilder.newJob(Blocking.class)
              .withIdentity("long", "reports")
              .requestRecovery()
              .storeDurably()
              .build();
      a.scheduleJob(job, TriggerBuilder.newTrigger().withIdentity("t").startNow().build());
      a.start();
      await(
          "the run on node a",
          () -> {
            Run r = first(cwA, "reports.long");
            return r != null && r.status().equals(RunStatus.RUNNING);
          });
      Run earlier = first(cwA, "reports.long");
      assertNotNull(earlier);
      // Node a stops without waiting for its job, as a node that dies leaves it.
      a.shutdown(false);

      b = Quartzes.clustered("cw-cluster", "node-b");
      CronwatchQuartz.watch(cwB, b, QuartzOptions.defaults().app("billing"));
      b.start();
      await(
          "the earlier run failed by the recovery",
          () -> cwB.getRun(earlier.id()).status().equals(RunStatus.FAILED));
      assertEquals(CronwatchQuartz.RECOVERED, cwB.getRun(earlier.id()).error());
      await("the recovered firing's own run", () -> cwB.runs("reports.long", 10).size() == 2);
    } finally {
      RELEASE.countDown();
      if (b != null) {
        b.shutdown(true);
      }
      a.shutdown(true);
      run(sql, true);
    }
  }
}
