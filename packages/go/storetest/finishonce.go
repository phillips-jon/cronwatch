package storetest

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	cronwatch "cronwatch.dev/go"
)

// T0 is Monday 2026-01-05 09:30:00Z, the SDK tests' clock start.
const T0 int64 = 1767605400000

const min = 60_000

// Clock is a settable clock for a client.
type Clock struct{ at atomic.Int64 }

// NewClock is a clock at start.
func NewClock(start int64) *Clock {
	c := &Clock{}
	c.at.Store(start)
	return c
}

// Now is the time.
func (c *Clock) Now() int64 { return c.at.Load() }

// Advance moves the clock on by ms and answers the new time.
func (c *Clock) Advance(ms int64) int64 { return c.at.Add(ms) }

// Set moves the clock to t.
func (c *Clock) Set(t int64) { c.at.Store(t) }

// Capture is a channel that keeps the alerts it is sent.
type Capture struct {
	mu     sync.Mutex
	Alerts []cronwatch.Alert
}

// Name is "capture".
func (c *Capture) Name() string { return "capture" }

// Send keeps the alert.
func (c *Capture) Send(_ context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.Alerts = append(c.Alerts, a)
	return nil
}

// Types are the kept alerts' types, in order.
func (c *Capture) Types() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := []string{}
	for _, a := range c.Alerts {
		out = append(out, string(a.Type))
	}
	return out
}

// Errors keeps what a client reports, as "where: message".
type Errors struct {
	mu   sync.Mutex
	list []string
}

// Add keeps an error.
func (e *Errors) Add(err error, where string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.list = append(e.list, where+": "+err.Error())
}

// List is what was kept.
func (e *Errors) List() []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]string(nil), e.list...)
}

// Process is one client over a shared store, as one process would have.
type Process struct {
	Client *cronwatch.Client
	Alerts *Capture
	Errors *Errors
}

// NewProcess is a client over store, with a capture channel and an error list.
func NewProcess(t *testing.T, store cronwatch.Store, now func() int64) *Process {
	t.Helper()
	p := &Process{Alerts: &Capture{}, Errors: &Errors{}}
	c, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithClock(now), cronwatch.WithAlerts(p.Alerts),
		cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(p.Errors.Add))
	if err != nil {
		t.Fatal(err)
	}
	p.Client = c
	return p
}

// Shared opens stores over one database, as several processes would have
// them: each call to Open is another store on the same data.
type Shared struct {
	Open func() cronwatch.Store
	// Done is called at the end, to close the stores and drop the data.
	Done func()
}

func anyMatch(lists [][]string, re *regexp.Regexp) bool {
	for _, l := range lists {
		for _, e := range l {
			if re.MatchString(e) {
				return true
			}
		}
	}
	return false
}

// FinishOnce is finish-once.test.ts's tests over several stores sharing one
// database: however many processes finish a run, it is recorded and judged
// once. shared makes a fresh database each time it is called.
func FinishOnce(t *testing.T, shared func(t *testing.T) Shared) {
	ctx := context.Background()
	failed := func(id, job string, startedAt int64) cronwatch.Run {
		return cronwatch.Run{ID: id, Job: job, Status: cronwatch.StatusFailed, StartedAt: startedAt, FinishedAt: ptr(startedAt + 1000), DurationMs: ptr(int64(1000)),
			Error: ptr("ERROR: deadlock detected"), Metrics: cronwatch.Metrics{}, Trigger: "pg_cron"}
	}

	t.Run("two processes finishing one run: one records and judges it, the other reports it already finished", func(t *testing.T) {
		s := shared(t)
		defer s.Done()
		c := NewClock(T0)
		one, two := NewProcess(t, s.Open(), c.Now), NewProcess(t, s.Open(), c.Now)
		var jobs []*cronwatch.Job
		for _, p := range []*Process{one, two} {
			jobs = append(jobs, p.Client.MustJob("webhook-ingest", cronwatch.FailuresBeforeAlert(2)))
		}
		if _, err := jobs[0].Start(ctx, cronwatch.WithRunID("delivery-1")); err != nil {
			t.Fatal(err)
		}
		h1, err := one.Client.ResumeRun(ctx, "webhook-ingest", "delivery-1")
		if err != nil {
			t.Fatal(err)
		}
		h2, err := two.Client.ResumeRun(ctx, "webhook-ingest", "delivery-1")
		if err != nil {
			t.Fatal(err)
		}
		c.Advance(min)
		var wg sync.WaitGroup
		results := make([]*cronwatch.Run, 2)
		for i, h := range []*cronwatch.RunHandle{h1, h2} {
			wg.Add(1)
			go func() { defer wg.Done(); results[i] = h.Fail(ctx, errors.New("upstream 502")) }()
		}
		wg.Wait()
		if n := count(results); n != 1 {
			t.Errorf("%d finishes recorded, want 1", n)
		}
		if !anyMatch([][]string{one.Errors.List(), two.Errors.List()}, regexp.MustCompile(`already finished as failed; ignored`)) {
			t.Errorf("no process reported the run already finished: %v %v", one.Errors.List(), two.Errors.List())
		}
		runs, err := one.Client.Runs(ctx, "webhook-ingest", 50)
		if err != nil || len(runs) != 1 {
			t.Errorf("runs %d %v", len(runs), err)
		}
		st, err := one.Client.Store().GetState(ctx, "webhook-ingest")
		if err != nil || st.ConsecutiveFailures != 1 {
			t.Errorf("the failure counted once: %+v %v", st, err)
		}
		if types := append(one.Alerts.Types(), two.Alerts.Types()...); len(types) != 0 {
			t.Errorf("one failure is below failuresBeforeAlert 2: %v", types)
		}
	})

	t.Run("two processes recording one finished run from a source: it is judged once", func(t *testing.T) {
		s := shared(t)
		defer s.Done()
		c := NewClock(T0)
		one, two := NewProcess(t, s.Open(), c.Now), NewProcess(t, s.Open(), c.Now)
		for _, p := range []*Process{one, two} {
			p.Client.MustJob("db:rollup", cronwatch.FailuresBeforeAlert(2))
		}
		at := T0 - min
		running := failed("pgcron:9", "db:rollup", at)
		running.Status, running.FinishedAt, running.DurationMs, running.Error = cronwatch.StatusRunning, nil, nil, nil
		if _, err := one.Client.RecordRun(ctx, running); err != nil {
			t.Fatal(err)
		}
		if _, err := two.Client.Jobs(ctx); err != nil {
			t.Fatal(err)
		}
		done := failed("pgcron:9", "db:rollup", at)
		var wg sync.WaitGroup
		for _, p := range []*Process{one, two} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := p.Client.RecordRun(ctx, done); err != nil {
					t.Error(err)
				}
			}()
		}
		wg.Wait()
		st, err := one.Client.Store().GetState(ctx, "db:rollup")
		if err != nil || st.ConsecutiveFailures != 1 {
			t.Errorf("judged once: %+v %v", st, err)
		}
		if types := append(one.Alerts.Types(), two.Alerts.Types()...); len(types) != 0 {
			t.Errorf("alerts %v", types)
		}
		// The SDK's two promises both read the run as running before either
		// writes, so one always reports the other's finish. Goroutines may
		// instead read it after the first finish landed, and a run already
		// finished is left alone without a word; either way the only thing
		// either process may report is that finish.
		for _, e := range append(one.Errors.List(), two.Errors.List()...) {
			if !regexp.MustCompile(`pgcron:9 of db:rollup was already finished as failed; ignored`).MatchString(e) {
				t.Errorf("unexpected error: %s", e)
			}
		}
	})

	t.Run("many processes starting and finishing one id: exactly one finish is recorded", func(t *testing.T) {
		s := shared(t)
		defer s.Done()
		c := NewClock(T0)
		var procs []*Process
		var jobs []*cronwatch.Job
		for i := 0; i < 6; i++ {
			p := NewProcess(t, s.Open(), c.Now)
			procs = append(procs, p)
			jobs = append(jobs, p.Client.MustJob("ingest"))
		}
		if _, err := procs[0].Client.Check(ctx); err != nil {
			t.Fatal(err)
		}
		for k := 0; k < 5; k++ {
			id := fmt.Sprintf("evt_%d", k)
			handles := make([]*cronwatch.RunHandle, len(jobs))
			var wg sync.WaitGroup
			for i, j := range jobs {
				wg.Add(1)
				go func() {
					defer wg.Done()
					h, err := j.Start(ctx, cronwatch.WithRunID(id))
					if err != nil {
						t.Error(err)
						return
					}
					handles[i] = h
				}()
			}
			wg.Wait()
			finished := make([]*cronwatch.Run, len(handles))
			for i, h := range handles {
				if h == nil {
					continue
				}
				wg.Add(1)
				go func() { defer wg.Done(); finished[i] = h.FinishWith(ctx, fmt.Sprintf("worker %d", i)) }()
			}
			wg.Wait()
			if n := count(finished); n != 1 {
				t.Errorf("%s: %d finishes recorded, want 1", id, n)
			}
		}
		runs, err := procs[0].Client.Runs(ctx, "ingest", 500)
		if err != nil || len(runs) != 5 {
			t.Fatalf("runs %d %v", len(runs), err)
		}
		for _, r := range runs {
			if r.Status != cronwatch.StatusOK {
				t.Errorf("run %s is %s", r.ID, r.Status)
			}
		}
		var unexpected []string
		for _, p := range procs {
			for _, e := range p.Errors.List() {
				if !strings.Contains(e, "already finished") {
					unexpected = append(unexpected, e)
				}
			}
		}
		if len(unexpected) > 0 {
			t.Errorf("unexpected errors: %v", unexpected)
		}
	})
}

func count(runs []*cronwatch.Run) int {
	n := 0
	for _, r := range runs {
		if r != nil {
			n++
		}
	}
	return n
}
