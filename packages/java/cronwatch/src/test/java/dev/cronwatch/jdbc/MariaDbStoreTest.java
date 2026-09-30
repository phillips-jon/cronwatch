package dev.cronwatch.jdbc;

import dev.cronwatch.jdbc.Servers.Kind;

/** The store on MariaDB, when {@code CRONWATCH_TEST_MARIADB} is set. */
class MariaDbStoreTest extends MysqlDialectTests {
  @Override
  Kind kind() {
    return Kind.MARIADB;
  }
}
