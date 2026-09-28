package cronwatch

// The client-hardening.test.ts cases that wait on the client's own timers
// (a channel's 15 seconds, triage's 25, a check's 20 second retry budget,
// Start's first check a second in), with those waits shortened. The SDK's
// tests mock its timers; Go's are real, so the waits are made small.

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// shorten sets a wait for one test.
func shorten(t *testing.T, v *time.Duration, d time.Duration) {
	saved := *v
	*v = d
	t.Cleanup(func() { *v = saved })
}

type errorsOf struct {
	mu   sync.Mutex
	list []string
}

func (e *errorsOf) add(err error, where string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.list = append(e.list, where)
}

func (e *errorsOf) wheres() []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]string{}, e.list...)
}

type alertsOf struct {
	mu   sync.Mutex
	list []Alert
}

func (a *alertsOf) Name() string { return "capture" }

func (a *alertsOf) Send(_ context.Context, alert Alert, _ ChannelContext) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.list = append(a.list, alert)
	return nil
}

func (a *alertsOf) types() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := []string{}
	for _, x := range a.list {
		out = append(out, string(x.Type))
	}
	return out
}

func sameStrings(t *testing.T, what string, got, want []string) {
	t.Helper()
	if strings.Join(got, "|") != strings.Join(want, "|") || len(got) != len(want) {
		t.Errorf("%s: got %v, want %v", what, got, want)
	}
}

func failing(context.Context, *JobContext) error { return errors.New("x") }

func TestHungChannelTimesOutWithoutHoldingUpTheOthers(t *testing.T) {
	shorten(t, &channelTimeout, 50*time.Millisecond)
	release := make(chan struct{})
	defer close(release)
	hung := ChannelFunc("hung", func(context.Context, Alert) error { <-release; return nil })
	good := &alertsOf{}
	errs := &errorsOf{}
	cw := MustNew(WithAlerts(hung, good), WithErrorHandler(errs.add), WithoutCronSecret())
	_ = cw.Run(context.Background(), "h", failing)
	sameStrings(t, "the other channel has it", good.types(), []string{"failed"})
	sameStrings(t, "errors", errs.wheres(), []string{"alert channel hung"})
	s, _ := cw.Store().GetState(context.Background(), "h")
	if len(s.Undelivered) != 0 {
		t.Error("one channel took it: delivered")
	}
}

func TestHungChannelIsSkippedUntilItReturns(t *testing.T) {
	shorten(t, &channelTimeout, 30*time.Millisecond)
	release := make(chan struct{})
	var sends atomic.Int32
	hung := ChannelFunc("hung", func(ctx context.Context, a Alert) error {
		if sends.Add(1) == 1 {
			<-release // ignores its context: hangs past the timeout
		}
		return nil
	})
	errs := &errorsOf{}
	cw := MustNew(WithAlerts(hung), WithErrorHandler(errs.add), WithoutCronSecret())
	ctx := context.Background()
	_ = cw.Run(ctx, "one", failing)
	_ = cw.Run(ctx, "two", failing)
	if n := sends.Load(); n != 1 {
		t.Fatalf("the hung channel was sent %d alerts while it hung", n)
	}
	wheres := errs.wheres()
	sameStrings(t, "errors", wheres, []string{"alert channel hung", "alert channel hung"})
	close(release)
	deadline := time.Now().Add(5 * time.Second)
	for {
		cw.busyMu.Lock()
		busy := cw.channelBusy[0]
		cw.busyMu.Unlock()
		if !busy {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the channel stayed stalled after returning")
		}
		time.Sleep(time.Millisecond)
	}
	_ = cw.Run(ctx, "three", failing)
	if n := sends.Load(); n != 2 {
		t.Errorf("once returned, the channel is sent to again: %d sends", n)
	}
}

func TestTriageIsCancelledWhenTheClientStopsWaiting(t *testing.T) {
	shorten(t, &triageTimeout, 50*time.Millisecond)
	var cause atomic.Value
	errs := &errorsOf{}
	alerts := &alertsOf{}
	cw := MustNew(WithAlerts(alerts), WithErrorHandler(errs.add), WithoutCronSecret(), WithTriage(func(ctx context.Context, _ TriageContext) (string, error) {
		<-ctx.Done()
		cause.Store(ctx.Err())
		return "too late", nil
	}))
	_ = cw.Run(context.Background(), "t", failing)
	deadline := time.Now().Add(5 * time.Second)
	for cause.Load() == nil && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if err, _ := cause.Load().(error); err == nil {
		t.Error("the triage's context was not cancelled")
	}
	sameStrings(t, "errors", errs.wheres(), []string{"triage for t"})
	sameStrings(t, "alerts", alerts.types(), []string{"failed"})
	alerts.mu.Lock()
	if alerts.list[0].Triage != nil || !alerts.list[0].TriageTried {
		t.Error("a triage that timed out is tried once and gave nothing")
	}
	alerts.mu.Unlock()
}

func TestRetriesStopOnceACheckHasSpentItsBudget(t *testing.T) {
	shorten(t, &retryBudget, 200*time.Millisecond)
	store := NewMemoryStore()
	var clock atomic.Int64
	clock.Store(1767605400000)
	now := func() int64 { return clock.Load() }
	for _, name := range []string{"a", "b", "c"} {
		recorder := MustNew(WithStore(store), WithClock(now), WithDeliver(DeliverAtCheck), WithoutCronSecret())
		_ = recorder.Run(context.Background(), name, failing)
	}
	var mu sync.Mutex
	var tried []string
	// Each attempt takes 120ms of wall clock and fails.
	slow := ChannelFunc("slow", func(_ context.Context, a Alert) error {
		mu.Lock()
		tried = append(tried, a.Job)
		mu.Unlock()
		time.Sleep(120 * time.Millisecond)
		return errors.New("timed out")
	})
	server := MustNew(WithStore(store), WithClock(now), WithAlerts(slow), WithoutCronSecret(), WithErrorHandler(func(error, string) {}))
	if _, err := server.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	sameStrings(t, "the budget covers two attempts", tried, []string{"a", "b"})
	tried = nil
	mu.Unlock()
	s, _ := store.GetState(context.Background(), "c")
	if len(s.Undelivered) != 1 {
		t.Error("c is still queued")
	}
	if _, err := server.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	sameStrings(t, "each check has a fresh budget", tried, []string{"a", "b"})
	mu.Unlock()
}

// countingStore counts checks by their first read.
type countingStore struct {
	*MemoryStore
	checks atomic.Int32
}

func (s *countingStore) RunningRuns(ctx context.Context) ([]Run, error) {
	s.checks.Add(1)
	return s.MemoryStore.RunningRuns(ctx)
}

func TestStopAlsoCancelsTheFirstCheckStartSchedules(t *testing.T) {
	shorten(t, &firstCheckDelay, 30*time.Millisecond)
	store := &countingStore{MemoryStore: NewMemoryStore()}
	cw := MustNew(WithStore(store), WithoutCronSecret())
	cw.Start(time.Hour)
	cw.Stop()
	time.Sleep(100 * time.Millisecond)
	if n := store.checks.Load(); n != 0 {
		t.Fatalf("%d checks after stop", n)
	}
	cw.Start(time.Hour)
	deadline := time.Now().Add(5 * time.Second)
	for store.checks.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	cw.Stop()
	if n := store.checks.Load(); n != 1 {
		t.Errorf("%d checks, want the first one", n)
	}
	// A second Start while one runs does nothing.
	cw.Start(time.Hour)
	cw.Start(time.Minute)
	cw.Stop()
}

func TestStartChecksOnItsInterval(t *testing.T) {
	shorten(t, &firstCheckDelay, 10*time.Millisecond)
	store := &countingStore{MemoryStore: NewMemoryStore()}
	cw := MustNew(WithStore(store), WithoutCronSecret())
	// Five seconds is the shortest interval, so the first check is the one seen here.
	cw.Start(time.Millisecond)
	deadline := time.Now().Add(5 * time.Second)
	for store.checks.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	if err := cw.Close(); err != nil {
		t.Fatal(err)
	}
	if n := store.checks.Load(); n != 1 {
		t.Errorf("%d checks in the first 50ms, want 1 (the interval is at least five seconds)", n)
	}
}
