package cronwatch

// Sending alerts: channels, triage, and the queue of alerts no channel
// accepted, retried once per check (client.ts dispatch, retryUndelivered,
// recordDelivery, deliver, addTriage).

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// Channel is where alerts go.
type Channel interface {
	// Name names the channel in errors ("alert channel <name>").
	Name() string
	// Send returns once the alert went out (to at least one recipient), or
	// an error when it went nowhere. ctx ends after 15 seconds.
	Send(ctx context.Context, alert Alert, cc ChannelContext) error
}

// ChannelContext is what the client hands a channel with each alert.
type ChannelContext struct {
	report func(error)
}

// NewChannelContext is a channel context that reports to report, for
// sending to a channel outside a client (a test, say).
func NewChannelContext(report func(error)) ChannelContext {
	return ChannelContext{report: report}
}

// ReportError reports a problem that did not stop the alert going out,
// such as one of several recipients refusing it. It goes to the client's
// error handler; the zero ChannelContext writes it to standard error, as
// the SDK does for a channel called without one.
func (cc ChannelContext) ReportError(err error) {
	if cc.report != nil {
		cc.report(err)
		return
	}
	fmt.Fprintln(Stderr, "[cronwatch] alert channel:", err)
}

type funcChannel struct {
	name string
	send func(context.Context, Alert) error
}

func (f funcChannel) Name() string { return f.name }

func (f funcChannel) Send(ctx context.Context, alert Alert, _ ChannelContext) error {
	return f.send(ctx, alert)
}

// ChannelFunc wraps a function as a channel (the SDK's custom()).
func ChannelFunc(name string, send func(ctx context.Context, alert Alert) error) Channel {
	return funcChannel{name, send}
}

// Console is the default channel: it writes each alert to standard error,
// and recoveries to standard output.
func Console() Channel {
	return ChannelFunc("console", func(_ context.Context, alert Alert) error {
		line := "[cronwatch] " + alert.Title + "\n" + alert.Message
		if alert.Triage != nil && *alert.Triage != "" {
			line += "\nTriage: " + *alert.Triage
		}
		w := Stderr
		if alert.Type == AlertRecovered {
			w = Stdout
		}
		_, err := fmt.Fprintln(w, line)
		return err
	})
}

// TriageFunc diagnoses an alert in a few sentences, or answers "" for no
// diagnosis. ctx ends when the client stops waiting (25 seconds); pass it
// to any request made.
type TriageFunc func(ctx context.Context, tc TriageContext) (string, error)

// TriageContext is what a triage function is given.
type TriageContext struct {
	Alert Alert
	// The job's five newest runs.
	RecentRuns []Run
}

// Source is where runs this process does not wrap come from, such as
// pg_cron's jobs. Check syncs each one first, so what it records is
// evaluated in the same check.
type Source interface {
	Name() string
	// Sync declares the jobs and records their new runs, returning the
	// alerts recording them sent.
	Sync(ctx context.Context, host SourceHost) ([]Alert, error)
}

// SourceHost is what a Source may use of the client. A *Client is one.
type SourceHost interface {
	Job(name string, options ...JobOption) (*Job, error)
	RecordRun(ctx context.Context, run Run, options ...RecordOption) ([]Alert, error)
	Store() Store
	Now() int64
	ReportError(err error, where string)
}

var _ SourceHost = (*Client)(nil)

// alertKey identifies an alert across retries.
func alertKey(a Alert) string {
	id := ""
	if a.Run != nil {
		id = a.Run.ID
	}
	return string(a.Type) + "|" + strconv.FormatInt(a.At, 10) + "|" + id
}

// dispatch composes, triages and sends each draft. The state was saved
// before this (updateState), so a slow channel holds up nothing else;
// afterwards only the delivery fields are written back, onto a fresh read
// of the state.
func (c *Client) dispatch(ctx context.Context, drafts []alertDraft, def Definition, now int64) []Alert {
	composed := []Alert{}
	if len(drafts) == 0 {
		return composed
	}
	var delivered, failed []Alert
	for _, draft := range drafts {
		alert := composeAlert(draft, def, now)
		if c.deferDelivery {
			failed = append(failed, alert)
		} else {
			if c.triage != nil && alert.Type != AlertRecovered {
				c.addTriage(ctx, &alert, triageTimeout)
			}
			if c.deliver(ctx, alert) {
				delivered = append(delivered, alert)
			} else {
				failed = append(failed, alert)
			}
		}
		composed = append(composed, alert)
	}
	c.recordDelivery(ctx, def.Name(), delivered, failed, nil, now)
	return composed
}

// retryUndelivered sends the alerts no channel accepted last time, once
// each, oldest first. state is the job's state as this check left it: an
// alert that no longer describes it (staleAlert) is dropped instead.
// Retries across a check share retryBudget of wall-clock time; once it is
// spent the rest stay queued for the next check.
func (c *Client) retryUndelivered(ctx context.Context, name string, state JobState, now int64, spent *time.Duration) []Alert {
	pending := state.Undelivered
	if len(pending) == 0 || isSilenced(state, now) || c.deferDelivery {
		return []Alert{}
	}
	var delivered, failed, dropped []Alert
	for _, a := range pending {
		if staleAlert(a, state) {
			dropped = append(dropped, a)
		}
	}
	for _, a := range pending {
		if staleAlert(a, state) {
			continue
		}
		left := retryBudget - *spent
		if left <= 0 {
			break
		}
		started := time.Now()
		alert := a.clone()
		// An alert queued by a process that delivers at check time was never
		// triaged. One that was tried (TriageTried) is not tried again.
		if c.triage != nil && alert.Type != AlertRecovered && !alert.TriageTried {
			c.addTriage(ctx, &alert, min(triageTimeout, left))
		}
		if c.deliver(ctx, alert) {
			delivered = append(delivered, alert)
		} else {
			failed = append(failed, alert)
		}
		*spent += max(0, time.Since(started))
	}
	c.recordDelivery(ctx, name, delivered, failed, dropped, now)
	if delivered == nil {
		return []Alert{}
	}
	return delivered
}

// recordDelivery marks delivered alerts done, drops stale ones, and keeps
// failed ones for the next check. A failed alert replaces its stored copy,
// so a triage made on this attempt is kept. LastAlertAt moves only on a
// delivery.
func (c *Client) recordDelivery(ctx context.Context, name string, delivered, failed, dropped []Alert, now int64) {
	_, trimmed, err := updateState(ctx, c, name, func(previous JobState) (JobState, int, error) {
		state := normalizeState(&previous, name)
		done := map[string]bool{}
		for _, a := range delivered {
			done[alertKey(a)] = true
		}
		for _, a := range dropped {
			done[alertKey(a)] = true
		}
		retried := map[string]Alert{}
		for _, a := range failed {
			retried[alertKey(a)] = a
		}
		kept := []Alert{}
		known := map[string]bool{}
		for _, a := range state.Undelivered {
			key := alertKey(a)
			if done[key] {
				continue
			}
			if r, ok := retried[key]; ok {
				a = r
			}
			kept = append(kept, a.clone())
			known[key] = true
		}
		for _, a := range failed {
			if !known[alertKey(a)] {
				kept = append(kept, a.clone())
			}
		}
		trimmed := max(0, len(kept)-maxUndelivered)
		state.Undelivered = kept[trimmed:]
		if len(delivered) > 0 {
			state.LastAlertAt = ptr(now)
		}
		return state, trimmed, nil
	})
	if err != nil {
		c.report(err, "recording alert delivery for "+name)
		return
	}
	if trimmed > 0 {
		plural := "s"
		if trimmed == 1 {
			plural = ""
		}
		c.report(fmt.Errorf("%d undelivered alert%s for %s dropped: only the newest %d are kept for retry", trimmed, plural, name, maxUndelivered), "alert queue for "+name)
	}
}

// deliver sends to every channel at once. True when at least one accepted
// it, or there are none. A channel that has not returned from an earlier
// send past its timeout gets nothing more until it does, so a hung channel
// holds one goroutine rather than one per alert.
func (c *Client) deliver(ctx context.Context, alert Alert) bool {
	if len(c.alerts) == 0 {
		return true
	}
	results := make(chan bool, len(c.alerts))
	for i, ch := range c.alerts {
		go func(i int, ch Channel) {
			results <- c.sendOne(ctx, i, ch, alert)
		}(i, ch)
	}
	ok := false
	for range c.alerts {
		if <-results {
			ok = true
		}
	}
	return ok
}

// sendOne sends one alert to one channel within channelTimeout. A channel
// whose earlier send ran past its timeout and has still not returned is
// skipped until it does, so a hung channel holds one goroutine rather than
// one per alert.
func (c *Client) sendOne(ctx context.Context, i int, ch Channel, alert Alert) bool {
	where := "alert channel " + ch.Name()
	c.busyMu.Lock()
	stalled := c.channelBusy[i]
	c.busyMu.Unlock()
	if stalled {
		c.report(errors.New("still sending an earlier alert, past its timeout"), where)
		return false
	}
	sendCtx, cancel := context.WithTimeout(storeCtx(ctx), channelTimeout)
	defer cancel()
	done := make(chan error, 1)
	finished := false
	go func() {
		defer func() {
			if p := recover(); p != nil {
				done <- fmt.Errorf("panicked: %v", p)
			}
			c.busyMu.Lock()
			finished = true
			delete(c.channelBusy, i)
			c.busyMu.Unlock()
		}()
		done <- ch.Send(sendCtx, alert.clone(), ChannelContext{report: func(err error) { c.report(err, where) }})
	}()
	timer := time.NewTimer(channelTimeout)
	defer timer.Stop()
	select {
	case err := <-done:
		if err != nil {
			c.report(err, where)
			return false
		}
		return true
	case <-timer.C:
		c.busyMu.Lock()
		if !finished {
			c.channelBusy[i] = true
		}
		c.busyMu.Unlock()
		c.report(fmt.Errorf("timed out after %dms", channelTimeout.Milliseconds()), where)
		return false
	}
}

// addTriage sets the alert's triage to the diagnosis, or to none, so it is
// tried once per alert. A triage that ran past its timeout and has still
// not returned holds off the next one until it does, as a hung channel is.
func (c *Client) addTriage(ctx context.Context, alert *Alert, timeout time.Duration) {
	where := "triage for " + alert.Job
	alert.TriageTried = true
	alert.Triage = nil
	c.busyMu.Lock()
	stalled := c.triageBusy
	c.busyMu.Unlock()
	if stalled {
		c.report(errors.New("an earlier triage is still running past its timeout"), where)
		return
	}
	recent, err := c.store.ListRuns(storeCtx(ctx), alert.Job, 5)
	if err != nil {
		c.report(err, where)
		return
	}
	tctx, cancel := context.WithTimeout(storeCtx(ctx), timeout)
	defer cancel()
	type answer struct {
		text string
		err  error
	}
	done := make(chan answer, 1)
	finished := false
	tc := TriageContext{Alert: alert.clone(), RecentRuns: recent}
	go func() {
		defer func() {
			if p := recover(); p != nil {
				done <- answer{err: fmt.Errorf("panicked: %v", p)}
			}
			c.busyMu.Lock()
			finished = true
			c.triageBusy = false
			c.busyMu.Unlock()
		}()
		text, err := c.triage(tctx, tc)
		done <- answer{text, err}
	}()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case a := <-done:
		if a.err != nil {
			c.report(a.err, where)
			return
		}
		if a.text != "" {
			alert.Triage = ptr(a.text)
		}
	case <-timer.C:
		cancel()
		c.busyMu.Lock()
		if !finished {
			c.triageBusy = true
		}
		c.busyMu.Unlock()
		c.report(fmt.Errorf("timed out after %dms", timeout.Milliseconds()), where)
	}
}
