package cronwatch_test

// What the Go API adds to the SDK's: panics, contexts, RunValue, Current,
// and a definition's field order under functional options.

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
)

func TestAPanicIsRecordedAsAFailedRunAndPanicsOn(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("boom")
	var recovered any
	func() {
		defer func() { recovered = recover() }()
		_ = job.Run(bg, func(context.Context, *cronwatch.JobContext) error { panic("kaboom") })
	}()
	eq(t, "the panic goes on", recovered, any("kaboom"))
	run := runs(t, k.cw, "boom")[0]
	eq(t, "status", run.Status, cronwatch.StatusFailed)
	if !regexp.MustCompile(`^panic: kaboom\n    at \S+ \(\S+:\d+\)`).MatchString(*run.Error) {
		t.Errorf("error %q", *run.Error)
	}
	if n := strings.Count(*run.Error, "\n    at "); n < 1 || n > 5 {
		t.Errorf("%d frames", n)
	}
	sameList(t, "alerts", k.alerts.Types(), []string{"failed"})
	if !strings.HasPrefix(k.alerts.List()[0].Message, "Started ") || !strings.Contains(k.alerts.List()[0].Message, "\npanic: kaboom") {
		t.Errorf("message %q", k.alerts.List()[0].Message)
	}

	// An error value panicked is written with its message.
	func() {
		defer func() { recovered = recover() }()
		_ = job.Run(bg, func(context.Context, *cronwatch.JobContext) error { panic(errors.New("bad state")) })
	}()
	if err, ok := recovered.(error); !ok || err.Error() != "bad state" {
		t.Errorf("recovered %v", recovered)
	}
	if !strings.HasPrefix(*runs(t, k.cw, "boom")[0].Error, "panic: bad state\n") {
		t.Error(*runs(t, k.cw, "boom")[0].Error)
	}
}

func TestTheJobsContextIsCancelledAtItsTimeout(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("slow", cronwatch.Timeout(30*time.Millisecond))
	var cause error
	err := job.Run(bg, func(ctx context.Context, _ *cronwatch.JobContext) error {
		<-ctx.Done()
		cause = context.Cause(ctx)
		return ctx.Err()
	})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("the job's own error comes back: %v", err)
	}
	eq(t, "cause", cause.Error(), `job "slow" passed its timeout of 30ms`)
	run := runs(t, k.cw, "slow")[0]
	eq(t, "status", run.Status, cronwatch.StatusFailed)
	eq(t, "error", *run.Error, "Error: context deadline exceeded")
	eq(t, "stored as milliseconds", jsonOf(job.Definition()), `{"timeout":30,"name":"slow"}`)
}

func TestACancelledCallerStillGetsItsRunRecorded(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("request")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := job.Run(ctx, func(ctx context.Context, j *cronwatch.JobContext) error {
		if ctx.Err() == nil {
			t.Error("the job sees its caller's cancellation")
		}
		j.Log("did it anyway")
		return nil
	})
	check(t, err)
	run := runs(t, k.cw, "request")[0]
	eq(t, "status", run.Status, cronwatch.StatusOK)
	eq(t, "output", *run.Output, "did it anyway")
	sameList(t, "errors", k.wheres(), []string{})

	// A handle finished with a cancelled context is recorded too.
	h := must[*cronwatch.RunHandle](t)(job.Start(ctx))
	eq(t, "finish", h.Finish(ctx).Status, cronwatch.StatusOK)
}

func TestRunValue(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("value", cronwatch.Expect("done"))
	got := must[string](t)(cronwatch.RunValue(bg, job, func(context.Context, *cronwatch.JobContext) (string, error) { return "all done", nil }))
	eq(t, "returned", got, "all done")
	run := runs(t, k.cw, "value")[0]
	eq(t, "output", *run.Output, "all done")
	eq(t, "status", run.Status, cronwatch.StatusOK)
	// A logged line is the output, not the string.
	must[string](t)(cronwatch.RunValue(bg, job, func(_ context.Context, j *cronwatch.JobContext) (string, error) { j.Log("logged"); return "done", nil }))
	run = runs(t, k.cw, "value")[0]
	eq(t, "logged output", *run.Output, "logged")
	eq(t, "expect sees the log, not the string", *run.Error, `Output did not contain "done"`)

	web := k.cw.MustJob("web")
	res, err := cronwatch.RunValue(bg, web, func(context.Context, *cronwatch.JobContext) (*http.Response, error) {
		return &http.Response{StatusCode: 503, Status: "503 Service Unavailable"}, nil
	})
	check(t, err)
	eq(t, "the response comes back", res.StatusCode, 503)
	eq(t, "error", *runs(t, k.cw, "web")[0].Error, "HTTP 503 Service Unavailable")
	must[*http.Response](t)(cronwatch.RunValue(bg, web, func(context.Context, *cronwatch.JobContext) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Status: "200 OK"}, nil
	}))
	eq(t, "a 200 is a success", runs(t, k.cw, "web")[0].Status, cronwatch.StatusOK)

	n, err := cronwatch.RunValue(bg, web, func(context.Context, *cronwatch.JobContext) (int, error) { return 3, errors.New("partial") })
	eq(t, "value with the error", n, 3)
	if err == nil || err.Error() != "partial" {
		t.Error(err)
	}
}

func TestCurrent(t *testing.T) {
	k := newKit(t)
	if cronwatch.Current(bg) != nil {
		t.Error("outside a run")
	}
	job := k.cw.MustJob("cur")
	check(t, job.Run(bg, func(ctx context.Context, j *cronwatch.JobContext) error {
		c := cronwatch.Current(ctx)
		if c != j {
			t.Error("Current is the run's context")
		}
		eq(t, "name", c.Name(), "cur")
		eq(t, "started", c.StartedAt(), T0)
		c.Log("from deep down")
		return nil
	}))
	run := runs(t, k.cw, "cur")[0]
	eq(t, "output", *run.Output, "from deep down")
	eq(t, "id", len(run.ID), 36)
}

func TestMetricsAreFiniteNumbers(t *testing.T) {
	k := newKit(t)
	check(t, k.cw.Run(bg, "m", func(_ context.Context, j *cronwatch.JobContext) error {
		inf := math.Inf(1)
		if err := j.Metric("bad", inf); err == nil || err.Error() != `metric "bad" must be a finite number` {
			t.Error(err)
		}
		return j.Metrics(cronwatch.Metrics{{Name: "zeta", Value: 1}, {Name: "10", Value: 2}, {Name: "2", Value: 3}})
	}))
	eq(t, "JavaScript's key order", jsonOf(runs(t, k.cw, "m")[0].Metrics), `{"2":3,"10":2,"zeta":1}`)
}

func TestOptionsKeepTheOrderGiven(t *testing.T) {
	cw := cronwatch.MustNew(cronwatch.WithDefaults(cronwatch.Grace("5m"), cronwatch.Timeout(time.Minute)), cronwatch.WithoutCronSecret())
	job := cw.MustJob("x", cronwatch.Schedule("@hourly"), cronwatch.Budget("b", 1), cronwatch.Expect("done"), cronwatch.Budget("a", 2),
		cronwatch.Budget("10", 3), cronwatch.Grace("1m"), cronwatch.Tags("t", "u"), cronwatch.Description("Hourly"), cronwatch.FailuresBeforeAlert(2),
		cronwatch.MaxDuration(1500*time.Microsecond), cronwatch.Budget("b", 4))
	eq(t, "definition", jsonOf(job.Definition()),
		`{"grace":"1m","timeout":60000,"schedule":"@hourly","budget":{"10":3,"b":4,"a":2},"tags":["t","u"],"description":"Hourly","failuresBeforeAlert":2,"maxDuration":1.5,"name":"x","expect":"contains \"done\""}`)
	eq(t, "the store has the same", jsonOf(must[*cronwatch.StoredJob](t)(func() (*cronwatch.StoredJob, error) {
		check(t, job.Run(bg, func(_ context.Context, j *cronwatch.JobContext) error { j.Log("done"); return nil }))
		return cw.Store().GetJob(bg, "x")
	}()).Definition), jsonOf(job.Definition()))
	re := cw.MustJob("re", cronwatch.ExpectMatch(regexp.MustCompile(`(?i)wrote \d+`)))
	eq(t, "regexp", jsonOf(re.Definition()), `{"grace":"5m","timeout":60000,"name":"re","expect":"matches /(?i)wrote \\d+/"}`)
	fn := cw.MustJob("fn", cronwatch.ExpectFunc(func(o string) bool { return o != "" }), cronwatch.Grace(90_000))
	eq(t, "function", jsonOf(fn.Definition()), `{"grace":90000,"timeout":60000,"name":"fn","expect":"custom function"}`)
	names := []string{}
	for _, d := range cw.DefinedJobs() {
		names = append(names, d.Name())
	}
	sameList(t, "declared in order", names, []string{"x", "re", "fn"})
}

func TestAnExpectFunctionThatPanicsFailsTheRun(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("f", cronwatch.ExpectFunc(func(string) bool { panic("no parser") }))
	check(t, job.Run(bg, ok))
	eq(t, "error", *runs(t, k.cw, "f")[0].Error, "Output check threw: no parser")
}

func TestRedaction(t *testing.T) {
	k := newKit(t)
	check(t, k.cw.Run(bg, "r", func(_ context.Context, j *cronwatch.JobContext) error { j.Log("password=hunter2"); return nil }))
	eq(t, "default", *runs(t, k.cw, "r")[0].Output, "password=[redacted]")

	plain := newKit(t, cronwatch.WithoutRedaction())
	check(t, plain.cw.Run(bg, "r", func(_ context.Context, j *cronwatch.JobContext) error { j.Log("password=hunter2\x00"); return nil }))
	eq(t, "kept, less NULs", *runs(t, plain.cw, "r")[0].Output, "password=hunter2")

	broken := newKit(t, cronwatch.WithRedact(func(string) string { panic("oops") }))
	check(t, broken.cw.Run(bg, "r", func(_ context.Context, j *cronwatch.JobContext) error { j.Log("password=hunter2"); return nil }))
	eq(t, "the default after a panic", *runs(t, broken.cw, "r")[0].Output, "password=[redacted]")
	sameList(t, "reported", broken.wheres(), []string{"redact"})

	custom := newKit(t, cronwatch.WithRedact(strings.ToUpper))
	check(t, custom.cw.Run(bg, "r", func(_ context.Context, j *cronwatch.JobContext) error { j.Log("quiet"); return nil }))
	eq(t, "custom", *runs(t, custom.cw, "r")[0].Output, "QUIET")
}

func TestASecretSplitByTheCutIsRedactedWhole(t *testing.T) {
	const cap = 16 * 1024
	var body []string
	for i := range 25 {
		body = append(body, strings.Repeat("QUJD", 15)+fmt.Sprintf("%04d", i))
	}
	pem := "-----BEGIN PRIVATE KEY-----\n" + strings.Join(body, "\n") + "\n-----END PRIVATE KEY-----"
	bearer := "Authorization: Bearer opaqueTOKENvalue1234567890"
	k := newKit(t)
	// The cut lands inside the key's body, and in a second run just after "Bear".
	check(t, k.cw.Run(bg, "pem", func(_ context.Context, j *cronwatch.JobContext) error {
		j.Log(strings.Repeat("x", cap))
		j.Log(pem[:900])
		j.Log(pem[900:])
		j.Log("done")
		return nil
	}))
	out := *runs(t, k.cw, "pem")[0].Output
	if strings.Contains(out, "QUJD") || !strings.HasSuffix(out, "[redacted]\ndone") {
		t.Errorf("pem: %q", out[len(out)-200:])
	}
	tail := strings.Repeat("y", cap-30)
	if _, err := cronwatch.RunValue(bg, k.cw.MustJob("bearer"), func(context.Context, *cronwatch.JobContext) (string, error) {
		return bearer + "\n" + tail, nil
	}); err != nil {
		t.Fatal(err)
	}
	if out := *runs(t, k.cw, "bearer")[0].Output; strings.Contains(out, "opaqueTOKEN") || len(out) > cap+len("[earlier output trimmed]\n") {
		t.Errorf("bearer: %q", out[:80])
	}

	// Errors, recorded runs and flushed lines the same way.
	_ = k.cw.Run(bg, "thrown", func(context.Context, *cronwatch.JobContext) error {
		return errors.New(strings.Repeat("e", cap) + " " + bearer + " " + strings.Repeat("z", cap-40))
	})
	if e := *runs(t, k.cw, "thrown")[0].Error; strings.Contains(e, "opaqueTOKEN") {
		t.Error("thrown: the token was kept")
	}
	k.cw.MustJob("imported")
	if _, err := k.cw.RecordRun(bg, cronwatch.Run{ID: "i1", Job: "imported", Status: cronwatch.StatusOK, StartedAt: 1, FinishedAt: ptr(int64(2)), DurationMs: ptr(int64(1)),
		Output: ptr(bearer + "\n" + tail), Metrics: cronwatch.Metrics{}, Trigger: "source"}); err != nil {
		t.Fatal(err)
	}
	if r := must[*cronwatch.Run](t)(k.cw.GetRun(bg, "i1")); strings.Contains(*r.Output, "opaqueTOKEN") {
		t.Error("recordRun: the token was kept")
	}
	h := must[*cronwatch.RunHandle](t)(k.cw.MustJob("flushed").Start(bg))
	h.Log(bearer)
	h.Log(tail)
	h.Flush(bg)
	if r := must[*cronwatch.Run](t)(k.cw.GetRun(bg, h.ID())); strings.Contains(*r.Output, "opaqueTOKEN") {
		t.Error("flush: the token was kept")
	}
	h.Finish(bg)
	if r := must[*cronwatch.Run](t)(k.cw.GetRun(bg, h.ID())); strings.Contains(*r.Output, "opaqueTOKEN") {
		t.Error("finish: the token was kept")
	}
}

func TestNewAndWithStoreValidate(t *testing.T) {
	if _, err := cronwatch.New(cronwatch.WithRetention("soon")); err == nil || err.Error() != `retention "soon" is not a duration like "15m", "1h30m" or "90s"` {
		t.Error(err)
	}
	if _, err := cronwatch.New(cronwatch.WithStore(nil)); err == nil {
		t.Error("a nil store")
	}
	if _, err := cronwatch.New(cronwatch.WithRedact(nil)); err == nil {
		t.Error("a nil redact")
	}
	k := newKit(t)
	if _, err := k.cw.Silence(bg, "x", -time.Second); err == nil || err.Error() != "silence duration must be a non-negative number of milliseconds" {
		t.Error(err)
	}
}
