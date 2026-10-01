package dev.cronwatch.store;

import dev.cronwatch.store.Servers.Kind;

/** The store on MySQL, when {@code CRONWATCH_TEST_MYSQL} is set. */
class MysqlStoreTest extends MysqlDialectTests {
  @Override
  Kind kind() {
    return Kind.MYSQL;
  }
}
