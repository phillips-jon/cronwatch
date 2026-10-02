package cronwatch_test

// client-hardening.test.ts. The hung channel, triage timeout, retry budget
// and Start/Stop cases need the package's own waits shortened, so they are
// in timing_internal_test.go; the handler case waits for phase 3.

import (
	"bytes"
	"context"
	"errors"
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
)

func TestCronFiringMoreOftenThanItsGraceIsStillMissed(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("often", cronwatch.Schedule("*/5 * * * *")) // default grace 10m
	check(t, job.Run(bg, ok))                                       // 09:30
	k.c.Advance(14 * MIN)
	sameList(t, "09:35 is due, grace runs to 09:45", alertTypes(checkNow(t, k.cw).Alerts), []string{})
	k.c.Advance(2 * MIN)
	sameList(t, "missed", alertTypes(checkNow(t, k.cw).Alerts), []string{"missed"})
	check(t, job.Run(bg, ok))
	sameList(t, "alerts", k.alerts.Types(), []string{"missed", "recovered"})
}

func TestMissedThenAQuietFailureStillRecoversLater(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("quiet", cronwatch.Schedule("every 1h"), cronwatch.FailuresBeforeAlert(3))
	checkNow(t, k.cw)
	k.c.Advance(2 * HOUR)
	checkNow(t, k.cw)
	_ = job.Run(bg, fails("x"))
	sameList(t, "missed", k.alerts.Types(), []string{"missed"})
	check(t, job.Run(bg, ok))
	sameList(t, "recovered", k.alerts.Types(), []string{"missed", "recovered"})
	if !strings.Contains(k.alerts.List()[1].Message, "after: missed") {
		t.Error(k.alerts.List()[1].Message)
	}
}

func TestAStoreOutageNeverStopsTheJob(t *testing.T) {
	store := newTestStore()
	store.breaks("UpsertJob", "InsertRun", "GetState", "SetState", "UpdateRun", "ListRuns")
	k := newKit(t, cronwatch.WithStore(store))
	ran := 0
	job := k.cw.MustJob("s")
	v, err := cronwatch.RunValue(bg, job, func(context.Context, *cronwatch.JobContext) (int, error) { ran++; return 7, nil })
	check(t, err)
	eq(t, "result", v, 7)
	err = job.Run(bg, func(context.Context, *cronwatch.JobContext) error { ran++; return errors.New("the job's own") })
	if err == nil || err.Error() != "the job's own" {
		t.Fatal(err)
	}
	eq(t, "ran", ran, 2)
	wheres := k.wheres()
	if len(wheres) == 0 {
		t.Fatal("no errors reported")
	}
	for _, w := range wheres {
		if w != "recording s" {
			t.Errorf("reported as %q", w)
		}
	}
	store.mends()
	must[string](t)(cronwatch.RunValue(bg, job, func(context.Context, *cronwatch.JobContext) (string, error) { return "back", nil }))
	eq(t, "runs", len(runs(t, k.cw, "s")), 1)
}

func TestAStoreThatFailsToInitialiseIsTriedAgain(t *testing.T) {
	store := newTestStore()
	inits := 0
	store.init = func() error {
		inits++
		if inits == 1 {
			return errors.New("not yet")
		}
		return nil
	}
	k := newKit(t, cronwatch.WithStore(store))
	job := k.cw.MustJob("i")
	eq(t, "result", must[int](t)(cronwatch.RunValue(bg, job, func(context.Context, *cronwatch.JobContext) (int, error) { return 1, nil })), 1)
	sameList(t, "errors", k.wheres(), []string{"recording i"})
	// The finished run was written on the retry, once init went through.
	eq(t, "inits", inits, 2)
	check(t, job.Run(bg, ok))
	eq(t, "inits", inits, 2)
	eq(t, "runs", len(runs(t, k.cw, "i")), 2)
}

func TestDispatchDoesNotOverwriteASilenceMadeWhileSending(t *testing.T) {
	var cw *cronwatch.Client
	silencer := channel("silencer", func(cronwatch.Alert) error {
		_, err := cw.Silence(bg, "loud", hour)
		return err
	})
	k := newKit(t, cronwatch.WithAlerts(silencer))
	cw = k.cw
	_ = cw.Run(bg, "loud", fails("x"))
	s := state(t, cw, "loud")
	if s.SilencedUntil == nil {
		t.Error("the silence did not survive")
	}
	eq(t, "open", jsonOf(*s)[strings.Index(jsonOf(*s), `"open"`):strings.Index(jsonOf(*s), `,"consecutiveFailures"`)], `"open":{"failed":1767605400000}`)
	eq(t, "lastAlertAt", *s.LastAlertAt, T0)
}

func TestAnAlertNoChannelTookIsRetriedOncePerCheck(t *testing.T) {
	var mu sync.Mutex
	down, attempts := true, 0
	var got []cronwatch.Alert
	flaky := channel("flaky", func(a cronwatch.Alert) error {
		mu.Lock()
		defer mu.Unlock()
		attempts++
		if down {
			return errors.New("down")
		}
		got = append(got, a)
		return nil
	})
	k := newKit(t, cronwatch.WithAlerts(flaky))
	_ = k.cw.Run(bg, "r", fails("x"))
	s := state(t, k.cw, "r")
	eq(t, "queued", len(s.Undelivered), 1)
	if s.LastAlertAt != nil {
		t.Error("nothing was delivered")
	}
	k.c.Advance(MIN)
	checkNow(t, k.cw)
	eq(t, "one retry per check", attempts, 2)
	mu.Lock()
	down = false
	mu.Unlock()
	k.c.Advance(MIN)
	result := checkNow(t, k.cw)
	sameList(t, "delivered", alertTypes(result.Alerts), []string{"failed"})
	sameList(t, "got", alertTypes(got), []string{"failed"})
	eq(t, "the same alert, not a new one", got[0].At, T0)
	s = state(t, k.cw, "r")
	eq(t, "queue", len(s.Undelivered), 0)
	eq(t, "lastAlertAt", *s.LastAlertAt, T0+2*MIN)
	checkNow(t, k.cw)
	eq(t, "not sent again", attempts, 3)
}

func TestDeliverAtCheckQueuesForAnotherProcess(t *testing.T) {
	c := storeClock()
	store := cronwatch.NewMemoryStore()
	unused := &captureOf{}
	triaged := 0
	recorder := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(c.Now), cronwatch.WithAlerts(unused), cronwatch.WithDeliver(cronwatch.DeliverAtCheck),
		cronwatch.WithTriage(func(context.Context, cronwatch.TriageContext) (string, error) { return "never asked", nil }), cronwatch.WithoutCronSecret())
	job := recorder.MustJob("backup", cronwatch.Schedule("40 3 * * *"), cronwatch.Timezone("UTC"))
	_ = job.Run(bg, fails("disk full"))
	eq(t, "nothing sent from the recording process", unused.n(), 0)
	s := must[*cronwatch.JobState](t)(store.GetState(bg, "backup"))
	sameList(t, "queued", alertTypes(s.Undelivered), []string{"failed"})
	if s.LastAlertAt != nil {
		t.Error("lastAlertAt")
	}
	sameList(t, "its own check does not send either", alertTypes(checkNow(t, recorder).Alerts), []string{})

	// The web server: can send, and has not declared the job.
	sent := &captureOf{}
	server := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(c.Now), cronwatch.WithAlerts(sent), cronwatch.WithoutCronSecret(),
		cronwatch.WithTriage(func(context.Context, cronwatch.TriageContext) (string, error) {
			triaged++
			return "The disk is full.", nil
		}))
	c.Advance(MIN)
	result := checkNow(t, server)
	sameList(t, "sent", alertTypes(result.Alerts), []string{"failed"})
	sameList(t, "sent", sent.types(), []string{"failed"})
	eq(t, "triage", *sent.get(0).Triage, "The disk is full.")
	eq(t, "the alert from the run, not a new one", sent.get(0).At, T0)
	eq(t, "triaged", triaged, 1)
	s = must[*cronwatch.JobState](t)(store.GetState(bg, "backup"))
	eq(t, "queue", len(s.Undelivered), 0)
	eq(t, "lastAlertAt", *s.LastAlertAt, T0+MIN)
	checkNow(t, server)
	sameList(t, "sent once", sent.types(), []string{"failed"})

	// The recovery takes the same route.
	check(t, job.Run(bg, ok))
	checkNow(t, server)
	sameList(t, "recovered", sent.types(), []string{"failed", "recovered"})
	eq(t, "recoveries are not triaged", triaged, 1)
}

func TestDeliverTakesOnlyNowOrCheck(t *testing.T) {
	_, err := cronwatch.New(cronwatch.WithDeliver("later"))
	if err == nil || err.Error() != `deliver must be "now" or "check", not "later"` {
		t.Error(err)
	}
}

func TestOverlappingRunsShareStateWithoutLosingUpdates(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("par", cronwatch.FailuresBeforeAlert(2))
	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _ = job.Run(bg, fails("x")) }()
	}
	wg.Wait()
	eq(t, "failures", state(t, k.cw, "par").ConsecutiveFailures, 3)
	sameList(t, "one alert, not one per run", k.alerts.Types(), []string{"failed"})
}

func TestJobRejectsNumbersThatWouldTurnACheckOff(t *testing.T) {
	k := newKit(t)
	for _, c := range []struct {
		options []cronwatch.JobOption
		want    string
	}{
		{[]cronwatch.JobOption{cronwatch.FailuresBeforeAlert(0)}, `job "a": failuresBeforeAlert must be a whole number, 1 or more (got 0)`},
		{[]cronwatch.JobOption{cronwatch.FailuresBeforeAlert(-2)}, `job "a": failuresBeforeAlert must be a whole number, 1 or more (got -2)`},
		{[]cronwatch.JobOption{cronwatch.Budget("cost", math.NaN())}, `job "a": budget.cost must be a finite number, 0 or more (got NaN)`},
		{[]cronwatch.JobOption{cronwatch.Budget("cost", math.Inf(1))}, `job "a": budget.cost must be a finite number, 0 or more (got Infinity)`},
		{[]cronwatch.JobOption{cronwatch.Budget("cost", -1)}, `job "a": budget.cost must be a finite number, 0 or more (got -1)`},
		{[]cronwatch.JobOption{cronwatch.Floor("rows", math.NaN())}, `job "a": floor.rows must be a finite number (got NaN)`},
		{[]cronwatch.JobOption{cronwatch.Floor("rows", math.Inf(-1))}, `job "a": floor.rows must be a finite number (got -Infinity)`},
		{[]cronwatch.JobOption{cronwatch.Floor("cost", 3), cronwatch.Budget("cost", 2)}, `job "a": floor.cost (3) is above budget.cost (2), so every run would alert`},
		{[]cronwatch.JobOption{cronwatch.Grace(math.NaN())}, `grace must be a non-negative number of milliseconds`},
		{[]cronwatch.JobOption{cronwatch.Timeout(0)}, `job "a": timeout must be longer than zero`},
		{[]cronwatch.JobOption{cronwatch.MaxDuration("0s")}, `job "a": maxDuration must be longer than zero`},
		{[]cronwatch.JobOption{cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("Mars/Olympus")}, `job "a": timezone "Mars/Olympus" is not an IANA timezone`},
		{[]cronwatch.JobOption{cronwatch.Schedule("  ")}, `job "a": schedule must be a non-empty string`},
	} {
		if _, err := k.cw.Job("a", c.options...); err == nil || err.Error() != c.want {
			t.Errorf("want %s, got %v", c.want, err)
		}
	}
	d := cronwatch.MustNew(cronwatch.WithDefaults(cronwatch.FailuresBeforeAlert(0)))
	if _, err := d.Job("a"); err == nil || !strings.Contains(err.Error(), "failuresBeforeAlert") {
		t.Error(err)
	}
	if _, err := cronwatch.New(cronwatch.WithDefaults(cronwatch.Schedule("@hourly"))); err == nil || !strings.Contains(err.Error(), "WithDefaults takes grace, timeout, timezone and failuresBeforeAlert") {
		t.Error(err)
	}
	must[*cronwatch.Job](t)(k.cw.Job("a", cronwatch.Budget("errors", 0), cronwatch.FailuresBeforeAlert(2), cronwatch.Timeout("5m")))
	must[*cronwatch.Job](t)(k.cw.Job("c", cronwatch.Floor("delta", -5), cronwatch.Budget("delta", 5)))
}

func TestAReturnedStringIsCappedLikeLoggedOutput(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("big")
	must[string](t)(cronwatch.RunValue(bg, job, func(context.Context, *cronwatch.JobContext) (string, error) { return strings.Repeat("x", 40_000), nil }))
	out := *runs(t, k.cw, "big")[0].Output
	if len(out) >= 17*1024 || !strings.HasPrefix(out, "[earlier output trimmed]") {
		t.Errorf("output of %d bytes", len(out))
	}
}

func TestRunsTakesAWholeNumberOfRunsInRange(t *testing.T) {
	k := newKit(t)
	for i := 0; i < 3; i++ {
		check(t, k.cw.Run(bg, "n", ok))
	}
	eq(t, "two", len(must[[]cronwatch.Run](t)(k.cw.Runs(bg, "n", 2))), 2)
	eq(t, "at least one", len(must[[]cronwatch.Run](t)(k.cw.Runs(bg, "n", -4))), 1)
	entries := must[[]cronwatch.JobWithRuns](t)(k.cw.JobsWithRuns(bg, 2))
	eq(t, "runs", len(entries[0].Runs), 2)
	eq(t, "last run", entries[0].Job.LastRun.ID, entries[0].Runs[0].ID)
}

func TestAnErrorIsNamedOnce(t *testing.T) {
	k := newKit(t)
	_ = k.cw.Run(bg, "db", fails("connect ECONNREFUSED 10.0.0.12:5432"))
	eq(t, "error", *runs(t, k.cw, "db")[0].Error, "Error: connect ECONNREFUSED 10.0.0.12:5432")
	msg := k.alerts.List()[0].Message
	if strings.Contains(msg, "Error: Error:") || !strings.Contains(msg, "\nError: connect ECONNREFUSED") {
		t.Error(msg)
	}
	_ = k.cw.Run(bg, "db", fails("two\nlines"))
	eq(t, "two lines", *runs(t, k.cw, "db")[0].Error, "Error: two\nlines")
}

func TestTheBaselineReadsPastFailuresToTwentySuccesses(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("base")
	at := func(ms int64, fail bool) {
		_ = job.Run(bg, func(context.Context, *cronwatch.JobContext) error {
			k.c.Advance(ms)
			if fail {
				return errors.New("x")
			}
			return nil
		})
		k.c.Advance(MIN)
	}
	for i := 0; i < 5; i++ {
		at(100_000, false)
	}
	for i := 0; i < 15; i++ {
		at(1_000, false)
	}
	for i := 0; i < 10; i++ {
		at(1_000, true)
	}
	// Fifteen 1s runs alone would make 10s the limit; with the five 100s runs, p95 is 100s.
	at(30_000, false)
	sameList(t, "alerts", k.alerts.Types(), []string{"failed", "recovered"})
}

func TestADiagnosisMadeOnARetryIsKept(t *testing.T) {
	c := storeClock()
	store := cronwatch.NewMemoryStore()
	queued(t, store, c, "backup")
	asked := 0
	var mu sync.Mutex
	down := true
	sent := &captureOf{}
	flaky := channel("flaky", func(a cronwatch.Alert) error {
		mu.Lock()
		defer mu.Unlock()
		if down {
			return errors.New("down")
		}
		return sent.Send(bg, a, cronwatch.ChannelContext{})
	})
	server := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(c.Now), cronwatch.WithAlerts(flaky), cronwatch.WithoutCronSecret(),
		cronwatch.WithErrorHandler(func(error, string) {}),
		cronwatch.WithTriage(func(context.Context, cronwatch.TriageContext) (string, error) {
			asked++
			return "The disk is full.", nil
		}))
	checkNow(t, server)
	eq(t, "asked", asked, 1)
	s := must[*cronwatch.JobState](t)(store.GetState(bg, "backup"))
	eq(t, "the stored copy has it", *s.Undelivered[0].Triage, "The disk is full.")
	checkNow(t, server)
	checkNow(t, server)
	eq(t, "not asked again on later retries", asked, 1)
	mu.Lock()
	down = false
	mu.Unlock()
	checkNow(t, server)
	sameList(t, "sent", sent.types(), []string{"failed"})
	eq(t, "with triage", *sent.get(0).Triage, "The disk is full.")
}

func TestATriageThatFailsOrAnswersNothingIsTriedOnce(t *testing.T) {
	for _, answer := range []func() (string, error){
		func() (string, error) { return "", errors.New("api down") },
		func() (string, error) { return "", nil },
	} {
		c := storeClock()
		store := cronwatch.NewMemoryStore()
		queued(t, store, c, "backup")
		asked := 0
		server := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(c.Now), cronwatch.WithoutCronSecret(),
			cronwatch.WithErrorHandler(func(error, string) {}),
			cronwatch.WithAlerts(channel("down", func(cronwatch.Alert) error { return errors.New("down") })),
			cronwatch.WithTriage(func(context.Context, cronwatch.TriageContext) (string, error) { asked++; return answer() }))
		for i := 0; i < 3; i++ {
			checkNow(t, server)
		}
		eq(t, "asked", asked, 1)
		a := must[*cronwatch.JobState](t)(store.GetState(bg, "backup")).Undelivered[0]
		if a.Triage != nil || !a.TriageTried {
			t.Error("recorded as null")
		}
	}
}

func TestAnAlertWhoseConditionClosedIsDroppedFromTheQueue(t *testing.T) {
	var mu sync.Mutex
	down := true
	var sent []string
	flaky := channel("flaky", func(a cronwatch.Alert) error {
		mu.Lock()
		defer mu.Unlock()
		if down {
			return errors.New("down")
		}
		sent = append(sent, string(a.Type)+"@"+jsonOf(a.At))
		return nil
	})
	k := newKit(t, cronwatch.WithAlerts(flaky))
	_ = k.cw.Run(bg, "s", fails("x"))
	k.c.Advance(MIN)
	check(t, k.cw.Run(bg, "s", ok))
	sameList(t, "queued", alertTypes(state(t, k.cw, "s").Undelivered), []string{"failed", "recovered"})
	mu.Lock()
	down = false
	mu.Unlock()
	k.c.Advance(MIN)
	checkNow(t, k.cw)
	sameList(t, "the failure is over, so only its recovery goes", sent, []string{"recovered@" + jsonOf(T0+MIN)})
	eq(t, "queue", len(state(t, k.cw, "s").Undelivered), 0)
}

func TestAnAlertWhoseConditionOpenedAgainIsDropped(t *testing.T) {
	var mu sync.Mutex
	down := true
	var sent []string
	flaky := channel("flaky", func(a cronwatch.Alert) error {
		mu.Lock()
		defer mu.Unlock()
		if down {
			return errors.New("down")
		}
		sent = append(sent, string(a.Type)+"@"+jsonOf(a.At))
		return nil
	})
	k := newKit(t, cronwatch.WithAlerts(flaky))
	_ = k.cw.Run(bg, "s", fails("x"))
	k.c.Advance(MIN)
	check(t, k.cw.Run(bg, "s", ok))
	k.c.Advance(MIN)
	_ = k.cw.Run(bg, "s", fails("again"))
	sameList(t, "queued", alertTypes(state(t, k.cw, "s").Undelivered), []string{"failed", "recovered", "failed"})
	mu.Lock()
	down = false
	mu.Unlock()
	k.c.Advance(MIN)
	checkNow(t, k.cw)
	sameList(t, "sent", sent, []string{"failed@" + jsonOf(T0+2*MIN)})
}

func TestAJobThatCannotBeEvaluatedIsReportedAndShownFailing(t *testing.T) {
	k := newKit(t)
	good := k.cw.MustJob("good", cronwatch.Schedule("every 1h"))
	check(t, good.Run(bg, ok))
	store := k.cw.Store()
	check(t, store.UpsertJob(bg, definition(t, `{"name":"bad","schedule":"not a schedule"}`), T0))
	check(t, store.UpsertJob(bg, definition(t, `{"name":"odd","timeout":"soon"}`), T0))
	check(t, store.InsertRun(bg, cronwatch.Run{ID: "hung", Job: "odd", Status: cronwatch.StatusRunning, StartedAt: T0, Metrics: cronwatch.Metrics{}, Trigger: "run"}))
	k.c.Advance(2 * HOUR)
	result := checkNow(t, k.cw)
	var got []string
	for _, a := range result.Alerts {
		got = append(got, a.Job+":"+string(a.Type))
	}
	sameList(t, "alerts", got, []string{"good:missed"})
	health := map[string]cronwatch.JobHealth{}
	for _, j := range result.Jobs {
		health[j.Name] = j.Health
	}
	eq(t, "bad", health["bad"], cronwatch.HealthFailing)
	eq(t, "good", health["good"], cronwatch.HealthLate)
	eq(t, "odd", health["odd"], cronwatch.HealthFailing)
	sameList(t, "errors", k.wheres(), []string{"checking odd", "checking bad", "checking odd"})
	sameList(t, "sent", k.alerts.Types(), []string{"missed"})

	before := len(k.errors.List())
	jobs := must[[]cronwatch.JobSummary](t)(k.cw.Jobs(bg))
	var rows []string
	for _, j := range jobs {
		rows = append(rows, j.Name+" "+string(j.Health)+" "+jsonOf(j.NextExpectedAt == nil))
	}
	sameList(t, "jobs", rows, []string{"bad failing true", "good late false", "odd failing true"})
	sameList(t, "reading", k.wheres()[before:], []string{"reading bad", "reading odd"})
	eq(t, "bad", summary(t, k.cw, "bad").Health, cronwatch.HealthFailing)
	must[cronwatch.JobState](t)(k.cw.Silence(bg, "bad", hour))
	eq(t, "silenced", summary(t, k.cw, "bad").Health, cronwatch.HealthSilenced)
}

func TestTrimmingTheUndeliveredQueuePastTwentyIsReported(t *testing.T) {
	k := newKit(t, cronwatch.WithDeliver(cronwatch.DeliverAtCheck))
	for i := 0; i < 10; i++ {
		_ = k.cw.Run(bg, "q", fails("x"))
		check(t, k.cw.Run(bg, "q", ok))
	}
	eq(t, "twenty", len(state(t, k.cw, "q").Undelivered), 20)
	sameList(t, "no errors", k.wheres(), []string{})
	_ = k.cw.Run(bg, "q", fails("x"))
	eq(t, "still twenty", len(state(t, k.cw, "q").Undelivered), 20)
	sameList(t, "errors", k.wheres(), []string{"alert queue for q"})
}

func TestStartWithDeliverAtCheckSaysOnceAnotherProcessMustSend(t *testing.T) {
	var buf bytes.Buffer
	saved := cronwatch.Stderr
	cronwatch.Stderr = &buf
	defer func() { cronwatch.Stderr = saved }()
	cw := cronwatch.MustNew(cronwatch.WithDeliver(cronwatch.DeliverAtCheck), cronwatch.WithoutCronSecret())
	cw.StartChecking(time.Hour)
	cw.Stop()
	cw.StartChecking(time.Hour)
	cw.Stop()
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	eq(t, "warnings", len(lines), 1)
	if !strings.Contains(lines[0], "DeliverAtCheck") || !strings.Contains(lines[0], "send no alerts") || !strings.Contains(lines[0], "Another process") {
		t.Error(lines[0])
	}
	other := cronwatch.MustNew(cronwatch.WithoutCronSecret())
	other.Start(time.Hour)
	other.Stop()
	eq(t, "a delivering client says nothing", len(strings.Split(strings.TrimSpace(buf.String()), "\n")), 1)
}

// ---- shared by the tests above

// storeClock is a clock at T0.
func storeClock() *clockOf { return &clockOf{at: T0} }

type clockOf struct {
	mu sync.Mutex
	at int64
}

func (c *clockOf) Now() int64 { c.mu.Lock(); defer c.mu.Unlock(); return c.at }

func (c *clockOf) Advance(ms int64) { c.mu.Lock(); defer c.mu.Unlock(); c.at += ms }

// The audit: a timeout past what a time.Duration holds (some 292 years)
// wrapped round where the float's conversion is not saturating (amd64),
// and the job's context ended as it started.
func TestAVeryLongTimeoutDoesNotEndTheJobAtOnce(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("forever", cronwatch.Timeout("20000w"))
	check(t, job.Run(bg, func(ctx context.Context, _ *cronwatch.JobContext) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) < 100*365*24*time.Hour {
			return errors.New("the deadline is not centuries away")
		}
		return nil
	}))
}

// The audit: each channel gets a copy of the alert, but its details' slices
// were shared, so a channel that changed them changed every other's.
func TestAChannelChangingAnAlertsDetailsChangesNoOtherChannels(t *testing.T) {
	changer := cronwatch.ChannelFunc("changer", func(_ context.Context, a cronwatch.Alert) error {
		if d, ok := a.Details.(cronwatch.OverBudgetDetails); ok {
			for i := range d.Breaches {
				d.Breaches[i].Metric = "changed"
			}
		}
		return nil
	})
	seen := &captureOf{}
	k := newKit(t, cronwatch.WithAlerts(changer, seen))
	job := k.cw.MustJob("spend", cronwatch.Budget("cost", 1))
	check(t, job.Run(bg, func(_ context.Context, j *cronwatch.JobContext) error { return j.Metric("cost", 2) }))
	if seen.n() != 1 {
		t.Fatalf("alerts: %v", seen.types())
	}
	if d := seen.get(0).Details.(cronwatch.OverBudgetDetails); d.Breaches[0].Metric != "cost" {
		t.Fatalf("the other channel's copy was changed: %+v", d)
	}
}

// captureOf keeps the alerts sent to it.
type captureOf struct {
	mu     sync.Mutex
	alerts []cronwatch.Alert
}

func (c *captureOf) Name() string { return "capture" }

func (c *captureOf) Send(_ context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.alerts = append(c.alerts, a)
	return nil
}

func (c *captureOf) n() int { c.mu.Lock(); defer c.mu.Unlock(); return len(c.alerts) }

func (c *captureOf) get(i int) cronwatch.Alert { c.mu.Lock(); defer c.mu.Unlock(); return c.alerts[i] }

func (c *captureOf) types() []string { c.mu.Lock(); defer c.mu.Unlock(); return alertTypes(c.alerts) }

// queued is a job's failure queued by a DeliverAtCheck process, so a
// check elsewhere must triage and send it.
func queued(t *testing.T, store cronwatch.Store, c *clockOf, name string) {
	t.Helper()
	recorder := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(c.Now), cronwatch.WithDeliver(cronwatch.DeliverAtCheck), cronwatch.WithoutCronSecret())
	if recorder.Run(bg, name, fails("disk full")) == nil {
		t.Fatal("the job should fail")
	}
}

// readsItself is an error whose Error reads its receiver, so a nil one
// panics there.
type readsItself struct{ why string }

func (e *readsItself) Error() string { return e.why }

// The audit: a nil *T returned as an error (or logged) panicked inside
// CronWatch after the job returned, leaving its run running.
func TestATypedNilErrorIsRecorded(t *testing.T) {
	k := newKit(t)
	err := k.cw.Run(bg, "typed", func(_ context.Context, j *cronwatch.JobContext) error {
		var e *readsItself
		j.Log(e)
		return e
	})
	if err == nil {
		t.Fatal("the error was lost")
	}
	run := runs(t, k.cw, "typed")[0]
	eq(t, "failed", run.Status, cronwatch.StatusFailed)
	eq(t, "error", *run.Error, "Error: <nil>")
	eq(t, "output", *run.Output, "Error: <nil>")
}

// The audit: a DiscardWhen predicate that panicked escaped Run after the
// run was inserted, leaving it running.
func TestADiscardPredicateThatPanicsIsReported(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("given")
	err := job.Run(bg, fails("later"), cronwatch.DiscardWhen(func(error) bool { panic("predicate broke") }))
	if err == nil {
		t.Fatal("the error was lost")
	}
	eq(t, "failed", runs(t, k.cw, "given")[0].Status, cronwatch.StatusFailed)
	eq(t, "reported", strings.Join(k.errors.List(), "\n"), "discarding given: panicked: predicate broke")
}

// The audit: Current(ctx) is nil outside a run, and its methods panicked.
func TestANilJobContextDoesNothing(t *testing.T) {
	jc := cronwatch.Current(bg)
	jc.Log("nobody hears this")
	check(t, jc.Metric("rows", 1))
	check(t, jc.Metrics(cronwatch.Metrics{{Name: "rows", Value: 1}}))
	eq(t, "name", jc.Name()+jc.RunID(), "")
	eq(t, "started", jc.StartedAt(), int64(0))
}

// The audit: a job's timeout cause was not a context.DeadlineExceeded.
func TestTheTimeoutCauseIsADeadline(t *testing.T) {
	k := newKit(t)
	var cause error
	_ = k.cw.Run(bg, "slow", func(ctx context.Context, _ *cronwatch.JobContext) error {
		<-ctx.Done()
		cause = context.Cause(ctx)
		return cause
	}, cronwatch.Timeout(20))
	if !errors.Is(cause, context.DeadlineExceeded) || cause.Error() != `job "slow" passed its timeout of 20ms` {
		t.Fatalf("cause %v", cause)
	}
}

// The audit: a store that panicked in a Start with a run id left that id's
// start in flight for good, so every later Start of it waited forever.
func TestAStartThatPanickedEndsForTheNextOne(t *testing.T) {
	store := newTestStore()
	k := newKit(t, cronwatch.WithStore(store))
	job := k.cw.MustJob("resumable")
	store.hook("GetRun", func() { panic("the store fell over") })
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("the panic did not reach the caller")
			}
		}()
		_, _ = job.Start(bg, cronwatch.WithRunID("run-1"))
	}()
	done := make(chan error, 1)
	go func() {
		_, err := job.Start(bg, cronwatch.WithRunID("run-1"))
		done <- err
	}()
	select {
	case err := <-done:
		check(t, err)
	case <-time.After(5 * time.Second):
		t.Fatal("the next start waited on the one that panicked")
	}
}

// The audit: a store that panicked while a run's start closed missed and
// stuck, in the goroutine beside the job, ended the process.
func TestAPanicClosingMissedAtTheStartIsReported(t *testing.T) {
	store := newTestStore()
	k := newKit(t, cronwatch.WithStore(store))
	job := k.cw.MustJob("nightly")
	store.hook("GetState", func() { panic("the store fell over") })
	check(t, job.Run(bg, func(context.Context, *cronwatch.JobContext) error { return nil }))
	if got := strings.Join(k.errors.List(), "\n"); got != "starting nightly: panicked: the store fell over" {
		t.Fatalf("reported: %q", got)
	}
}
