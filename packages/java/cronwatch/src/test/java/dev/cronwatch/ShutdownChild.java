package dev.cronwatch;

import dev.cronwatch.jdbc.SqlStore;
import java.util.List;
import org.sqlite.SQLiteDataSource;

/**
 * The child JVM {@link ShutdownHookTest} starts: a client over a SQLite file, a run that sleeps,
 * and {@code System.exit} while it sleeps. Its arguments are the file and {@code hook} or {@code
 * nohook}.
 */
final class ShutdownChild {
  private ShutdownChild() {}

  public static void main(String[] args) throws Exception {
    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite:" + args[0]);
    Cronwatch.Builder builder =
        Cronwatch.builder().store(SqlStore.sqlite(ds)).alerts(List.of()).noCronSecret();
    if (args[1].equals("nohook")) {
      builder.noShutdownHook();
    }
    Cronwatch cw = builder.build();
    Thread.ofPlatform()
        .start(
            () -> {
              try {
                cw.run("interrupted-by-exit", j -> Thread.sleep(120_000));
              } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
              }
            });
    long deadline = System.nanoTime() + 30_000_000_000L;
    while (cw.runs("interrupted-by-exit", 1).isEmpty() && System.nanoTime() < deadline) {
      Thread.sleep(10);
    }
    System.exit(3);
  }
}
