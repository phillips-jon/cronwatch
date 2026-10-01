package cronwatch

// Runs that span calls (client.ts start(), resume() and the RunHandle): a
// run recorded as running now and finished later, perhaps by another
// process.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/output"
)

// ReservedRunIDPrefix starts the run ids of the pg_cron source, so no other
// run may use it.
const ReservedRunIDPrefix = "pgcron:"

// maxRunID is the longest run id, in UTF-16 code units (JavaScript's string
// length): what Start, Resume and RecordRun take, and every store holds.
const maxRunID = 200

// checkRunID is the SDK's error for a run id no store could hold, or one
// reserved for the pg_cron source.
func checkRunID(job, id, method string) error {
	if n := js.Length16(id); n == 0 || n > maxRunID {
		return fmt.Errorf("job %s: %s() needs a run id of 1 to %d characters (got %d characters)", js.Quote(job), method, maxRunID, n)
	}
	// Postgres refuses NUL in text, so no store could hold such an id.
	if strings.Contains(id, "\x00") {
		return fmt.Errorf("job %s: %s() cannot take a run id containing a NUL character", js.Quote(job), method)
	}
	if strings.HasPrefix(id, ReservedRunIDPrefix) {
		return fmt.Errorf("job %s: %s() cannot take a run id starting with %s, which the pg_cron source uses for its runs", js.Quote(job), method, js.Quote(ReservedRunIDPrefix))
	}
	return nil
}

// startCall is a Start with an id still in flight, so two at once in this
// process record one run and get one handle.
type startCall struct {
	done   chan struct{}
	handle *RunHandle
	err    error
}

// Start records a running run now, to finish later with the handle, perhaps
// from another process (see Resume). Store failures go to the error
// handler; it returns an error only for an invalid run id or one that
// belongs to another job. A run that is never finished is marked stuck by
// the first check after the job's timeout.
func (j *Job) Start(ctx context.Context, options ...RunOption) (*RunHandle, error) {
	cfg := runOptions(options, "start")
	c, def := j.c, j.def
	if !cfg.hasID {
		return c.recordStart(ctx, def, cfg.trigger, "", false)
	}
	if err := checkRunID(def.name, cfg.id, "start"); err != nil {
		return nil, err
	}
	// Keyed by job as well, so another job's start with the same id is not
	// handed this job's run: it fails as it would one call later.
	key := def.name + "\n" + cfg.id
	c.mu.Lock()
	if call, ok := c.starting[key]; ok {
		c.mu.Unlock()
		<-call.done
		return call.handle, call.err
	}
	// The error stands for a start that panicked (a store's panic, carried
	// on up this caller's stack): the call still ends, so the start of this
	// id waiting on it, and every later one, is not left waiting for good.
	call := &startCall{done: make(chan struct{}), err: fmt.Errorf("starting run %s of %s panicked", cfg.id, js.Quote(def.name))}
	c.starting[key] = call
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.starting, key)
		c.mu.Unlock()
		close(call.done)
	}()
	call.handle, call.err = c.recordStart(ctx, def, cfg.trigger, cfg.id, true)
	return call.handle, call.err
}

// Resume is a handle on a run this job started elsewhere, by its id, so
// this process can log to it and finish it.
func (j *Job) Resume(ctx context.Context, runID string) (*RunHandle, error) {
	return j.c.resumeHandle(ctx, j.def, runID)
}

// ResumeRun is Resume for a job declared in this process, by name.
func (c *Client) ResumeRun(ctx context.Context, name, runID string) (*RunHandle, error) {
	def, ok := c.declared(name)
	if !ok {
		return nil, fmt.Errorf("resumeRun: job %s is not declared; call Job first", js.Quote(name))
	}
	return c.resumeHandle(ctx, def, runID)
}

// recordStart is the start of execute without the function: the run is
// inserted and missed and stuck close. A store that fails is reported and
// the handle inserts the finished run instead, as execute does.
func (c *Client) recordStart(ctx context.Context, def *jobDef, trigger, id string, hasID bool) (*RunHandle, error) {
	name := def.name
	sctx := storeCtx(ctx)
	if hasID {
		var stored *Run
		err := c.ensureReady(sctx)
		if err == nil {
			stored, err = c.store.GetRun(sctx, id)
		}
		if err != nil {
			c.report(err, "recording "+name)
		}
		if stored != nil {
			return c.existingHandle(def, *stored)
		}
	}
	if !hasID {
		id = newID()
	}
	run := Run{ID: id, Job: name, Status: StatusRunning, StartedAt: c.now(), Metrics: Metrics{}, Trigger: trigger}
	recorded := false
	err := c.sync(sctx, def, true)
	if err == nil {
		err = c.store.InsertRun(sctx, run.clone())
	}
	if err == nil {
		recorded = true
	} else {
		// Another process may have started a run with this id first.
		if hasID {
			if stored, gerr := c.store.GetRun(sctx, id); gerr == nil && stored != nil {
				return c.existingHandle(def, *stored)
			}
		}
		c.report(err, "recording "+name)
	}
	if recorded {
		if _, _, err := updateState(sctx, c, name, func(s JobState) (JobState, struct{}, error) { return onRunStart(s), struct{}{}, nil }); err != nil {
			c.report(err, "starting "+name)
		}
	}
	return c.newHandle(def, run.ID, &run, recorded, ""), nil
}

// resumeHandle is Job.Resume and Client.ResumeRun. A store that cannot be
// read is reported, and Finish reads it again.
func (c *Client) resumeHandle(ctx context.Context, def *jobDef, runID string) (*RunHandle, error) {
	if err := checkRunID(def.name, runID, "resume"); err != nil {
		return nil, err
	}
	sctx := storeCtx(ctx)
	var stored *Run
	err := c.ensureReady(sctx)
	if err == nil {
		stored, err = c.store.GetRun(sctx, runID)
	}
	if err != nil {
		c.report(err, "resuming "+def.name)
		return c.newHandle(def, runID, nil, true, ""), nil
	}
	if stored == nil {
		return c.newHandle(def, runID, nil, true, "was not found"), nil
	}
	return c.existingHandle(def, *stored)
}

// existingHandle is a handle on a stored run. One still running, or marked
// timeout by a check, can be finished.
func (c *Client) existingHandle(def *jobDef, stored Run) (*RunHandle, error) {
	if stored.Job != def.name {
		return nil, fmt.Errorf("run %s belongs to job %s, not %s", js.Quote(stored.ID), js.Quote(stored.Job), js.Quote(def.name))
	}
	inactive := ""
	if stored.Status == StatusOK || stored.Status == StatusFailed {
		inactive = "already finished as " + string(stored.Status)
	}
	return c.newHandle(def, stored.ID, &stored, true, inactive), nil
}

// RunHandle is a run recorded by Start or found by Resume, to finish later.
// Lines and metrics wait in the handle until Flush or Finish merges them
// onto a fresh read of the stored run. It is safe for use by many
// goroutines at once; Flush and Finish take their turns.
type RunHandle struct {
	c        *Client
	def      *jobDef
	id       string
	base     *Run
	recorded bool
	// inactive is why Finish has nothing to do, or "".
	inactive string

	// turn orders Flush and Finish, as the SDK's inTurn queue does.
	turn sync.Mutex

	mu           sync.Mutex
	rec          *output.Recorder
	finished     bool
	finishCalled bool
	// head is the first 16 KB of every line flushed from this handle,
	// unredacted, or nil before the first flush. The stored output keeps
	// only the tail, so without it an expect rule at Finish would miss a
	// line logged early, which Run would have seen.
	head *string
}

func (c *Client) newHandle(def *jobDef, id string, base *Run, recorded bool, inactive string) *RunHandle {
	return &RunHandle{c: c, def: def, id: id, base: base, recorded: recorded, inactive: inactive, rec: output.NewRecorder(), finished: inactive != ""}
}

// ID is the run's id.
func (h *RunHandle) ID() string { return h.id }

// Job is the job's name.
func (h *RunHandle) Job() string { return h.def.name }

// StartedAt is when the run started, in epoch milliseconds; false when a
// resumed run could not be read.
func (h *RunHandle) StartedAt() (int64, bool) {
	if h.base == nil {
		return 0, false
	}
	return h.base.StartedAt, true
}

// Active is false once finished, and from the start for a resumed run that
// already finished or does not exist.
func (h *RunHandle) Active() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return !h.finished
}

// Log adds a line of output, kept in the handle until Flush or Finish.
// It holds the handle's lock as it writes, so a line logged as a Flush
// takes the recorder goes to the one taken or to its successor, never to
// one already read.
func (h *RunHandle) Log(parts ...any) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.rec.Log(parts...)
}

// Metric reports a number for this run. A later value for the same name
// replaces an earlier one.
func (h *RunHandle) Metric(name string, value float64) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.rec.Metric(name, value)
}

func (h *RunHandle) ignored(why string) {
	h.c.report(fmt.Errorf("run %s of %s %s; ignored", h.id, h.def.name, why), "finishing "+h.def.name)
}

// Flush appends the lines and metrics added so far to the stored run,
// which must still be running and belong to this job. A read, change and
// write of the run's row, written only while it is still running: two
// processes appending to one run at the same moment can lose one's lines,
// but a flush never undoes a finish. Problems go to the error handler.
func (h *RunHandle) Flush(ctx context.Context) {
	h.turn.Lock()
	defer h.turn.Unlock()
	c, name := h.c, h.def.name
	sctx := storeCtx(ctx)
	h.mu.Lock()
	if h.finished || !h.recorded {
		h.mu.Unlock()
		return
	}
	taken := h.rec
	lines := taken.Output()
	metrics := recorderMetrics(taken)
	if lines == nil && len(metrics) == 0 {
		h.mu.Unlock()
		return
	}
	// Lines logged while this waits on the store go to a new recorder.
	h.rec = output.NewRecorder()
	h.mu.Unlock()
	putBack := func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		later := h.rec
		h.rec = output.NewRecorder()
		for _, text := range []*string{taken.ExpectText(), later.ExpectText()} {
			if text != nil {
				h.rec.Log(*text)
			}
		}
		for _, m := range recorderMetrics(taken).merged(recorderMetrics(later)) {
			_ = h.rec.Metric(m.Name, m.Value)
		}
	}
	stored, err := c.store.GetRun(sctx, h.id)
	if err != nil {
		putBack()
		c.report(err, "flushing "+name)
		return
	}
	// Not running: the lines stay here for Finish, which reports why it cannot record them.
	if stored == nil || stored.Status != StatusRunning {
		putBack()
		return
	}
	if stored.Job != name {
		putBack()
		c.report(fmt.Errorf("run %s of %s belongs to job %s; ignored", h.id, name, js.Quote(stored.Job)), "flushing "+name)
		return
	}
	next := stored.clone()
	if lines != nil {
		next.Output = joinOutput(stored.Output, ptr(output.RedactAndCap(*lines, c.redact)))
	}
	next.Metrics = stored.Metrics.merged(metrics)
	// Only over a row still running, so a flush never undoes a finish written meanwhile.
	ok, err := c.writeRunIf(sctx, next, StatusRunning)
	if err != nil {
		putBack()
		c.report(err, "flushing "+name)
		return
	}
	if !ok {
		putBack()
		return
	}
	if text := taken.ExpectText(); text != nil {
		h.mu.Lock()
		if h.head == nil || js.Length16(*h.head) < output.OutputCap {
			h.head = ptr(js.Head16(*joinLines(h.head, text), output.OutputCap))
		}
		h.mu.Unlock()
	}
}

// Finish finishes the run successfully (unless an expect rule says
// otherwise), judges it like any other and sends what that produces. It
// returns the run as recorded, or nil when nothing was recorded: the run
// was already finished (here or elsewhere), was not found, or belongs to
// another job, which is reported to the error handler. When several
// processes finish one run, only the one whose write lands judges it. A
// store that fails is reported, nothing is recorded, and the handle stays
// active so Finish can be called again.
func (h *RunHandle) Finish(ctx context.Context) *Run { return h.finish(ctx, nil, nil) }

// FinishWith finishes the run with a result, treated like the value a
// RunValue function returns: a string is the output when nothing was
// logged (and what an expect rule checks), and an *http.Response of 400 or
// more fails the run.
func (h *RunHandle) FinishWith(ctx context.Context, result any) *Run {
	return h.finish(ctx, result, nil)
}

// Fail finishes the run as failed with err, written like an error a Run
// function returned.
func (h *RunHandle) Fail(ctx context.Context, err error) *Run {
	if err == nil {
		err = errors.New("failed")
	}
	return h.finish(ctx, nil, err)
}

func (h *RunHandle) finish(ctx context.Context, result any, failure error) *Run {
	h.mu.Lock()
	if h.finishCalled {
		h.mu.Unlock()
		h.ignored("was already finished by this handle")
		return nil
	}
	h.finishCalled = true
	wasInactive := h.finished
	h.finished = true
	h.mu.Unlock()
	// The store failed part way and nothing was recorded, so the handle can be finished again.
	retryable := func(err error) *Run {
		h.mu.Lock()
		h.finishCalled, h.finished = false, false
		h.mu.Unlock()
		h.c.report(err, "finishing "+h.def.name)
		return nil
	}

	h.turn.Lock()
	defer h.turn.Unlock()
	c, name := h.c, h.def.name
	sctx := storeCtx(ctx)
	if wasInactive {
		h.ignored(h.inactive)
		return nil
	}
	from := h.base
	if h.recorded {
		stored, err := c.store.GetRun(sctx, h.id)
		if err != nil {
			return retryable(err)
		}
		if stored != nil {
			from = stored
		}
	}
	if from == nil {
		h.ignored("was not found")
		return nil
	}
	if from.Job != name {
		h.ignored("belongs to job " + js.Quote(from.Job))
		return nil
	}
	if from.Status == StatusOK || from.Status == StatusFailed {
		h.ignored("was already finished as " + string(from.Status))
		return nil
	}
	h.mu.Lock()
	rec, head := h.rec, h.head
	h.mu.Unlock()
	resultText, isText := result.(string)
	finishedAt := c.now()
	added := rec.Output()
	if added == nil && isText {
		added = ptr(resultText)
	}
	run := from.clone()
	run.Status = StatusRunning
	run.FinishedAt = ptr(finishedAt)
	run.DurationMs = ptr(runDuration(from.StartedAt, finishedAt))
	run.Error = nil
	// Capped by conclude, after it is redacted.
	run.Output = joinLines(from.Output, added)
	run.Metrics = from.Metrics.merged(recorderMetrics(rec))
	expectText := rec.ExpectText()
	if expectText == nil && isText {
		expectText = ptr(resultText)
	}
	expectText = joinLines(head, joinLines(from.Output, expectText))
	var failureText *string
	if failure != nil {
		failureText = ptr(output.DescribeError(failure))
	}
	c.conclude(h.def, &run, result, failureText, expectText)
	why, err := c.recordFinish(sctx, h.def, &run, h.recorded, finishedAt)
	if err != nil {
		return retryable(err)
	}
	if why != "" {
		h.ignored(why)
		return nil
	}
	return &run
}

// joinLines is two stretches of text as one, a line apart; either may be nil.
func joinLines(before, after *string) *string {
	if before == nil || *before == "" {
		return after
	}
	if after == nil {
		return before
	}
	return ptr(*before + "\n" + *after)
}

// joinOutput is output appended to stored output, capped like any run's.
func joinOutput(before, after *string) *string {
	joined := joinLines(before, after)
	if joined == nil {
		return nil
	}
	return ptr(output.CapOutput(*joined))
}
