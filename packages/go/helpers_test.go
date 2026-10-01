package cronwatch_test

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

// What the client tests share: a client with a settable clock, a capture
// channel and an error list (the SDK tests' make()), and a store whose
// methods can be made to fail or to run a hook first (helpers.ts flaky(),
// and the Proxy stores the SDK's tests build).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/storetest"
)

const (
	T0   = storetest.T0
	MIN  = int64(60_000)
	HOUR = int64(3_600_000)
)

var bg = context.Background()

const hour = time.Hour

// kit is a client and what a test watches it through.
type kit struct {
	cw     *cronwatch.Client
	c      *storetest.Clock
	alerts *storetest.Capture
	errors *storetest.Errors
}

// newKit is a client on a clock at T0 that sends to a capture channel,
// keeps its errors, and runs handlers without a secret. Options given
// replace these defaults.
func newKit(t *testing.T, options ...cronwatch.Option) *kit {
	t.Helper()
	k := &kit{c: storetest.NewClock(T0), alerts: &storetest.Capture{}, errors: &storetest.Errors{}}
	all := append([]cronwatch.Option{cronwatch.WithClock(k.c.Now), cronwatch.WithAlerts(k.alerts), cronwatch.WithoutCronSecret(),
		cronwatch.WithErrorHandler(k.errors.Add)}, options...)
	cw, err := cronwatch.New(all...)
	if err != nil {
		t.Fatal(err)
	}
	k.cw = cw
	return k
}

// wheres are the "where" of each error kept, in order.
func (k *kit) wheres() []string {
	out := []string{}
	for _, e := range k.errors.List() {
		where, _, _ := strings.Cut(e, ": ")
		out = append(out, where)
	}
	return out
}

// messages are the errors kept, without their "where".
func (k *kit) messages() []string {
	out := []string{}
	for _, e := range k.errors.List() {
		_, msg, _ := strings.Cut(e, ": ")
		out = append(out, msg)
	}
	return out
}

func must[T any](t *testing.T) func(T, error) T {
	return func(v T, err error) T {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
}

func check(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func eq[T comparable](t *testing.T, what string, got, want T) {
	t.Helper()
	if got != want {
		t.Errorf("%s: got %v, want %v", what, got, want)
	}
}

func sameList[T comparable](t *testing.T, what string, got, want []T) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("%s: got %v, want %v", what, got, want)
		return
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("%s: got %v, want %v", what, got, want)
			return
		}
	}
}

// jsonOf is the SDK's JSON of a value.
func jsonOf(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return "error: " + err.Error()
	}
	return string(b)
}

func alertTypes(alerts []cronwatch.Alert) []string {
	out := []string{}
	for _, a := range alerts {
		out = append(out, string(a.Type))
	}
	return out
}

func ok(context.Context, *cronwatch.JobContext) error { return nil }

func fails(msg string) cronwatch.JobFunc {
	return func(context.Context, *cronwatch.JobContext) error { return errors.New(msg) }
}

func ptr[T any](v T) *T { return &v }

func definition(t *testing.T, text string) cronwatch.Definition {
	t.Helper()
	var d cronwatch.Definition
	check(t, json.Unmarshal([]byte(text), &d))
	return d
}

func runs(t *testing.T, cw *cronwatch.Client, name string) []cronwatch.Run {
	t.Helper()
	return must[[]cronwatch.Run](t)(cw.Runs(bg, name, 50))
}

func state(t *testing.T, cw *cronwatch.Client, name string) *cronwatch.JobState {
	t.Helper()
	return must[*cronwatch.JobState](t)(cw.Store().GetState(bg, name))
}

func summary(t *testing.T, cw *cronwatch.Client, name string) *cronwatch.JobSummary {
	t.Helper()
	return must[*cronwatch.JobSummary](t)(cw.JobSummary(bg, name))
}

func checkNow(t *testing.T, cw *cronwatch.Client) *cronwatch.CheckResult {
	t.Helper()
	return must[*cronwatch.CheckResult](t)(cw.Check(bg))
}

// waitFor polls until cond holds, for code running in another goroutine.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(time.Millisecond)
	}
}

// running reports whether the job's newest run is still running.
func running(t *testing.T, cw *cronwatch.Client, name string) func() bool {
	return func() bool {
		list, err := cw.Store().ListRuns(bg, name, 1)
		return err == nil && len(list) == 1 && list[0].Status == cronwatch.StatusRunning
	}
}

// testStore wraps a memory store: a method named in broken fails, and a
// hook named for a method runs before it (after, for GetState's delay).
type testStore struct {
	inner *cronwatch.MemoryStore

	mu     sync.Mutex
	broken map[string]bool
	hooks  map[string]func()
	// after are hooks that run once, after the next call's read.
	after map[string]func()
	// stateDelay is how long a GetState waits after reading, as over a network.
	stateDelay time.Duration
	// init, when set, replaces Init.
	init func() error
	// cas, when set, replaces CompareAndSetState.
	cas   func(cronwatch.JobState, int64) (bool, error)
	calls map[string]int
	// gone, once kill is called, is what every call waits on, as for a
	// process that died: nothing it asks of the store completes until the
	// test buries it (closes gone), and then each call fails.
	gone chan struct{}
}

// kill makes every later call wait until bury, then fail.
func (s *testStore) kill() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.gone == nil {
		s.gone = make(chan struct{})
	}
}

// bury lets the calls a kill held go, each failing.
func (s *testStore) bury() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.gone != nil {
		close(s.gone)
	}
}

func newTestStore() *testStore {
	return &testStore{inner: cronwatch.NewMemoryStore(), broken: map[string]bool{}, hooks: map[string]func(){}, after: map[string]func(){}, calls: map[string]int{}}
}

func (s *testStore) breaks(names ...string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, n := range names {
		s.broken[n] = true
	}
}

func (s *testStore) mends(names ...string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(names) == 0 {
		s.broken = map[string]bool{}
	}
	for _, n := range names {
		delete(s.broken, n)
	}
}

// hook runs fn once, before the next call of the method.
func (s *testStore) hook(name string, fn func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hooks[name] = fn
}

// hookAfter runs fn once, after the next call of the method has read.
func (s *testStore) hookAfter(name string, fn func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.after[name] = fn
}

func (s *testStore) leave(name string) {
	s.mu.Lock()
	fn := s.after[name]
	delete(s.after, name)
	s.mu.Unlock()
	if fn != nil {
		fn()
	}
}

func (s *testStore) count(name string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls[name]
}

// enter counts a call, runs its hook, and fails it while it is broken.
func (s *testStore) enter(name string) error {
	s.mu.Lock()
	s.calls[name]++
	fn := s.hooks[name]
	delete(s.hooks, name)
	broken := s.broken[name]
	gone := s.gone
	s.mu.Unlock()
	if gone != nil {
		<-gone
		return fmt.Errorf("store gone: %s", name)
	}
	if fn != nil {
		fn()
	}
	if broken {
		return fmt.Errorf("store down: %s", name)
	}
	return nil
}

func (s *testStore) Init(ctx context.Context) error {
	if err := s.enter("Init"); err != nil {
		return err
	}
	if s.init != nil {
		return s.init()
	}
	return s.inner.Init(ctx)
}

func (s *testStore) Close() error { return s.inner.Close() }

func (s *testStore) UpsertJob(ctx context.Context, d cronwatch.Definition, now int64) error {
	if err := s.enter("UpsertJob"); err != nil {
		return err
	}
	return s.inner.UpsertJob(ctx, d, now)
}

func (s *testStore) GetJob(ctx context.Context, name string) (*cronwatch.StoredJob, error) {
	if err := s.enter("GetJob"); err != nil {
		return nil, err
	}
	return s.inner.GetJob(ctx, name)
}

func (s *testStore) ListJobs(ctx context.Context) ([]cronwatch.StoredJob, error) {
	if err := s.enter("ListJobs"); err != nil {
		return nil, err
	}
	return s.inner.ListJobs(ctx)
}

func (s *testStore) DeleteJob(ctx context.Context, name string) error {
	if err := s.enter("DeleteJob"); err != nil {
		return err
	}
	return s.inner.DeleteJob(ctx, name)
}

func (s *testStore) InsertRun(ctx context.Context, r cronwatch.Run) error {
	if err := s.enter("InsertRun"); err != nil {
		return err
	}
	return s.inner.InsertRun(ctx, r)
}

func (s *testStore) UpdateRun(ctx context.Context, r cronwatch.Run) error {
	if err := s.enter("UpdateRun"); err != nil {
		return err
	}
	return s.inner.UpdateRun(ctx, r)
}

func (s *testStore) UpdateRunIf(ctx context.Context, r cronwatch.Run, from []cronwatch.RunStatus) (bool, error) {
	if err := s.enter("UpdateRunIf"); err != nil {
		return false, err
	}
	return s.inner.UpdateRunIf(ctx, r, from)
}

func (s *testStore) GetRun(ctx context.Context, id string) (*cronwatch.Run, error) {
	if err := s.enter("GetRun"); err != nil {
		return nil, err
	}
	r, err := s.inner.GetRun(ctx, id)
	s.leave("GetRun")
	return r, err
}

func (s *testStore) ListRuns(ctx context.Context, job string, limit int) ([]cronwatch.Run, error) {
	if err := s.enter("ListRuns"); err != nil {
		return nil, err
	}
	return s.inner.ListRuns(ctx, job, limit)
}

func (s *testStore) LastRun(ctx context.Context, job string) (*cronwatch.Run, error) {
	if err := s.enter("LastRun"); err != nil {
		return nil, err
	}
	return s.inner.LastRun(ctx, job)
}

func (s *testStore) RunningRuns(ctx context.Context) ([]cronwatch.Run, error) {
	list, err := s.inner.RunningRuns(ctx)
	if err != nil {
		return nil, err
	}
	// The hook runs after the read, as the SDK's racing store does.
	if err := s.enter("RunningRuns"); err != nil {
		return nil, err
	}
	return list, nil
}

func (s *testStore) GetState(ctx context.Context, job string) (*cronwatch.JobState, error) {
	if err := s.enter("GetState"); err != nil {
		return nil, err
	}
	st, err := s.inner.GetState(ctx, job)
	if s.stateDelay > 0 {
		time.Sleep(s.stateDelay)
	}
	return st, err
}

func (s *testStore) SetState(ctx context.Context, st cronwatch.JobState) error {
	if err := s.enter("SetState"); err != nil {
		return err
	}
	return s.inner.SetState(ctx, st)
}

func (s *testStore) CompareAndSetState(ctx context.Context, st cronwatch.JobState, expected int64) (bool, error) {
	if err := s.enter("CompareAndSetState"); err != nil {
		return false, err
	}
	if s.cas != nil {
		return s.cas(st, expected)
	}
	return s.inner.CompareAndSetState(ctx, st, expected)
}

func (s *testStore) Prune(ctx context.Context, before int64) (int, error) {
	if err := s.enter("Prune"); err != nil {
		return 0, err
	}
	return s.inner.Prune(ctx, before)
}

// noCAS is a store with UpdateRunIf but no CompareAndSetState.
type noCAS struct {
	cronwatch.Store
	u cronwatch.RunUpdater
}

func (s noCAS) UpdateRunIf(ctx context.Context, r cronwatch.Run, from []cronwatch.RunStatus) (bool, error) {
	return s.u.UpdateRunIf(ctx, r, from)
}

// noRunIf is a store with CompareAndSetState but no UpdateRunIf.
type noRunIf struct {
	cronwatch.Store
	c cronwatch.StateComparer
}

func (s noRunIf) CompareAndSetState(ctx context.Context, st cronwatch.JobState, expected int64) (bool, error) {
	return s.c.CompareAndSetState(ctx, st, expected)
}

// channel is a channel made of a function.
func channel(name string, send func(cronwatch.Alert) error) cronwatch.Channel {
	return cronwatch.ChannelFunc(name, func(_ context.Context, a cronwatch.Alert) error { return send(a) })
}
