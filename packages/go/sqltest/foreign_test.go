package sqltest

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

import (
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

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

// farCronStarts are last-run starts a foreign or damaged row could hold for
// a cron job: before the year 1 (the first fire of the year 1 was missed),
// after 9999 (never due again), and the BIGINT extremes.
var farCronStarts = []string{"-62135596800001", "253402300800000", "-9223372036854775808", "9223372036854775807"}

// cronOverForeignRow: a check, and the dashboard's pages for the job, over
// a cron job whose last run started at startedAt, answer with no error.
func cronOverForeignRow(t *testing.T, db *sql.DB, dialect sqlstore.Dialect, p, startedAt string) {
	store := newStore(t, db, dialect, p)
	must(t, store.Init(ctx))
	var def cronwatch.Definition
	must(t, def.UnmarshalJSON([]byte(`{"name":"far","schedule":"0 2 * * *","timezone":"UTC","grace":"10m"}`)))
	must(t, store.UpsertJob(ctx, def, 1))
	trigger := "trigger"
	if dialect == sqlstore.MySQL {
		trigger = "`trigger`"
	}
	_, err := db.ExecContext(ctx, "INSERT INTO "+p+"runs (id, job, status, started_at, finished_at, duration_ms, metrics, "+trigger+") VALUES ('far1', 'far', 'ok', "+startedAt+", "+startedAt+", 0, '{}', 'run')")
	must(t, err)

	proc := process(t, store, storetest.NewClock(storetest.T0).Now)
	_, err = proc.Client.Check(ctx)
	must(t, err)
	routes, err := proc.Client.Routes(cronwatch.WithToken("tok"), cronwatch.WithBasePath("/cronwatch"))
	must(t, err)
	for _, path := range []string{"/cronwatch/", "/cronwatch/jobs/far", "/cronwatch/api/jobs/far"} {
		r := httptest.NewRequest(http.MethodGet, "http://app.test"+path, nil)
		r.Header.Set("Authorization", "Bearer tok")
		w := httptest.NewRecorder()
		routes.ServeHTTP(w, r)
		if w.Code != http.StatusOK {
			t.Errorf("%s answered %d", path, w.Code)
		}
	}
	if errs := proc.Errors.List(); len(errs) > 0 {
		t.Fatalf("errors: %v", errs)
	}
	types := proc.Alerts.Types()
	if strings.HasPrefix(startedAt, "-") {
		if len(types) != 1 || types[0] != "missed" || !strings.HasPrefix(proc.Alerts.List()[0].Message, "Due 0001-01-01 02:00:00 UTC ") {
			t.Errorf("alerts: %v", types)
		}
	} else if len(types) != 0 {
		t.Errorf("alerts: %v", types)
	}
	must(t, proc.Client.Close())
}

func TestSQLiteCronOverForeignRow(t *testing.T) {
	for i, startedAt := range farCronStarts {
		t.Run(startedAt, func(t *testing.T) {
			cronOverForeignRow(t, sqliteDB(t, tempFile(t, "farcron"+strconv.Itoa(i)+".db")), sqlstore.SQLite, sqlstore.DefaultPrefix, startedAt)
		})
	}
}

func TestServerCronOverForeignRow(t *testing.T) {
	eachServer(t, func(t *testing.T, b backend) {
		for _, startedAt := range farCronStarts {
			t.Run(startedAt, func(t *testing.T) {
				cronOverForeignRow(t, b.open(t), b.dialect, prefix("farcron"), startedAt)
			})
		}
	})
}

// damagedStates are state rows a damaged or hand-edited MySQL or MariaDB
// row could hold in its LONGTEXT column: text that is not JSON, JSON that
// is not an object, and objects whose version is not a number.
var damagedStates = []string{`{`, `not json`, `5`, `"x"`, `[]`, `null`, `{"version":"x"}`, `{"version":true}`, `{"version":{"a":1}}`, `{"version":[1]}`}

// TestMySQLDamagedStateRowIsReplaced: a check, a silence, and a second check
// over jobs whose state rows are damaged answer with no error, and the
// silence replaces each row (it counts as version 0, as on SQLite).
func TestMySQLDamagedStateRowIsReplaced(t *testing.T) {
	mysqlServers(t, func(t *testing.T, b backend) {
		db := b.open(t)
		p := prefix("dmg")
		store := newStore(t, db, sqlstore.MySQL, p)
		must(t, store.Init(ctx))
		for i, text := range damagedStates {
			name := "dmg" + strconv.Itoa(i)
			var def cronwatch.Definition
			must(t, def.UnmarshalJSON([]byte(`{"name":"`+name+`"}`)))
			must(t, store.UpsertJob(ctx, def, 1))
			_, err := db.ExecContext(ctx, "INSERT INTO "+p+"state (job, state) VALUES (?, ?)", name, text)
			must(t, err)
		}
		proc := process(t, store, storetest.NewClock(storetest.T0).Now)
		_, err := proc.Client.Check(ctx)
		must(t, err)
		for i, text := range damagedStates {
			name := "dmg" + strconv.Itoa(i)
			if _, err := proc.Client.Silence(ctx, name, time.Hour); err != nil {
				t.Errorf("silencing over %s: %v", text, err)
				continue
			}
			st, err := store.GetState(ctx, name)
			must(t, err)
			if st == nil || st.SilencedUntil == nil || *st.SilencedUntil != storetest.T0+3600000 {
				t.Errorf("the state after silencing over %s: %+v", text, st)
			}
		}
		_, err = proc.Client.Check(ctx)
		must(t, err)
		if errs := proc.Errors.List(); len(errs) > 0 {
			t.Fatalf("errors: %v", errs)
		}
		must(t, proc.Client.Close())
	})
}
