package cronwatch

// The client-hardening.test.ts cases that wait on the client's own timers
// (a channel's 15 seconds, triage's 25, a check's 20 second retry budget,
// Start's first check a second in), with those waits shortened. The SDK's
// tests mock its timers; Go's are real, so the waits are made small.

import (
	"context"
	"errors"
	"net/http"
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
		busy := cw.channelBusy[0] > 0
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
	cw.StartChecking(time.Hour)
	cw.Stop()
	time.Sleep(100 * time.Millisecond)
	if n := store.checks.Load(); n != 0 {
		t.Fatalf("%d checks after stop", n)
	}
	cw.StartChecking(time.Hour)
	deadline := time.Now().Add(5 * time.Second)
	for store.checks.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	cw.Stop()
	if n := store.checks.Load(); n != 1 {
		t.Errorf("%d checks, want the first one", n)
	}
	// A second StartChecking while one runs does nothing.
	cw.StartChecking(time.Hour)
	cw.StartChecking(time.Minute)
	cw.Stop()
}

// Start, deprecated, is StartChecking under its former name: one interval
// whichever name begins it, and Stop ends it.
func TestStartIsStartChecking(t *testing.T) {
	shorten(t, &firstCheckDelay, time.Hour)
	cw := MustNew(WithoutCronSecret())
	cw.Start(time.Hour)
	cw.timerMu.Lock()
	first := cw.stop
	cw.timerMu.Unlock()
	if first == nil {
		t.Fatal("Start began no interval")
	}
	cw.StartChecking(time.Minute)
	cw.timerMu.Lock()
	same := cw.stop == first
	cw.timerMu.Unlock()
	if !same {
		t.Error("StartChecking after Start began a second interval")
	}
	cw.Stop()
	cw.timerMu.Lock()
	stopped := cw.stop == nil
	cw.timerMu.Unlock()
	if !stopped {
		t.Error("Stop did not end the interval Start began")
	}
}

func TestStartChecksOnItsInterval(t *testing.T) {
	shorten(t, &firstCheckDelay, 10*time.Millisecond)
	store := &countingStore{MemoryStore: NewMemoryStore()}
	cw := MustNew(WithStore(store), WithoutCronSecret())
	// Five seconds is the shortest interval, so the first check is the one seen here.
	cw.StartChecking(time.Millisecond)
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

// The audit: a send to a channel that returns in time used to clear the
// mark a hung send to the same channel had set, so the next alert started a
// second goroutine that hung too.
func TestAHungChannelStaysMarkedWhenAnotherSendToItReturns(t *testing.T) {
	shorten(t, &channelTimeout, 40*time.Millisecond)
	release := make(chan struct{})
	defer close(release)
	var hung atomic.Int32
	ch := ChannelFunc("flaky", func(_ context.Context, a Alert) error {
		if a.Job == "slow" {
			time.Sleep(80 * time.Millisecond) // past the timeout, but returns
			return nil
		}
		hung.Add(1)
		<-release // ignores its context
		return nil
	})
	cw := MustNew(WithAlerts(ch), WithErrorHandler(func(error, string) {}), WithoutCronSecret())
	ctx := context.Background()
	var wg sync.WaitGroup
	for _, name := range []string{"hangs", "slow"} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = cw.Run(ctx, name, failing)
		}()
	}
	wg.Wait()
	time.Sleep(100 * time.Millisecond) // the slow send has returned by now
	_ = cw.Run(ctx, "next", failing)
	if n := hung.Load(); n != 1 {
		t.Fatalf("the hung channel holds %d goroutines, want 1", n)
	}
}

func TestAHungTriageStaysMarkedWhenAnotherTriageReturns(t *testing.T) {
	shorten(t, &triageTimeout, 40*time.Millisecond)
	release := make(chan struct{})
	defer close(release)
	var hung atomic.Int32
	cw := MustNew(WithAlerts(&alertsOf{}), WithErrorHandler(func(error, string) {}), WithoutCronSecret(),
		WithTriage(func(_ context.Context, tc TriageContext) (string, error) {
			if tc.Alert.Job == "slow" {
				time.Sleep(80 * time.Millisecond)
				return "", nil
			}
			hung.Add(1)
			<-release
			return "", nil
		}))
	ctx := context.Background()
	var wg sync.WaitGroup
	for _, name := range []string{"hangs", "slow"} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = cw.Run(ctx, name, failing)
		}()
	}
	wg.Wait()
	time.Sleep(100 * time.Millisecond)
	_ = cw.Run(ctx, "next", failing)
	if n := hung.Load(); n != 1 {
		t.Fatalf("the hung triage holds %d goroutines, want 1", n)
	}
}

// The audit: a store that panics during a check used to leave the check
// marked as in flight, so every later Check waited on it for ever.
func TestACheckThatPanicsEndsAndTheNextOneRuns(t *testing.T) {
	store := &panickyStore{MemoryStore: NewMemoryStore()}
	store.panics.Store(true)
	cw := MustNew(WithStore(store), WithoutCronSecret())
	if _, err := cw.Check(context.Background()); err == nil || !strings.Contains(err.Error(), "panicked") {
		t.Fatalf("the panicking check: %v", err)
	}
	store.panics.Store(false)
	done := make(chan error, 1)
	go func() {
		_, err := cw.Check(context.Background())
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the next check waited on the one that panicked")
	}
}

// The audit: a caller that gave up used to fail the check it shared with
// the others (and a waiter could not give up at all).
func TestACallerGivingUpDoesNotFailTheCheckOthersShare(t *testing.T) {
	store := &panickyStore{MemoryStore: NewMemoryStore(), gate: make(chan struct{}), entered: make(chan struct{})}
	cw := MustNew(WithStore(store), WithoutCronSecret())
	first, cancel := context.WithCancel(context.Background())
	firstDone := make(chan error, 1)
	go func() {
		_, err := cw.Check(first)
		firstDone <- err
	}()
	<-store.entered
	second := make(chan error, 1)
	go func() {
		_, err := cw.Check(context.Background())
		second <- err
	}()
	cancel()
	if err := <-firstDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("the caller that gave up: %v", err)
	}
	close(store.gate)
	if err := <-second; err != nil {
		t.Fatalf("the caller still waiting: %v", err)
	}
}

// panickyStore panics in RunningRuns while panics is set, and waits there
// on gate when it has one.
type panickyStore struct {
	*MemoryStore
	panics  atomic.Bool
	gate    chan struct{}
	entered chan struct{}
	once    sync.Once
}

func (s *panickyStore) RunningRuns(ctx context.Context) ([]Run, error) {
	if s.panics.Load() {
		panic("the store broke")
	}
	if s.gate != nil {
		s.once.Do(func() { close(s.entered) })
		<-s.gate
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
	return s.MemoryStore.RunningRuns(ctx)
}

// The audit: a Host header of many distinct characters outside ASCII,
// sent before any token is checked, took seconds to punycode.
func TestALongHostOutsideASCIIIsNotRead(t *testing.T) {
	var b strings.Builder
	for r := rune(0x4e00); b.Len() <= maxIDNHost; r++ {
		b.WriteRune(r)
	}
	if _, err := readHost(b.String()); err == nil {
		t.Fatal("a host past the bound was read")
	}
	if got, err := readHost("bücher.example"); err != nil || got != "xn--bcher-kva.example" {
		t.Fatalf("got %q %v", got, err)
	}
	for r := rune(0x4e00 + maxIDNHost); r < 0x4e00+40000; r++ {
		b.WriteRune(r)
	}
	started := time.Now()
	r := &http.Request{Host: b.String()}
	_ = requestOrigin(r)
	if d := time.Since(started); d > time.Second {
		t.Fatalf("took %v", d)
	}
}
