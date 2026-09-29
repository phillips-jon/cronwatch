package sqltest

import (
	"database/sql"
	"strings"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
	"cronwatch.dev/go/storetest"
)

// Rows another process wrote: a state whose version is 1.5 or "x", and a
// running run that started at the lowest BIGINT. Neither may make a
// statement fail, or refuse every write of the job for good.

func foreignVersions(t *testing.T, db *sql.DB, dialect sqlstore.Dialect, p string) {
	store := newStore(t, db, dialect, p)
	must(t, store.Init(ctx))
	insert := "INSERT INTO " + p + "state (job, state) VALUES ('v', ?)"
	if dialect == sqlstore.Postgres {
		insert = "INSERT INTO " + p + "state (job, state) VALUES ('v', $1::jsonb)"
	}
	storetest.ReplayForeignVersions(t, fixturePath, store, func(text string) error {
		_, err := db.ExecContext(ctx, insert, text)
		return err
	})
}

// checkOverForeignRows: a check marks the run timed out with its duration
// held at 2^53 - 1, and writes the state over its version of 1.5. The
// stuck alert is sent: its text writes a start before the year 1 as words,
// not as a date.
func checkOverForeignRows(t *testing.T, db *sql.DB, dialect sqlstore.Dialect, p string) {
	store := newStore(t, db, dialect, p)
	must(t, store.Init(ctx))
	var def cronwatch.Definition
	must(t, def.UnmarshalJSON([]byte(`{"name":"far","timeout":"5m"}`)))
	must(t, store.UpsertJob(ctx, def, 1))
	trigger := "trigger"
	if dialect == sqlstore.MySQL {
		trigger = "`trigger`"
	}
	_, err := db.ExecContext(ctx, "INSERT INTO "+p+"runs (id, job, status, started_at, metrics, "+trigger+") VALUES ('far1', 'far', 'running', -9223372036854775808, '{}', 'run')")
	must(t, err)
	_, err = db.ExecContext(ctx, "INSERT INTO "+p+`state (job, state) VALUES ('far', '{"job":"far","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"version":1.5}')`)
	must(t, err)

	proc := process(t, store, storetest.NewClock(storetest.T0).Now)
	for range 2 {
		_, err := proc.Client.Check(ctx)
		must(t, err)
	}
	if errs := proc.Errors.List(); len(errs) > 0 {
		t.Fatalf("errors: %v", errs)
	}
	run, err := store.GetRun(ctx, "far1")
	must(t, err)
	if run.Status != cronwatch.StatusTimeout || run.DurationMs == nil || *run.DurationMs != 9007199254740991 {
		t.Errorf("the run: %s, duration %v", run.Status, run.DurationMs)
	}
	st, err := store.GetState(ctx, "far")
	must(t, err)
	// 1.5 counted as 0, then the timeout and the alert each wrote the state.
	if st.Version == nil || *st.Version != 2 || st.ConsecutiveFailures != 1 {
		t.Errorf("the state: version %v, %d failures", st.Version, st.ConsecutiveFailures)
	}
	sent := proc.Alerts.List()
	if len(sent) != 1 || sent[0].Type != "stuck" {
		t.Fatalf("alerts: %v", proc.Alerts.Types())
	}
	want := "Started before 0001-01-01 00:00:00 UTC and never reported finishing. Marked as timed out after 104249991d 8h."
	if first, _, _ := strings.Cut(sent[0].Message, "\n"); first != want {
		t.Errorf("the stuck alert's first line: %q", first)
	}
	must(t, proc.Client.Close())
}

func TestSQLiteForeignVersions(t *testing.T) {
	foreignVersions(t, sqliteDB(t, tempFile(t, "fv.db")), sqlstore.SQLite, sqlstore.DefaultPrefix)
}

func TestSQLiteCheckOverForeignRows(t *testing.T) {
	checkOverForeignRows(t, sqliteDB(t, tempFile(t, "far.db")), sqlstore.SQLite, sqlstore.DefaultPrefix)
}

func TestServerForeignVersions(t *testing.T) {
	eachServer(t, func(t *testing.T, b backend) {
		foreignVersions(t, b.open(t), b.dialect, prefix("fv"))
	})
}

func TestServerCheckOverForeignRows(t *testing.T) {
	eachServer(t, func(t *testing.T, b backend) {
		checkOverForeignRows(t, b.open(t), b.dialect, prefix("far"))
	})
}
