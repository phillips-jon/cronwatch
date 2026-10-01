package sqltest

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
	"cronwatch.dev/go/storetest"

	_ "github.com/go-sql-driver/mysql"
	_ "github.com/jackc/pgx/v5/stdlib"
	_ "modernc.org/sqlite"
)

// The servers, from the environment:
//
//	CRONWATCH_TEST_PG       a Postgres URL, as pgx reads it:
//	                        postgres://user:password@127.0.0.1:5432/db?sslmode=disable
//	CRONWATCH_TEST_MYSQL    a mysql:// URL (mysql://user:password@127.0.0.1:3306/db,
//	                        as the PHP port's tests take it) or a go-sql-driver DSN
//	                        (user:password@tcp(127.0.0.1:3306)/db)
//	CRONWATCH_TEST_MARIADB  the same, for MariaDB
//
// A test of a server that is not set is skipped, with the reason.

// ctx is the tests' context.
var ctx = context.Background()

// backend is one database the tests run on.
type backend struct {
	name    string
	dialect sqlstore.Dialect
	// open is a new *sql.DB on the backend's database (for SQLite, the
	// file given).
	open func(t *testing.T) *sql.DB
}

var seq atomic.Int64

// prefix is a table prefix no other test uses, so tests on one server
// never see each other's tables.
func prefix(label string) string {
	return fmt.Sprintf("cwgo_%s_%d_%d_", label, os.Getpid()%100000, seq.Add(1))
}

// mysqlDSN reads CRONWATCH_TEST_MYSQL's form: a mysql:// or mariadb:// URL
// becomes a go-sql-driver DSN, anything else is one already.
func mysqlDSN(t *testing.T, value string) string {
	lower := strings.ToLower(value)
	if !strings.HasPrefix(lower, "mysql://") && !strings.HasPrefix(lower, "mariadb://") {
		return value
	}
	u, err := url.Parse(value)
	if err != nil {
		t.Fatalf("CRONWATCH_TEST_MYSQL is not a URL: %v", err)
	}
	password, _ := u.User.Password()
	host := u.Host
	if u.Port() == "" {
		host += ":3306"
	}
	return fmt.Sprintf("%s:%s@tcp(%s)/%s?%s", u.User.Username(), password, host, strings.TrimPrefix(u.Path, "/"), u.RawQuery)
}

func server(t *testing.T, name, variable, driver string, dsn func(string) string) *sql.DB {
	t.Helper()
	value := os.Getenv(variable)
	if value == "" {
		t.Skipf("%s: set %s to run", name, variable)
	}
	db, err := sql.Open(driver, dsn(value))
	if err != nil {
		t.Fatal(err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		db.Close()
		t.Fatalf("%s: %v", name, err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func postgresDB(t *testing.T) *sql.DB {
	return server(t, "Postgres", "CRONWATCH_TEST_PG", "pgx", func(v string) string { return v })
}

func mysqlDB(t *testing.T) *sql.DB {
	return server(t, "MySQL", "CRONWATCH_TEST_MYSQL", "mysql", func(v string) string { return mysqlDSN(t, v) })
}

func mariaDB(t *testing.T) *sql.DB {
	return server(t, "MariaDB", "CRONWATCH_TEST_MARIADB", "mysql", func(v string) string { return mysqlDSN(t, v) })
}

// sqliteDB opens a SQLite file (or ":memory:").
func sqliteDB(t *testing.T, file string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", file)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func tempFile(t *testing.T, name string) string {
	return filepath.Join(t.TempDir(), name)
}

// servers are the backends whose tables are named by a prefix per test.
var servers = []backend{
	{"postgres", sqlstore.Postgres, postgresDB},
	{"mysql", sqlstore.MySQL, mysqlDB},
	{"mariadb", sqlstore.MySQL, mariaDB},
}

// newStore is a store over db with the prefix given; its tables are dropped
// when the test ends.
func newStore(t *testing.T, db *sql.DB, dialect sqlstore.Dialect, p string) *sqlstore.Store {
	t.Helper()
	s, err := sqlstore.New(db, dialect, sqlstore.Prefix(p))
	if err != nil {
		t.Fatal(err)
	}
	if dialect != sqlstore.SQLite {
		t.Cleanup(func() { dropTables(db, p) })
	}
	return s
}

func dropTables(db *sql.DB, p string) {
	for _, table := range []string{"jobs", "runs", "state"} {
		_, _ = db.ExecContext(ctx, "DROP TABLE IF EXISTS "+p+table)
	}
}

// eachServer runs fn on every server that is set, each a subtest.
func eachServer(t *testing.T, fn func(t *testing.T, b backend)) {
	for _, b := range servers {
		t.Run(b.name, func(t *testing.T) { fn(t, b) })
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// process is a client over store, as one process would have.
func process(t *testing.T, store cronwatch.Store, now func() int64) *storetest.Process {
	return storetest.NewProcess(t, store, now)
}

func ptr[T any](v T) *T { return &v }
