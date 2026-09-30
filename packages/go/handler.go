package cronwatch

// Job.Handler: the SDK's fetch-style job handler (client.ts handler()) as an
// http.Handler, for a platform cron that calls a URL (Vercel's crons, Cloud
// Scheduler, a crontab line running curl). Each request carrying the cron
// secret runs the function as a recorded run and is answered with how it
// went.

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"cronwatch.dev/go/internal/js"
)

// HandlerFunc is a job's work for one request. ctx is the request's
// context with the job's timeout added. The function may answer the
// request itself through w, and a status of 400 or more written there
// fails the run; when it writes nothing, the handler answers with how the
// run went.
type HandlerFunc func(ctx context.Context, job *JobContext, w http.ResponseWriter, r *http.Request) error

// HandlerOption configures a job's handler.
type HandlerOption func(*handlerConfig)

type handlerConfig struct {
	secret string
	open   bool
}

// WithSecret is the secret the handler's requests must carry, as
// `Authorization: Bearer <secret>`, in place of the client's cron secret
// (WithCronSecret, $CRON_SECRET by default). "" counts as unset.
func WithSecret(secret string) HandlerOption {
	return func(c *handlerConfig) { c.secret, c.open = secret, false }
}

// WithoutSecret lets anyone run the job through the handler (the SDK's
// `secret: null`), for one behind your own auth, or a function only its
// platform can invoke.
func WithoutSecret() HandlerOption { return func(c *handlerConfig) { c.secret, c.open = "", true } }

// Handler is the job as an http.Handler (the SDK's job.handler()). A
// request must send `Authorization: Bearer <secret>` (compared in constant
// time): the handler's WithSecret, else the client's cron secret. With no
// secret at all it answers 503 and reports it once to the error handler as
// "handler", unless the environment is development (see WithToken) or
// WithoutSecret (or the client's WithoutCronSecret) lets anyone in; a
// wrong or missing bearer is 401. Each request it lets in runs fn as a run
// with the trigger "handler", answered with
// {"ok","job","run","status","durationMs"}, 200 when the run was ok and
// 500 when it failed, with the error's first line as "error" for a caller
// who sent the secret. A function that wrote its own answer is answered
// with that, and a status of 400 or more it wrote fails the run. A panic in
// fn is a failed run like an error (`panic: <value>`), answered 500 as the
// SDK answers a throw; a panic with http.ErrAbortHandler, or one after fn
// began its own answer, is recorded the same way and then aborts the
// response, as net/http does.
//
//	mux.Handle("POST /api/cron/nightly", nightly.Handler(func(ctx context.Context, job *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
//		path, err := buildReport(ctx)
//		job.Log("Report written:", path)
//		return err
//	}))
func (j *Job) Handler(fn HandlerFunc, options ...HandlerOption) http.Handler {
	return HandlerValue(j, func(ctx context.Context, job *JobContext, w http.ResponseWriter, r *http.Request) (struct{}, error) {
		return struct{}{}, fn(ctx, job, w, r)
	}, options...)
}

// HandlerValue is Job.Handler for a function that returns a value, as
// RunValue is Run's: a string is the run's output when nothing was logged,
// and an *http.Response (a call to another service, say) is the answer,
// copied to the caller, its status of 400 or more failing the run with
// "HTTP <status> <reason>". The response's body is closed. A response
// returned with an error is not the answer: the run failed with the error,
// and the caller gets the JSON answer.
func HandlerValue[T any](job *Job, fn func(ctx context.Context, job *JobContext, w http.ResponseWriter, r *http.Request) (T, error), options ...HandlerOption) http.Handler {
	cfg := handlerConfig{}
	for _, o := range options {
		o(&cfg)
	}
	c := job.c
	h := &jobHandler{job: job}
	switch {
	case cfg.open:
		h.optedOut = true
	case cfg.secret != "":
		h.secret = cfg.secret
	default:
		h.secret = c.cronSecret
		h.optedOut = c.secretOptOut
	}
	h.run = func(w *answerWriter, r *http.Request) executed {
		return c.execute(r.Context(), job.def, func(ctx context.Context, jc *JobContext) (any, error) {
			v, err := fn(ctx, jc, w, r)
			if w.status >= 400 {
				// What the function wrote is the outcome, as a response it
				// returned would be. A response it returned as well is closed
				// unread, as one beside any answer it wrote is.
				if res, ok := any(v).(*http.Response); ok && res != nil && res.Body != nil {
					_ = res.Body.Close()
				}
				return &http.Response{StatusCode: w.status, Status: strconv.Itoa(w.status) + " " + http.StatusText(w.status)}, err
			}
			return v, err
		}, "handler", nil)
	}
	return h
}

type jobHandler struct {
	job      *Job
	secret   string
	optedOut bool
	run      func(*answerWriter, *http.Request) executed
}

func handlerJSON(w http.ResponseWriter, body any, status int) {
	data := []byte(js.Stringify(body))
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func (h *jobHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c := h.job.c
	if h.secret == "" && !h.optedOut && environment() != "development" {
		c.warnNoSecret()
		handlerJSON(w, js.NewObject("ok", false, "error", "CRON_SECRET is not set, so this job will not run for an unauthenticated request. Set it, or pass cronwatch.WithoutSecret() to Handler to allow anyone."), http.StatusServiceUnavailable)
		return
	}
	if h.secret != "" {
		sent, _ := header(r, "Authorization")
		if !constantTimeEqual(latin1(sent), "Bearer "+h.secret) {
			handlerJSON(w, js.NewObject("ok", false, "error", "Unauthorized"), http.StatusUnauthorized)
			return
		}
	}
	aw := &answerWriter{ResponseWriter: w}
	out := h.run(aw, r)
	// A response the function returned is the answer only when it returned
	// no error with it (the SDK cannot return one and throw) and wrote no
	// answer of its own; otherwise its body is closed unread.
	res, _ := out.result.(*http.Response)
	if res != nil && (out.panicked || out.err != nil || aw.wrote) {
		if res.Body != nil {
			_ = res.Body.Close()
		}
		res = nil
	}
	if out.panicked {
		// The run is recorded as failed. http.ErrAbortHandler is net/http's
		// own way to abort a response, and one the function had begun to
		// write cannot become the JSON answer: both abort the response, as
		// net/http does, without the stack it logs for any other panic.
		if err, ok := out.panicValue.(error); (ok && errors.Is(err, http.ErrAbortHandler)) || aw.wrote {
			panic(http.ErrAbortHandler)
		}
	} else if aw.wrote {
		return
	}
	if res != nil {
		copyResponse(w, res)
		return
	}
	run := out.run
	body := js.NewObject("ok", run.Status == StatusOK, "job", h.job.def.name, "run", run.ID, "status", string(run.Status), "durationMs", intOrNull(run.DurationMs))
	// Error text only goes to a caller who proved they hold the secret.
	if h.secret != "" && run.Error != nil && *run.Error != "" {
		first, _, _ := strings.Cut(*run.Error, "\n")
		body.Set("error", first)
	}
	status := http.StatusOK
	if run.Status != StatusOK {
		status = http.StatusInternalServerError
	}
	handlerJSON(w, body, status)
}

// copyResponse answers with a response the function returned: its headers,
// status and body.
func copyResponse(w http.ResponseWriter, res *http.Response) {
	defer func() {
		if res.Body != nil {
			_ = res.Body.Close()
		}
	}()
	for k, v := range res.Header {
		if strings.EqualFold(k, "Content-Length") || strings.EqualFold(k, "Transfer-Encoding") {
			continue
		}
		w.Header()[k] = append([]string(nil), v...)
	}
	if res.ContentLength >= 0 && len(res.TransferEncoding) == 0 {
		w.Header().Set("Content-Length", strconv.FormatInt(res.ContentLength, 10))
	}
	status := res.StatusCode
	if status == 0 {
		status = http.StatusOK
	}
	w.WriteHeader(status)
	if res.Body != nil {
		_, _ = io.Copy(w, res.Body)
	}
}

// warnNoSecret reports, once per client, that a handler refused a request
// for want of a secret.
func (c *Client) warnNoSecret() {
	c.warnMu.Lock()
	warned := c.warnedNoSecret
	c.warnedNoSecret = true
	c.warnMu.Unlock()
	if !warned {
		c.report(errors.New("handler refused a request because no CRON_SECRET is set; pass cronwatch.WithoutSecret() to allow unauthenticated requests"), "handler")
	}
}

// answerWriter is the ResponseWriter a handler's function gets: it notes
// the status the function answered with, if any.
type answerWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (a *answerWriter) WriteHeader(code int) {
	// An informational status is not the answer; more headers may follow.
	if !a.wrote && (code >= 200 || code == http.StatusSwitchingProtocols) {
		a.status, a.wrote = code, true
	}
	a.ResponseWriter.WriteHeader(code)
}

func (a *answerWriter) Write(p []byte) (int, error) {
	if !a.wrote {
		a.status, a.wrote = http.StatusOK, true
	}
	return a.ResponseWriter.Write(p)
}

// Flush sends what was written so far, when the server can.
func (a *answerWriter) Flush() {
	if !a.wrote {
		a.status, a.wrote = http.StatusOK, true
	}
	_ = http.NewResponseController(a.ResponseWriter).Flush()
}

// Unwrap is the server's ResponseWriter, for http.ResponseController.
func (a *answerWriter) Unwrap() http.ResponseWriter { return a.ResponseWriter }
