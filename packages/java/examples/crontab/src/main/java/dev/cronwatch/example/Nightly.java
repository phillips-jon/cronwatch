package dev.cronwatch.example;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.store.SqlStore;
import org.sqlite.SQLiteDataSource;

/**
 * A job a crontab runs, recorded on a SQLite file both crontab lines reach:
 *
 * <pre>
 * # m  h  dom mon dow  command
 * 0    2  *   *   *    java -cp app.jar dev.cronwatch.example.Nightly
 * *&#47;5  *  *   *   *    java -cp app.jar dev.cronwatch.example.CronwatchMain check
 * </pre>
 *
 * <p>The file is {@code $CRONWATCH_DB}, else {@code cronwatch.db} in the working directory.
 */
public final class Nightly {
  private Nightly() {}

  /** The client both lines build: the same store, so the check sees the job's runs. */
  public static Cronwatch cronwatch() {
    String path = System.getenv("CRONWATCH_DB");
    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite:" + (path == null || path.isEmpty() ? "cronwatch.db" : path));
    return Cronwatch.builder().store(SqlStore.sqlite(ds)).build();
  }

  /** Builds the report, as a recorded run, and exits non-zero when it fails, so cron mails it. */
  public static void main(String[] args) {
    try (Cronwatch cw = cronwatch()) {
      Job nightly =
          cw.job(
              "nightly-report",
              JobOptions.builder().schedule("0 2 * * *").grace("15m").expect("Report written"));
      nightly.run(job -> job.log("Report written"));
    } catch (RuntimeException e) {
      System.err.println("nightly-report failed: " + e.getMessage());
      System.exit(1);
    }
  }
}
