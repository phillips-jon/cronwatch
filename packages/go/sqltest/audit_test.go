package sqltest

// What the audit before the first release found in the SQL store, each
// with the scenario that showed it.

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
)

// allBackends runs fn on SQLite and on every server that is set.
func allBackends(t *testing.T, fn func(t *testing.T, db *sql.DB, dialect sqlstore.Dialect, p string)) {
	t.Run("sqlite", func(t *testing.T) {
		fn(t, sqliteDB(t, tempFile(t, "audit.db")), sqlstore.SQLite, "cronwatch_")
	})
	eachServer(t, func(t *testing.T, b backend) { fn(t, b.open(t), b.dialect, prefix("audit")) })
}

// A row another writer (or a hand edit) left in a shape of its own, valid
// JSON but not what the SDK writes, used to fail every read it was part of:
// a running run's metrics that are not all numbers failed RunningRuns, and
// with it every check, and a definition that is not an object failed
// ListJobs. The SDK parses them and carries on; so does the store now.
func TestARowOfAnotherShapeDoesNotBlindTheChecks(t *testing.T) {
	allBackends(t, func(t *testing.T, db *sql.DB, dialect sqlstore.Dialect, p string) {
		s := newStore(t, db, dialect, p)
		must(t, s.Init(ctx))
		must(t, s.InsertRun(ctx, cronwatch.Run{ID: "good", Job: "a", Status: cronwatch.StatusRunning, StartedAt: 1, Metrics: cronwatch.Metrics{}, Trigger: "run"}))
		must(t, s.UpsertJob(ctx, definitionOf(t, `{"name":"a","schedule":"0 * * * *"}`), 1))
		must(t, s.Close())
		_, err := db.ExecContext(ctx, `INSERT INTO `+p+`runs (id, job, status, started_at, metrics) VALUES ('bad', 'b', 'running', 2, '{"rows":"12","n":3}')`)
		must(t, err)
		_, err = db.ExecContext(ctx, `INSERT INTO `+p+`jobs (name, definition, created_at, updated_at) VALUES ('b', '[]', 1, 1)`)
		must(t, err)
		running, err := s.RunningRuns(ctx)
		must(t, err)
		if len(running) != 2 {
			t.Fatalf("running runs: %d, want 2", len(running))
		}
		for _, r := range running {
			if r.ID == "bad" && string(mustJSON(t, r.Metrics)) != `{"n":3}` {
				t.Errorf("the numbers are kept: %s", mustJSON(t, r.Metrics))
			}
		}
		jobs, err := s.ListJobs(ctx)
		must(t, err)
		if len(jobs) != 2 {
			t.Fatalf("jobs: %d, want 2", len(jobs))
		}
		cw, err := cronwatch.New(cronwatch.WithStore(s), cronwatch.WithoutCronSecret(), cronwatch.WithAlerts())
		must(t, err)
		if _, err := cw.Check(ctx); err != nil {
			t.Fatalf("the check: %v", err)
		}
	})
}

func mustJSON(t *testing.T, v interface{ MarshalJSON() ([]byte, error) }) []byte {
	t.Helper()
	b, err := v.MarshalJSON()
	must(t, err)
	return b
}

// MySQL's trigger column is VARCHAR(255): a longer trigger used to lose
// the whole run. It is cut to fit.
func TestMySQLKeepsARunWithALongTrigger(t *testing.T) {
	mysqlServers(t, func(t *testing.T, b backend) {
		s := newStore(t, b.open(t), sqlstore.MySQL, prefix("trigger"))
		must(t, s.Init(ctx))
		long := strings.Repeat("é", 300)
		must(t, s.InsertRun(ctx, cronwatch.Run{ID: "r", Job: "j", Status: cronwatch.StatusRunning, StartedAt: 1, Metrics: cronwatch.Metrics{}, Trigger: long}))
		got, err := s.GetRun(ctx, "r")
		must(t, err)
		if got == nil || got.Trigger != strings.Repeat("é", 255) {
			t.Fatalf("got %+v", got)
		}
	})
}

// A state write from version 0 whose INSERT landed but whose answer was
// lost (the connection dropped after the commit) used to be answered "not
// written", as if another process had written first; the client then
// worked the change out again over its own write, and the alert the first
// attempt opened never went out. The row holding exactly what was sent is
// the write's own.
func TestMySQLCountsAStateWriteWhoseAnswerWasLost(t *testing.T) {
	value := os.Getenv("CRONWATCH_TEST_MYSQL")
	if value == "" {
		t.Skip("MySQL: set CRONWATCH_TEST_MYSQL to run")
	}
	base := mysqlDB(t)
	db, fail := wrapped(t, base, mysqlDSN(t, value))
	p := prefix("lost")
	s := newStore(t, db, sqlstore.MySQL, p)
	must(t, s.Init(ctx))
	fail.Store(func(query string) bool {
		return strings.HasPrefix(query, "INSERT INTO "+p+"state") && !strings.Contains(query, "DUPLICATE")
	})
	one := int64(1)
	ok, err := s.CompareAndSetState(ctx, cronwatch.JobState{Job: "j", Open: []cronwatch.OpenCondition{}, Version: &one}, 0)
	fail.Store(nil)
	if err != nil || !ok {
		t.Fatalf("the write landed: ok %v, err %v", ok, err)
	}
}

// failAfter is a driver around another whose statements, when the hook
// says so, run and then answer an error, as a connection lost after the
// server committed does.
type failAfter struct {
	inner driver.Driver
	hook  *atomic.Value
}

type failHook func(query string) bool

func (d failAfter) Open(name string) (driver.Conn, error) {
	c, err := d.inner.Open(name)
	if err != nil {
		return nil, err
	}
	return failConn{c, d.hook}, nil
}

type failConn struct {
	driver.Conn
	hook *atomic.Value
}

var errLost = errors.New("invalid connection")

func (c failConn) fails(query string) bool {
	h, _ := c.hook.Load().(failHook)
	return h != nil && h(query)
}

func (c failConn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	r, err := c.Conn.(driver.ExecerContext).ExecContext(ctx, query, args)
	if err == nil && c.fails(query) {
		return nil, errLost
	}
	return r, err
}

func (c failConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	return c.Conn.(driver.QueryerContext).QueryContext(ctx, query, args)
}

func (c failConn) BeginTx(ctx context.Context, o driver.TxOptions) (driver.Tx, error) {
	return c.Conn.(driver.ConnBeginTx).BeginTx(ctx, o)
}

func (c failConn) PrepareContext(ctx context.Context, query string) (driver.Stmt, error) {
	st, err := c.Conn.(driver.ConnPrepareContext).PrepareContext(ctx, query)
	if err != nil {
		return nil, err
	}
	return failStmt{st, c.fails(query)}, nil
}

type failStmt struct {
	driver.Stmt
	fail bool
}

func (s failStmt) ExecContext(ctx context.Context, args []driver.NamedValue) (driver.Result, error) {
	r, err := s.Stmt.(driver.StmtExecContext).ExecContext(ctx, args)
	if err == nil && s.fail {
		return nil, errLost
	}
	return r, err
}

func (s failStmt) QueryContext(ctx context.Context, args []driver.NamedValue) (driver.Rows, error) {
	return s.Stmt.(driver.StmtQueryContext).QueryContext(ctx, args)
}

var failSeq atomic.Int64

// failHolder sets and clears a failAfter driver's hook.
type failHolder struct{ v *atomic.Value }

func (f failHolder) Store(h func(string) bool) {
	if h == nil {
		f.v.Store(failHook(nil))
		return
	}
	f.v.Store(failHook(h))
}

// wrapped is a *sql.DB on base's driver through failAfter.
func wrapped(t *testing.T, base *sql.DB, dsn string) (*sql.DB, failHolder) {
	t.Helper()
	hook := &atomic.Value{}
	hook.Store(failHook(nil))
	name := "cw-fail-after-" + strings.NewReplacer("/", "_").Replace(t.Name()) + "-" + string(rune('a'+failSeq.Add(1)))
	sql.Register(name, failAfter{base.Driver(), hook})
	db, err := sql.Open(name, dsn)
	must(t, err)
	t.Cleanup(func() { db.Close() })
	return db, failHolder{hook}
}
