package cronwatch

// Running a job: the recorded run around a function (execute), how a
// finished run is judged (conclude), and how its finish is written once,
// however many processes finish it (recordFinish, claimFinish).

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/output"
	"cronwatch.dev/go/internal/schedule"
)

// Job is a declared job's handle.
type Job struct {
	c   *Client
	def *jobDef
}

// JobFunc is a job's work. ctx is cancelled when the job's timeout passes
// (and when the caller's context is); job logs output and reports metrics.
// A returned error fails the run and is returned from Run.
type JobFunc func(ctx context.Context, job *JobContext) error

// Name is the job's name.
func (j *Job) Name() string { return j.def.name }

// Definition is the job's definition as it is stored.
func (j *Job) Definition() Definition { return j.def.stored.clone() }

// RunOption configures one run.
type RunOption func(*runConfig)

type runConfig struct {
	trigger string
	id      string
	hasID   bool
	discard func(error) bool
}

// WithTrigger names what started the run. The default is "run" for Run
// and "start" for Start.
func WithTrigger(trigger string) RunOption { return func(r *runConfig) { r.trigger = trigger } }

// WithRunID gives Start your own stable id for the run, such as a queue's
// job id: 1 to 200 characters, not starting with "pgcron:" (the pg_cron
// source's). A start with an id already recorded for this job records
// nothing and returns a handle on that run instead; an id recorded for
// another job is an error. Start only.
func WithRunID(id string) RunOption { return func(r *runConfig) { r.id, r.hasID = id, true } }

// DiscardWhen takes a run back rather than judging it when the function
// returns an error discard answers true for: an attempt a queue gives back
// without failing, such as a River job that snoozes itself. The run's row
// is deleted while it is still running (through the store's RunDeleter),
// no alert is sent, the job's failures in a row are left as they were, and
// the error is still returned. A row a check already marked stuck is left
// as it is, and a store that is not a RunDeleter records the run as it
// ended; both are reported to the error handler as "discarding <job>". The
// SDK has no counterpart; the PHP port takes back a released Laravel job's
// attempt the same way. Run and RunValue only.
func DiscardWhen(discard func(err error) bool) RunOption {
	return func(r *runConfig) { r.discard = discard }
}

func runOptions(options []RunOption, trigger string) runConfig {
	cfg := runConfig{trigger: trigger}
	for _, o := range options {
		o(&cfg)
	}
	return cfg
}

// Run runs fn now as a recorded run and returns its error. The run is
// recorded however the store is doing: store errors go to the error
// handler, never to the caller. A panic in fn is recorded as a failed run
// and then carries on up the stack.
func (j *Job) Run(ctx context.Context, fn JobFunc, options ...RunOption) error {
	cfg := runOptions(options, "run")
	if cfg.hasID {
		return fmt.Errorf("job %s: WithRunID is for Start, not Run", js.Quote(j.def.name))
	}
	_, err := RunValue(ctx, j, func(ctx context.Context, job *JobContext) (struct{}, error) {
		return struct{}{}, fn(ctx, job)
	}, options...)
	return err
}

// RunValue runs fn as a recorded run of job, as Job.Run does, and returns
// what it returns. A string is the run's output when nothing was logged
// (and what an expect rule checks), and an *http.Response whose status is
// 400 or more fails the run with "HTTP <status> <reason>".
func RunValue[T any](ctx context.Context, job *Job, fn func(ctx context.Context, job *JobContext) (T, error), options ...RunOption) (T, error) {
	cfg := runOptions(options, "run")
	var zero T
	if cfg.hasID {
		return zero, fmt.Errorf("job %s: WithRunID is for Start, not Run", js.Quote(job.def.name))
	}
	var result T
	out := job.c.execute(ctx, job.def, func(ctx context.Context, jc *JobContext) (any, error) {
		v, err := fn(ctx, jc)
		result = v
		return v, err
	}, cfg.trigger, cfg.discard)
	if out.panicked {
		panic(out.panicValue)
	}
	if out.err != nil {
		return result, out.err
	}
	return result, nil
}

// JobContext is what a job's function gets: its run, and where it logs
// output and reports metrics.
type JobContext struct {
	name      string
	runID     string
	startedAt int64
	rec       *output.Recorder
}

type contextKey struct{}

// Current is the job context of the run ctx belongs to, or nil outside one.
// A nil *JobContext is safe to use: it logs and reports nothing, and has
// no name, run or start, so code shared with work run outside a job (a
// gocron task, say) may call Current(ctx).Log without a check.
func Current(ctx context.Context) *JobContext {
	jc, _ := ctx.Value(contextKey{}).(*JobContext)
	return jc
}

// Name is the job's name.
func (j *JobContext) Name() string {
	if j == nil {
		return ""
	}
	return j.name
}

// RunID is the run's id.
func (j *JobContext) RunID() string {
	if j == nil {
		return ""
	}
	return j.runID
}

// StartedAt is when the run started, in epoch milliseconds.
func (j *JobContext) StartedAt() int64 {
	if j == nil {
		return 0
	}
	return j.startedAt
}

// Log appends a line of output: the parts joined by spaces, strings as they
// are, errors as "Name: message", anything else as JSON. Kept with the run
// (the last 16 KB), shown in alerts and on the dashboard.
func (j *JobContext) Log(parts ...any) {
	if j == nil {
		return
	}
	j.rec.Log(parts...)
}

// Metric reports a number for this run: tokens, cost, rows, anything.
// Watched against budgets and baselines. A later value for the same name
// replaces an earlier one.
func (j *JobContext) Metric(name string, value float64) error {
	if j == nil {
		return nil
	}
	return j.rec.Metric(name, value)
}

// Metrics reports several numbers at once.
func (j *JobContext) Metrics(values Metrics) error {
	if j == nil {
		return nil
	}
	for _, m := range values {
		if err := j.rec.Metric(m.Name, m.Value); err != nil {
			return err
		}
	}
	return nil
}

// executed is how a run went.
type executed struct {
	run        Run
	result     any
	err        error
	panicked   bool
	panicValue any
	// discarded is a run taken back (DiscardWhen): nothing was judged.
	discarded bool
}

func recorderMetrics(rec *output.Recorder) Metrics {
	m, _ := metricsFrom(rec.Metrics())
	return m
}

// execute runs fn as a recorded run. The function always runs, whatever the
// store is doing: store errors go to the error handler, and the result is
// the function's own outcome. discard, when not nil, says which returned
// errors take the run back rather than finish it (DiscardWhen).
func (c *Client) execute(ctx context.Context, def *jobDef, fn func(context.Context, *JobContext) (any, error), trigger string, discard func(error) bool) executed {
	name := def.name
	sctx := storeCtx(ctx)
	startedAt := c.now()
	run := Run{ID: newID(), Job: name, Status: StatusRunning, StartedAt: startedAt, Metrics: Metrics{}, Trigger: trigger}
	recorded := false
	if err := c.sync(sctx, def, true); err != nil {
		c.report(err, "recording "+name)
	} else if err := c.store.InsertRun(sctx, run.clone()); err != nil {
		c.report(err, "recording "+name)
	} else {
		recorded = true
	}
	// Closing missed and stuck happens beside the job, which never waits on
	// it. A run that may be given back (DiscardWhen) closes them only once
	// it is known not to be, as the PHP port's released job does: one
	// taken back must leave the state as it was, or a job overdue would
	// have missed closed by each attempt given back and opened again by the
	// next check, an alert each time.
	var started sync.WaitGroup
	closeOnStart := func() {
		if _, _, err := updateState(sctx, c, name, func(s JobState) (JobState, struct{}, error) { return onRunStart(s), struct{}{}, nil }); err != nil {
			c.report(err, "starting "+name)
		}
	}
	if recorded && discard == nil {
		started.Add(1)
		go func() {
			defer started.Done()
			// A panic here (a store's) would end the process, where the
			// same panic beside the job is the job's to see: reported.
			defer func() {
				if p := recover(); p != nil {
					c.report(fmt.Errorf("panicked: %v", p), "starting "+name)
				}
			}()
			closeOnStart()
		}()
	}

	rec := output.NewRecorder()
	jc := &JobContext{name: name, runID: run.ID, startedAt: startedAt, rec: rec}
	timeout, _ := timeoutMs(def.stored)
	jobCtx, cancel := context.WithTimeoutCause(context.WithValue(ctx, contextKey{}, jc), msDuration(timeout),
		timeoutCause{fmt.Sprintf("job %s passed its timeout of %s", js.Quote(name), schedule.FormatDuration(timeout))})
	out := executed{}
	var panicText string
	func() {
		defer func() {
			if p := recover(); p != nil {
				out.panicked, out.panicValue = true, p
				panicText = output.PanicMessage(p)
			}
		}()
		out.result, out.err = fn(jobCtx, jc)
	}()
	cancel()

	if discard != nil && !out.panicked && out.err != nil && c.givenBack(name, discard, out.err) {
		if !recorded || c.discardRun(sctx, run) {
			out.discarded = true
			out.run = run
			return out
		}
	}
	if recorded && discard != nil {
		closeOnStart()
	}

	finishedAt := c.now()
	run.FinishedAt = ptr(finishedAt)
	run.DurationMs = ptr(runDuration(startedAt, finishedAt))
	run.Metrics = recorderMetrics(rec)
	run.Output = rec.Output()
	resultText, isText := out.result.(string)
	if run.Output == nil && isText && !out.panicked && out.err == nil {
		run.Output = ptr(resultText)
	}
	expectText := rec.ExpectText()
	if expectText == nil && isText && !out.panicked && out.err == nil {
		expectText = ptr(resultText)
	}
	var failure *string
	switch {
	case out.panicked:
		failure = &panicText
	case out.err != nil:
		failure = ptr(output.DescribeError(out.err))
	}
	c.conclude(def, &run, out.result, failure, expectText)
	out.run = run

	started.Wait()
	ignored, err := c.recordFinish(sctx, def, &run, recorded, finishedAt)
	if err != nil {
		c.report(err, "recording "+name)
	} else if ignored != "" {
		c.report(fmt.Errorf("run %s of %s %s; ignored", run.ID, name, ignored), "finishing "+name)
	}
	out.run = run
	return out
}

// timeoutCause is why a job's context ended at its timeout. It is a
// context.DeadlineExceeded for errors.Is, as the context's own error is,
// so a job that returns the cause keeps the standard sentinel.
type timeoutCause struct{ text string }

func (e timeoutCause) Error() string { return e.text }

func (timeoutCause) Unwrap() error { return context.DeadlineExceeded }

// givenBack is discard(err), a panic in it reported and the run not given
// back, so it is recorded rather than left running to be reported stuck.
func (c *Client) givenBack(name string, discard func(error) bool, err error) (back bool) {
	defer func() {
		if p := recover(); p != nil {
			c.report(fmt.Errorf("panicked: %v", p), "discarding "+name)
			back = false
		}
	}()
	return discard(err)
}

// msDuration is ms milliseconds as a time.Duration, held at the longest
// one (some 292 years) past it: the conversion would otherwise wrap (on
// amd64), and a timeout of "20000w" would end the job's context at once.
func msDuration(ms float64) time.Duration {
	if ns := ms * float64(time.Millisecond); ns < math.MaxInt64 {
		return time.Duration(ns)
	}
	return math.MaxInt64
}

// discardRun takes back a run still running (DiscardWhen) and says whether
// the caller is done with it. A store that is not a RunDeleter, or that
// fails, is reported and the run is finished as it ended, so it is not left
// running to be reported stuck; a row no longer running (a check marked it
// stuck meanwhile) is reported and left as it is.
func (c *Client) discardRun(ctx context.Context, run Run) bool {
	deleter, ok := c.store.(RunDeleter)
	if !ok {
		c.report(errors.New("the store cannot take back a run (it is not a cronwatch.RunDeleter); recorded as it ended"), "discarding "+run.Job)
		return false
	}
	deleted, err := deleter.DeleteRunIf(ctx, run.ID, run.Job, StatusRunning)
	if err != nil {
		c.report(err, "discarding "+run.Job)
		return false
	}
	if !deleted {
		c.report(fmt.Errorf("run %s of %s is no longer running; left as it is", run.ID, run.Job), "discarding "+run.Job)
	}
	return true
}

// httpFailure is the error an HTTP response of 400 or more fails a run with.
func httpFailure(result any) (string, bool) {
	res, ok := result.(*http.Response)
	if !ok || res == nil || res.StatusCode < 400 {
		return "", false
	}
	reason := strings.TrimSpace(strings.TrimPrefix(res.Status, strconv.Itoa(res.StatusCode)))
	text := "HTTP " + strconv.Itoa(res.StatusCode)
	if reason != "" {
		text += " " + reason
	}
	return text, true
}

// conclude sets a finished run's status and error from how it ended, then
// redacts its output and error and caps them, in that order. failure is the
// error text of a function that failed, not yet capped, or nil.
func (c *Client) conclude(def *jobDef, run *Run, result any, failure *string, expectText *string) {
	if failure != nil {
		run.Status = StatusFailed
		run.Error = ptr(*failure)
	} else if text, failed := httpFailure(result); failed {
		run.Status = StatusFailed
		run.Error = ptr(text)
	} else if unmet := checkExpectation(def.expect, expectText); unmet != nil {
		run.Status = StatusFailed
		run.Error = unmet
	} else {
		run.Status = StatusOK
	}
	// Redacted after the expect check, so a rule can still match what was
	// logged, and before the cap, so the cut cannot keep half a secret. NULs
	// go last, so not even a custom redact can store one.
	if run.Output != nil {
		run.Output = ptr(output.RedactAndCap(*run.Output, c.redact))
	}
	if run.Error != nil {
		run.Error = ptr(output.RedactAndCap(*run.Error, c.redact))
	}
}

// recordFinish writes a finished run and evaluates it. recorded says
// whether its start was written; if not, it is inserted now. Returns why
// nothing was recorded (another process finished the run first, say), or
// "". Returns the store's error, so a handle can be finished again.
func (c *Client) recordFinish(ctx context.Context, def *jobDef, run *Run, recorded bool, finishedAt int64) (string, error) {
	if !recorded {
		// The start was never written; the store may be back by now.
		if err := c.sync(ctx, def, false); err != nil {
			return "", err
		}
		err := c.store.InsertRun(ctx, run.clone())
		if err == nil {
			c.finishRun(ctx, def.stored, *run, finishedAt)
			return "", nil
		}
		// Another process may have recorded a run with this id meanwhile.
		stored, gerr := c.store.GetRun(ctx, run.ID)
		if gerr != nil || stored == nil {
			return "", err
		}
		if stored.Job != run.Job {
			return "belongs to job " + js.Quote(stored.Job), nil
		}
	}
	late, ignored, err := c.claimFinish(ctx, *run)
	if err != nil {
		return "", err
	}
	if ignored != "" {
		return ignored, nil
	}
	if !late || run.Status == StatusOK {
		c.finishRun(ctx, def.stored, *run, finishedAt)
	}
	return "", nil
}

// writeRunIf is a conditional write (RunUpdater.UpdateRunIf), or for a
// store without one, a read then a plain write.
func (c *Client) writeRunIf(ctx context.Context, run Run, from ...RunStatus) (bool, error) {
	if u, ok := c.store.(RunUpdater); ok {
		return u.UpdateRunIf(ctx, run.clone(), from)
	}
	stored, err := c.store.GetRun(ctx, run.ID)
	if err != nil || stored == nil {
		return false, err
	}
	for _, s := range from {
		if stored.Status == s {
			return true, c.store.UpdateRun(ctx, run.clone())
		}
	}
	return false, nil
}

// claimFinish writes a finished run over its stored row, only while that
// row is still running, or else still marked timeout by a check. Only the
// process whose write lands goes on to evaluate the run; for the others it
// says why nothing was written. late means a check already counted the run
// as a stuck failure: a late failure must not count twice, while a late
// success still closes stuck and recovers.
func (c *Client) claimFinish(ctx context.Context, run Run) (late bool, ignored string, err error) {
	if ok, err := c.writeRunIf(ctx, run, StatusRunning); err != nil || ok {
		return false, "", err
	}
	if ok, err := c.writeRunIf(ctx, run, StatusTimeout); err != nil || ok {
		return ok, "", err
	}
	stored, err := c.store.GetRun(ctx, run.ID)
	if err != nil {
		return false, "", err
	}
	if stored == nil {
		return false, "was not found", nil
	}
	return false, "was already finished as " + string(stored.Status), nil
}

// finishRun evaluates a finished run (ok, failed, or timed out by a
// check), already written, against the job's state, and sends what that
// produces. The alerts are written with that state (see outbox). Never
// fails: problems go to the error handler.
func (c *Client) finishRun(ctx context.Context, def Definition, run Run, now int64) []Alert {
	var history []Run
	var historyErr error
	read := false
	_, out, err := updateState(ctx, c, run.Job, func(previous JobState) (JobState, held, error) {
		if !read {
			history, historyErr = c.history(ctx, run)
			read = true
		}
		if historyErr != nil {
			return JobState{}, held{}, historyErr
		}
		e, err := onRunFinish(def, run, previous, history, now)
		if err != nil {
			return JobState{}, held{}, err
		}
		settled := applySilence(previous, e, now)
		state, out := c.outbox(settled.state, settled.alerts, def, now)
		return state, out, nil
	})
	if err != nil {
		c.report(err, "evaluating "+run.Job)
		return []Alert{}
	}
	c.reportDropped(run.Job, out.dropped)
	return c.dispatch(ctx, run.Job, out.alerts, now)
}

// history is the runs before run, newest first, with up to baselineWindow
// successful ones when the store has them. One small read normally; a
// larger one only when failures crowd the successes out of it.
func (c *Client) history(ctx context.Context, run Run) ([]Run, error) {
	runs, err := c.store.ListRuns(ctx, run.Job, historyPage)
	if err != nil {
		return nil, err
	}
	others := func(list []Run) []Run {
		out := []Run{}
		for _, r := range list {
			if r.ID != run.ID {
				out = append(out, r)
			}
		}
		return out
	}
	if len(runs) == historyPage && !hasFullBaseline(others(runs)) {
		if runs, err = c.store.ListRuns(ctx, run.Job, historyMax); err != nil {
			return nil, err
		}
	}
	return others(runs), nil
}

// RecordOption configures RecordRun.
type RecordOption func(*recordConfig)

type recordConfig struct{ skipEvaluation bool }

// WithoutEvaluation stores the run without judging it, for history
// imported on first sight.
func WithoutEvaluation() RecordOption { return func(r *recordConfig) { r.skipEvaluation = true } }

// RecordRun records a run that happened outside this process, for a
// Source. Its job must be declared with Job first. Runs are keyed by id: a
// new one is inserted, a stored one still running (or marked timeout by a
// check) is finished when this one is not running, and anything else is
// left alone, so recording the same run twice changes nothing. Finishing
// is conditional: when two processes record the same finish, only the one
// whose write lands evaluates it, and the other reports it as already
// finished. A stored run of another job is left alone and reported. A
// finished run is judged as if it had been wrapped here (expect, failures,
// duration, budgets) and its output and error are redacted the same way. A
// metric that is not a finite number is refused before anything is
// written, as JobContext.Metric refuses it. Returns the alerts it sent.
func (c *Client) RecordRun(ctx context.Context, input Run, options ...RecordOption) ([]Alert, error) {
	var cfg recordConfig
	for _, o := range options {
		o(&cfg)
	}
	def, ok := c.declared(input.Job)
	if !ok {
		return nil, fmt.Errorf("recordRun: job %s is not declared; call Job first", js.Quote(input.Job))
	}
	// The longest id Start takes; MySQL's column would hold 255, but every
	// store holds 200.
	if n := js.Length16(input.ID); n == 0 || n > maxRunID {
		return nil, fmt.Errorf("recordRun: run ids must be 1 to %d characters (got %d characters; job %s)", maxRunID, n, js.Quote(input.Job))
	}
	if strings.Contains(input.ID, "\x00") {
		return nil, fmt.Errorf("recordRun: run ids cannot contain a NUL character (job %s)", js.Quote(input.Job))
	}
	// Refused as JobContext.Metric refuses them: a store keeps NaN and
	// infinities as null, or refuses them.
	for _, m := range input.Metrics {
		if math.IsNaN(m.Value) || math.IsInf(m.Value, 0) {
			return nil, fmt.Errorf("recordRun: metric %s must be a finite number (job %s, run %s)", js.Quote(m.Name), js.Quote(input.Job), js.Quote(input.ID))
		}
	}
	if err := c.sync(ctx, def, false); err != nil {
		return nil, err
	}
	run := input.clone()
	if run.Status == StatusOK {
		if unmet := checkExpectation(def.expect, run.Output); unmet != nil {
			run.Status = StatusFailed
			run.Error = unmet
		}
	}
	if run.Output != nil {
		run.Output = ptr(output.RedactAndCap(*run.Output, c.redact))
	}
	if run.Error != nil {
		run.Error = ptr(output.RedactAndCap(*run.Error, c.redact))
	}
	evaluate := !cfg.skipEvaluation

	stored, err := c.store.GetRun(ctx, run.ID)
	if err != nil {
		return nil, err
	}
	if stored != nil {
		return c.recordOver(ctx, def.stored, *stored, run, evaluate)
	}
	if err := c.store.InsertRun(ctx, run.clone()); err != nil {
		// Another process recorded it first.
		again, gerr := c.store.GetRun(ctx, run.ID)
		if gerr == nil && again != nil {
			return c.recordOver(ctx, def.stored, *again, run, evaluate)
		}
		return nil, err
	}
	if !evaluate {
		return []Alert{}, nil
	}
	if _, _, err := updateState(ctx, c, run.Job, func(s JobState) (JobState, struct{}, error) { return onRunStart(s), struct{}{}, nil }); err != nil {
		return nil, err
	}
	if run.Status == StatusRunning {
		return []Alert{}, nil
	}
	return c.finishRun(ctx, def.stored, run, c.now()), nil
}

// recordOver is RecordRun for a run already stored.
func (c *Client) recordOver(ctx context.Context, def Definition, stored Run, run Run, evaluate bool) ([]Alert, error) {
	if stored.Job != run.Job {
		c.report(fmt.Errorf("run %s of %s belongs to job %s; ignored", run.ID, run.Job, js.Quote(stored.Job)), "recording "+run.Job)
		return []Alert{}, nil
	}
	if (stored.Status != StatusRunning && stored.Status != StatusTimeout) || run.Status == StatusRunning {
		return []Alert{}, nil
	}
	late, ignored, err := c.claimFinish(ctx, run)
	if err != nil {
		return nil, err
	}
	if ignored != "" {
		c.report(fmt.Errorf("run %s of %s %s; ignored", run.ID, run.Job, ignored), "recording "+run.Job)
		return []Alert{}, nil
	}
	if !evaluate || (late && run.Status != StatusOK) {
		return []Alert{}, nil
	}
	return c.finishRun(ctx, def, run, c.now()), nil
}
