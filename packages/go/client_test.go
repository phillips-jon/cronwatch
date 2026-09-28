package cronwatch_test

// client.test.ts. The handler tests wait for phase 3 (handler()).

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"testing"

	cronwatch "cronwatch.dev/go"
)

func TestRunRecordsOutputMetricsAndDuration(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("report", cronwatch.Schedule("0 2 * * *"))
	result, err := cronwatch.RunValue(bg, job, func(_ context.Context, j *cronwatch.JobContext) (string, error) {
		j.Log("hello", map[string]int{"n": 1})
		check(t, j.Metric("rows", 42))
		k.c.Advance(1500)
		return "done", nil
	})
	check(t, err)
	eq(t, "result", result, "done")
	run := runs(t, k.cw, "report")[0]
	eq(t, "status", run.Status, cronwatch.StatusOK)
	eq(t, "duration", *run.DurationMs, int64(1500))
	eq(t, "output", *run.Output, `hello {"n":1}`)
	eq(t, "metrics", jsonOf(run.Metrics), `{"rows":42}`)
	s := summary(t, k.cw, "report")
	eq(t, "health", s.Health, cronwatch.HealthHealthy)
	eq(t, "next", *s.NextExpectedAt, int64(1767664800000)) // 2026-01-06 02:00Z
}

func TestFailingJobIsRecordedAlertsAndReturnsItsError(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("nightly")
	err := job.Run(bg, fails("db down"))
	if err == nil || err.Error() != "db down" {
		t.Fatalf("the job's own error comes back: %v", err)
	}
	run := runs(t, k.cw, "nightly")[0]
	eq(t, "status", run.Status, cronwatch.StatusFailed)
	eq(t, "error", *run.Error, "Error: db down")
	sameList(t, "alerts", k.alerts.Types(), []string{"failed"})
	if !strings.Contains(k.alerts.Alerts[0].Message, "db down") {
		t.Error(k.alerts.Alerts[0].Message)
	}
	eq(t, "health", summary(t, k.cw, "nightly").Health, cronwatch.HealthFailing)
}

func TestExpectTurnsAQuietSuccessIntoAFailure(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("export", cronwatch.Expect("wrote"))
	check(t, job.Run(bg, func(_ context.Context, j *cronwatch.JobContext) error { j.Log("wrote 12 files"); return nil }))
	sameList(t, "alerts", k.alerts.Types(), []string{})
	k.c.Advance(HOUR)
	check(t, job.Run(bg, func(_ context.Context, j *cronwatch.JobContext) error { j.Log("nothing to do"); return nil }))
	run := runs(t, k.cw, "export")[0]
	eq(t, "status", run.Status, cronwatch.StatusFailed)
	eq(t, "error", *run.Error, `Output did not contain "wrote"`)
	sameList(t, "alerts", k.alerts.Types(), []string{"failed"})
	// A returned string counts as output too.
	must[string](t)(cronwatch.RunValue(bg, job, func(context.Context, *cronwatch.JobContext) (string, error) { return "wrote 3 files", nil }))
	sameList(t, "alerts", k.alerts.Types(), []string{"failed", "recovered"})
}

func TestRunDefinesOnFirstUseAndValidates(t *testing.T) {
	k := newKit(t)
	check(t, k.cw.Run(bg, "adhoc", ok, cronwatch.Schedule("every 5m")))
	eq(t, "jobs", len(must[[]cronwatch.JobSummary](t)(k.cw.Jobs(bg))), 1)
	for _, c := range []struct {
		options []cronwatch.JobOption
		name    string
		want    string
	}{
		{nil, "bad name!", `job name "bad name!" must be 1 to 120 characters of letters, digits, ".", "_", ":" or "-"`},
		{[]cronwatch.JobOption{cronwatch.Schedule("nope")}, "x", `schedule "nope" is not a cron expression or "every <duration>": `},
		{[]cronwatch.JobOption{cronwatch.Grace("soon")}, "x", `grace "soon" is not a duration like "15m", "1h30m" or "90s"`},
	} {
		_, err := k.cw.Job(c.name, c.options...)
		if err == nil || !strings.HasPrefix(err.Error(), c.want) {
			t.Errorf("%s: %v", c.want, err)
		}
	}
}

func TestCheckFindsAMissedRunOnceAndARunRecovers(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("sync", cronwatch.Schedule("every 1h"), cronwatch.Grace("10m"))
	checkNow(t, k.cw) // registers at T0
	k.c.Advance(30 * MIN)
	sameList(t, "early", alertTypes(checkNow(t, k.cw).Alerts), []string{})
	k.c.Set(T0 + 70*MIN + 1)
	r := checkNow(t, k.cw)
	sameList(t, "missed", alertTypes(r.Alerts), []string{"missed"})
	eq(t, "health", r.Jobs[0].Health, cronwatch.HealthLate)
	sameList(t, "no repeat", alertTypes(checkNow(t, k.cw).Alerts), []string{})
	check(t, job.Run(bg, ok))
	sameList(t, "alerts", k.alerts.Types(), []string{"missed", "recovered"})
	eq(t, "health", summary(t, k.cw, "sync").Health, cronwatch.HealthHealthy)
}

func TestJobDeclaredAgainWithoutScheduleClosesMissed(t *testing.T) {
	k := newKit(t)
	k.cw.MustJob("sync", cronwatch.Schedule("every 1h"), cronwatch.Grace("10m"))
	checkNow(t, k.cw)
	k.c.Set(T0 + 70*MIN + 1)
	sameList(t, "missed", alertTypes(checkNow(t, k.cw).Alerts), []string{"missed"})
	job := k.cw.MustJob("sync")
	k.c.Advance(MIN)
	r := checkNow(t, k.cw)
	sameList(t, "recovered", alertTypes(r.Alerts), []string{"recovered"})
	a := r.Alerts[0]
	eq(t, "title", a.Title, "sync is no longer scheduled")
	eq(t, "message", a.Message, "Missed since 2026-01-05 10:40:00 UTC (1m ago). It has no schedule now, so nothing is due; the missed alert is closed.")
	eq(t, "details", jsonOf(a)[strings.Index(jsonOf(a), `"details"`):strings.Index(jsonOf(a), `,"job"`)], `"details":{"after":["missed"],"reason":"unscheduled","since":1767609600001}`)
	eq(t, "health", r.Jobs[0].Health, cronwatch.HealthNeverRan)
	sameList(t, "no repeat", alertTypes(checkNow(t, k.cw).Alerts), []string{})
	check(t, job.Run(bg, ok))
	sameList(t, "the next run owes nothing", k.alerts.Types(), []string{"missed", "recovered"})
}

func TestScheduleRemovedWhileSilencedClosesMissedQuietly(t *testing.T) {
	k := newKit(t)
	k.cw.MustJob("sync", cronwatch.Schedule("every 1h"), cronwatch.Grace("10m"))
	checkNow(t, k.cw)
	k.c.Set(T0 + 70*MIN + 1)
	checkNow(t, k.cw)
	must[cronwatch.JobState](t)(k.cw.Silence(bg, "sync", hour))
	k.cw.MustJob("sync")
	k.c.Advance(MIN)
	sameList(t, "quiet", alertTypes(checkNow(t, k.cw).Alerts), []string{})
	eq(t, "open", len(summary(t, k.cw, "sync").Open), 0)
	k.c.Advance(2 * HOUR)
	sameList(t, "still quiet", alertTypes(checkNow(t, k.cw).Alerts), []string{})
	sameList(t, "alerts", k.alerts.Types(), []string{"missed"})
}

func TestCheckMarksARunThatNeverFinishedAsStuck(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("long", cronwatch.Timeout("5m"))
	release := make(chan struct{})
	defer close(release)
	go func() {
		_ = job.Run(bg, func(ctx context.Context, _ *cronwatch.JobContext) error { <-release; return nil })
	}()
	waitFor(t, "the run to start", running(t, k.cw, "long"))
	k.c.Advance(4 * MIN)
	sameList(t, "not yet", alertTypes(checkNow(t, k.cw).Alerts), []string{})
	k.c.Advance(2 * MIN)
	r := checkNow(t, k.cw)
	sameList(t, "stuck", alertTypes(r.Alerts), []string{"stuck"})
	eq(t, "status", runs(t, k.cw, "long")[0].Status, cronwatch.StatusTimeout)
	eq(t, "health", r.Jobs[0].Health, cronwatch.HealthStuck)
	if !strings.Contains(k.alerts.Alerts[0].Message, "never reported finishing") {
		t.Error(k.alerts.Alerts[0].Message)
	}
}

func TestSlowAndOverBudgetFromTheJobsBaseline(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("agent", cronwatch.Budget("cost", 1))
	run := func(ms int64, tokens, cost float64) {
		check(t, job.Run(bg, func(_ context.Context, j *cronwatch.JobContext) error {
			k.c.Advance(ms)
			return j.Metrics(cronwatch.Metrics{{Name: "tokens", Value: tokens}, {Name: "cost", Value: cost}})
		}))
	}
	for i := 0; i < 5; i++ {
		run(1000, 1000, 0.5)
		k.c.Advance(HOUR)
	}
	sameList(t, "none yet", k.alerts.Types(), []string{})
	run(15_000, 1000, 0.5)
	sameList(t, "slow", k.alerts.Types(), []string{"slow"})
	k.c.Advance(HOUR)
	run(1000, 5000, 1.2)
	sameList(t, "over budget", k.alerts.Types(), []string{"slow", "over_budget"})
	last := k.alerts.Alerts[1]
	if !strings.Contains(last.Message, "cost: 1.2, limit 1 (budget)") || !strings.Contains(last.Message, "tokens: 5,000, limit 3,000 (three times the usual 1,000)") {
		t.Error(last.Message)
	}
	k.c.Advance(HOUR)
	run(1000, 1000, 0.5)
	sameList(t, "recovered", k.alerts.Types(), []string{"slow", "over_budget", "recovered"})
}

func TestSilenceSwallowsAlertsAndUnsilenceAlertsAgain(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("flaky")
	must[cronwatch.JobState](t)(k.cw.Silence(bg, "flaky", hour))
	if job.Run(bg, fails("x")) == nil {
		t.Fatal("error")
	}
	sameList(t, "silenced", k.alerts.Types(), []string{})
	eq(t, "health", summary(t, k.cw, "flaky").Health, cronwatch.HealthSilenced)
	must[cronwatch.JobState](t)(k.cw.Unsilence(bg, "flaky"))
	if job.Run(bg, fails("y")) == nil {
		t.Fatal("error")
	}
	sameList(t, "alerts", k.alerts.Types(), []string{"failed"})
}

func TestTriageIsAttachedAndNeverBlocks(t *testing.T) {
	k := newKit(t, cronwatch.WithTriage(func(_ context.Context, tc cronwatch.TriageContext) (string, error) {
		return "Probably " + tc.Alert.Job + "'s database.", nil
	}))
	if k.cw.Run(bg, "t", fails("x")) == nil {
		t.Fatal("error")
	}
	eq(t, "triage", *k.alerts.Alerts[0].Triage, "Probably t's database.")

	k2 := newKit(t, cronwatch.WithTriage(func(context.Context, cronwatch.TriageContext) (string, error) { return "", errors.New("api down") }))
	if k2.cw.Run(bg, "t", fails("x")) == nil {
		t.Fatal("error")
	}
	sameList(t, "alerts", k2.alerts.Types(), []string{"failed"})
	a := k2.alerts.Alerts[0]
	if a.Triage != nil || !a.TriageTried {
		t.Error("tried, and gave nothing")
	}
	if !strings.Contains(jsonOf(a), `"triage":null`) {
		t.Error("written as null")
	}
	sameList(t, "errors", k2.wheres(), []string{"triage for t"})
}

func TestForgetRemovesTheJobAndItsRuns(t *testing.T) {
	k := newKit(t)
	check(t, k.cw.Run(bg, "gone", ok))
	eq(t, "jobs", len(must[[]cronwatch.JobSummary](t)(k.cw.Jobs(bg))), 1)
	check(t, k.cw.Forget(bg, "gone"))
	eq(t, "jobs", len(must[[]cronwatch.JobSummary](t)(k.cw.Jobs(bg))), 0)
	if summary(t, k.cw, "gone") != nil {
		t.Error("summary of a forgotten job")
	}
}

func TestAFailingChannelDoesNotBreakTheRun(t *testing.T) {
	k := newKit(t, cronwatch.WithAlerts(channel("broken", func(cronwatch.Alert) error { return errors.New("no network") })))
	err := k.cw.Run(bg, "x", fails("job"))
	if err == nil || !regexp.MustCompile(`job`).MatchString(err.Error()) {
		t.Fatal(err)
	}
	sameList(t, "errors", k.wheres(), []string{"alert channel broken"})
}
