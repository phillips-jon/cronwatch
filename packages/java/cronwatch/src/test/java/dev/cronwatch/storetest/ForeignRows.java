package dev.cronwatch.storetest;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.store.Store;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * A client over rows another writer left in a SQL store's tables, rows the SDK's writers never make
 * but a foreign or damaged row can hold: a run that started at the lowest {@code BIGINT} under a
 * state whose version is {@code 1.5}, and a cron job whose last run started before the year 1 or
 * after 9999. Nothing is reported as an error, every duration and time is one every store holds,
 * and the alerts are the SDK's. For a SQL store of the app's own; the caller runs the SQL that
 * plants each row, since only it can write raw rows into its database.
 */
public final class ForeignRows {
  private ForeignRows() {}

  /** Runs one SQL statement against the store's database. */
  @FunctionalInterface
  public interface SqlRunner {
    /**
     * Runs the statement.
     *
     * @throws Exception when it fails
     */
    void exec(String sql) throws Exception;
  }

  /**
   * The starts a foreign or damaged row could give a cron job's last run, as SQL literals: before
   * the year 1, after 9999, and the {@code BIGINT} extremes.
   */
  public static final List<String> FAR_STARTS =
      List.of("-62135596800001", "253402300800000", "-9223372036854775808", "9223372036854775807");

  private record Client(Cronwatch cw, List<Alert> sent, List<String> errors) {}

  private static Client client(Store store) {
    List<Alert> sent = new CopyOnWriteArrayList<>();
    List<String> errors = new CopyOnWriteArrayList<>();
    Cronwatch cw =
        Cronwatch.builder()
            .store(store)
            .alert(Channel.of("capture", (alert, ctx) -> sent.add(alert)))
            .noCronSecret()
            .onError((where, e) -> errors.add(where + ": " + e.getMessage()))
            .noShutdownHook()
            .build();
    return new Client(cw, sent, errors);
  }

  private static void exec(SqlRunner sql, String text) {
    Checks.must("running " + text, () -> sql.exec(text));
  }

  private static List<String> types(List<Alert> alerts) {
    List<String> out = new ArrayList<>();
    for (Alert a : alerts) {
      out.add(a.type().value());
    }
    return out;
  }

  /**
   * Two checks over a job with a 5 minute timeout whose running run started at the lowest {@code
   * BIGINT}, under a state whose version is 1.5: the run is marked timed out with its duration held
   * at 2^53 - 1, the state's 1.5 counts as 0, and the stuck alert is sent, its start written in
   * words.
   *
   * @throws AssertionError at the first thing that goes wrong
   */
  public static void checkOverForeignRows(Store store, String prefix, SqlRunner sql) {
    Checks.must("init", store::init);
    Checks.must(
        "upsertJob",
        () -> store.upsertJob(Definition.fromJson("{\"name\":\"far\",\"timeout\":\"5m\"}"), 1));
    exec(
        sql,
        "INSERT INTO "
            + prefix
            + "runs (id, job, status, started_at) VALUES ('far1', 'far', 'running',"
            + " -9223372036854775808)");
    exec(
        sql,
        "INSERT INTO "
            + prefix
            + "state (job, state) VALUES ('far', '{\"job\":\"far\",\"open\":{},"
            + "\"consecutiveFailures\":0,\"silencedUntil\":null,\"lastAlertAt\":null,"
            + "\"version\":1.5}')");
    Client c = client(store);
    try (Cronwatch cw = c.cw()) {
      for (int i = 0; i < 2; i++) {
        cw.check();
      }
      Checks.eq("nothing reported", c.errors(), List.of());
      Run run = Checks.get("getRun", () -> store.getRun("far1"));
      Checks.eq("the run is there", run != null, true);
      Checks.eq("the run's status", run.status(), RunStatus.TIMEOUT);
      Checks.eq("the duration, held at 2^53 - 1", run.durationMs(), Evaluate.MAX_DURATION_MS);
      JobState state = Checks.get("getState", () -> store.getState("far"));
      Checks.eq("the state is there", state != null, true);
      Checks.eq(
          "the state's 1.5 counted as 0, then the timeout and the alert each wrote it",
          state.version(),
          2L);
      Checks.eq("the timeout counted", state.consecutiveFailures(), 1L);
      Checks.eq("the alerts sent", types(c.sent()), List.of("stuck"));
      Checks.eq(
          "the stuck alert's first line",
          c.sent().get(0).message().split("\n", -1)[0],
          "Started before 0001-01-01 00:00:00 UTC and never reported finishing. Marked as timed"
              + " out after 104249991d 8h.");
    }
  }

  /**
   * A check and the reads the dashboard makes over a cron job ({@code 0 2 * * *} in UTC, grace 10m)
   * whose last run started at {@code startedAt}, one of {@link #FAR_STARTS}. Nothing reports an
   * error. A cron counts from a start before the year 1 as from the year's first millisecond, so
   * the first fire of the year 1 was missed; after 9999 nothing is due again.
   *
   * @throws AssertionError at the first thing that goes wrong
   */
  public static void cronOverForeignRow(
      Store store, String prefix, String startedAt, SqlRunner sql) {
    Checks.must("init", store::init);
    Checks.must(
        "upsertJob",
        () ->
            store.upsertJob(
                Definition.fromJson(
                    "{\"name\":\"far\",\"schedule\":\"0 2 * * *\",\"timezone\":\"UTC\","
                        + "\"grace\":\"10m\"}"),
                1));
    exec(
        sql,
        "INSERT INTO "
            + prefix
            + "runs (id, job, status, started_at, finished_at, duration_ms) VALUES ('far1',"
            + " 'far', 'ok', "
            + startedAt
            + ", "
            + startedAt
            + ", 0)");
    Client c = client(store);
    try (Cronwatch cw = c.cw()) {
      cw.check();
      cw.jobsWithRuns(20);
      cw.jobSummary("far");
      Checks.eq("nothing reported from " + startedAt, c.errors(), List.of());
      boolean missed = startedAt.startsWith("-");
      Checks.eq(
          "the alerts sent from " + startedAt,
          types(c.sent()),
          missed ? List.of("missed") : List.of());
      if (missed) {
        String message = c.sent().get(0).message();
        Checks.eq(
            "the missed alert from " + startedAt + ": " + message,
            message.startsWith("Due 0001-01-01 02:00:00 UTC "),
            true);
      }
    }
  }
}
