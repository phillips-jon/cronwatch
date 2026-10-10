package sqltest

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
	"cronwatch.dev/go/storetest"
)

// Each dialect's own tests: stores.test.ts's for SQLite and Postgres, and
// the PHP port's MysqlStoreTest for MySQL and MariaDB.

func column(t *testing.T, db *sql.DB, query string, args ...any) []string {
	t.Helper()
	rows, err := db.QueryContext(ctx, query, args...)
	must(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var v sql.NullString
		must(t, rows.Scan(&v))
		out = append(out, v.String)
	}
	must(t, rows.Err())
	return out
}

func definitionOf(t *testing.T, text string) cronwatch.Definition {
	var d cronwatch.Definition
	must(t, json.Unmarshal([]byte(text), &d))
	return d
}

func stateOf(t *testing.T, text string) cronwatch.JobState {
	var s cronwatch.JobState
	must(t, json.Unmarshal([]byte(text), &s))
	return s
}

// jsonOf is the SDK's JSON of a value. A type's own MarshalJSON is called
// directly: encoding/json would escape U+2028, U+2029, and HTML characters
// in what it returns, which JSON.stringify does not.
func jsonOf(t *testing.T, v any) string {
	if m, ok := v.(json.Marshaler); ok {
		b, err := m.MarshalJSON()
		must(t, err)
		return string(b)
	}
	b, err := json.Marshal(v)
	must(t, err)
	return string(b)
}

// ---- SQLite

func TestSQLiteFilePersistsBetweenOpens(t *testing.T) {
	file := tempFile(t, "persist.db")
	a := newStore(t, sqliteDB(t, file), sqlstore.SQLite, sqlstore.DefaultPrefix)
	must(t, a.Init(ctx))
	must(t, a.UpsertJob(ctx, definitionOf(t, `{"name":"keep"}`), 1))
	must(t, a.Close())
	b := newStore(t, sqliteDB(t, file), sqlstore.SQLite, sqlstore.DefaultPrefix)
	must(t, b.Init(ctx))
	j, err := b.GetJob(ctx, "keep")
	must(t, err)
	if j.CreatedAt != 1 {
		t.Errorf("createdAt %d", j.CreatedAt)
	}
	must(t, b.Close())
}

func TestSQLiteOpeningRetriesABusyDatabase(t *testing.T) {
	file := tempFile(t, "busy.db")
	holderDB := sqliteDB(t, file)
	holder, err := holderDB.Conn(ctx)
	must(t, err)
	defer holder.Close()
	_, err = holder.ExecContext(ctx, "CREATE TABLE t (x)")
	must(t, err)
	_, err = holder.ExecContext(ctx, "BEGIN EXCLUSIVE")
	must(t, err)
	store := newStore(t, sqliteDB(t, file), sqlstore.SQLite, sqlstore.DefaultPrefix)
	started := time.Now()
	err = store.Init(ctx)
	if err == nil || !strings.Contains(err.Error(), "SQLITE_BUSY") {
		t.Fatalf("init on a busy database: %v", err)
	}
	if time.Since(started) < 1500*time.Millisecond {
		t.Errorf("it gave up after %s, without trying for a while first", time.Since(started))
	}
	_, err = holder.ExecContext(ctx, "COMMIT")
	must(t, err)
	// The next use opens afresh, and gets WAL and the busy timeout this time.
	must(t, store.Init(ctx))
	must(t, store.UpsertJob(ctx, definitionOf(t, `{"name":"after"}`), 1))
	if mode := column(t, holderDB, "PRAGMA journal_mode"); !reflect.DeepEqual(mode, []string{"wal"}) {
		t.Errorf("journal_mode %v", mode)
	}
	must(t, store.Close())
}

func TestSQLitePrefixKeepsTwoStoresApart(t *testing.T) {
	db := sqliteDB(t, tempFile(t, "two.db"))
	one := newStore(t, db, sqlstore.SQLite, sqlstore.DefaultPrefix)
	two := newStore(t, db, sqlstore.SQLite, "other_")
	must(t, one.Init(ctx))
	must(t, two.Init(ctx))
	must(t, one.UpsertJob(ctx, definitionOf(t, `{"name":"a"}`), 1))
	j, err := two.GetJob(ctx, "a")
	must(t, err)
	if j != nil {
		t.Error("the other prefix sees the job")
	}
	tables := column(t, db, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
	want := []string{"cronwatch_jobs", "cronwatch_runs", "cronwatch_state", "other_jobs", "other_runs", "other_state"}
	if !reflect.DeepEqual(tables, want) {
		t.Errorf("tables %v", tables)
	}
	must(t, one.Close())
	must(t, two.Close())
}

// Many goroutines on one SQLite store take turns on its one connection.
func TestSQLiteManyGoroutines(t *testing.T) {
	store := newStore(t, sqliteDB(t, tempFile(t, "many.db")), sqlstore.SQLite, sqlstore.DefaultPrefix)
	must(t, store.Init(ctx))
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for k := 0; k < 10; k++ {
				r := storetest.NewRun(fmt.Sprintf("g%d-%d", i, k), "many", cronwatch.StatusOK, int64(i*100+k))
				if err := store.InsertRun(ctx, r); err != nil {
					t.Error(err)
				}
			}
		}()
	}
	wg.Wait()
	runs, err := store.ListRuns(ctx, "many", 500)
	must(t, err)
	if len(runs) != 200 {
		t.Errorf("%d runs", len(runs))
	}
	must(t, store.Close())
}

// ---- Postgres

func TestPostgresSchemaIsTheSDKs(t *testing.T) {
	db := postgresDB(t)
	p := prefix("schema")
	store := newStore(t, db, sqlstore.Postgres, p)
	must(t, store.Init(ctx))
	must(t, store.Init(ctx)) // IF NOT EXISTS: a second init changes nothing
	rows, err := db.QueryContext(ctx, `SELECT table_name, column_name, data_type, coalesce(column_default, '') FROM information_schema.columns
		WHERE table_name LIKE $1 ORDER BY table_name, ordinal_position`, p+"%")
	must(t, err)
	types, defaults := map[string]string{}, map[string]string{}
	var runColumns []string
	for rows.Next() {
		var table, col, typ, def string
		must(t, rows.Scan(&table, &col, &typ, &def))
		key := strings.TrimPrefix(table, p) + "." + col
		types[key], defaults[key] = typ, def
		if table == p+"runs" {
			runColumns = append(runColumns, col)
		}
	}
	rows.Close()
	if want := []string{"seq", "id", "job", "status", "started_at", "finished_at", "duration_ms", "error", "output", "metrics", "trigger"}; !reflect.DeepEqual(runColumns, want) {
		t.Errorf("run columns %v", runColumns)
	}
	for key, want := range map[string]string{"runs.seq": "bigint", "runs.started_at": "bigint", "runs.metrics": "jsonb", "jobs.definition": "jsonb", "state.state": "jsonb"} {
		if types[key] != want {
			t.Errorf("%s is %s, want %s", key, types[key], want)
		}
	}
	if !strings.HasPrefix(defaults["runs.seq"], "nextval(") || defaults["runs.trigger"] != "'run'::text" {
		t.Errorf("defaults %v", defaults)
	}
	indexes := column(t, db, "SELECT indexname FROM pg_indexes WHERE indexname LIKE $1 ORDER BY indexname", p+"%")
	if want := []string{p + "jobs_pkey", p + "runs_job_started", p + "runs_pkey", p + "runs_running", p + "state_pkey"}; !reflect.DeepEqual(indexes, want) {
		t.Errorf("indexes %v", indexes)
	}
	partial := column(t, db, "SELECT indexdef FROM pg_indexes WHERE indexname = $1", p+"runs_running")
	if len(partial) != 1 || !strings.HasSuffix(partial[0], "WHERE (status = 'running'::text)") {
		t.Errorf("partial index %v", partial)
	}

	// Numbers come back as numbers, and JSONB as the SDK reads it: keys by
	// length, then bytes.
	run := cronwatch.Run{ID: "r1", Job: "nightly", Status: cronwatch.StatusOK, StartedAt: 1767605400000, FinishedAt: ptr(int64(1767605401000)), DurationMs: ptr(int64(1000)),
		Output: ptr("tab\tand \"quotes\" \U0001F600"), Metrics: cronwatch.Metrics{{Name: "ratio", Value: 0.30000000000000004}, {Name: "tiny", Value: 1e-7}, {Name: "huge", Value: 1e21}}, Trigger: "run"}
	must(t, store.InsertRun(ctx, run))
	read, err := store.GetRun(ctx, "r1")
	must(t, err)
	if read.StartedAt != 1767605400000 || *read.DurationMs != 1000 || *read.Output != *run.Output {
		t.Errorf("read %+v", read)
	}
	if got := jsonOf(t, read.Metrics); got != `{"huge":1e+21,"tiny":1e-7,"ratio":0.30000000000000004}` {
		t.Errorf("metrics in JSONB's order: %s", got)
	}
	must(t, store.UpsertJob(ctx, definitionOf(t, `{"name":"a","schedule":"every 5m","tags":["x"]}`), 1))
	j, err := store.GetJob(ctx, "a")
	must(t, err)
	if !reflect.DeepEqual(j.Definition.Keys(), []string{"name", "tags", "schedule"}) {
		t.Errorf("definition keys %v", j.Definition.Keys())
	}
	// Runs started in one millisecond come back in insertion order (seq).
	for _, id := range []string{"t1", "t2", "t3"} {
		must(t, store.InsertRun(ctx, storetest.NewRun(id, "ties", cronwatch.StatusOK, 5)))
	}
	ties, err := store.ListRuns(ctx, "ties", 10)
	must(t, err)
	if ids := []string{ties[0].ID, ties[1].ID, ties[2].ID}; !reflect.DeepEqual(ids, []string{"t3", "t2", "t1"}) {
		t.Errorf("ties %v", ids)
	}
	must(t, store.Close())
}

func TestPostgresNulCharactersAreStillRecorded(t *testing.T) {
	db := postgresDB(t)
	store := newStore(t, db, sqlstore.Postgres, prefix("nul"))
	var reported []error
	cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithAlerts(), cronwatch.WithoutCronSecret(),
		cronwatch.WithErrorHandler(func(err error, where string) { reported = append(reported, fmt.Errorf("%s: %w", where, err)) }))
	must(t, err)
	err = cw.Run(ctx, "nul", func(_ context.Context, job *cronwatch.JobContext) error {
		job.Log("before\x00after")
		return errors.New("bad\x00byte")
	})
	if err == nil || err.Error() != "bad\x00byte" {
		t.Fatalf("the job's own error comes back: %v", err)
	}
	runs, err := cw.Runs(ctx, "nul", 10)
	must(t, err)
	if runs[0].Status != cronwatch.StatusFailed || *runs[0].Output != "beforeafter" || !strings.HasPrefix(*runs[0].Error, "Error: badbyte") {
		t.Errorf("run %+v", runs[0])
	}
	st, err := store.GetState(ctx, "nul")
	must(t, err)
	if st.ConsecutiveFailures != 1 {
		t.Error("the state, with its alert, was written too")
	}
	// So are a trigger, metric names, and a definition's text.
	nul2 := cw.MustJob("nul2", cronwatch.Description("a\x00b"), cronwatch.Tags("t\x00"), cronwatch.Budget("c\x00", 5))
	must(t, nul2.Run(ctx, func(_ context.Context, job *cronwatch.JobContext) error {
		return job.Metric("ro\x00ws", 2)
	}, cronwatch.WithTrigger("cr\x00on")))
	second, err := cw.Runs(ctx, "nul2", 10)
	must(t, err)
	if len(second) != 1 || second[0].Status != cronwatch.StatusOK || second[0].Trigger != "cron" || len(second[0].Metrics) != 1 || second[0].Metrics[0] != (cronwatch.Metric{Name: "rows", Value: 2}) {
		t.Errorf("runs %+v", second)
	}
	stored, err := store.GetJob(ctx, "nul2")
	must(t, err)
	// JSONB gives the keys back in its own order.
	var got, want any
	text, _ := stored.Definition.MarshalJSON()
	must(t, json.Unmarshal(text, &got))
	must(t, json.Unmarshal([]byte(`{"name":"nul2","description":"ab","tags":["t"],"budget":{"c":5}}`), &want))
	if !reflect.DeepEqual(got, want) {
		t.Errorf("definition %s", text)
	}
	if len(reported) > 0 {
		t.Errorf("reported %v", reported)
	}
}

func TestPostgresTwoStoresRacingOnOneJobsState(t *testing.T) {
	p := prefix("race")
	one := newStore(t, postgresDB(t), sqlstore.Postgres, p)
	two := newStore(t, postgresDB(t), sqlstore.Postgres, p)
	must(t, one.Init(ctx))
	must(t, two.Init(ctx))
	state := func(version, n int) cronwatch.JobState {
		return stateOf(t, fmt.Sprintf(`{"job":"r","open":{},"consecutiveFailures":%d,"silencedUntil":null,"lastAlertAt":null,"version":%d}`, n, version))
	}
	race := func(what string, a, b cronwatch.JobState, expected int64) {
		var wg sync.WaitGroup
		results := make([]bool, 2)
		for i, s := range []*sqlstore.Store{one, two} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				st := a
				if i == 1 {
					st = b
				}
				ok, err := s.CompareAndSetState(ctx, st, expected)
				if err != nil {
					t.Error(err)
				}
				results[i] = ok
			}()
		}
		wg.Wait()
		if results[0] == results[1] {
			t.Errorf("%s: %v", what, results)
		}
	}
	race("exactly one insert wins", state(1, 1), state(1, 2), 0)
	race("exactly one update wins", state(2, 3), state(2, 4), 1)
	st, err := one.GetState(ctx, "r")
	must(t, err)
	if *st.Version != 2 {
		t.Errorf("version %d", *st.Version)
	}
}

func TestPostgresManyInstancesInitAtOnce(t *testing.T) {
	p := prefix("init")
	var stores []*sqlstore.Store
	for i := 0; i < 8; i++ {
		stores = append(stores, newStore(t, postgresDB(t), sqlstore.Postgres, p))
	}
	var wg sync.WaitGroup
	for _, s := range stores {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := s.Init(ctx); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	must(t, stores[0].UpsertJob(ctx, definitionOf(t, `{"name":"a"}`), 1))
	j, err := stores[7].GetJob(ctx, "a")
	must(t, err)
	if j.CreatedAt != 1 {
		t.Errorf("createdAt %d", j.CreatedAt)
	}
}

// A run recorded while the app has a transaction open survives the app's
// rollback: the store writes each statement on its own, never inside the
// app's transaction.
func TestServerRunSurvivesTheAppsRollback(t *testing.T) {
	eachServer(t, func(t *testing.T, b backend) {
		db := b.open(t)
		p := prefix("tx")
		store := newStore(t, db, b.dialect, p)
		cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithAlerts(), cronwatch.WithoutCronSecret())
		must(t, err)
		_, err = db.ExecContext(ctx, "CREATE TABLE "+p+"orders (id INT PRIMARY KEY)")
		must(t, err)
		t.Cleanup(func() { _, _ = db.ExecContext(ctx, "DROP TABLE IF EXISTS "+p+"orders") })
		tx, err := db.BeginTx(ctx, nil)
		must(t, err)
		_, err = tx.ExecContext(ctx, "INSERT INTO "+p+"orders VALUES (1)")
		must(t, err)
		_, err = cronwatch.RunValue(ctx, cw.MustJob("import"), func(context.Context, *cronwatch.JobContext) (string, error) { return "imported", nil })
		must(t, err)
		must(t, tx.Rollback())
		if n := column(t, db, "SELECT COUNT(*) FROM "+p+"orders"); !reflect.DeepEqual(n, []string{"0"}) {
			t.Errorf("orders %v", n)
		}
		runs, err := cw.Runs(ctx, "import", 10)
		must(t, err)
		if len(runs) != 1 || *runs[0].Output != "imported" {
			t.Errorf("the run was lost with the app's rollback: %v", runs)
		}
	})
}

// ---- MySQL and MariaDB

func mysqlServers(t *testing.T, fn func(t *testing.T, b backend)) {
	eachServer(t, func(t *testing.T, b backend) {
		if b.dialect != sqlstore.MySQL {
			t.Skip("MySQL and MariaDB only")
		}
		fn(t, b)
	})
}

func TestMySQLKeepsTheSDKsJSONByteForByte(t *testing.T) {
	mysqlServers(t, func(t *testing.T, b backend) {
		db := b.open(t)
		p := prefix("bytes")
		store := newStore(t, db, sqlstore.MySQL, p)
		must(t, store.Init(ctx))
		must(t, store.Init(ctx)) // IF NOT EXISTS: a second init changes nothing
		rows, err := db.QueryContext(ctx, `SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, COALESCE(COLLATION_NAME, '') FROM information_schema.COLUMNS
			WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE ? ORDER BY TABLE_NAME, ORDINAL_POSITION`, p+"%")
		must(t, err)
		types := map[string]string{}
		var runColumns []string
		for rows.Next() {
			var table, col, typ, coll string
			must(t, rows.Scan(&table, &col, &typ, &coll))
			key := strings.TrimPrefix(table, p) + "." + col
			types[key] = strings.TrimSpace(typ + " " + coll)
			if table == p+"runs" {
				runColumns = append(runColumns, col)
			}
		}
		rows.Close()
		for key, want := range map[string]string{
			// text, never the JSON type, which rewrites what it holds
			"jobs.definition": "longtext utf8mb4_bin", "runs.metrics": "longtext utf8mb4_bin", "state.state": "longtext utf8mb4_bin",
			// names compare as bytes: "b" and "B" are two jobs
			"jobs.name": "varchar utf8mb4_bin",
		} {
			if types[key] != want {
				t.Errorf("%s is %q, want %q", key, types[key], want)
			}
		}
		if want := []string{"seq", "id", "job", "status", "started_at", "finished_at", "duration_ms", "error", "output", "metrics", "trigger"}; !reflect.DeepEqual(runColumns, want) {
			t.Errorf("run columns %v", runColumns)
		}

		def := definitionOf(t, `{"grace":"15m","schedule":"0 2 * * *","budget":{"cost":2},"tags":["café ☃ 😀"],"name":"nightly"}`)
		must(t, store.UpsertJob(ctx, def, 1))
		run := cronwatch.Run{ID: "r1", Job: "nightly", Status: cronwatch.StatusOK, StartedAt: 1, FinishedAt: ptr(int64(2)), DurationMs: ptr(int64(1)),
			Output: ptr("tab\tand \"quotes\" 😀"), Metrics: cronwatch.Metrics{{Name: "ratio", Value: 0.30000000000000004}, {Name: "tiny", Value: 1e-7}, {Name: "huge", Value: 1e21}, {Name: "üml", Value: 7}}, Trigger: "run"}
		must(t, store.InsertRun(ctx, run))
		state := stateOf(t, `{"job":"nightly","open":{"failed":5},"consecutiveFailures":1,"silencedUntil":null,"lastAlertAt":null,"pendingRecovery":["missed"],"undelivered":[],"version":3}`)
		must(t, store.SetState(ctx, state))
		if got := column(t, db, "SELECT definition FROM "+p+"jobs"); got[0] != jsonOf(t, def) {
			t.Errorf("definition %s", got[0])
		}
		if got := column(t, db, "SELECT metrics FROM "+p+"runs"); got[0] != `{"ratio":0.30000000000000004,"tiny":1e-7,"huge":1e+21,"üml":7}` {
			t.Errorf("metrics %s", got[0])
		}
		if got := column(t, db, "SELECT state FROM "+p+"state"); got[0] != jsonOf(t, state) {
			t.Errorf("state %s", got[0])
		}
		read, err := store.GetRun(ctx, "r1")
		must(t, err)
		if jsonOf(t, read) != jsonOf(t, run) {
			t.Errorf("run read back %s", jsonOf(t, read))
		}
	})
}

// MySQL answers how many rows an UPDATE changed, not how many it matched,
// unless the connection asks for found rows. Neither may make a
// conditional write that landed read as refused.
func TestMySQLConditionalWritesDoNotLeanOnHowRowsAreCounted(t *testing.T) {
	mysqlServers(t, func(t *testing.T, b backend) {
		p := prefix("rows")
		must(t, newStore(t, b.open(t), sqlstore.MySQL, p).Init(ctx))
		variable := map[string]string{"mysql": "CRONWATCH_TEST_MYSQL", "mariadb": "CRONWATCH_TEST_MARIADB"}[b.name]
		for _, foundRows := range []bool{false, true} {
			dsn := mysqlDSN(t, os.Getenv(variable))
			sep := "?"
			if strings.Contains(dsn, "?") {
				sep = "&"
			}
			db, err := sql.Open("mysql", dsn+sep+fmt.Sprintf("clientFoundRows=%v", foundRows))
			must(t, err)
			t.Cleanup(func() { db.Close() })
			store, err := sqlstore.New(db, sqlstore.MySQL, sqlstore.Prefix(p))
			must(t, err)
			job := map[bool]string{false: "changed", true: "found"}[foundRows]
			v := func(version, failures int) cronwatch.JobState {
				return stateOf(t, fmt.Sprintf(`{"job":%q,"open":{},"consecutiveFailures":%d,"silencedUntil":null,"lastAlertAt":null,"version":%d}`, job, failures, version))
			}
			cas := func(what string, s cronwatch.JobState, expected int64, want bool) {
				t.Helper()
				ok, err := store.CompareAndSetState(ctx, s, expected)
				must(t, err)
				if ok != want {
					t.Errorf("%s (found rows %v): %v", what, foundRows, ok)
				}
			}
			cas("first", v(1, 0), 0, true)
			cas("a write from a stale read is refused", v(1, 9), 0, false)
			cas("another version", v(3, 0), 2, false)
			cas("the version read", v(2, 1), 1, true)
			st, err := store.GetState(ctx, job)
			must(t, err)
			if *st.Version != 2 {
				t.Errorf("version %d", *st.Version)
			}
			must(t, store.SetState(ctx, stateOf(t, fmt.Sprintf(`{"job":"%s-old","open":{},"consecutiveFailures":3,"silencedUntil":null,"lastAlertAt":null}`, job))))
			cas("state written before versions counts as 0", stateOf(t, fmt.Sprintf(`{"job":"%s-old","open":{},"consecutiveFailures":4,"silencedUntil":null,"lastAlertAt":null,"version":1}`, job)), 0, true)
			// A state at version 0 that already holds these very values.
			zero := stateOf(t, fmt.Sprintf(`{"job":"%s-zero","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null}`, job))
			must(t, store.SetState(ctx, zero))
			cas("a write of what version 0 already holds still wrote", zero, 0, true)

			// A flush that writes what the row already holds still wrote.
			run := storetest.NewRun(job+"-r", job, cronwatch.StatusRunning, 1)
			run.Output = ptr("same")
			must(t, store.InsertRun(ctx, run))
			ok, err := store.UpdateRunIf(ctx, run, []cronwatch.RunStatus{cronwatch.StatusRunning})
			must(t, err)
			if !ok {
				t.Errorf("an unchanged row matched and wrote (found rows %v)", foundRows)
			}
			ok, err = store.UpdateRunIf(ctx, run, []cronwatch.RunStatus{cronwatch.StatusTimeout})
			must(t, err)
			if ok {
				t.Errorf("a row of another status was written (found rows %v)", foundRows)
			}
		}
	})
}
