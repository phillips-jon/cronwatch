package cronwatch

// Checks, reads and the interval (client.ts check(), jobs(), silence(),
// start()).

import (
	"context"
	"fmt"
	"time"

	"cronwatch.dev/go/internal/schedule"
)

// checkCall is a check in flight, which concurrent callers share.
type checkCall struct {
	done   chan struct{}
	result *CheckResult
	err    error
}

// Check looks for missed and stuck runs across every job, sends alerts,
// retries alerts no channel accepted, and prunes old runs. Call it from an
// interval (Start), a cron hitting the dashboard's check route, or by hand.
// Concurrent calls share one check. A job that cannot be evaluated is
// reported to the error handler and shown as failing; the error returned is
// for the store failing as the check starts.
func (c *Client) Check(ctx context.Context) (*CheckResult, error) {
	c.checkMu.Lock()
	if call := c.checking; call != nil {
		c.checkMu.Unlock()
		<-call.done
		return call.result, call.err
	}
	call := &checkCall{done: make(chan struct{})}
	c.checking = call
	c.checkMu.Unlock()
	call.result, call.err = c.runCheck(ctx)
	c.checkMu.Lock()
	c.checking = nil
	c.checkMu.Unlock()
	close(call.done)
	return call.result, call.err
}

func (c *Client) runCheck(ctx context.Context) (*CheckResult, error) {
	if err := c.ensureReady(ctx); err != nil {
		return nil, err
	}
	alerts := []Alert{}
	for _, source := range c.sources {
		found, err := func() (found []Alert, err error) {
			defer func() {
				if p := recover(); p != nil {
					err = fmt.Errorf("panicked: %v", p)
				}
			}()
			return source.Sync(ctx, c)
		}()
		if err != nil {
			c.report(err, "source "+source.Name())
			continue
		}
		alerts = append(alerts, found...)
	}
	for _, def := range c.declaredAll() {
		if err := c.sync(ctx, def); err != nil {
			return nil, err
		}
	}
	now := c.now()

	// Runs that never reported back. One that cannot be judged (its job's
	// stored timeout no longer parses, say) is reported and skipped.
	running, err := c.store.RunningRuns(ctx)
	if err != nil {
		return nil, err
	}
	for _, run := range running {
		if err := func() error {
			var def Definition
			if declared, ok := c.declared(run.Job); ok {
				def = declared.stored
			} else {
				stored, err := c.store.GetJob(ctx, run.Job)
				if err != nil {
					return err
				}
				if stored == nil {
					return nil
				}
				def = stored.Definition
			}
			stuck, err := isStuck(def, run, now)
			if err != nil || !stuck {
				return err
			}
			timeout, _ := timeoutMs(def)
			run.Status = StatusTimeout
			run.FinishedAt = ptr(now)
			run.DurationMs = ptr(now - run.StartedAt)
			run.Error = ptr(fmt.Sprintf("Still running after %s; marked as timed out", schedule.FormatDuration(timeout)))
			// Only over a row still running: a finish that landed meanwhile wins.
			ok, err := c.writeRunIf(ctx, run, StatusRunning)
			if err != nil || !ok {
				return err
			}
			alerts = append(alerts, c.finishRun(ctx, def, run, now)...)
			return nil
		}(); err != nil {
			c.report(err, "checking "+run.Job)
		}
	}

	// Each job on its own: one that cannot be evaluated is reported, shown
	// as failing (see unevaluableSummary) and does not stop the others.
	jobs := []JobSummary{}
	var spent time.Duration
	stored, err := c.store.ListJobs(ctx)
	if err != nil {
		return nil, err
	}
	for _, job := range stored {
		summary, found, err := c.checkJob(ctx, job, now, &spent)
		alerts = append(alerts, found...)
		if err != nil {
			c.report(err, "checking "+job.Name)
			summary = c.unevaluable(ctx, job, now)
		}
		jobs = append(jobs, summary)
	}

	pruned := 0
	if now-c.lastPruneAt > pruneInterval {
		c.lastPruneAt = now
		n, err := c.store.Prune(ctx, now-int64(c.retentionMs))
		if err != nil {
			c.report(err, "pruning")
		} else {
			pruned = n
		}
	}
	return &CheckResult{CheckedAt: now, Jobs: jobs, Alerts: alerts, Pruned: pruned}, nil
}

// checkJob is one job's part of a check: missed, then retries and sends.
func (c *Client) checkJob(ctx context.Context, job StoredJob, now int64, spent *time.Duration) (JobSummary, []Alert, error) {
	recent, err := c.store.ListRuns(ctx, job.Name, baselineWindow)
	if err != nil {
		return JobSummary{}, nil, err
	}
	var last *Run
	if len(recent) > 0 {
		last = &recent[0]
	}
	var nextExpectedAt *int64
	state, drafts, err := updateState(ctx, c, job.Name, func(previous JobState) (JobState, []alertDraft, error) {
		out, err := onCheck(job.Definition, job, last, previous, now)
		if err != nil {
			return JobState{}, nil, err
		}
		nextExpectedAt = out.nextExpectedAt
		settled := applySilence(previous, out.evaluation, now)
		return settled.state, settled.alerts, nil
	})
	if err != nil {
		return JobSummary{}, nil, err
	}
	alerts := c.retryUndelivered(ctx, job.Name, state, now, spent)
	alerts = append(alerts, c.dispatch(ctx, drafts, job.Definition, now)...)
	summary, err := summarize(job, recent, state, nextExpectedAt, now)
	return summary, alerts, err
}

// JobWithRuns is a job's summary and its newest runs.
type JobWithRuns struct {
	Job  JobSummary
	Runs []Run
}

// snapshot is a job's summary and its newest runs, without alerting. A job
// that cannot be evaluated is reported and shown as failing.
func (c *Client) snapshot(ctx context.Context, job StoredJob, now int64, runs int) JobWithRuns {
	recent, err := c.store.ListRuns(ctx, job.Name, max(runs, baselineWindow))
	newest := func() []Run {
		if len(recent) > runs {
			return recent[:runs]
		}
		return recent
	}
	if err == nil {
		var state JobState
		state, err = c.readState(ctx, job.Name)
		if err == nil {
			var last *Run
			if len(recent) > 0 {
				last = &recent[0]
			}
			var out checkOutcome
			out, err = onCheck(job.Definition, job, last, state, now)
			if err == nil {
				var summary JobSummary
				summary, err = summarize(job, recent, state, out.nextExpectedAt, now)
				if err == nil {
					return JobWithRuns{summary, newest()}
				}
			}
		}
	}
	c.report(err, "reading "+job.Name)
	return JobWithRuns{c.unevaluable(ctx, job, now), newest()}
}

// unevaluable is the summary of a job whose evaluation failed, from
// whatever can still be read.
func (c *Client) unevaluable(ctx context.Context, job StoredJob, now int64) JobSummary {
	recent, err := c.store.ListRuns(ctx, job.Name, baselineWindow)
	if err != nil {
		recent = nil
	}
	state, err := c.readState(ctx, job.Name)
	if err != nil {
		state = emptyState(job.Name)
	}
	return unevaluableSummary(job, recent, state, now)
}

// Jobs is every job the store knows about, with its health. It sends no alerts.
func (c *Client) Jobs(ctx context.Context) ([]JobSummary, error) {
	all, err := c.JobsWithRuns(ctx, 0)
	if err != nil {
		return nil, err
	}
	out := make([]JobSummary, len(all))
	for i, e := range all {
		out[i] = e.Job
	}
	return out, nil
}

// JobsWithRuns is every job's summary with its newest limit runs (0 to
// 500), read together. What the dashboard shows.
func (c *Client) JobsWithRuns(ctx context.Context, limit int) ([]JobWithRuns, error) {
	if err := c.ensureReady(ctx); err != nil {
		return nil, err
	}
	for _, def := range c.declaredAll() {
		if err := c.sync(ctx, def); err != nil {
			return nil, err
		}
	}
	now := c.now()
	stored, err := c.store.ListJobs(ctx)
	if err != nil {
		return nil, err
	}
	out := []JobWithRuns{}
	for _, job := range stored {
		out = append(out, c.snapshot(ctx, job, now, clampLimit(limit, 0)))
	}
	return out, nil
}

// JobSummary is one job's summary, or nil when the store does not know it.
func (c *Client) JobSummary(ctx context.Context, name string) (*JobSummary, error) {
	if err := c.ensureReady(ctx); err != nil {
		return nil, err
	}
	if def, ok := c.declared(name); ok {
		if err := c.sync(ctx, def); err != nil {
			return nil, err
		}
	}
	stored, err := c.store.GetJob(ctx, name)
	if err != nil || stored == nil {
		return nil, err
	}
	s := c.snapshot(ctx, *stored, c.now(), 0).Job
	return &s, nil
}

// Runs is a job's runs, newest first. limit is 1 to 500.
func (c *Client) Runs(ctx context.Context, name string, limit int) ([]Run, error) {
	if err := c.ensureReady(ctx); err != nil {
		return nil, err
	}
	return c.store.ListRuns(ctx, name, clampLimit(limit, 1))
}

// GetRun is one run by its id, or nil.
func (c *Client) GetRun(ctx context.Context, id string) (*Run, error) {
	if err := c.ensureReady(ctx); err != nil {
		return nil, err
	}
	return c.store.GetRun(ctx, id)
}

// Silence stops alerts for a job for a while. State keeps updating
// underneath: nothing opens while it is silenced, so the first problem
// after the silence alerts as usual.
func (c *Client) Silence(ctx context.Context, name string, d time.Duration) (JobState, error) {
	ms, err := schedule.ParseDuration(d, "silence duration")
	if err != nil {
		return JobState{}, err
	}
	return c.patchState(ctx, name, func(s *JobState) { s.SilencedUntil = ptr(c.now() + int64(ms)) })
}

// Unsilence ends a silence.
func (c *Client) Unsilence(ctx context.Context, name string) (JobState, error) {
	return c.patchState(ctx, name, func(s *JobState) { s.SilencedUntil = nil })
}

// patchState reads, changes and writes one job's state, in turn with every
// other update to it.
func (c *Client) patchState(ctx context.Context, name string, change func(*JobState)) (JobState, error) {
	if err := c.ensureReady(ctx); err != nil {
		return JobState{}, err
	}
	state, _, err := updateState(ctx, c, name, func(current JobState) (JobState, struct{}, error) {
		next := normalizeState(&current, name)
		change(&next)
		return next, struct{}{}, nil
	})
	return state, err
}

// Forget removes a job and its runs from the store. A job still declared
// in code comes back on its next run.
func (c *Client) Forget(ctx context.Context, name string) error {
	if err := c.ensureReady(ctx); err != nil {
		return err
	}
	c.mu.Lock()
	if _, ok := c.definitions[name]; ok {
		delete(c.definitions, name)
		for i, n := range c.order {
			if n == name {
				c.order = append(c.order[:i:i], c.order[i+1:]...)
				break
			}
		}
	}
	delete(c.synced, name)
	c.mu.Unlock()
	return c.store.DeleteJob(ctx, name)
}

// Start checks on an interval in a goroutine, for long-running servers:
// the first check a second from now, then every `every` (a minute when 0,
// five seconds at least). Not for serverless functions, where nothing runs
// between requests: call Check from a cron there instead. A second Start
// does nothing.
func (c *Client) Start(every time.Duration) {
	c.timerMu.Lock()
	defer c.timerMu.Unlock()
	if c.stop != nil {
		return
	}
	if every == 0 {
		every = time.Minute
	}
	every = max(every, 5*time.Second)
	c.warnMu.Lock()
	if c.deferDelivery && !c.warnedDeferredStart {
		c.warnedDeferredStart = true
		fmt.Fprintln(Stderr, `[cronwatch] Start() was called with DeliverAtCheck, so these checks send no alerts. Another process must run checks with DeliverNow (the default) to send them.`)
	}
	c.warnMu.Unlock()
	stop := make(chan struct{})
	c.stop = stop
	delay := firstCheckDelay
	go func() {
		tick := func() {
			if _, err := c.Check(context.Background()); err != nil {
				c.report(err, "check")
			}
		}
		first := time.NewTimer(delay)
		defer first.Stop()
		ticker := time.NewTicker(every)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-first.C:
				tick()
			case <-ticker.C:
				tick()
			}
		}
	}()
}

// Stop stops the interval Start began. A check in flight finishes.
func (c *Client) Stop() {
	c.timerMu.Lock()
	defer c.timerMu.Unlock()
	if c.stop != nil {
		close(c.stop)
		c.stop = nil
	}
}

// Close stops the interval and closes the store.
func (c *Client) Close() error {
	c.Stop()
	return c.store.Close()
}
