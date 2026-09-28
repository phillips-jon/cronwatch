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

func TestHandlerPanicsAreRecordedThenCarryOn(t *testing.T) {
	k := newKit(t)
	h := must[*cronwatch.Job](t)(k.cw.Job("p")).Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error {
		panic("boom")
	})
	func() {
		defer func() {
			if recover() == nil {
				t.Error("the panic did not carry on")
			}
		}()
		serve(h, "GET", "http://x/", nil, "")
	}()
	list := runs(t, k.cw, "p")
	eq(t, "failed", list[0].Status, cronwatch.StatusFailed)
	contains(t, "error", *list[0].Error, "panic: boom")
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
