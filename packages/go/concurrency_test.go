package cronwatch_test

// concurrency.test.ts, on the memory store. The SQLite case is the SQL
// store's, in the sqltest module.

import (
	"context"
	"errors"
	"sync"
	"testing"
	"testing/synctest"
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

// scheduleOf is the schedule the store holds for a job.
func scheduleOf(t *testing.T, store cronwatch.Store, name string) string {
	t.Helper()
	job := must[*cronwatch.StoredJob](t)(store.GetJob(bg, name))
	if job == nil {
		t.Fatalf("%s is not stored", name)
	}
	return job.Definition.Schedule()
}

// heldUpsert is a store whose next write of a job's definition waits until
// the returned function lets it go, so a test can declare the job again, or
// ask for another write, while that one is under way.
func heldUpsert() (*testStore, func()) {
	store := newTestStore()
	gate := make(chan struct{})
	store.hook("UpsertJob", func() { <-gate })
	return store, func() { close(gate) }
}

func TestAHandleFromAnEarlierDeclarationWritesTheOneThatStands(t *testing.T) {
	k := newKit(t)
	earlier := k.cw.MustJob("a")
	k.cw.MustJob("a", cronwatch.Schedule("every 5m"))
	check(t, earlier.Run(bg, ok))
	eq(t, "after the run", scheduleOf(t, k.cw.Store(), "a"), "every 5m")
	checkNow(t, k.cw)
	eq(t, "after a check", scheduleOf(t, k.cw.Store(), "a"), "every 5m")
	// And once the store has the one that stands, the handle leaves it alone.
	check(t, earlier.Run(bg, ok))
	eq(t, "after a later run", scheduleOf(t, k.cw.Store(), "a"), "every 5m")
	sameList(t, "errors", k.wheres(), []string{})
}

// What a scheduler integration met: a job's first run declared it without a
// schedule, the integration then declared it with one and wrote that, and
// the run's handle wrote its own definition over it.
func TestAHandleFromAnEarlierDeclarationLeavesALaterOneWritten(t *testing.T) {
	k := newKit(t)
	earlier := k.cw.MustJob("a")
	k.cw.MustJob("a", cronwatch.Schedule("every 5m"))
	eq(t, "written", must[bool](t)(k.cw.SyncJob(bg, "a")), true)
	handle := must[*cronwatch.RunHandle](t)(earlier.Start(bg))
	handle.Finish(bg)
	eq(t, "after the run", scheduleOf(t, k.cw.Store(), "a"), "every 5m")
}

func TestAHandleWhoseJobWasForgottenWritesItsOwnDefinition(t *testing.T) {
	k := newKit(t)
	handle := k.cw.MustJob("a", cronwatch.Schedule("every 5m"))
	check(t, k.cw.Forget(bg, "a"))
	check(t, handle.Run(bg, ok))
	eq(t, "schedule", scheduleOf(t, k.cw.Store(), "a"), "every 5m")
}

func TestADeclarationMadeWhileTheEarlierOneIsWrittenIsStillToBeWritten(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		store, release := heldUpsert()
		k := newKit(t, cronwatch.WithStore(store))
		earlier := k.cw.MustJob("a")
		var wg sync.WaitGroup
		wg.Go(func() { _ = earlier.Run(bg, ok) })
		synctest.Wait()
		k.cw.MustJob("a", cronwatch.Schedule("every 5m"))
		release()
		wg.Wait()
		checkNow(t, k.cw)
		eq(t, "schedule", scheduleOf(t, store.inner, "a"), "every 5m")
	})
}

func TestADeclarationsWriteWaitsForTheEarlierOnes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		store, release := heldUpsert()
		k := newKit(t, cronwatch.WithStore(store))
		earlier := k.cw.MustJob("a")
		var wg sync.WaitGroup
		wg.Go(func() { _ = earlier.Run(bg, ok) })
		synctest.Wait()
		k.cw.MustJob("a", cronwatch.Schedule("every 5m"))
		var later *cronwatch.JobSummary
		var err error
		wg.Go(func() { later, err = k.cw.JobSummary(bg, "a") })
		// Were the later write not to wait its turn, it would land here, under the earlier one.
		synctest.Wait()
		release()
		wg.Wait()
		check(t, err)
		eq(t, "stored", scheduleOf(t, store.inner, "a"), "every 5m")
		eq(t, "the later read", later.Definition.Schedule(), "every 5m")
	})
}

func TestSyncJobWaitsItsTurnAndWritesTheDeclarationThatStandsThen(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		store, release := heldUpsert()
		k := newKit(t, cronwatch.WithStore(store))
		earlier := k.cw.MustJob("a")
		var wg sync.WaitGroup
		wg.Go(func() { _ = earlier.Run(bg, ok) })
		synctest.Wait()
		k.cw.MustJob("a", cronwatch.Schedule("every 5m"))
		var wrote bool
		var err error
		wg.Go(func() { wrote, err = k.cw.SyncJob(bg, "a") })
		synctest.Wait()
		// Declared again while SyncJob waits: this is the one it writes.
		k.cw.MustJob("a", cronwatch.Schedule("every 10m"))
		release()
		wg.Wait()
		check(t, err)
		eq(t, "wrote", wrote, true)
		eq(t, "stored", scheduleOf(t, store.inner, "a"), "every 10m")
		eq(t, "writes", store.count("UpsertJob"), 2)
		checkNow(t, k.cw)
		eq(t, "writes once it is marked written", store.count("UpsertJob"), 2)
	})
}

func TestAWriteWaitingItsTurnGivesUpWithItsContext(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		store, release := heldUpsert()
		k := newKit(t, cronwatch.WithStore(store))
		job := k.cw.MustJob("a")
		var wg sync.WaitGroup
		wg.Go(func() { _ = job.Run(bg, ok) })
		synctest.Wait()
		ctx, cancel := context.WithCancel(bg)
		var err error
		wg.Go(func() { _, err = k.cw.JobSummary(ctx, "a") })
		synctest.Wait()
		cancel()
		synctest.Wait()
		if !errors.Is(err, context.Canceled) {
			t.Errorf("got %v, want the context's error", err)
		}
		release()
		wg.Wait()
		eq(t, "writes", store.count("UpsertJob"), 1)
	})
}
