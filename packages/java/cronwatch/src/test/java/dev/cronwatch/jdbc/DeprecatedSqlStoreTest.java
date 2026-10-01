package dev.cronwatch.jdbc;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.storetest.StoreContract;
import org.junit.jupiter.api.Test;
import org.sqlite.SQLiteDataSource;

/** The SQL store under its name before 1.0 still works, as the store it now hands every call to. */
@SuppressWarnings("removal") // the deprecated alias is what this tests
class DeprecatedSqlStoreTest {
  private static SQLiteDataSource memory() {
    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite::memory:");
    return ds;
  }

  @Test
  void theOldNamePassesTheContract() {
    StoreContract.run(SqlStore.sqlite(memory()));
  }

  @Test
  void theOldNameKeepsItsOptions() {
    SqlStore store = SqlStore.sqlite(memory()).prefix("app_");
    assertEquals("app_", store.tablePrefix());
    assertEquals("sqlite", store.dialect());
    assertEquals("SqlStore(sqlite, prefix app_)", store.toString());
    assertEquals("sqlite", SqlStore.of(memory()).dialect());
  }
}
