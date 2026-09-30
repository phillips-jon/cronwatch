package cronwatch

// Sending alerts: channels, triage, and the queue of alerts no channel
// accepted, retried once per check (client.ts dispatch, retryUndelivered,
// recordDelivery, deliver, addTriage).

import (
	"context"
	"errors"
	"fmt"
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

// held is the alerts written with the state that opened their conditions,
// and how many older ones the queue let go.
type held struct {
	alerts  []Alert
	dropped int
}

// outbox is an evaluation as it is written: its drafts composed into alerts
// and held in the same state (holdAlerts), so the write that opens a
// condition also keeps its alerts, and a process that stops before sending
// them does not lose them. Called inside updateState, so it only computes.
func (c *Client) outbox(state JobState, drafts []alertDraft, def Definition, now int64) (JobState, held) {
	alerts := make([]Alert, len(drafts))
	for i, d := range drafts {
		alerts[i] = composeAlert(d, def, now)
	}
	next, dropped := holdAlerts(state, alerts, c.now()+sendLeaseMs, c.deferDelivery)
	return next, held{alerts, dropped}
}

// reportDropped reports alerts let go because a job's queue was full.
func (c *Client) reportDropped(name string, dropped int) {
	if dropped <= 0 {
		return
	}
	plural := "s"
	if dropped == 1 {
		plural = ""
	}
	c.report(fmt.Errorf("%d undelivered alert%s for %s dropped: only the newest %d are kept for retry", dropped, plural, name, maxUndelivered), "alert queue for "+name)
}

// dispatch triages and sends each alert the outbox holds (see outbox). The
// state, with the alerts in it, was saved before this, so a slow channel
// holds up nothing else; afterwards only the delivery fields are written
// back, onto a fresh read of the state, and the alerts leave Sending.
// Triage is made here, never stored with the held alert: the write that
// opens a condition cannot wait for it, and a retry triages an alert that
// has none. With DeliverAtCheck the alerts were queued for a check
// elsewhere instead.
func (c *Client) dispatch(ctx context.Context, name string, alerts []Alert, now int64) []Alert {
	if len(alerts) == 0 || c.deferDelivery {
		return alerts
	}
	sent := make([]Alert, len(alerts))
	var delivered, failed []Alert
	for i, alert := range alerts {
		alert = alert.clone()
		if c.triage != nil && alert.Type != AlertRecovered {
			c.addTriage(ctx, &alert, triageTimeout)
		}
		if c.deliver(ctx, alert) {
			delivered = append(delivered, alert)
		} else {
			failed = append(failed, alert)
		}
		sent[i] = alert
	}
	c.recordDelivery(ctx, name, delivered, failed, nil, now)
	return sent
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
// failed ones for the next check, taking them all out of Sending
// (recordSent). A failed alert replaces its stored copy, so a triage made
// on this attempt is kept. LastAlertAt moves only on a delivery. When this
// write fails, alerts still in Sending are retried once their lease runs
// out.
func (c *Client) recordDelivery(ctx context.Context, name string, delivered, failed, stale []Alert, now int64) {
	_, trimmed, err := updateState(ctx, c, name, func(previous JobState) (JobState, int, error) {
		state, dropped := recordSent(normalizeState(&previous, name), delivered, failed, stale, now)
		return state, dropped, nil
	})
	if err != nil {
		c.report(err, "recording alert delivery for "+name)
		return
	}
	c.reportDropped(name, trimmed)
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
	stalled := c.channelBusy[i] > 0
	c.busyMu.Unlock()
	if stalled {
		c.report(errors.New("still sending an earlier alert, past its timeout"), where)
		return false
	}
	sendCtx, cancel := context.WithTimeout(storeCtx(ctx), channelTimeout)
	defer cancel()
	done := make(chan error, 1)
	// finished and counted are this send's own, under busyMu: only a send
	// counted as stalled uncounts itself, so another send to the channel
	// that returns in time never clears a hung one's mark.
	finished, counted := false, false
	go func() {
		defer func() {
			if p := recover(); p != nil {
				done <- fmt.Errorf("panicked: %v", p)
			}
			c.busyMu.Lock()
			finished = true
			if counted {
				if c.channelBusy[i]--; c.channelBusy[i] <= 0 {
					delete(c.channelBusy, i)
				}
			}
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
			counted = true
			c.channelBusy[i]++
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
	stalled := c.triageBusy > 0
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
	// As for a channel: only a triage counted as stalled uncounts itself.
	finished, counted := false, false
	tc := TriageContext{Alert: alert.clone(), RecentRuns: recent}
	go func() {
		defer func() {
			if p := recover(); p != nil {
				done <- answer{err: fmt.Errorf("panicked: %v", p)}
			}
			c.busyMu.Lock()
			finished = true
			if counted {
				c.triageBusy--
			}
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
			counted = true
			c.triageBusy++
		}
		c.busyMu.Unlock()
		c.report(fmt.Errorf("timed out after %dms", timeout.Milliseconds()), where)
	}
}
