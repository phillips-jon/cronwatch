package cronwatch_test

// Job.Handler: the SDK's handler tests (client.test.ts and
// client-hardening.test.ts), and the Go answers: a status the function
// wrote, an *http.Response it returned, and a real server in front.

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	cronwatch "cronwatch.dev/go"
)

func TestHandlerChecksTheBearerAndReportsTheRun(t *testing.T) {
	secret := "s3" + "cret"
	k := newKit(t, cronwatch.WithCronSecret(secret))
	job := must[*cronwatch.Job](t)(k.cw.Job("hourly", cronwatch.Schedule("@hourly")))
	h := job.Handler(func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
		j.Log(r.URL.Path)
		if r.Header.Get("X-Fail") != "" {
			return errors.New("nope\nsecond line")
		}
		return nil
	})
	status(t, "no auth", serve(h, "GET", "http://x/api/cron/hourly", nil, ""), 401)
	eq(t, "no auth body", serve(h, "GET", "http://x/api/cron/hourly", hdr{"authorization": "Bearer wrong"}, "").Body.String(), `{"ok":false,"error":"Unauthorized"}`)
	status(t, "lowercase bearer", serve(h, "GET", "http://x/api/cron/hourly", hdr{"authorization": "bearer " + secret}, ""), 401)
	res := serve(h, "GET", "http://x/api/cron/hourly", hdr{"authorization": "Bearer " + secret}, "")
	status(t, "ok", res, 200)
	eq(t, "type", res.Header().Get("Content-Type"), "application/json; charset=utf-8")
	eq(t, "cache", res.Header().Get("Cache-Control"), "no-store")
	list := runs(t, k.cw, "hourly")
	eq(t, "body", res.Body.String(), `{"ok":true,"job":"hourly","run":"`+list[0].ID+`","status":"ok","durationMs":0}`)
	k.c.Advance(1000)
	failed := serve(h, "GET", "http://x/api/cron/hourly", hdr{"authorization": "Bearer " + secret, "x-fail": "1"}, "")
	status(t, "failed", failed, 500)
	eq(t, "the error's first line", decode(t, failed)["error"].(string), "Error: nope")
	list = runs(t, k.cw, "hourly")
	eq(t, "runs", len(list), 2)
	eq(t, "output", *list[1].Output, "/api/cron/hourly")
	eq(t, "trigger", list[0].Trigger, "handler")
}

func TestHandlerWithSecretIsItsOwn(t *testing.T) {
	k := newKit(t, cronwatch.WithCronSecret("client-"+"secret"))
	job := must[*cronwatch.Job](t)(k.cw.Job("own"))
	h := job.Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error { return nil }, cronwatch.WithSecret("own-"+"secret"))
	status(t, "the client's", serve(h, "POST", "http://x/", hdr{"authorization": "Bearer client-" + "secret"}, ""), 401)
	status(t, "its own", serve(h, "POST", "http://x/", hdr{"authorization": "Bearer own-" + "secret"}, ""), 200)
	empty := job.Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error { return nil }, cronwatch.WithSecret(""))
	status(t, "an empty one is the client's", serve(empty, "POST", "http://x/", hdr{"authorization": "Bearer client-" + "secret"}, ""), 200)
}

func TestHandlerAResponseIsTheAnswerAndFailsTheRunAt400(t *testing.T) {
	k := newKit(t)
	job := must[*cronwatch.Job](t)(k.cw.Job("h"))
	returned := cronwatch.HandlerValue(job, func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 503, Status: "503 Service Unavailable", Header: http.Header{"X-Upstream": {"1"}},
			Body: io.NopCloser(strings.NewReader("bad")), ContentLength: 3}, nil
	})
	res := serve(returned, "GET", "http://x/", nil, "")
	status(t, "passed through", res, 503)
	eq(t, "body", res.Body.String(), "bad")
	eq(t, "header", res.Header().Get("X-Upstream"), "1")
	eq(t, "error", *runs(t, k.cw, "h")[0].Error, "HTTP 503 Service Unavailable")
	sameList(t, "alerts", k.alerts.Types(), []string{"failed"})

	written := job.Handler(func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
		http.Error(w, "not here", http.StatusNotFound)
		return nil
	})
	k.c.Advance(1000)
	res = serve(written, "GET", "http://x/", nil, "")
	status(t, "written", res, 404)
	eq(t, "written body", res.Body.String(), "not here\n")
	eq(t, "written error", *runs(t, k.cw, "h")[0].Error, "HTTP 404 Not Found")

	fine := job.Handler(func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusAccepted)
		_, err := io.WriteString(w, "queued")
		return err
	})
	k.c.Advance(1000)
	res = serve(fine, "GET", "http://x/", nil, "")
	status(t, "accepted", res, 202)
	eq(t, "written ok", res.Body.String(), "queued")
	eq(t, "an ok run", runs(t, k.cw, "h")[0].Status, cronwatch.StatusOK)

	text := cronwatch.HandlerValue(job, func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) (string, error) {
		return "Report written", nil
	})
	k.c.Advance(1000)
	res = serve(text, "GET", "http://x/", nil, "")
	status(t, "a string", res, 200)
	eq(t, "its output", *runs(t, k.cw, "h")[0].Output, "Report written")
}

// closeCounter is a body that counts its closes.
type closeCounter struct {
	io.Reader
	closed *int
}

func (b closeCounter) Close() error { *b.closed++; return nil }

// The audit: a response returned with an error was the answer (a 200 for a
// failed run), and one returned by a function that wrote its own answer
// was never closed.
func TestHandlerAResponseReturnedWithAnErrorIsNotTheAnswer(t *testing.T) {
	k := newKit(t)
	job := must[*cronwatch.Job](t)(k.cw.Job("h"))
	closed := 0
	upstream := func() *http.Response {
		return &http.Response{StatusCode: 200, Status: "200 OK", Body: closeCounter{strings.NewReader("fine"), &closed}, ContentLength: 4}
	}
	failing := cronwatch.HandlerValue(job, func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) (*http.Response, error) {
		return upstream(), errors.New("the report was empty")
	})
	res := serve(failing, "GET", "http://x/", nil, "")
	status(t, "the run's answer", res, 500)
	eq(t, "not ok", decode(t, res)["ok"], any(false))
	eq(t, "closed", closed, 1)
	eq(t, "error", *runs(t, k.cw, "h")[0].Error, "Error: the report was empty")

	wrote := cronwatch.HandlerValue(job, func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) (*http.Response, error) {
		w.WriteHeader(http.StatusAccepted)
		return upstream(), nil
	})
	k.c.Advance(1000)
	res = serve(wrote, "GET", "http://x/", nil, "")
	status(t, "its own answer", res, 202)
	eq(t, "closed too", closed, 2)
}

func TestHandlerFailsClosedWithoutASecretOutsideDevelopment(t *testing.T) {
	t.Setenv("CRONWATCH_ENV", "")
	t.Setenv("APP_ENV", "")
	t.Setenv("GO_ENV", "")
	k := newKit(t, cronwatch.WithCronSecret(""))
	ran := 0
	h := must[*cronwatch.Job](t)(k.cw.Job("closed")).Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error {
		ran++
		return nil
	})
	res := serve(h, "GET", "http://x/", nil, "")
	status(t, "closed", res, 503)
	contains(t, "message", decode(t, res)["error"].(string), "CRON_SECRET is not set")
	serve(h, "GET", "http://x/", nil, "")
	eq(t, "ran", ran, 0)
	sameList(t, "reported once", k.wheres(), []string{"handler"})

	// Opting out runs the job, and does not show the error to the caller.
	open := must[*cronwatch.Job](t)(k.cw.Job("open")).Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error {
		return errors.New("private detail")
	}, cronwatch.WithoutSecret())
	failed := serve(open, "GET", "http://x/", nil, "")
	status(t, "open", failed, 500)
	if _, has := decode(t, failed)["error"]; has {
		t.Error("the error went to a caller who sent no secret")
	}
	t.Setenv("APP_ENV", "local")
	status(t, "development", serve(h, "GET", "http://x/", nil, ""), 200)
	eq(t, "ran in development", ran, 1)

	// A client made WithoutCronSecret lets anyone in.
	anyone := newKit(t)
	t.Setenv("APP_ENV", "")
	status(t, "WithoutCronSecret", serve(must[*cronwatch.Job](t)(anyone.cw.Job("any")).Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error { return nil }), "GET", "http://x/", nil, ""), 200)
}

func TestHandlerAPanicIsAFailedRunAnswered500(t *testing.T) {
	secret := "s3" + "cret"
	k := newKit(t, cronwatch.WithCronSecret(secret))
	h := must[*cronwatch.Job](t)(k.cw.Job("p")).Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error {
		panic("boom")
	})
	res := serve(h, "GET", "http://x/", hdr{"authorization": "Bearer " + secret}, "")
	status(t, "answered", res, 500)
	eq(t, "type", res.Header().Get("Content-Type"), "application/json; charset=utf-8")
	list := runs(t, k.cw, "p")
	eq(t, "failed", list[0].Status, cronwatch.StatusFailed)
	contains(t, "error", *list[0].Error, "panic: boom\n    at ")
	eq(t, "body", res.Body.String(), `{"ok":false,"job":"p","run":"`+list[0].ID+`","status":"failed","durationMs":0,"error":"panic: boom"}`)
	sameList(t, "alerts", k.alerts.Types(), []string{"failed"})

	// A caller without the secret gets no error text, as for any failure.
	open := must[*cronwatch.Job](t)(k.cw.Job("q")).Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error {
		panic(errors.New("private detail"))
	}, cronwatch.WithoutSecret())
	res = serve(open, "GET", "http://x/", nil, "")
	status(t, "open", res, 500)
	if _, has := decode(t, res)["error"]; has {
		t.Error("the panic went to a caller who sent no secret")
	}
}

func TestHandlerAbortStillPropagates(t *testing.T) {
	k := newKit(t)
	abort := func(fn cronwatch.HandlerFunc) any {
		var got any
		func() {
			defer func() { got = recover() }()
			serve(must[*cronwatch.Job](t)(k.cw.Job("a")).Handler(fn), "GET", "http://x/", nil, "")
		}()
		return got
	}
	got := abort(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error {
		panic(http.ErrAbortHandler)
	})
	eq(t, "ErrAbortHandler carries on", got, any(http.ErrAbortHandler))
	list := runs(t, k.cw, "a")
	eq(t, "recorded", list[0].Status, cronwatch.StatusFailed)
	contains(t, "error", *list[0].Error, "panic: net/http: abort Handler")

	// A panic once the function has begun its own answer cannot become the
	// JSON answer, so the response is aborted too.
	k.c.Advance(1000)
	got = abort(func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
		_, _ = io.WriteString(w, "half")
		panic("late")
	})
	eq(t, "aborted", got, any(http.ErrAbortHandler))
	list = runs(t, k.cw, "a")
	eq(t, "runs", len(list), 2)
	contains(t, "late panic", *list[0].Error, "panic: late")

	// Through a server, a panic is the 500 and the server carries on.
	mux := http.NewServeMux()
	mux.Handle("/boom", must[*cronwatch.Job](t)(k.cw.Job("b")).Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error {
		panic("boom")
	}))
	server := httptest.NewServer(mux)
	defer server.Close()
	answer, err := http.Get(server.URL + "/boom")
	check(t, err)
	answer.Body.Close()
	eq(t, "through a server", answer.StatusCode, 500)
}

func TestHandlerThroughAServer(t *testing.T) {
	secret := "s3" + "cret"
	k := newKit(t, cronwatch.WithCronSecret(secret))
	job := must[*cronwatch.Job](t)(k.cw.Job("served"))
	mux := http.NewServeMux()
	mux.Handle("POST /api/cron/served", job.Handler(func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
		if cronwatch.Current(ctx) != j {
			t.Error("the context does not carry the job")
		}
		// The function can flush through the wrapped writer.
		w.Header().Set("Content-Type", "text/plain")
		_, _ = io.WriteString(w, "started\n")
		if err := http.NewResponseController(w).Flush(); err != nil {
			t.Errorf("flush: %v", err)
		}
		_, _ = io.WriteString(w, "done\n")
		return nil
	}))
	server := httptest.NewServer(mux)
	defer server.Close()
	req, _ := http.NewRequest("POST", server.URL+"/api/cron/served", nil)
	req.Header.Set("Authorization", "Bearer "+secret)
	res, err := http.DefaultClient.Do(req)
	check(t, err)
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	eq(t, "status", res.StatusCode, 200)
	eq(t, "body", string(body), "started\ndone\n")
	eq(t, "ok", runs(t, k.cw, "served")[0].Status, cronwatch.StatusOK)
}
