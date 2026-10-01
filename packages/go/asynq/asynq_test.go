package asynq_test

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	cwasynq "cronwatch.dev/go/asynq"
	"cronwatch.dev/go/storetest"
	"github.com/hibiken/asynq"
)

type kit struct {
	cw     *cronwatch.Client
	store  *cronwatch.MemoryStore
	alerts *capture
	errors *storetest.Errors
}

func newKit(t *testing.T, store *cronwatch.MemoryStore) *kit {
	t.Helper()
	if store == nil {
		store = cronwatch.NewMemoryStore()
	}
	k := &kit{store: store, alerts: &capture{}, errors: &storetest.Errors{}}
	cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithAlerts(k.alerts), cronwatch.WithErrorHandler(k.errors.Add))
	check(t, err)
	k.cw = cw
	return k
}

func (k *kit) runs(t *testing.T, name string) []cronwatch.Run {
	t.Helper()
	runs, err := k.cw.Runs(context.Background(), name, 50)
	check(t, err)
	return runs
}

func (k *kit) stored(t *testing.T, name string) cronwatch.Definition {
	t.Helper()
	_, err := k.cw.Check(context.Background())
	check(t, err)
	job, err := k.store.GetJob(context.Background(), name)
	if err != nil || job == nil {
		t.Fatalf("job %s is not stored (%v)", name, err)
	}
	return job.Definition
}

// redisOpt is Redis where CRONWATCH_TEST_REDIS says, or a place no test
// that needs none connects to.
func redisOpt(t *testing.T, need bool) asynq.RedisConnOpt {
	t.Helper()
	url := os.Getenv("CRONWATCH_TEST_REDIS")
	if url == "" {
		if need {
			t.Skip("CRONWATCH_TEST_REDIS is not set")
		}
		return asynq.RedisClientOpt{Addr: "127.0.0.1:1"}
	}
	opt, err := asynq.ParseRedisURI(url)
	check(t, err)
	return opt
}

func TestConvertReadsAsynqCronspecs(t *testing.T) {
	tokyo, err := time.LoadLocation("Asia/Tokyo")
	check(t, err)
	for _, c := range []struct {
		spec, text, zone string
		loc              *time.Location
	}{
		{"0 2 * * *", "0 2 * * *", "UTC", nil},
		{"@daily", "0 0 * * *", "UTC", time.UTC},
		{"@every 30s", "every 30s", "", time.UTC},
		{"0 9 * * mon-fri", "0 9 * * 1-5", "Asia/Tokyo", tokyo},
		{"CRON_TZ=Europe/London 30 6 * * *", "30 6 * * *", "Europe/London", tokyo},
	} {
		got, err := cwasynq.Convert(c.spec, c.loc, "cronwatch: x")
		if err != nil || got.Schedule != c.text || got.Timezone != c.zone {
			t.Errorf("%s: got %v %v, want %q in %q", c.spec, got, err, c.text, c.zone)
		}
	}
	if _, err := cwasynq.Convert("0 2 * * * *", time.UTC, "cronwatch: x"); err == nil || !strings.Contains(err.Error(), "robfig/cron cannot read the cronspec") {
		t.Errorf("six fields: %v", err)
	}
}

func TestSchedulerEntriesAreJobs(t *testing.T) {
	t.Setenv("CRONWATCH_APP_ID", "billing")
	k := newKit(t, nil)
	w := cwasynq.New(k.cw, cwasynq.Options{Defaults: []cronwatch.JobOption{cronwatch.Grace("5m")}})
	s := w.NewScheduler(redisOpt(t, false), &asynq.SchedulerOpts{Logger: quiet{}})
	nightly, err := s.RegisterWith("0 2 * * *", asynq.NewTask("report:nightly", nil), []cronwatch.JobOption{cronwatch.Timeout("2h")})
	check(t, err)
	_, err = s.Register("*/5 * * * *", cwasynq.CheckTask())
	check(t, err)
	_, err = s.Register("@every 1h", asynq.NewTask("sync:twice", nil))
	check(t, err)
	_, err = s.Register("@every 2h", asynq.NewTask("sync:twice", nil))
	check(t, err)
	eq(t, "nightly", string(must(k.stored(t, "report:nightly").MarshalJSON())),
		`{"grace":"5m","schedule":"0 2 * * *","timezone":"UTC","timeout":"2h","tags":["asynq","asynq:billing"],"name":"report:nightly"}`)
	eq(t, "two schedules, none", k.stored(t, "sync:twice").Schedule(), "")
	contains(t, "reported", strings.Join(k.errors.List(), "\n"), `"sync:twice" is run by 2 Asynq entries on different schedules (every 1h; every 2h)`)
	if job, _ := k.store.GetJob(context.Background(), cwasynq.CheckType); job != nil {
		t.Error("the check is a job")
	}
	check(t, s.Unregister(nightly))
	gone := k.stored(t, "report:nightly")
	eq(t, "unregistered: no schedule", gone.Schedule(), "")
	eq(t, "kept its timeout", fmt.Sprint(first(gone.Get("timeout"))), "2h")
}

func TestMiddlewareFollowsTheRetryRules(t *testing.T) {
	k := newKit(t, nil)
	w := cwasynq.New(k.cw, cwasynq.Options{Tasks: map[string][]cronwatch.JobOption{"email:send": nil}})
	var attempts atomic.Int32
	handler := w.Middleware()(asynq.HandlerFunc(func(ctx context.Context, task *asynq.Task) error {
		if job := cronwatch.Current(ctx); job != nil {
			job.Log("sending")
		}
		switch string(task.Payload()) {
		case "fail":
			if attempts.Add(1) < 3 {
				return errors.New("smtp down")
			}
			return nil
		case "revoke":
			return fmt.Errorf("unsubscribed: %w", asynq.RevokeTask)
		case "skip":
			return fmt.Errorf("bad address: %w", asynq.SkipRetry)
		case "panic":
			panic("boom")
		}
		return nil
	}))
	ctx := context.Background()
	for range 3 {
		_ = handler.ProcessTask(ctx, asynq.NewTask("email:send", []byte("fail")))
	}
	runs := k.runs(t, "email:send")
	eq(t, "three attempts, three runs", len(runs), 3)
	eq(t, "failed first", *runs[2].Error, "Error: smtp down")
	eq(t, "then ok", runs[0].Status, cronwatch.StatusOK)
	eq(t, "logged", *runs[0].Output, "sending")
	eq(t, "one alert, closed", strings.Join(k.alerts.types("email:send"), ","), "failed,recovered")

	if err := handler.ProcessTask(ctx, asynq.NewTask("email:send", []byte("revoke"))); !errors.Is(err, asynq.RevokeTask) {
		t.Errorf("the revoke went missing: %v", err)
	}
	eq(t, "a revoke is not a run", len(k.runs(t, "email:send")), 3)
	_ = handler.ProcessTask(ctx, asynq.NewTask("email:send", []byte("skip")))
	eq(t, "SkipRetry is a failure", k.runs(t, "email:send")[0].Status, cronwatch.StatusFailed)
	func() {
		defer func() {
			if recover() == nil {
				t.Error("the panic did not carry on to Asynq")
			}
		}()
		_ = handler.ProcessTask(ctx, asynq.NewTask("email:send", []byte("panic")))
	}()
	contains(t, "a panic fails the run", *k.runs(t, "email:send")[0].Error, "panic: boom")

	// A type nobody watches passes through.
	check(t, handler.ProcessTask(ctx, asynq.NewTask("image:resize", nil)))
	eq(t, "not recorded", len(k.runs(t, "image:resize")), 0)
}

func TestAServerFindsTheSchedulersJobsInTheStore(t *testing.T) {
	t.Setenv("CRONWATCH_APP_ID", "billing")
	store := cronwatch.NewMemoryStore()
	scheduling := newKit(t, store)
	s := cwasynq.New(scheduling.cw, cwasynq.Options{}).NewScheduler(redisOpt(t, false), nil)
	_, err := s.RegisterWith("0 2 * * *", asynq.NewTask("report:nightly", nil), []cronwatch.JobOption{cronwatch.Expect("written")})
	check(t, err)
	_ = scheduling.stored(t, "report:nightly")

	// Another app on the same store with a type of the same name is not
	// this app's.
	serving := newKit(t, store)
	handler := cwasynq.New(serving.cw, cwasynq.Options{}).Middleware()(asynq.HandlerFunc(func(ctx context.Context, task *asynq.Task) error {
		cronwatch.Current(ctx).Log("Report written")
		return nil
	}))
	check(t, handler.ProcessTask(context.Background(), asynq.NewTask("report:nightly", nil)))
	runs := serving.runs(t, "report:nightly")
	eq(t, "recorded by the server", len(runs), 1)
	eq(t, "ok", runs[0].Status, cronwatch.StatusOK)
	stored := serving.stored(t, "report:nightly")
	eq(t, "the scheduler's definition kept", string(must(stored.MarshalJSON())),
		`{"schedule":"0 2 * * *","timezone":"UTC","tags":["asynq","asynq:billing"],"name":"report:nightly","expect":"contains \"written\""}`)

	t.Setenv("CRONWATCH_APP_ID", "search")
	other := newKit(t, store)
	otherHandler := cwasynq.New(other.cw, cwasynq.Options{}).Middleware()(asynq.HandlerFunc(func(context.Context, *asynq.Task) error { return nil }))
	check(t, otherHandler.ProcessTask(context.Background(), asynq.NewTask("report:nightly", nil)))
	eq(t, "another app's job is left alone", len(other.runs(t, "report:nightly")), 1)
}

// The audit: every task type a server saw that was not a job stayed in
// memory for the life of the process.
func TestTypesNotJobsAreForgottenAfterTheirMinute(t *testing.T) {
	w := cwasynq.New(newKit(t, nil).cw, cwasynq.Options{})
	start := time.Unix(1_700_000_000, 0)
	for i := range 100 {
		w.NoteUnknownForTest(fmt.Sprintf("made:up:%d", i), start)
	}
	eq(t, "within the minute", w.UnknownForTest(), 100)
	w.NoteUnknownForTest("later", start.Add(time.Minute))
	eq(t, "after it", w.UnknownForTest(), 1)
	for i := range cwasynq.MaxUnknown + 5 {
		w.NoteUnknownForTest(fmt.Sprintf("flood:%d", i), start.Add(time.Minute+time.Second))
	}
	if n := w.UnknownForTest(); n > cwasynq.MaxUnknown {
		t.Fatalf("%d remembered, past the bound", n)
	}
}

// TestAsynqEndToEnd runs a real server, scheduler and periodic task
// manager on the Redis CRONWATCH_TEST_REDIS names.
func TestAsynqEndToEnd(t *testing.T) {
	t.Setenv("CRONWATCH_APP_ID", "billing")
	opt := redisOpt(t, true)
	queue := fmt.Sprintf("cw_asynq_%d", time.Now().UnixNano())
	k := newKit(t, nil)
	// A job an earlier deploy scheduled, since taken out.
	_, err := k.cw.Job("digest:weekly", cronwatch.Schedule("0 9 * * 1"), cronwatch.Tags("asynq", "asynq:billing"))
	check(t, err)
	_, err = k.cw.Check(context.Background())
	check(t, err)
	cw, err := cronwatch.New(cronwatch.WithStore(k.store), cronwatch.WithAlerts(k.alerts), cronwatch.WithErrorHandler(k.errors.Add))
	check(t, err)
	k.cw = cw
	w := cwasynq.New(k.cw, cwasynq.Options{Tasks: map[string][]cronwatch.JobOption{"report:flaky": nil}})

	var flaky atomic.Int32
	mux := asynq.NewServeMux()
	mux.Use(w.Middleware())
	mux.HandleFunc("report:tick", func(ctx context.Context, _ *asynq.Task) error {
		cronwatch.Current(ctx).Log("tick")
		return nil
	})
	mux.HandleFunc("report:flaky", func(ctx context.Context, _ *asynq.Task) error {
		if flaky.Add(1) < 3 {
			return errors.New("not yet")
		}
		return nil
	})
	mux.Handle(cwasynq.CheckType, w.CheckHandler())
	server := asynq.NewServer(opt, asynq.Config{
		Queues:                   map[string]int{queue: 1},
		Concurrency:              2,
		RetryDelayFunc:           func(int, error, *asynq.Task) time.Duration { return 0 },
		DelayedTaskCheckInterval: 100 * time.Millisecond,
		TaskCheckInterval:        50 * time.Millisecond,
		Logger:                   quiet{},
	})
	check(t, server.Start(mux))
	defer server.Shutdown()

	scheduler := w.NewScheduler(opt, &asynq.SchedulerOpts{Logger: quiet{}})
	_, err = scheduler.Register("@every 1s", asynq.NewTask("report:tick", nil, asynq.Queue(queue)))
	check(t, err)
	check(t, scheduler.Start())
	defer scheduler.Shutdown()

	manager, err := w.NewPeriodicTaskManager(asynq.PeriodicTaskManagerOpts{
		RedisConnOpt:               opt,
		SchedulerOpts:              &asynq.SchedulerOpts{Logger: quiet{}},
		PeriodicTaskConfigProvider: configs{{Cronspec: "30 4 * * *", Task: asynq.NewTask("report:early", nil, asynq.Queue(queue))}},
		SyncInterval:               time.Second,
	})
	check(t, err)
	check(t, manager.Start())
	defer manager.Shutdown()

	client := asynq.NewClient(opt)
	defer client.Close()
	_, err = client.Enqueue(asynq.NewTask("report:flaky", nil, asynq.Queue(queue), asynq.MaxRetry(5)))
	check(t, err)

	waitFor(t, "a scheduled run", func() bool {
		runs := k.runs(t, "report:tick")
		return len(runs) > 0 && runs[0].Status == cronwatch.StatusOK
	})
	waitFor(t, "the manager's config", func() bool {
		job, _ := k.cw.JobSummary(context.Background(), "report:early")
		return job != nil || slicesContainName(k.cw.DefinedJobs(), "report:early")
	})
	_, err = client.Enqueue(cwasynq.CheckTask(), asynq.Queue(queue))
	check(t, err)
	waitFor(t, "the check", func() bool {
		job, _ := k.store.GetJob(context.Background(), "digest:weekly")
		return job != nil && job.Definition.Schedule() == ""
	})
	eq(t, "the scheduler's entry", k.stored(t, "report:tick").Schedule(), "every 1s")
	eq(t, "the manager's", k.stored(t, "report:early").Schedule(), "30 4 * * *")
	waitFor(t, "flaky's attempts", func() bool {
		runs := k.runs(t, "report:flaky")
		return len(runs) == 3 && runs[0].Status == cronwatch.StatusOK
	})
	eq(t, "flaky's alerts", strings.Join(k.alerts.types("report:flaky"), ","), "failed,recovered")
	eq(t, "no errors", strings.Join(k.errors.List(), "\n"), "")
}

func slicesContainName(defs []cronwatch.Definition, name string) bool {
	for _, d := range defs {
		if d.Name() == name {
			return true
		}
	}
	return false
}

type configs []*asynq.PeriodicTaskConfig

func (c configs) GetConfigs() ([]*asynq.PeriodicTaskConfig, error) { return c, nil }

// quiet is an Asynq logger that says nothing.
type quiet struct{}

func (quiet) Debug(...any) {}
func (quiet) Info(...any)  {}
func (quiet) Warn(...any)  {}
func (quiet) Error(...any) {}
func (quiet) Fatal(...any) {}

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

func (c *capture) types(job string) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []string
	for _, a := range c.list {
		if a.Job == job {
			out = append(out, string(a.Type))
		}
	}
	return out
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func check(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func must(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

// first is a value without the ok beside it.
func first(v any, _ bool) any { return v }

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
