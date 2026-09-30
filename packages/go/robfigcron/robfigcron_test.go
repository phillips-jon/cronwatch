package robfigcron_test

import (
	"context"
	"errors"
	"io"
	"log"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/robfigcron"
	"cronwatch.dev/go/storetest"
	"github.com/robfig/cron/v3"
)

// kit is a client on a store the test can read, with its alerts and errors kept.
type kit struct {
	cw     *cronwatch.Client
	store  *cronwatch.MemoryStore
	alerts *storetest.Capture
	errors *storetest.Errors
}

func newKit(t *testing.T, store *cronwatch.MemoryStore) *kit {
	t.Helper()
	if store == nil {
		store = cronwatch.NewMemoryStore()
	}
	k := &kit{store: store, alerts: &storetest.Capture{}, errors: &storetest.Errors{}}
	cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithAlerts(k.alerts), cronwatch.WithErrorHandler(k.errors.Add))
	if err != nil {
		t.Fatal(err)
	}
	k.cw = cw
	return k
}

func (k *kit) runs(t *testing.T, name string) []cronwatch.Run {
	t.Helper()
	runs, err := k.cw.Runs(context.Background(), name, 50)
	if err != nil {
		t.Fatal(err)
	}
	return runs
}

func (k *kit) stored(t *testing.T, name string) cronwatch.Definition {
	t.Helper()
	job, err := k.store.GetJob(context.Background(), name)
	if err != nil || job == nil {
		t.Fatalf("job %s is not stored (%v)", name, err)
	}
	return job.Definition
}

func (k *kit) check(t *testing.T) {
	t.Helper()
	if _, err := k.cw.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

var quiet = cron.PrintfLogger(log.New(io.Discard, "", 0))

// NightlyReport is a job named after its function.
func NightlyReport() {}

type Cleanup struct{ ran chan struct{} }

func (c *Cleanup) Run() {
	if c.ran != nil {
		c.ran <- struct{}{}
	}
}

func TestEntriesAreJobsWithTheirSchedules(t *testing.T) {
	t.Setenv("CRONWATCH_APP_ID", "billing")
	k := newKit(t, nil)
	w := robfigcron.New(k.cw, robfigcron.Options{
		Logger:   quiet,
		Defaults: []cronwatch.JobOption{cronwatch.Grace("5m")},
		Jobs:     map[string][]cronwatch.JobOption{"robfigcron_test.NightlyReport": {cronwatch.Timeout("2h"), cronwatch.Tags("reports")}},
		Exclude:  []string{"robfigcron_test.Skipped"},
	})
	c := cron.New(w.Option(), cron.WithLocation(time.UTC))
	must := func(_ cron.EntryID, err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(c.AddFunc("0 2 * * *", NightlyReport))
	must(c.AddJob("@every 1h30m", &Cleanup{}))
	must(c.AddJob("*/5 * * * *", robfigcron.Named("pinger", cron.FuncJob(func() {}), cronwatch.Description("pings"))))
	must(c.AddFunc("0 3 * * *", func() {}))
	must(c.AddFunc("30 2 * * *", Skipped))
	check(t, w.Sync(context.Background()))
	k.check(t)

	nightly := k.stored(t, "robfigcron_test.NightlyReport")
	eq(t, "nightly", string(mustJSON(nightly.MarshalJSON())), `{"grace":"5m","schedule":"0 2 * * *","timezone":"UTC","timeout":"2h","tags":["reports","robfig-cron","robfig-cron:billing"],"name":"robfigcron_test.NightlyReport"}`)
	cleanup := k.stored(t, "robfigcron_test.Cleanup")
	eq(t, "an interval", cleanup.Schedule(), "every 1h30m")
	eq(t, "no zone for an interval", cleanup.Timezone(), "")
	pinger := k.stored(t, "pinger")
	eq(t, "named", pinger.Schedule(), "*/5 * * * *")
	eq(t, "its options", pinger.Description(), "pings")
	if job, _ := k.store.GetJob(context.Background(), "robfigcron_test.Skipped"); job != nil {
		t.Error("an excluded job was declared")
	}
	errs := k.errors.List()
	eq(t, "one report", len(errs), 1)
	contains(t, "a closure is reported", errs[0], "robfig/cron entry 4 is a function literal (cronwatch.dev/go/robfigcron_test.TestEntriesAreJobsWithTheirSchedules.func")
	contains(t, "and how to name it", errs[0], "wrap it in robfigcron.Named")

	// Syncing again changes nothing and reports nothing again.
	check(t, w.Sync(context.Background()))
	eq(t, "reported once", len(k.errors.List()), 1)
}

func Skipped() {}

// The review: forgetting a job the cron still runs left the watch holding
// it as unchanged, and the next sync took it for an entry gone.
func TestAJobForgottenWhileTheCronRunsItKeepsItsSchedule(t *testing.T) {
	ctx := context.Background()
	k := newKit(t, nil)
	w := robfigcron.New(k.cw, robfigcron.Options{Logger: quiet})
	c := cron.New(w.Option(), cron.WithLocation(time.UTC))
	_, err := c.AddFunc("0 2 * * *", NightlyReport)
	check(t, err)
	check(t, w.Sync(ctx))
	k.check(t)
	check(t, k.cw.Forget(ctx, "robfigcron_test.NightlyReport"))
	for range 2 {
		check(t, w.Sync(ctx))
		k.check(t)
	}
	eq(t, "the schedule", k.stored(t, "robfigcron_test.NightlyReport").Schedule(), "0 2 * * *")
	eq(t, "nothing reported", len(k.errors.List()), 0)
}

func TestRunsAreRecordedAndEntriesFollowed(t *testing.T) {
	k := newKit(t, nil)
	var recovered []any
	var mu sync.Mutex
	recoverer := func(j cron.Job) cron.Job {
		return cron.FuncJob(func() {
			defer func() {
				if p := recover(); p != nil {
					mu.Lock()
					recovered = append(recovered, p)
					mu.Unlock()
				}
			}()
			j.Run()
		})
	}
	w := robfigcron.New(k.cw, robfigcron.Options{Logger: quiet, Chain: []cron.JobWrapper{recoverer}})
	c := cron.New(w.Option(), cron.WithSeconds())
	ran := make(chan struct{}, 10)
	id, err := c.AddJob("@every 1s", &Cleanup{ran: ran})
	check(t, err)
	_, err = c.AddJob("@every 1s", robfigcron.Named("panics", cron.FuncJob(func() { panic("boom") })))
	check(t, err)
	_, err = c.AddJob("@every 1s", w.Func("reports", func(ctx context.Context, job *cronwatch.JobContext) error {
		if cronwatch.Current(ctx) != job {
			t.Error("the context does not carry the job")
		}
		job.Log("Report written")
		if err := job.Metric("rows", 3); err != nil {
			return err
		}
		return errors.New("disk full")
	}))
	check(t, err)
	c.Start()
	defer c.Stop()
	<-ran
	waitFor(t, "the runs", func() bool {
		return len(k.runs(t, "robfigcron_test.Cleanup")) > 0 && len(k.runs(t, "panics")) > 0 && len(k.runs(t, "reports")) > 0
	})
	waitFor(t, "every run finished", func() bool {
		for _, name := range []string{"robfigcron_test.Cleanup", "panics", "reports"} {
			if k.runs(t, name)[0].Status == cronwatch.StatusRunning {
				return false
			}
		}
		return true
	})
	eq(t, "ok", k.runs(t, "robfigcron_test.Cleanup")[0].Status, cronwatch.StatusOK)
	eq(t, "trigger", k.runs(t, "robfigcron_test.Cleanup")[0].Trigger, robfigcron.Trigger)
	panicked := k.runs(t, "panics")[0]
	eq(t, "a panic fails the run", panicked.Status, cronwatch.StatusFailed)
	contains(t, "with the panic", *panicked.Error, "panic: boom")
	mu.Lock()
	eq(t, "and carries on to the wrapper outside", len(recovered) > 0, true)
	mu.Unlock()
	reports := k.runs(t, "reports")[0]
	eq(t, "an error fails the run", *reports.Error, "Error: disk full")
	eq(t, "the output", *reports.Output, "Report written")
	w.Wait()
	eq(t, "declared at start", k.stored(t, "reports").Schedule(), "every 1s")

	// An entry added while the cron runs is declared; one removed loses its schedule.
	_, err = c.AddJob("0 0 4 * * *", robfigcron.Named("later", &Cleanup{}))
	check(t, err)
	waitFor(t, "the added entry", func() bool {
		w.Wait()
		job, _ := k.store.GetJob(context.Background(), "later")
		return job != nil || k.cw.DefinedJobs() != nil && slices.ContainsFunc(k.cw.DefinedJobs(), func(d cronwatch.Definition) bool { return d.Name() == "later" })
	})
	c.Remove(id)
	w.Wait()
	check(t, w.Sync(context.Background()))
	k.check(t)
	cleanup := k.stored(t, "robfigcron_test.Cleanup")
	eq(t, "removed: no schedule", cleanup.Schedule(), "")
	eq(t, "and says so", cleanup.Description(), "A scheduled task (no longer scheduled)")
	eq(t, "later has its schedule", k.stored(t, "later").Schedule(), "0 4 * * *")
}

func TestTwoAppsOnOneStoreKeepTheirOwnJobs(t *testing.T) {
	store := cronwatch.NewMemoryStore()
	ctx := context.Background()
	declare := func(app string, specs map[string]string) (*kit, *robfigcron.Watcher) {
		k := newKit(t, store)
		w := robfigcron.New(k.cw, robfigcron.Options{App: app, Logger: quiet})
		c := cron.New(w.Option(), cron.WithLocation(time.UTC))
		for name, spec := range specs {
			if _, err := c.AddJob(spec, robfigcron.Named(name, &Cleanup{})); err != nil {
				t.Fatal(err)
			}
		}
		check(t, w.Sync(ctx))
		k.check(t)
		return k, w
	}
	declare("billing", map[string]string{"invoices": "0 1 * * *", "dunning": "0 6 * * *"})
	declare("search", map[string]string{"reindex": "0 3 * * *"})
	// Billing deploys without dunning: its next process takes dunning's
	// schedule away, and leaves search's reindex alone.
	billing, _ := declare("billing", map[string]string{"invoices": "0 1 * * *"})
	eq(t, "invoices kept", billing.stored(t, "invoices").Schedule(), "0 1 * * *")
	eq(t, "dunning unscheduled", billing.stored(t, "dunning").Schedule(), "")
	eq(t, "dunning keeps its tags", strings.Join(billing.stored(t, "dunning").Tags(), ","), "robfig-cron,robfig-cron:billing")
	eq(t, "reindex untouched", billing.stored(t, "reindex").Schedule(), "0 3 * * *")
}

func TestAChainGivenAfterWatchIsReported(t *testing.T) {
	k := newKit(t, nil)
	w := robfigcron.New(k.cw, robfigcron.Options{Logger: quiet})
	c := cron.New(w.Option(), cron.WithLocation(time.UTC), cron.WithChain())
	if _, err := c.AddFunc("0 2 * * *", NightlyReport); err != nil {
		t.Fatal(err)
	}
	check(t, w.Sync(context.Background()))
	errs := k.errors.List()
	eq(t, "reported", len(errs), 1)
	contains(t, "why", errs[0], "give your wrappers in robfigcron.Options.Chain")

	// A watcher watches one cron.
	cron.New(w.Option())
	contains(t, "a second cron", k.errors.List()[1], "a robfigcron.Watcher watches one cron")
}

func TestAScheduleThatCannotMatchIsWatchedWithoutOne(t *testing.T) {
	k := newKit(t, nil)
	newYork, err := time.LoadLocation("America/New_York")
	check(t, err)
	w := robfigcron.New(k.cw, robfigcron.Options{Logger: quiet})
	c := cron.New(w.Option(), cron.WithLocation(newYork))
	_, err = c.AddJob("30 2 * * *", robfigcron.Named("gap", &Cleanup{}))
	check(t, err)
	_, err = c.AddJob("0 2 * * *", robfigcron.Named("twice", &Cleanup{}))
	check(t, err)
	_, err = c.AddJob("0 5 * * *", robfigcron.Named("twice", &Cleanup{}))
	check(t, err)
	check(t, w.Sync(context.Background()))
	k.check(t)
	eq(t, "no schedule", k.stored(t, "gap").Schedule(), "")
	eq(t, "one name, two schedules", k.stored(t, "twice").Schedule(), "")
	errs := k.errors.List()
	eq(t, "reported", len(errs), 3)
	contains(t, "the gap", strings.Join(errs, "\n"), "declaring robfig/cron entry 1 (gap): cronwatch: robfig/cron entry 1 (gap) is \"30 2 * * *\", due at a time that does not exist in America/New_York")
	contains(t, "the collision", strings.Join(errs, "\n"), `"twice" is run by 2 robfig/cron entries on different schedules`)
}

// The audit: a Func in a cron the watcher was not given to recorded its
// runs but reported the watcher unattached at every one.
func TestAFuncOutsideAWatchedCronReportsNothing(t *testing.T) {
	k := newKit(t, nil)
	w := robfigcron.New(k.cw, robfigcron.Options{})
	job := w.Func("loose", func(context.Context, *cronwatch.JobContext) error { return nil })
	for range 3 {
		job.Run()
	}
	eq(t, "runs", len(k.runs(t, "loose")), 3)
	eq(t, "reported", strings.Join(k.errors.List(), "\n"), "")
}

func check(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func mustJSON(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

func eq[T comparable](t *testing.T, what string, got, want T) {
	t.Helper()
	if got != want {
		t.Errorf("%s: got %v, want %v", what, got, want)
	}
}

func contains(t *testing.T, what, got, want string) {
	t.Helper()
	if !strings.Contains(got, want) {
		t.Errorf("%s: %q is not in %q", what, want, got)
	}
}
