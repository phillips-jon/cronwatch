package dev.cronwatch.example;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.store.SqlStore;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.sqlite.SQLiteDataSource;

/** The two crontab lines, each a JVM of its own, on one SQLite file. */
class CrontabTest {
  /** What a child JVM printed and how it ended. */
  record Ran(int status, String out, String err) {}

  private static Ran java(Path db, String main, String... args)
      throws IOException, InterruptedException {
    Path java = Path.of(System.getProperty("java.home"), "bin", "java");
    List<String> command =
        new java.util.ArrayList<>(
            List.of(
                java.toString(),
                "--enable-native-access=ALL-UNNAMED",
                "-cp",
                System.getProperty("java.class.path"),
                main));
    command.addAll(List.of(args));
    ProcessBuilder pb = new ProcessBuilder(command);
    pb.environment().put("CRONWATCH_DB", db.toString());
    Path out = Files.createTempFile(db.getParent(), "out", ".txt");
    Path err = Files.createTempFile(db.getParent(), "err", ".txt");
    pb.redirectOutput(out.toFile());
    pb.redirectError(err.toFile());
    Process p = pb.start();
    if (!p.waitFor(120, TimeUnit.SECONDS)) {
      p.destroyForcibly();
      throw new AssertionError(main + " did not end in two minutes");
    }
    return new Ran(
        p.exitValue(),
        Files.readString(out, StandardCharsets.UTF_8),
        Files.readString(err, StandardCharsets.UTF_8));
  }

  @Test
  void theJobAndItsCheckShareOneFile(@TempDir Path dir) throws Exception {
    Path db = dir.resolve("cronwatch.db");
    Ran job = java(db, "dev.cronwatch.example.Nightly");
    assertEquals(0, job.status(), job.err());
    Ran check = java(db, "dev.cronwatch.example.CronwatchMain", "check");
    assertEquals(0, check.status(), check.err());
    assertEquals("cronwatch: checked 1 job, sent 0 alerts", check.out().strip());

    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite:" + db);
    try (Cronwatch cw =
        Cronwatch.builder().store(SqlStore.sqlite(ds)).noShutdownHook().alerts(List.of()).build()) {
      List<Run> runs = cw.runs("nightly-report", 5);
      assertEquals(1, runs.size());
      assertEquals(RunStatus.OK, runs.get(0).status());
      assertEquals("Report written", runs.get(0).output());
    }

    Ran unknown = java(db, "dev.cronwatch.example.CronwatchMain", "run");
    assertEquals(2, unknown.status());
    assertTrue(unknown.err().contains("usage: cronwatch check"), unknown.err());
  }
}
