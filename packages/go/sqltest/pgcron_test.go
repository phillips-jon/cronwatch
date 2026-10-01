package sqltest

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

// The pg_cron source against a real pg_cron, as the SDK's pgcron.test.ts
// runs it, when CRONWATCH_TEST_PGCRON is the URL of a Postgres with pg_cron
// preloaded (cron.database_name naming that database). Through pgx's stdlib
// and through lib/pq, since the source reads through whatever driver the
// app uses.

import (
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/pgcron"
	"cronwatch.dev/go/sqlstore"
	"cronwatch.dev/go/storetest"

	_ "github.com/lib/pq"
)

// pgcronDB is a *sql.DB on the pg_cron server through driver, with the
// extension made.
func pgcronDB(t *testing.T, driver string) *sql.DB {
	t.Helper()
	db := server(t, "pg_cron", "CRONWATCH_TEST_PGCRON", driver, func(v string) string {
		if driver == "postgres" && !strings.Contains(v, "sslmode=") {
			if strings.Contains(v, "?") {
				return v + "&sslmode=disable"
			}
			return v + "?sslmode=disable"
		}
		return v
	})
	run(t, db, "CREATE EXTENSION IF NOT EXISTS pg_cron")
	return db
}

func run(t *testing.T, db interface {
	Exec(string, ...any) (sql.Result, error)
}, query string, args ...any) {
	t.Helper()
	if _, err := db.Exec(query, args...); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
}

// runIDs are the runids a query answers.
func runIDs(t *testing.T, db *sql.DB, query string, args ...any) []int64 {
	t.Helper()
	rows, err := db.Query(query, args...)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		must(t, rows.Scan(&id))
		out = append(out, id)
	}
	return out
}

func others(errs *storetest.Errors) []string {
	var out []string
	for _, e := range errs.List() {
		if !regexp.MustCompile(`cron\.|row level`).MatchString(e) {
			out = append(out, e)
		}
	}
	return out
}

func find(jobs []cronwatch.JobSummary, name string) *cronwatch.JobSummary {
	for i := range jobs {
		if jobs[i].Name == name {
			return &jobs[i]
		}
	}
	return nil
}

func TestPgCronAgainstARealPgCron(t *testing.T) {
	db := pgcronDB(t, "pgx")
	tag := fmt.Sprintf("cwgotest%d", os.Getpid())
	p := tag + "_"
	names := struct{ ok, fail, sleep string }{tag + "-ok", tag + "-fail", tag + "-sleep"}
	t.Cleanup(func() {
		_, _ = db.Exec(`SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1`, tag+"%")
	})
	var offset time.Duration
	now := func() int64 { return time.Now().Add(offset).UnixMilli() }
	store := newStore(t, db, sqlstore.Postgres, p)
	alerts := &storetest.Capture{}
	newClient := func() *cronwatch.Client {
		cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithAlerts(alerts), cronwatch.WithClock(now), cronwatch.WithoutCronSecret(),
			cronwatch.WithErrorHandler(func(error, string) {}),
			cronwatch.WithSources(pgcron.New(db, pgcron.Options{
				Pick:    func(j pgcron.Job) bool { return j.JobName != nil && strings.HasPrefix(*j.JobName, tag) },
				Options: []cronwatch.JobOption{cronwatch.Grace("30s")},
			})))
		must(t, err)
		t.Cleanup(func() { cw.Close() })
		return cw
	}
	run(t, db, `SELECT cron.schedule($1, '1 seconds', 'SELECT 1')`, names.ok)
	run(t, db, `SELECT cron.schedule($1, '1 seconds', 'SELECT 1/0')`, names.fail)
	run(t, db, `SELECT cron.schedule($1, '1 seconds', 'SELECT pg_sleep(3)')`, names.sleep)
	time.Sleep(3500 * time.Millisecond)

	cw := newClient()
	first, err := cw.Check(ctx)
	must(t, err)
	ok := find(first.Jobs, names.ok)
	if ok == nil || ok.Definition.Schedule() != "every 1s" || ok.Definition.Timezone() != "UTC" {
		t.Fatalf("the ok job: %+v", ok)
	}
	okRuns, err := cw.Runs(ctx, names.ok, 20)
	must(t, err)
	if len(okRuns) < 2 {
		t.Fatalf("ok runs imported (%d)", len(okRuns))
	}
	sawOutput := false
	for _, r := range okRuns {
		if !strings.HasPrefix(r.ID, "pgcron:") || r.Trigger != "pg_cron" {
			t.Errorf("run %s from %s", r.ID, r.Trigger)
		}
		sawOutput = sawOutput || r.Status == cronwatch.StatusOK && r.Output != nil && *r.Output == "1 row"
	}
	if !sawOutput {
		t.Error("no run with its output")
	}
	failRuns, err := cw.Runs(ctx, names.fail, 20)
	must(t, err)
	sawFailure := false
	for _, r := range failRuns {
		sawFailure = sawFailure || r.Status == cronwatch.StatusFailed && r.Error != nil && strings.Contains(*r.Error, "division by zero")
	}
	if !sawFailure {
		t.Error("the failure and its message were not imported")
	}
	var sent []string
	for _, a := range first.Alerts {
		sent = append(sent, string(a.Type)+" "+a.Job)
	}
	if strings.Join(sent, "|") != "failed "+names.fail {
		t.Errorf("alerts %v", sent)
	}
	if ok.Health != "healthy" {
		t.Errorf("ok health %s", ok.Health)
	}

	// A run imported while it was going is updated when it finishes.
	var running int64
	for i := 0; i < 40 && running == 0; i++ {
		ids := runIDs(t, db, `SELECT d.runid FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = $1 AND d.status = 'running' AND d.start_time IS NOT NULL`, names.sleep)
		if len(ids) > 0 {
			running = ids[0]
		} else {
			time.Sleep(250 * time.Millisecond)
		}
	}
	if running == 0 {
		t.Fatal("never saw the sleeping job running")
	}
	id := fmt.Sprintf("pgcron:%d", running)
	_, err = cw.Check(ctx)
	must(t, err)
	if r, _ := cw.GetRun(ctx, id); r == nil || r.Status != cronwatch.StatusRunning {
		t.Fatalf("%s: %+v", id, r)
	}
	time.Sleep(3500 * time.Millisecond)
	_, err = cw.Check(ctx)
	must(t, err)
	slept, _ := cw.GetRun(ctx, id)
	if slept == nil || slept.Status != cronwatch.StatusOK || *slept.DurationMs < 2900 {
		t.Fatalf("%s: %+v", id, slept)
	}

	// New runs keep arriving; nothing is copied twice, even by a fresh client after a restart.
	before, _ := cw.Runs(ctx, names.ok, 500)
	time.Sleep(2 * time.Second)
	_, err = cw.Check(ctx)
	must(t, err)
	after, _ := cw.Runs(ctx, names.ok, 500)
	if len(after) <= len(before) {
		t.Error("later runs were not imported")
	}
	seen := map[string]bool{}
	for _, r := range after {
		if seen[r.ID] {
			t.Errorf("%s copied twice", r.ID)
		}
		seen[r.ID] = true
	}

	// The ok job is unscheduled and the failing one paused: neither is missed.
	run(t, db, `SELECT cron.unschedule($1)`, names.ok)
	run(t, db, `SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = $1`, names.fail)
	time.Sleep(1500 * time.Millisecond)
	cw = newClient()
	_, err = cw.Check(ctx)
	must(t, err)
	settled, _ := cw.Runs(ctx, names.fail, 500)
	_, err = cw.Check(ctx)
	must(t, err)
	again, _ := cw.Runs(ctx, names.fail, 500)
	if len(again) != len(settled) {
		t.Errorf("re-import added runs: %d then %d", len(settled), len(again))
	}
	offset = 2 * time.Minute
	late, err := cw.Check(ctx)
	must(t, err)
	for _, a := range late.Alerts {
		if a.Type == cronwatch.AlertMissed && (a.Job == names.ok || a.Job == names.fail) {
			t.Errorf("%s missed", a.Job)
		}
	}
	okJob := find(late.Jobs, names.ok)
	if okJob == nil || okJob.Definition.Schedule() != "" || !strings.Contains(okJob.Definition.Description(), "no longer in cron.job") {
		t.Errorf("the unscheduled job: %+v", okJob)
	}
}

func TestPgCronRestartRowsACrowdedJobFirstSightAndARename(t *testing.T) {
	for _, driver := range []string{"pgx", "postgres"} {
		t.Run(driver, func(t *testing.T) {
			db := pgcronDB(t, driver)
			tag := fmt.Sprintf("cwgorow%d%s", os.Getpid(), driver[:2])
			names := struct{ busy, quiet, hist string }{tag + "-busy", tag + "-quiet", tag + "-hist"}
			t.Cleanup(func() {
				_, _ = db.Exec(`SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1`, tag+"%")
			})
			insert := func(jobid int64, status, times, message string) int64 {
				t.Helper()
				ids := runIDs(t, db, `INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
				SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', $2, $3, `+times+` RETURNING runid`, jobid, status, message)
				return ids[0]
			}
			ids := map[string]int64{}
			for _, name := range []string{names.busy, names.quiet, names.hist} {
				ids[name] = runIDs(t, db, `SELECT cron.schedule($1, '0 3 * * *', 'SELECT 1')`, name)[0]
				// Paused, so pg_cron itself adds no rows while the test writes its own.
				run(t, db, `SELECT cron.alter_job($1, active := false)`, ids[name])
			}
			// First sight of a job whose newest rows include a run cut off by a restart, and older failures.
			run(t, db, `INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
			SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'failed', 'ERROR: old', now() - interval '3 days', now() - interval '3 days' FROM generate_series(1, 5)`, ids[names.hist])
			insert(ids[names.hist], "failed", "NULL, NULL", "server restarted")
			run(t, db, `INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
			SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - make_interval(mins => 30 - g), now() - make_interval(mins => 30 - g) FROM generate_series(1, 19) g`, ids[names.hist])

			alerts := &storetest.Capture{}
			errs := &storetest.Errors{}
			cw, err := cronwatch.New(cronwatch.WithAlerts(alerts), cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(errs.Add),
				cronwatch.WithSources(pgcron.New(db, pgcron.Options{
					Pick:     func(j pgcron.Job) bool { return j.JobName != nil && strings.HasPrefix(*j.JobName, tag) },
					Timezone: "UTC",
				})))
			must(t, err)
			defer cw.Close()
			_, err = cw.Check(ctx)
			must(t, err)
			if runs, _ := cw.Runs(ctx, names.hist, 500); len(runs) != 20 {
				t.Fatalf("%d runs copied, want the twenty newest", len(runs))
			}
			if len(alerts.Types()) != 0 {
				t.Fatalf("history was judged: %v", alerts.Types())
			}
			_, err = cw.Check(ctx)
			must(t, err)
			if runs, _ := cw.Runs(ctx, names.hist, 500); len(runs) != 20 {
				t.Fatalf("%d runs after a second read", len(runs))
			}

			// A restart cuts off a busy job's queued run; the busy job then runs past a page; then the quiet job fails.
			cut := insert(ids[names.busy], "failed", "NULL, NULL", "server restarted")
			run(t, db, `INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
			SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - make_interval(secs => 600 - g), now() - make_interval(secs => 600 - g) FROM generate_series(1, 520) g`, ids[names.busy])
			disk := insert(ids[names.quiet], "failed", "now(), now()", "ERROR: disk full")
			for i := 0; i < 3; i++ {
				_, err = cw.Check(ctx)
				must(t, err)
			}
			if r, _ := cw.GetRun(ctx, fmt.Sprintf("pgcron:%d", cut)); r == nil || *r.Error != "server restarted" {
				t.Errorf("the cut off run: %+v", r)
			}
			if r, _ := cw.GetRun(ctx, fmt.Sprintf("pgcron:%d", disk)); r == nil || r.Status != cronwatch.StatusFailed {
				t.Errorf("the quiet job's failure: %+v", r)
			}
			quietAlerted := false
			for _, a := range alerts.List() {
				quietAlerted = quietAlerted || a.Type == cronwatch.AlertFailed && a.Job == names.quiet
			}
			if !quietAlerted {
				t.Error("the quiet job's failure did not alert")
			}

			// Renamed in pg_cron: the old name keeps its runs and loses its schedule.
			run(t, db, `UPDATE cron.job SET jobname = $1 WHERE jobid = $2`, names.quiet+"-v2", ids[names.quiet])
			run(t, db, `SELECT cron.alter_job($1, active := true)`, ids[names.quiet])
			_, err = cw.Check(ctx)
			must(t, err)
			jobs, _ := cw.Jobs(ctx)
			old := find(jobs, names.quiet)
			if old == nil || old.Definition.Schedule() != "" || !strings.Contains(old.Definition.Description(), "renamed to") {
				t.Errorf("the old name: %+v", old)
			}
			if v2 := find(jobs, names.quiet+"-v2"); v2 == nil || v2.Definition.Schedule() != "0 3 * * *" {
				t.Errorf("the new name: %+v", v2)
			}
			if o := others(errs); len(o) > 0 {
				t.Errorf("errors: %v", o)
			}
		})
	}
}

func TestPgCronARoleThatMayNotReadCronSettingsNeverAbortsTheCallersTransaction(t *testing.T) {
	admin := pgcronDB(t, "pgx")
	role := fmt.Sprintf("cwgorole%d", os.Getpid())
	u, err := url.Parse(os.Getenv("CRONWATCH_TEST_PGCRON"))
	must(t, err)
	u.User = url.UserPassword(role, "pw")
	t.Cleanup(func() {
		// Every job of the role goes before the role: pg_cron's scheduler stops on a job whose role is gone.
		_, _ = admin.Exec(`SELECT cron.unschedule(jobid) FROM cron.job WHERE username = $1`, role)
		_, _ = admin.Exec(`DROP OWNED BY ` + role)
		_, _ = admin.Exec(`DROP ROLE IF EXISTS ` + role)
	})
	run(t, admin, `CREATE ROLE `+role+` LOGIN PASSWORD 'pw'`)
	run(t, admin, `GRANT USAGE ON SCHEMA cron TO `+role)
	run(t, admin, `GRANT SELECT ON cron.job, cron.job_run_details TO `+role)
	db, err := sql.Open("pgx", u.String())
	must(t, err)
	defer db.Close()
	run(t, db, `SELECT cron.schedule($1, '0 3 * * *', 'SELECT 1')`, role+"-job")

	tx, err := db.BeginTx(ctx, nil)
	must(t, err)
	defer tx.Rollback()
	errs := &storetest.Errors{}
	cw, err := cronwatch.New(cronwatch.WithAlerts(), cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(errs.Add),
		cronwatch.WithSources(pgcron.New(tx, pgcron.Options{})))
	must(t, err)
	defer cw.Close()
	result, err := cw.Check(ctx)
	must(t, err)
	var one int
	must(t, tx.QueryRow("SELECT 1").Scan(&one))
	if one != 1 {
		t.Fatal("the transaction is not usable")
	}
	job := find(result.Jobs, role+"-job")
	if job == nil || job.Definition.Timezone() != "UTC" || job.Definition.Schedule() != "0 3 * * *" {
		t.Fatalf("assumed UTC, and cron.log_run unreadable taken as on: %+v", job)
	}
	if !strings.Contains(strings.Join(errs.List(), "\n"), "could not read cron.timezone") {
		t.Errorf("errors %v", errs.List())
	}
}
