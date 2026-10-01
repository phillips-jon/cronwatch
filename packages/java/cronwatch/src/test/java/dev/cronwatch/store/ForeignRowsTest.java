package dev.cronwatch.store;

import dev.cronwatch.storetest.ForeignRows;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.Statement;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.sqlite.SQLiteDataSource;

/** A client over rows another writer left in SQLite: a start at the lowest BIGINT, far dates. */
class ForeignRowsTest {
  @TempDir Path dir;

  private static SqlStore store(Path file) {
    SQLiteDataSource source = new SQLiteDataSource();
    source.setUrl("jdbc:sqlite:" + file);
    return SqlStore.sqlite(source);
  }

  private static void exec(Path file, String sql) throws Exception {
    try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + file);
        Statement s = c.createStatement()) {
      s.execute(sql);
    }
  }

  @Test
  void aCheckOverARunThatStartedAtTheLowestBigint() {
    Path file = dir.resolve("far.db");
    ForeignRows.checkOverForeignRows(store(file), "cronwatch_", sql -> exec(file, sql));
  }

  @Test
  void aCheckAndTheDashboardsReadsOverACronJobWhoseLastRunStartedFarOff() {
    int n = 0;
    for (String startedAt : ForeignRows.FAR_STARTS) {
      Path file = dir.resolve("far-" + n++ + ".db");
      ForeignRows.cronOverForeignRow(store(file), "cronwatch_", startedAt, sql -> exec(file, sql));
    }
  }
}
