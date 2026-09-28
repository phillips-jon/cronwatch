package cronwatch_test

// concurrency.test.ts, on the memory store. The SQLite case is the SQL
// store's, in the sqltest module.

import (
	"context"
	"sync"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
)

// slowReads is a store whose state reads take a while, as over a network:
// two processes reading at about the same time both get the old state
// before either writes.
func slowReads(inner *cronwatch.MemoryStore) *testStore {
	s := newTestStore()
	s.inner = inner
	s.stateDelay = 25 * time.Millisecond
	return s
}

// race is two clients, as two processes sharing one store, each failing
// the job once at the same time.
func race(t *testing.T, a, b cronwatch.Store) (*cronwatch.JobState, []string) {
	t.Helper()
	c := storeClock()
	capA, capB := &captureOf{}, &captureOf{}
	one := cronwatch.MustNew(cronwatch.WithStore(a), cronwatch.WithClock(c.Now), cronwatch.WithAlerts(capA), cronwatch.WithoutCronSecret())
	two := cronwatch.MustNew(cronwatch.WithStore(b), cronwatch.WithClock(c.Now), cronwatch.WithAlerts(capB), cronwatch.WithoutCronSecret())
	options := cronwatch.FailuresBeforeAlert(2)
	check(t, one.Run(bg, "shared", ok, options))
	var wg sync.WaitGroup
	for _, cw := range []*cronwatch.Client{one, two} {
		wg.Add(1)
		go func() { defer wg.Done(); _ = cw.Run(bg, "shared", fails("x"), options) }()
	}
	wg.Wait()
	st := must[*cronwatch.JobState](t)(a.GetState(bg, "shared"))
	return st, append(capA.types(), capB.types()...)
}

func TestTwoProcessesFailingAtOnceBothCountAndAlertOnce(t *testing.T) {
	store := cronwatch.NewMemoryStore()
	st, types := race(t, slowReads(store), slowReads(store))
	eq(t, "neither failure was lost", st.ConsecutiveFailures, 2)
	eq(t, "the condition opened", len(st.Open) == 1 && st.Open[0].Condition == cronwatch.ConditionFailed, true)
	sameList(t, "one alert", types, []string{"failed"})
	if st.Version == nil || *st.Version < 3 {
		t.Errorf("every write bumped the version (%v)", st.Version)
	}
}

func TestAStoreWithoutCASCannotKeepTwoProcessesApart(t *testing.T) {
	store := cronwatch.NewMemoryStore()
	a, b := slowReads(store), slowReads(store)
	st, types := race(t, noCAS{a, a}, noCAS{b, b})
	// The documented caveat: the later write wins, so one failure is lost.
	eq(t, "failures", st.ConsecutiveFailures, 1)
	sameList(t, "alerts", types, []string{})
}

func TestASilenceMadeByOneProcessSurvivesAnothersRun(t *testing.T) {
	store := cronwatch.NewMemoryStore()
	c := storeClock()
	runner := cronwatch.MustNew(cronwatch.WithStore(slowReads(store)), cronwatch.WithClock(c.Now), cronwatch.WithAlerts(&captureOf{}), cronwatch.WithoutCronSecret())
	admin := cronwatch.MustNew(cronwatch.WithStore(slowReads(store)), cronwatch.WithClock(c.Now), cronwatch.WithAlerts(&captureOf{}), cronwatch.WithoutCronSecret())
	check(t, runner.Run(bg, "s", ok))
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _ = runner.Run(bg, "s", fails("x")) }()
	go func() { defer wg.Done(); _, _ = admin.Silence(bg, "s", hour) }()
	wg.Wait()
	st := must[*cronwatch.JobState](t)(store.GetState(bg, "s"))
	if st.SilencedUntil == nil {
		t.Error("the silence was overwritten")
	}
	eq(t, "nor was the failure", st.ConsecutiveFailures, 1)
}

func TestAnUpdateThatKeepsLosingGivesUpAndTheRunFinishes(t *testing.T) {
	store := newTestStore()
	// Always refuses: as if another process wrote between every read and write.
	store.cas = func(cronwatch.JobState, int64) (bool, error) { return false, nil }
	k := newKit(t, cronwatch.WithStore(store))
	if err := k.cw.Run(bg, "busy", fails("x")); err == nil {
		t.Fatal("the job's error")
	}
	sameList(t, "errors", k.wheres(), []string{"evaluating busy"})
	eq(t, "status", runs(t, k.cw, "busy")[0].Status, cronwatch.StatusFailed)
	if msgs := k.messages(); len(msgs) != 1 || msgs[0] != "the state of busy changed under 10 attempts in a row to update it; gave up" {
		t.Error(msgs)
	}
}

func TestManyGoroutinesRunningOneJob(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("fanout", cronwatch.FailuresBeforeAlert(1000))
	const n = 50
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			fn := ok
			if i%2 == 1 {
				fn = fails("odd")
			}
			_ = job.Run(bg, func(ctx context.Context, j *cronwatch.JobContext) error {
				j.Log("worker", i)
				_ = j.Metric("i", float64(i))
				return fn(ctx, j)
			})
		}()
	}
	wg.Wait()
	list := must[[]cronwatch.Run](t)(k.cw.Runs(bg, "fanout", 500))
	eq(t, "runs", len(list), n)
	failed := 0
	for _, r := range list {
		if r.Status == cronwatch.StatusFailed {
			failed++
		}
		if r.Output == nil || r.Metrics == nil || len(r.Metrics) != 1 {
			t.Errorf("run %s lost its output or metrics", r.ID)
		}
	}
	eq(t, "failed", failed, n/2)
	sameList(t, "errors", k.wheres(), []string{})
	st := state(t, k.cw, "fanout")
	if st.Version == nil || *st.Version < 1 {
		t.Error("state written")
	}
}

func TestConcurrentChecksShareOneCheck(t *testing.T) {
	store := newTestStore()
	k := newKit(t, cronwatch.WithStore(store))
	k.cw.MustJob("a", cronwatch.Schedule("every 1h"))
	checkNow(t, k.cw)
	gate := make(chan struct{})
	entered := make(chan struct{})
	store.hook("RunningRuns", func() { close(entered); <-gate })
	before := store.count("RunningRuns")
	results := make([]*cronwatch.CheckResult, 4)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); results[0] = must[*cronwatch.CheckResult](t)(k.cw.Check(bg)) }()
	<-entered
	for i := 1; i < 4; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); results[i] = must[*cronwatch.CheckResult](t)(k.cw.Check(bg)) }()
	}
	time.Sleep(20 * time.Millisecond)
	close(gate)
	wg.Wait()
	eq(t, "one check ran", store.count("RunningRuns")-before, 1)
	for i := 1; i < 4; i++ {
		if results[i] != results[0] {
			t.Errorf("caller %d got a result of its own", i)
		}
	}
	// And a later call runs a check of its own.
	checkNow(t, k.cw)
	eq(t, "a second check", store.count("RunningRuns")-before, 2)
}
