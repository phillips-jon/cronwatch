package cronwatch_test

// DiscardWhen: an attempt a queue gives back without failing (a River
// snooze, an Asynq revoke) leaves no run behind, neither a failure nor a
// success, as the PHP port takes back a released Laravel job's attempt.

import (
	"context"
	"errors"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
)

var errSnoozed = errors.New("snoozed")

func snoozed(err error) bool { return errors.Is(err, errSnoozed) }

// The audit: a run given back used to close missed at its start all the
// same, so an overdue job that snoozed had missed opened again by the next
// check, one alert per snooze. It now leaves the state as it was, as the
// PHP port's released job does.
func TestAGivenBackRunLeavesMissedOpen(t *testing.T) {
	k := newKit(t)
	job := must[*cronwatch.Job](t)(k.cw.Job("q", cronwatch.Schedule("every 1h"), cronwatch.Grace("5m")))
	ctx := context.Background()
	check(t, job.Run(ctx, ok))
	k.c.Advance(HOUR + 10*MIN)
	checkNow(t, k.cw)
	sameList(t, "missed", k.alerts.Types(), []string{"missed"})
	for i := 0; i < 3; i++ {
		k.c.Advance(MIN)
		_ = job.Run(ctx, func(context.Context, *cronwatch.JobContext) error { return errSnoozed }, cronwatch.DiscardWhen(snoozed))
		k.c.Advance(MIN)
		checkNow(t, k.cw)
	}
	sameList(t, "one missed alert, still open", k.alerts.Types(), []string{"missed"})
	check(t, job.Run(ctx, ok))
	sameList(t, "the run that was not given back recovers it", k.alerts.Types(), []string{"missed", "recovered"})
}

func TestDiscardWhenTakesTheRunBack(t *testing.T) {
	k := newKit(t)
	job := must[*cronwatch.Job](t)(k.cw.Job("q", cronwatch.FailuresBeforeAlert(2)))
	ctx := context.Background()
	attempt := func(err error) error {
		k.c.Advance(1000)
		return job.Run(ctx, func(ctx context.Context, j *cronwatch.JobContext) error {
			j.Log("attempt")
			return err
		}, cronwatch.DiscardWhen(snoozed))
	}

	// A failure, a snooze, then another failure: two in a row, so an alert.
	if err := attempt(errors.New("down")); err == nil {
		t.Error("the error was not returned")
	}
	if err := attempt(errSnoozed); !errors.Is(err, errSnoozed) {
		t.Errorf("the snooze was not returned: %v", err)
	}
	eq(t, "the snooze is not a run", len(runs(t, k.cw, "q")), 1)
	eq(t, "failures in a row kept", state(t, k.cw, "q").ConsecutiveFailures, 1)
	sameList(t, "no alert yet", k.alerts.Types(), []string{})
	_ = attempt(errors.New("down again"))
	sameList(t, "the second failure alerts", k.alerts.Types(), []string{"failed"})
	eq(t, "runs", len(runs(t, k.cw, "q")), 2)

	// A snooze does not close the alert; a success does.
	_ = attempt(errSnoozed)
	sameList(t, "still open", k.alerts.Types(), []string{"failed"})
	check(t, attempt(nil))
	sameList(t, "recovered", k.alerts.Types(), []string{"failed", "recovered"})
	eq(t, "runs", len(runs(t, k.cw, "q")), 3)
	sameList(t, "nothing reported", k.wheres(), []string{})

	// A panic is never discarded.
	func() {
		defer func() { _ = recover() }()
		_ = job.Run(ctx, func(context.Context, *cronwatch.JobContext) error { panic(errSnoozed) }, cronwatch.DiscardWhen(snoozed))
	}()
	eq(t, "a panic is a failed run", runs(t, k.cw, "q")[0].Status, cronwatch.StatusFailed)
}

// withoutDeleter is a store that cannot take a run back.
type withoutDeleter struct{ cronwatch.Store }

func TestDiscardWhenWithoutARunDeleterRecordsTheRun(t *testing.T) {
	k := newKit(t, cronwatch.WithStore(withoutDeleter{cronwatch.NewMemoryStore()}))
	job := must[*cronwatch.Job](t)(k.cw.Job("q"))
	err := job.Run(context.Background(), func(context.Context, *cronwatch.JobContext) error { return errSnoozed }, cronwatch.DiscardWhen(snoozed))
	if !errors.Is(err, errSnoozed) {
		t.Errorf("returned %v", err)
	}
	list := runs(t, k.cw, "q")
	eq(t, "recorded as it ended", list[0].Status, cronwatch.StatusFailed)
	sameList(t, "reported", k.errors.List(), []string{"discarding q: the store cannot take back a run (it is not a cronwatch.RunDeleter); recorded as it ended"})
}

func TestDiscardWhenLeavesARunACheckMarkedStuck(t *testing.T) {
	k := newKit(t)
	job := must[*cronwatch.Job](t)(k.cw.Job("q", cronwatch.Timeout(time.Minute)))
	err := job.Run(context.Background(), func(context.Context, *cronwatch.JobContext) error {
		k.c.Advance(2 * 60_000)
		checkNow(t, k.cw)
		return errSnoozed
	}, cronwatch.DiscardWhen(snoozed))
	if !errors.Is(err, errSnoozed) {
		t.Errorf("returned %v", err)
	}
	list := runs(t, k.cw, "q")
	eq(t, "left as the check marked it", list[0].Status, cronwatch.StatusTimeout)
	eq(t, "reported", len(k.errors.List()), 1)
	contains(t, "why", k.errors.List()[0], "is no longer running; left as it is")
}
