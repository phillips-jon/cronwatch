// Package sqltest holds the tests of cronwatch.dev/go/sqlstore against real
// databases: SQLite through modernc.org/sqlite always, Postgres through
// pgx when CRONWATCH_TEST_PG is set, MySQL and MariaDB through
// go-sql-driver/mysql when CRONWATCH_TEST_MYSQL and CRONWATCH_TEST_MARIADB
// are set, and a SQLite file shared with the built SDK in Node. It is a
// module of its own so the drivers are requirements of the tests only,
// never of the cronwatch module. It has no code besides the tests.
package sqltest
