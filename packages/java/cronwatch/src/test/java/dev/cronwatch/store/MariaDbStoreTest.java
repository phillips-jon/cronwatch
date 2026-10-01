package dev.cronwatch.store;

import dev.cronwatch.store.Servers.Kind;

/** The store on MariaDB, when {@code CRONWATCH_TEST_MARIADB} is set. */
class MariaDbStoreTest extends MysqlDialectTests {
  @Override
  Kind kind() {
    return Kind.MARIADB;
  }
}
