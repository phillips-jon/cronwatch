package cronwatch_test

// correctness.test.ts. The autumn fire times are internal/schedule's tests;
// the routes case waits for phase 3; "a failed alert names the error once"
// is in evaluate_internal_test.go.

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
)

func TestAnAlertStillBeingSentCannotOverwriteWhatARunDid(t *testing.T) {
	var mu sync.Mutex
	var sent []string
	gate := make(chan struct{})
	// The missed alert takes a while (a slow webhook, or triage); everything else is instant.
	slow := channel("slow-for-missed", func(a cronwatch.Alert) error {
		if a.Type == cronwatch.AlertMissed {
			<-gate
		}
		mu.Lock()
		defer mu.Unlock()
		sent = append(sent, string(a.Type))
		return nil
	})
	k := newKit(t, cronwatch.WithAlerts(slow))
	job := k.cw.MustJob("sync", cronwatch.Schedule("every 5m"), cronwatch.Grace("1m"))
	check(t, job.Run(bg, ok))
	k.c.Advance(7 * MIN)
	done := make(chan struct{})
	go func() { defer close(done); checkNow(t, k.cw) }()
	waitFor(t, "the missed alert to be sent", func() bool {
		s := state(t, k.cw, "sync")
		return s != nil && len(s.Open) == 1
	})
	time.Sleep(20 * time.Millisecond)
	check(t, job.Run(bg, ok)) // the job turns up while the missed alert is in flight
	close(gate)
	<-done
	mu.Lock()
	sameList(t, "sent", sent, []string{"recovered", "missed"})
	mu.Unlock()
	eq(t, "missed stays closed", len(state(t, k.cw, "sync").Open), 0)
	k.c.Advance(MIN)
	check(t, job.Run(bg, ok))
	mu.Lock()
	sameList(t, "no second recovered", sent, []string{"recovered", "missed"})
	mu.Unlock()
}

func TestPruningKeepsEachJobsNewestRun(t *testing.T) {
	k := newKit(t, cronwatch.WithRetention("30d"))
	k.c.Set(1767225600000) // 2026-01-01
	monthly := k.cw.MustJob("monthly", cronwatch.Schedule("0 0 1 * *"), cronwatch.Timezone("UTC"))
	check(t, monthly.Run(bg, ok))
	k.c.Set(1769860800000) // 2026-01-31 12:00
	first := checkNow(t, k.cw)
	eq(t, "pruned", first.Pruned, 0)
	k.c.Advance(2 * HOUR)
	checkNow(t, k.cw)
	sameList(t, "alerts", k.alerts.Types(), []string{})
	eq(t, "health", summary(t, k.cw, "monthly").Health, cronwatch.HealthHealthy)
}

func TestAnExpectRegexpGivesTheSameAnswerEveryRun(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("g", cronwatch.ExpectMatch(regexp.MustCompile(`done`)))
	for i := 0; i < 4; i++ {
		check(t, job.Run(bg, func(_ context.Context, j *cronwatch.JobContext) error { j.Log("done"); return nil }))
	}
	for _, r := range runs(t, k.cw, "g") {
		eq(t, "status", r.Status, cronwatch.StatusOK)
	}
	eq(t, "stored", k.cw.DefinedJobs()[0].Expect(), "matches /done/")
}

func TestExpectSeesALineLoggedEarly(t *testing.T) {
	k := newKit(t)
	check(t, k.cw.Run(bg, "report", func(_ context.Context, j *cronwatch.JobContext) error {
		j.Log("Report written: /tmp/r.pdf")
		for i := 0; i < 3000; i++ {
			j.Log(fmt.Sprintf("row %d %s", i, strings.Repeat("x", 40)))
		}
		return nil
	}, cronwatch.Expect("Report written")))
	run := runs(t, k.cw, "report")[0]
	eq(t, "status", run.Status, cronwatch.StatusOK)
	if strings.Contains(*run.Output, "Report written") {
		t.Error("the stored output is still only the tail")
	}
}

func TestAnIntervalJobWhoseRunIsGoingIsBusyNotMissed(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("long", cronwatch.Schedule("every 5m"), cronwatch.Grace("2m"))
	finish := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = job.Run(bg, func(context.Context, *cronwatch.JobContext) error { <-finish; return nil })
	}()
	waitFor(t, "the run to start", running(t, k.cw, "long"))
	k.c.Advance(8 * MIN)
	checkNow(t, k.cw)
	sameList(t, "busy", k.alerts.Types(), []string{})
	close(finish)
	<-done
	sameList(t, "and no recovered for a miss that never was", k.alerts.Types(), []string{})
}

func TestARunACheckMarkedStuckThatThenFailsCountsOnce(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("slowpoke", cronwatch.Timeout("1m"), cronwatch.FailuresBeforeAlert(2))
	fail := make(chan struct{})
	result := make(chan error)
	go func() {
		result <- job.Run(bg, func(context.Context, *cronwatch.JobContext) error { <-fail; return errors.New("gave up") })
	}()
	waitFor(t, "the run to start", running(t, k.cw, "slowpoke"))
	k.c.Advance(2 * MIN)
	checkNow(t, k.cw)
	eq(t, "counted", state(t, k.cw, "slowpoke").ConsecutiveFailures, 1)
	close(fail)
	if <-result == nil {
		t.Fatal("the job's error")
	}
	eq(t, "counted once", state(t, k.cw, "slowpoke").ConsecutiveFailures, 1)
	sameList(t, "one run is one failure, under the threshold of two", k.alerts.Types(), []string{})
	eq(t, "the run keeps its real error", strings.Split(*runs(t, k.cw, "slowpoke")[0].Error, "\n")[0], "Error: gave up")
}

func TestALateSuccessAfterAStuckMarkRecovers(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("late", cronwatch.Timeout("30s"))
	finish := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = job.Run(bg, func(context.Context, *cronwatch.JobContext) error { <-finish; return nil })
	}()
	waitFor(t, "the run to start", running(t, k.cw, "late"))
	k.c.Advance(MIN)
	r := checkNow(t, k.cw)
	if !strings.HasPrefix(*r.Alerts[0].Run.Error, "Still running after 30s;") {
		t.Error(*r.Alerts[0].Run.Error)
	}
	close(finish)
	<-done
	sameList(t, "alerts", k.alerts.Types(), []string{"stuck", "recovered"})
}
