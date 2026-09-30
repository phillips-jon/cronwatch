package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.jdbc.SqlStore;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * A JVM that stops with a run open, in a child JVM ({@link ShutdownChild}): the shutdown hook
 * records the run failed, and without the hook it is left running, for the stuck check.
 */
class ShutdownHookTest {
  private static List<Run> runInChild(Path dir, String mode) throws Exception {
    Path file = dir.resolve("cw.db");
    String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
    Process child =
        new ProcessBuilder(
                java,
                "-cp",
                System.getProperty("java.class.path"),
                ShutdownChild.class.getName(),
                file.toString(),
                mode)
            .redirectErrorStream(true)
            .start();
    child.getOutputStream().close();
    assertTrue(child.waitFor(60, TimeUnit.SECONDS), "the child JVM ended");
    String output = new String(child.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    assertEquals(3, child.exitValue(), output);
    try (SqlStore store = SqlStore.sqlite(sqliteSource(file))) {
      store.init();
      return store.listRuns("interrupted-by-exit", 10);
    }
  }

  private static org.sqlite.SQLiteDataSource sqliteSource(Path file) {
    org.sqlite.SQLiteDataSource ds = new org.sqlite.SQLiteDataSource();
    ds.setUrl("jdbc:sqlite:" + file);
    return ds;
  }

  @Test
  void theHookRecordsARunTheJvmLeftOpenAsFailed(@TempDir Path dir) throws Exception {
    List<Run> runs = runInChild(dir, "hook");
    assertEquals(1, runs.size());
    Run run = runs.get(0);
    assertEquals(RunStatus.FAILED, run.status());
    assertEquals("Shutdown: the JVM stopped while the run was in progress", run.error());
  }

  @Test
  void withoutTheHookTheRunIsLeftRunning(@TempDir Path dir) throws Exception {
    List<Run> runs = runInChild(dir, "nohook");
    assertEquals(1, runs.size());
    assertEquals(RunStatus.RUNNING, runs.get(0).status());
    assertNull(runs.get(0).error());
  }
}
