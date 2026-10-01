package pgcron_test

// The pg_cron source against the fake tables (fake_test.go), as the SDK's
// pgcron.test.ts has it, and the replay of conformance/pgcron.json. The
// tests against a real pg_cron are in the sqltest module, which has a
// Postgres driver.

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/pgcron"
	"cronwatch.dev/go/storetest"
)

var bg = context.Background()

const (
	T0   = storetest.T0
	MIN  = int64(60_000)
	HOUR = 60 * MIN
	DAY  = 24 * HOUR
)

func TestMain(m *testing.M) {
	time.Local = time.UTC
	os.Exit(m.Run())
}

func utc(y int, m time.Month, d, h, min, s int) int64 {
	return time.Date(y, m, d, h, min, s, 0, time.UTC).UnixMilli()
}

// kit is a client watching a fake through the source.
type kit struct {
	cw     *cronwatch.Client
	alerts *storetest.Capture
	errors *storetest.Errors
}

func newKit(t *testing.T, cron *fakeCron, clock *storetest.Clock, store cronwatch.Store, o pgcron.Options) *kit {
	t.Helper()
	k := &kit{alerts: &storetest.Capture{}, errors: &storetest.Errors{}}
	options := []cronwatch.Option{cronwatch.WithAlerts(k.alerts), cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(k.errors.Add),
		cronwatch.WithSources(pgcron.New(cron.db(t), o))}
	if clock != nil {
		options = append(options, cronwatch.WithClock(clock.Now))
	}
	if store != nil {
		options = append(options, cronwatch.WithStore(store))
	}
	cw, err := cronwatch.New(options...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cw.Close() })
	k.cw = cw
	return k
}

func (k *kit) check(t *testing.T) *cronwatch.CheckResult {
	t.Helper()
	r, err := k.cw.Check(bg)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func (k *kit) runs(t *testing.T, name string, limit int) []cronwatch.Run {
	t.Helper()
	runs, err := k.cw.Runs(bg, name, limit)
	if err != nil {
		t.Fatal(err)
	}
	return runs
}

func (k *kit) run(t *testing.T, id string) *cronwatch.Run {
	t.Helper()
	r, err := k.cw.GetRun(bg, id)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// others are the errors that are not about settings or row level security.
func (k *kit) others() []string {
	var out []string
	for _, e := range k.errors.List() {
		if !regexp.MustCompile(`cron\.|row level`).MatchString(e) {
			out = append(out, e)
		}
	}
	return out
}

func summary(r *cronwatch.CheckResult, name string) cronwatch.JobSummary {
	for _, j := range r.Jobs {
		if j.Name == name {
			return j
		}
	}
	return cronwatch.JobSummary{}
}

func typesAndJobs(alerts []cronwatch.Alert) []string {
	out := []string{}
	for _, a := range alerts {
		out = append(out, string(a.Type)+" "+a.Job)
	}
	sort.Strings(out)
	return out
}

// num is a number, or the number a string holds, as the fixture has both.
func num(v any) float64 {
	if s, ok := v.(string); ok {
		n, _ := strconv.ParseFloat(s, 64)
		return n
	}
	f, _ := v.(float64)
	return f
}

func same[T comparable](t *testing.T, what string, got, want T) {
	t.Helper()
	if got != want {
		t.Errorf("%s: got %v, want %v", what, got, want)
	}
}

func sameList(t *testing.T, what string, got, want []string) {
	t.Helper()
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("%s: got %q, want %q", what, got, want)
	}
}

func TestConformancePgCron(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "conformance", "pgcron.json"))
	if err != nil {
		t.Fatal(err)
	}
	v, _ := js.Parse(string(data))
	f := v.(*js.Object)
	get := func(o *js.Object, key string) any { x, _ := o.Get(key); return x }
	count := 0
	for _, c := range get(f, "schedules").([]any) {
		o := c.(*js.Object)
		got, ok := pgcron.ScheduleOf(get(o, "schedule").(string))
		var result any = got
		if !ok {
			result = nil
		}
		same(t, "schedule "+js.Quote(get(o, "schedule").(string)), js.Stringify(result), js.Stringify(get(o, "result")))
		count++
	}
	for _, c := range get(f, "names").([]any) {
		o := c.(*js.Object)
		j := get(o, "job").(*js.Object)
		job := pgcron.Job{JobID: int64(get(j, "jobid").(float64))}
		if n, ok := get(j, "jobname").(string); ok {
			job.JobName = &n
		}
		same(t, "name of "+js.Stringify(j), pgcron.DefaultJobName(job), get(o, "name").(string))
		count++
	}
	for _, c := range get(f, "runs").([]any) {
		o := c.(*js.Object)
		r := get(o, "row").(*js.Object)
		row := pgcron.Row{RunID: int64(num(get(r, "runid"))), JobID: int64(num(get(r, "jobid")))}
		row.Status, _ = get(r, "status").(string)
		if m, ok := get(r, "return_message").(string); ok {
			row.ReturnMessage = &m
		}
		for key, into := range map[string]**time.Time{"start_time": &row.StartTime, "end_time": &row.EndTime} {
			if s, ok := get(r, key).(string); ok {
				tm, err := time.Parse(time.RFC3339Nano, s)
				if err != nil {
					t.Fatal(err)
				}
				*into = &tm
			}
		}
		fallback := T0
		if n, ok := get(o, "fallbackAt").(float64); ok {
			fallback = int64(n)
		}
		var got any
		if run := pgcron.RunOfRow(row, "db:j", "pgcron:db:", fallback); run != nil {
			got = js.ValueOf(run)
		}
		same(t, "run of "+js.Stringify(r), js.Stringify(got), js.Stringify(get(o, "run")))
		count++
	}
	same(t, "holdMs", float64(pgcron.HoldFor.Milliseconds()), get(f, "holdMs").(float64))
	t.Logf("%d cases replayed", count+1)
}

func TestJobsAreDeclaredHistoryIsCopiedQuietlyAndImportsAreIdempotent(t *testing.T) {
	c := storetest.NewClock(T0)
	cron := newFakeCron()
	cron.job(1, name("nightly vacuum"), "0 3 * * *", true)
	cron.job(2, nil, "10 seconds", true)
	cron.job(3, name("paused"), "0 * * * *", false)
	cron.job(4, name("other"), "0 * * * *", true)
	three := utc(2026, 1, 5, 3, 0, 0)
	for i := int64(24); i >= 1; i-- {
		cron.add(1, "succeeded", three-i*DAY, three-i*DAY+5000, "VACUUM")
	}
	cron.add(1, "failed", three, three+2000, "ERROR:  deadlock detected\n")
	store := cronwatch.NewMemoryStore()
	options := pgcron.Options{Pick: func(j pgcron.Job) bool { return j.JobID != 4 }, Prefix: "db:"}
	k := newKit(t, cron, c, store, options)

	first := k.check(t)
	var names []string
	for _, j := range first.Jobs {
		names = append(names, j.Name)
	}
	sameList(t, "jobs", names, []string{"db:nightly-vacuum", "db:paused", "db:pg_cron:2"})
	vacuum := summary(first, "db:nightly-vacuum")
	same(t, "schedule", vacuum.Definition.Schedule(), "0 3 * * *")
	same(t, "timezone", vacuum.Definition.Timezone(), "UTC")
	sameList(t, "tags", vacuum.Definition.Tags(), []string{"pg_cron"})
	same(t, "seconds", summary(first, "db:pg_cron:2").Definition.Schedule(), "every 10s")
	same(t, "a paused job is not expected to run", summary(first, "db:paused").Definition.Schedule(), "")
	runs := k.runs(t, "db:nightly-vacuum", 100)
	same(t, "twenty newest runs copied on first sight", len(runs), 20)
	same(t, "id", runs[0].ID, "pgcron:db:25")
	same(t, "status", runs[0].Status, cronwatch.StatusFailed)
	same(t, "error", *runs[0].Error, "ERROR:  deadlock detected")
	same(t, "duration", *runs[0].DurationMs, int64(2000))
	same(t, "trigger", runs[0].Trigger, "pg_cron")
	same(t, "output", *runs[1].Output, "VACUUM")
	sameList(t, "only the newest finished run is judged; history does not alert", k.alerts.Types(), []string{"failed"})

	k.check(t)
	// A new process over the same store.
	k = newKit(t, cron, c, store, options)
	k.check(t)
	same(t, "a re-import, even after a restart, adds nothing", len(k.runs(t, "db:nightly-vacuum", 100)), 20)
	sameList(t, "no new alerts", k.alerts.Types(), []string{})

	// A run not yet started holds the cursor; the run after it is copied now and it is copied once it starts.
	starting := cron.add(2, "starting", -1, -1)
	cron.add(2, "succeeded", T0-5000, T0-4000, "1 row")
	c.Advance(1000)
	k.check(t)
	var ids []string
	for _, r := range k.runs(t, "db:pg_cron:2", 20) {
		ids = append(ids, r.ID)
	}
	sameList(t, "ids", ids, []string{"pgcron:db:27"})
	cron.update(func() { starting.status, starting.start = "running", at(T0-3000) })
	k.check(t)
	same(t, "running", k.run(t, "pgcron:db:26").Status, cronwatch.StatusRunning)
	cron.update(func() {
		starting.status, starting.end = "failed", at(T0-1000)
		starting.message = name("ERROR:  boom")
	})
	c.Advance(1000)
	k.check(t)
	done := k.run(t, "pgcron:db:26")
	same(t, "finished", done.Status, cronwatch.StatusFailed)
	same(t, "duration", *done.DurationMs, int64(2000))
	sameList(t, "a run that was running and then failed is judged when it finishes", k.alerts.Types(), []string{"failed"})

	// The nightly job stops running: missed, from its schedule, with no run details at all.
	c.Set(utc(2026, 1, 6, 3, 11, 0))
	cron.add(2, "succeeded", c.Now()-2000, c.Now()-1000, "1 row")
	later := k.check(t)
	sameList(t, "later", typesAndJobs(later.Alerts), []string{"missed db:nightly-vacuum", "recovered db:pg_cron:2"})
	same(t, "each condition alerts once", len(k.check(t).Alerts), 0)

	// Unscheduled: its name keeps its history but loses its schedule, so it is never missed again,
	// and the missed alert it had open closes with a recovery that says so.
	cron.update(func() { cron.jobs = cron.jobs[1:] })
	c.Set(utc(2026, 1, 8, 3, 11, 0))
	gone := k.check(t)
	now := summary(gone, "db:nightly-vacuum")
	same(t, "no schedule", now.Definition.Schedule(), "")
	if !strings.Contains(now.Definition.Description(), "no longer watched") {
		t.Errorf("description %q", now.Definition.Description())
	}
	if len(now.Open) != 1 || now.Open[0] != "failed" {
		t.Errorf("its failure stays open until a successful run: %v", now.Open)
	}
	var closed []cronwatch.Alert
	for _, a := range gone.Alerts {
		if a.Job == "db:nightly-vacuum" {
			closed = append(closed, a)
		}
	}
	if len(closed) != 1 || closed[0].Type != cronwatch.AlertRecovered {
		t.Fatalf("closed %v", closed)
	}
	same(t, "title", closed[0].Title, "db:nightly-vacuum is no longer scheduled")
	details, _ := js.ValueOf(closed[0]).(*js.Object).Get("details")
	same(t, "details", js.Stringify(details), `{"after":["missed"],"reason":"unscheduled","since":`+js.FormatNumber(float64(utc(2026, 1, 6, 3, 11, 0)))+`}`)
	for _, a := range k.check(t).Alerts {
		if a.Job == "db:nightly-vacuum" {
			t.Errorf("once: %v", a.Type)
		}
	}
	same(t, "its history is kept", len(k.runs(t, "db:nightly-vacuum", 100)), 20)
}

// The review: the source declared a job again only when its settings
// changed, so after the dashboard's forget every later run was refused as
// not declared until the process restarted.
func TestAJobForgottenFromTheDashboardIsDeclaredAgainAndItsRunsRecorded(t *testing.T) {
	c := storetest.NewClock(T0)
	cron := newFakeCron()
	cron.job(1, name("vacuum"), "0 3 * * *", true)
	cron.add(1, "succeeded", T0-5000, T0-4000, "VACUUM")
	k := newKit(t, cron, c, cronwatch.NewMemoryStore(), pgcron.Options{})
	k.check(t)
	if err := k.cw.Forget(bg, "vacuum"); err != nil {
		t.Fatal(err)
	}
	cron.add(1, "succeeded", T0-3000, T0-2000, "VACUUM")
	cron.add(1, "failed", T0-1000, T0, "ERROR:  boom")
	c.Advance(1000)
	result := k.check(t)
	sameList(t, "errors", k.others(), nil)
	same(t, "jobs", len(result.Jobs), 1)
	same(t, "schedule", summary(result, "vacuum").Definition.Schedule(), "0 3 * * *")
	var ids []string
	for _, r := range k.runs(t, "vacuum", 50) {
		ids = append(ids, r.ID)
	}
	sameList(t, "the runs after the forget", ids, []string{"pgcron:3", "pgcron:2"})
	same(t, "declared", k.cw.Declares("vacuum"), true)
}

func TestAJobsOptionsApplyAndAScheduleItCannotReadIsReported(t *testing.T) {
	cron := newFakeCron()
	cron.job(1, name("odd"), "not a schedule", true)
	k := newKit(t, cron, nil, nil, pgcron.Options{Options: []cronwatch.JobOption{cronwatch.Grace("1m"), cronwatch.ExpectMatch(regexp.MustCompile(`rows?`))}})
	now := time.Now().UnixMilli()
	cron.add(1, "succeeded", now-1000, now, "nothing")
	result := k.check(t)
	same(t, "schedule", result.Jobs[0].Definition.Schedule(), "")
	grace, _ := result.Jobs[0].Definition.Get("grace")
	same(t, "grace", grace, any("1m"))
	if !strings.Contains(strings.Join(k.errors.List(), "\n"), "watching it without a schedule") {
		t.Errorf("errors %v", k.errors.List())
	}
	run := k.runs(t, "odd", 20)[0]
	same(t, "expect applies to imported output", run.Status, cronwatch.StatusFailed)
	if !strings.Contains(*run.Error, "did not match") {
		t.Errorf("error %q", *run.Error)
	}
}

func TestARunCutOffByARestartIsRecordedAndOneHeldRunNeverStopsTheOthers(t *testing.T) {
	c := storetest.NewClock(T0)
	cron := newFakeCron()
	cron.job(1, name("fast"), "30 seconds", true)
	cron.job(2, name("other"), "0 * * * *", true)
	k := newKit(t, cron, c, nil, pgcron.Options{})
	cron.add(1, "succeeded", T0-60_000, T0-59_000, "1 row")
	k.check(t)
	// pg_cron restarts while a run is queued: it marks it failed, "server restarted", with no times at all.
	restarted := cron.add(1, "failed", -1, -1, "server restarted")
	// The fast job then runs far more than a page's worth, and the other job fails after all of them.
	for i := int64(0); i < 520; i++ {
		cron.add(1, "succeeded", T0-50_000+i, T0-50_000+i+1, "1 row")
	}
	failure := cron.add(2, "failed", T0-1000, T0-500, "ERROR:  disk full")
	queued := cron.add(1, "starting", -1, -1)
	c.Advance(1000)
	k.check(t)
	k.check(t)
	id := func(d *detail) string { return "pgcron:" + js.FormatNumber(float64(d.runid)) }
	cut := k.run(t, id(restarted))
	same(t, "status", cut.Status, cronwatch.StatusFailed)
	same(t, "error", *cut.Error, "server restarted")
	same(t, "placed at the job's newest run before it", cut.StartedAt, T0-60_000)
	same(t, "the other job's failure is not starved", k.run(t, id(failure)).Status, cronwatch.StatusFailed)
	found := false
	for _, a := range k.alerts.List() {
		found = found || a.Type == cronwatch.AlertFailed && a.Job == "other"
	}
	same(t, "other failed", found, true)
	if k.run(t, id(queued)) != nil {
		t.Error("a queued run is not held")
	}

	// Held only so long: then it is copied as running from when it was first seen, and a late start updates nothing but its end.
	c.Advance(11 * MIN)
	k.check(t)
	waiting := k.run(t, id(queued))
	same(t, "status", waiting.Status, cronwatch.StatusRunning)
	same(t, "started", waiting.StartedAt, T0+1000)
	cron.update(func() { queued.status, queued.start, queued.end = "succeeded", at(c.Now()-2000), at(c.Now()-1000) })
	c.Advance(1000)
	k.check(t)
	same(t, "finished", k.run(t, id(queued)).Status, cronwatch.StatusOK)
	sameList(t, "errors", k.others(), nil)
}

func TestFirstSightNeverJudgesHistory(t *testing.T) {
	c := storetest.NewClock(T0)
	cron := newFakeCron()
	cron.job(1, name("nightly"), "0 3 * * *", true)
	for i := int64(0); i < 30; i++ {
		cron.add(1, "failed", T0-(40-i)*HOUR, T0-(40-i)*HOUR+1000, "ERROR:  old")
	}
	cron.add(1, "failed", -1, -1, "server restarted")
	for i := int64(0); i < 19; i++ {
		start := T0 - (10*HOUR - i*HOUR/2)
		cron.add(1, "succeeded", start, start+1000, "ok")
	}
	k := newKit(t, cron, c, nil, pgcron.Options{})
	k.check(t)
	k.check(t)
	same(t, "only the newest twenty are copied", len(k.runs(t, "nightly", 500)), 20)
	sameList(t, "no alert from history", k.alerts.Types(), []string{})
}

func TestARenamedJobLeavesNoScheduledGhost(t *testing.T) {
	c := storetest.NewClock(T0)
	cron := newFakeCron()
	job := cron.job(1, name("rollup"), "*/5 * * * *", true)
	cron.add(1, "succeeded", T0-60_000, T0-59_000, "1 row")
	store := cronwatch.NewMemoryStore()
	k := newKit(t, cron, c, store, pgcron.Options{})
	k.check(t)
	cron.update(func() { job.jobname = name("rollup-v2") })
	running := cron.add(1, "running", T0-1000, -1)
	k.check(t)
	jobs, _ := k.cw.Jobs(bg)
	find := func(list []cronwatch.JobSummary, n string) cronwatch.JobSummary {
		for _, j := range list {
			if j.Name == n {
				return j
			}
		}
		t.Fatalf("no job %s", n)
		return cronwatch.JobSummary{}
	}
	old := find(jobs, "rollup")
	same(t, "the old name has no schedule", old.Definition.Schedule(), "")
	if !strings.Contains(old.Definition.Description(), "renamed to rollup-v2") {
		t.Errorf("description %q", old.Definition.Description())
	}
	same(t, "new schedule", find(jobs, "rollup-v2").Definition.Schedule(), "*/5 * * * *")
	runID := "pgcron:" + js.FormatNumber(float64(running.runid))
	same(t, "the running run is the new name's", k.run(t, runID).Job, "rollup-v2")
	cron.update(func() { running.status, running.end = "succeeded", at(T0) })
	c.Advance(HOUR)
	cron.add(1, "succeeded", c.Now()-2000, c.Now()-1000, "1 row")
	k.check(t)
	same(t, "finished", k.run(t, runID).Status, cronwatch.StatusOK)
	for _, a := range k.alerts.List() {
		if a.Job == "rollup" {
			t.Errorf("the old name alerted: %s", a.Type)
		}
	}

	// Renamed again while no process watched: the next process retires the name the store still schedules.
	cron.update(func() { job.jobname = name("rollup-v3") })
	next := newKit(t, cron, c, store, pgcron.Options{})
	next.alerts = k.alerts
	c.Advance(MIN)
	next.check(t)
	jobs, _ = next.cw.Jobs(bg)
	same(t, "v2 unscheduled", find(jobs, "rollup-v2").Definition.Schedule(), "")
	if !strings.Contains(find(jobs, "rollup-v2").Definition.Description(), "renamed to rollup-v3") {
		t.Errorf("description %q", find(jobs, "rollup-v2").Definition.Description())
	}
	same(t, "v3 scheduled", find(jobs, "rollup-v3").Definition.Schedule(), "*/5 * * * *")
	same(t, "runs already copied under an old name are not copied again", len(next.runs(t, "rollup-v3", 20)), 0)
	c.Advance(HOUR)
	result := next.check(t)
	for _, a := range append(k.alerts.List(), result.Alerts...) {
		if a.Job != "rollup-v3" {
			t.Errorf("only the job's current name can be missed: %s %s", a.Type, a.Job)
		}
	}
	sameList(t, "errors", append(k.others(), next.others()...), nil)
}

func TestAJobPausedOrRenamedWhileMissedClosesMissedWithARecovery(t *testing.T) {
	c := storetest.NewClock(T0)
	cron := newFakeCron()
	hourly := cron.job(1, name("hourly"), "0 * * * *", true)
	rollup := cron.job(2, name("rollup"), "0 * * * *", true)
	cron.add(1, "succeeded", T0-3*HOUR, T0-3*HOUR+1000)
	cron.add(2, "succeeded", T0-3*HOUR, T0-3*HOUR+1000)
	k := newKit(t, cron, c, nil, pgcron.Options{})
	k.check(t)
	var got []string
	for _, a := range k.alerts.List() {
		got = append(got, string(a.Type)+" "+a.Job)
	}
	sort.Strings(got)
	sameList(t, "missed", got, []string{"missed hourly", "missed rollup"})
	cron.update(func() { hourly.active, rollup.jobname = false, name("rollup-v2") })
	c.Advance(MIN)
	r := k.check(t)
	got = nil
	for _, a := range r.Alerts {
		got = append(got, string(a.Type)+" "+a.Job+" "+a.Title)
	}
	sort.Strings(got)
	sameList(t, "recovered", got, []string{"recovered hourly hourly is no longer scheduled", "recovered rollup rollup is no longer scheduled"})
	c.Advance(MIN)
	same(t, "nothing more", len(k.check(t).Alerts), 0)
}

func TestARunMarkedTimeoutByACheckIsStillReadAndItsLateFinishRecorded(t *testing.T) {
	c := storetest.NewClock(T0)
	cron := newFakeCron()
	cron.job(1, name("vacuum"), "0 3 * * *", true)
	k := newKit(t, cron, c, nil, pgcron.Options{Options: []cronwatch.JobOption{cronwatch.Timeout("30m")}})
	long := cron.add(1, "running", T0, -1)
	id := "pgcron:" + js.FormatNumber(float64(long.runid))
	k.check(t)
	same(t, "running", k.run(t, id).Status, cronwatch.StatusRunning)
	c.Advance(45 * MIN)
	k.check(t)
	same(t, "timeout", k.run(t, id).Status, cronwatch.StatusTimeout)
	sameList(t, "stuck", k.alerts.Types(), []string{"stuck"})
	c.Advance(10 * MIN)
	cron.update(func() { long.status, long.end, long.message = "succeeded", at(c.Now()-60_000), name("VACUUM") })
	k.check(t)
	done := k.run(t, id)
	same(t, "ok", done.Status, cronwatch.StatusOK)
	same(t, "output", *done.Output, "VACUUM")
	sameList(t, "recovered", k.alerts.Types(), []string{"stuck", "recovered"})
	s, _ := k.cw.JobSummary(bg, "vacuum")
	same(t, "health", s.Health, cronwatch.JobHealth("healthy"))
}

func TestSettingsARoleMayNotReadAreAssumedAndReportedOnce(t *testing.T) {
	cron := newFakeCron()
	cron.settings = map[string]string{}
	cron.job(1, name("nightly"), "0 3 * * *", true)
	k := newKit(t, cron, nil, nil, pgcron.Options{})
	first := k.check(t)
	k.check(t)
	same(t, "timezone", first.Jobs[0].Definition.Timezone(), "UTC")
	n := 0
	for _, e := range k.errors.List() {
		if strings.Contains(e, "cron.timezone") {
			n++
		}
		if strings.Contains(e, "log_run") {
			t.Errorf("log_run unreadable is taken as on: %s", e)
		}
	}
	same(t, "reported once", n, 1)
}

func TestTheSourcesQueries(t *testing.T) {
	cron := newFakeCron()
	cron.settings["cron.log_run"] = "off"
	cron.job(1, name("nightly"), "0 3 * * *", true)
	cron.add(1, "succeeded", T0-1000, T0)
	k := newKit(t, cron, storetest.NewClock(T0), nil, pgcron.Options{Timezone: "America/New_York", JobIDs: []int64{1}})
	r := k.check(t)
	same(t, "no schedule when pg_cron records no runs", r.Jobs[0].Definition.Schedule(), "")
	same(t, "no runs read", len(k.runs(t, "nightly", 20)), 0)
	for _, q := range cron.queries {
		if strings.Contains(q, "current_setting") || strings.Contains(q, "COMMIT") || strings.Contains(q, "ROLLBACK") {
			t.Errorf("a query that could end the caller's transaction: %s", q)
		}
	}
	if !strings.Contains(strings.Join(k.errors.List(), "\n"), "cron.log_run is off") {
		t.Errorf("errors %v", k.errors.List())
	}
	// A job not picked by name or id is not declared.
	cron2 := newFakeCron()
	cron2.job(1, name("a"), "0 3 * * *", true)
	cron2.job(2, name("b"), "0 3 * * *", true)
	k2 := newKit(t, cron2, storetest.NewClock(T0), nil, pgcron.Options{Jobs: []string{"b"}})
	r = k2.check(t)
	if len(r.Jobs) != 1 || r.Jobs[0].Name != "b" {
		t.Errorf("jobs %v", r.Jobs)
	}
}
