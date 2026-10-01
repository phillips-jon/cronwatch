package river_test

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

// River end to end, against the Postgres CRONWATCH_TEST_PG names: a client
// with CronWatch's middleware works jobs that fail and retry, snooze,
// cancel themselves and panic, a periodic job, and the check.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	cwriver "cronwatch.dev/go/river"
	"cronwatch.dev/go/storetest"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/riverdriver/riverpgxv5"
	"github.com/riverqueue/river/rivermigrate"
	"github.com/riverqueue/river/rivertype"
)

// database is a pool on a schema of the test's own, River's tables made in it.
func database(t *testing.T) (*pgxpool.Pool, string) {
	t.Helper()
	url := os.Getenv("CRONWATCH_TEST_PG")
	if url == "" {
		t.Skip("CRONWATCH_TEST_PG is not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("cw_river_%d", time.Now().UnixNano())
	if _, err := pool.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
		pool.Close()
	})
	migrator, err := rivermigrate.New(riverpgxv5.New(pool), &rivermigrate.Config{Schema: schema})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := migrator.Migrate(ctx, rivermigrate.DirectionUp, nil); err != nil {
		t.Fatal(err)
	}
	return pool, schema
}

type FlakyArgs struct{}

func (FlakyArgs) Kind() string { return "flaky" }

type flakyWorker struct {
	river.WorkerDefaults[FlakyArgs]
}

func (flakyWorker) Work(ctx context.Context, job *river.Job[FlakyArgs]) error {
	cronwatch.Current(ctx).Log(fmt.Sprintf("attempt %d", job.Attempt))
	if job.Attempt < 3 {
		return fmt.Errorf("attempt %d failed", job.Attempt)
	}
	return nil
}

type SnoozyArgs struct{}

func (SnoozyArgs) Kind() string { return "snoozy" }

type snoozyWorker struct {
	river.WorkerDefaults[SnoozyArgs]
	calls atomic.Int32
}

func (w *snoozyWorker) Work(ctx context.Context, job *river.Job[SnoozyArgs]) error {
	if w.calls.Add(1) == 1 {
		return river.JobSnooze(time.Millisecond)
	}
	return nil
}

type CancelsArgs struct{}

func (CancelsArgs) Kind() string { return "cancels" }

type cancelsWorker struct {
	river.WorkerDefaults[CancelsArgs]
	calls atomic.Int32
}

func (w *cancelsWorker) Work(ctx context.Context, job *river.Job[CancelsArgs]) error {
	w.calls.Add(1)
	return river.JobCancel(errors.New("bad input"))
}

type PanicsArgs struct{}

func (PanicsArgs) Kind() string { return "panics" }

func (PanicsArgs) InsertOpts() river.InsertOpts { return river.InsertOpts{MaxAttempts: 1} }

type panicsWorker struct {
	river.WorkerDefaults[PanicsArgs]
}

func (panicsWorker) Work(ctx context.Context, job *river.Job[PanicsArgs]) error { panic("boom") }

type BlocksArgs struct{}

func (BlocksArgs) Kind() string { return "blocks" }

type blocksWorker struct {
	river.WorkerDefaults[BlocksArgs]
	done atomic.Bool
}

func (w *blocksWorker) Work(ctx context.Context, job *river.Job[BlocksArgs]) error {
	defer w.done.Store(true)
	<-ctx.Done()
	return ctx.Err()
}

type ReportArgs2 struct{}

func (ReportArgs2) Kind() string { return "nightly_report" }

type reportWorker struct {
	river.WorkerDefaults[ReportArgs2]
}

func (reportWorker) Work(ctx context.Context, job *river.Job[ReportArgs2]) error {
	cronwatch.Current(ctx).Log("Report written")
	return nil
}

// now retries a failed job at once.
type now struct{}

func (now) NextRetry(*rivertype.JobRow) time.Time { return time.Now() }

func TestRiverRecordsAttemptsFollowingTheRetryRules(t *testing.T) {
	t.Setenv("CRONWATCH_APP_ID", "billing")
	pool, schema := database(t)
	ctx := context.Background()
	store := cronwatch.NewMemoryStore()
	alerts, errs := &capture{}, &storetest.Errors{}
	cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithAlerts(alerts), cronwatch.WithErrorHandler(errs.Add))
	if err != nil {
		t.Fatal(err)
	}
	// A job an earlier deploy scheduled, taken out of the config since.
	if _, err := cw.Job("weekly-digest", cronwatch.Schedule("0 9 * * 1"), cronwatch.Tags("river", "river:billing")); err != nil {
		t.Fatal(err)
	}
	if _, err := cw.Check(ctx); err != nil {
		t.Fatal(err)
	}
	cw, err = cronwatch.New(cronwatch.WithStore(store), cronwatch.WithAlerts(alerts), cronwatch.WithErrorHandler(errs.Add))
	if err != nil {
		t.Fatal(err)
	}

	w := cwriver.New(cw, cwriver.Options{Kinds: map[string][]cronwatch.JobOption{
		"flaky": nil, "snoozy": nil, "cancels": nil, "panics": nil, "blocks": nil,
	}})
	snoozy, cancels, blocks := &snoozyWorker{}, &cancelsWorker{}, &blocksWorker{}
	workers := river.NewWorkers()
	river.AddWorker(workers, flakyWorker{})
	river.AddWorker(workers, snoozy)
	river.AddWorker(workers, cancels)
	river.AddWorker(workers, panicsWorker{})
	river.AddWorker(workers, blocks)
	river.AddWorker(workers, reportWorker{})
	river.AddWorker(workers, w.CheckWorker())
	client, err := river.NewClient(riverpgxv5.New(pool), &river.Config{
		Schema:            schema,
		Workers:           workers,
		Queues:            map[string]river.QueueConfig{river.QueueDefault: {MaxWorkers: 4}},
		Middleware:        []rivertype.Middleware{w.Middleware()},
		RetryPolicy:       now{},
		FetchPollInterval: 50 * time.Millisecond,
		FetchCooldown:     10 * time.Millisecond,
		PeriodicJobs: []*river.PeriodicJob{
			w.PeriodicJob(river.PeriodicInterval(time.Hour), func() (river.JobArgs, *river.InsertOpts) {
				return ReportArgs2{}, nil
			}, &river.PeriodicJobOpts{ID: "nightly-report", RunOnStart: true}, cronwatch.Grace("5m")),
		},
		Logger: quietLogger(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := client.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Stop(context.Background()) }()
	for _, args := range []river.JobArgs{FlakyArgs{}, SnoozyArgs{}, CancelsArgs{}, PanicsArgs{}} {
		if _, err := client.Insert(ctx, args, nil); err != nil {
			t.Fatal(err)
		}
	}

	runs := func(name string) []cronwatch.Run {
		list, err := cw.Runs(ctx, name, 50)
		if err != nil {
			t.Fatal(err)
		}
		return list
	}
	finished := func(name string, n int) func() bool {
		return func() bool {
			list := runs(name)
			return len(list) >= n && list[0].Status != cronwatch.StatusRunning
		}
	}
	waitFor(t, "flaky's three attempts", finished("flaky", 3))
	waitFor(t, "snoozy's second call", func() bool { return snoozy.calls.Load() >= 2 && finished("snoozy", 1)() })
	waitFor(t, "the cancel", func() bool { return cancels.calls.Load() >= 1 })
	waitFor(t, "the panic", finished("panics", 1))
	waitFor(t, "the periodic job", finished("nightly-report", 1))

	flaky := runs("flaky")
	eq(t, "three attempts, three runs", len(flaky), 3)
	eq(t, "the first failed", *flaky[2].Error, "Error: attempt 1 failed")
	eq(t, "the second failed", flaky[1].Status, cronwatch.StatusFailed)
	eq(t, "the third succeeded", flaky[0].Status, cronwatch.StatusOK)
	eq(t, "its log", *flaky[0].Output, "attempt 3")
	eq(t, "the trigger", flaky[0].Trigger, cwriver.Trigger)

	snoozed := runs("snoozy")
	eq(t, "the snooze is not a run", len(snoozed), 1)
	eq(t, "the attempt after it is", snoozed[0].Status, cronwatch.StatusOK)
	time.Sleep(200 * time.Millisecond)
	eq(t, "the cancel is not a run", len(runs("cancels")), 0)
	panicked := runs("panics")[0]
	eq(t, "a panic fails the run", panicked.Status, cronwatch.StatusFailed)
	contains(t, "with it", *panicked.Error, "panic: boom")
	report := runs("nightly-report")[0]
	eq(t, "the periodic job's run is its own", report.Status, cronwatch.StatusOK)
	eq(t, "logged", *report.Output, "Report written")

	// One failed alert for flaky's failures, closed by its success, and one
	// for the panic; the snooze and the cancel alert nothing.
	byJob := map[string][]string{}
	for _, a := range alerts.List() {
		byJob[a.Job] = append(byJob[a.Job], string(a.Type))
	}
	eq(t, "flaky", strings.Join(byJob["flaky"], ","), "failed,recovered")
	eq(t, "panics", strings.Join(byJob["panics"], ","), "failed")
	eq(t, "snoozy", len(byJob["snoozy"]), 0)
	eq(t, "cancels", len(byJob["cancels"]), 0)

	// A job cancelled from outside while it runs is not a failed attempt either.
	blocked, err := client.Insert(ctx, BlocksArgs{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the blocking run", func() bool { return len(runs("blocks")) == 1 })
	if _, err := client.JobCancel(ctx, blocked.Job.ID); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the cancel from outside", blocks.done.Load)
	waitFor(t, "its run taken back", func() bool { return len(runs("blocks")) == 0 })
	eq(t, "no alert for it", len(byJobOf(alerts)["blocks"]), 0)

	// The check: its job runs a sync and a check, and is never a job.
	if _, err := client.Insert(ctx, cwriver.CheckArgs{}, nil); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the check", func() bool {
		job, _ := store.GetJob(ctx, "weekly-digest")
		return job != nil && job.Definition.Schedule() == ""
	})
	if job, _ := store.GetJob(ctx, cwriver.CheckKind); job != nil {
		t.Error("the check is a job")
	}
	stored, _ := store.GetJob(ctx, "nightly-report")
	eq(t, "the periodic job's schedule", stored.Definition.Schedule(), "every 1h")
	eq(t, "no errors", strings.Join(errs.List(), "\n"), "")
}

func byJobOf(c *capture) map[string][]string {
	out := map[string][]string{}
	for _, a := range c.List() {
		out[a.Job] = append(out[a.Job], string(a.Type))
	}
	return out
}

// capture keeps the alerts sent.
type capture struct {
	mu   sync.Mutex
	list []cronwatch.Alert
}

func (c *capture) Name() string { return "capture" }

func (c *capture) Send(_ context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.list = append(c.list, a)
	return nil
}

func (c *capture) List() []cronwatch.Alert {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]cronwatch.Alert(nil), c.list...)
}

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func contains(t *testing.T, what, got, want string) {
	t.Helper()
	if !strings.Contains(got, want) {
		t.Errorf("%s: %q is not in %q", what, want, got)
	}
}
