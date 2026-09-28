package gocron_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	cwgocron "cronwatch.dev/go/gocron"
	"cronwatch.dev/go/storetest"
	"github.com/go-co-op/gocron/v2"
	"github.com/google/uuid"
)

type kit struct {
	cw     *cronwatch.Client
	store  *cronwatch.MemoryStore
	alerts *storetest.Capture
	errors *storetest.Errors
}

func newKit(t *testing.T) *kit {
	t.Helper()
	k := &kit{store: cronwatch.NewMemoryStore(), alerts: &storetest.Capture{}, errors: &storetest.Errors{}}
	cw, err := cronwatch.New(cronwatch.WithStore(k.store), cronwatch.WithAlerts(k.alerts), cronwatch.WithErrorHandler(k.errors.Add))
	check(t, err)
	k.cw = cw
	return k
}

func (k *kit) runs(t *testing.T, name string) []cronwatch.Run {
	t.Helper()
	runs, err := k.cw.Runs(context.Background(), name, 50)
	check(t, err)
	return runs
}

func (k *kit) stored(t *testing.T, name string) cronwatch.Definition {
	t.Helper()
	if _, err := k.cw.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
	job, err := k.store.GetJob(context.Background(), name)
	if err != nil || job == nil {
		t.Fatalf("job %s is not stored (%v)", name, err)
	}
	return job.Definition
}

func load(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	check(t, err)
	return loc
}

func at(times ...[3]uint) gocron.AtTimes {
	list := make([]gocron.AtTime, len(times))
	for i, t := range times {
		list[i] = gocron.NewAtTime(t[0], t[1], t[2])
	}
	return gocron.NewAtTimes(list[0], list[1:]...)
}

// scheduleOf is the schedule gocron reports for a definition.
func scheduleOf(t *testing.T, def gocron.JobDefinition, loc *time.Location) gocron.JobSchedule {
	t.Helper()
	s, err := gocron.NewScheduler(gocron.WithLocation(loc))
	check(t, err)
	defer func() { _ = s.Shutdown() }()
	job, err := s.NewJob(def, gocron.NewTask(func() {}))
	check(t, err)
	return job.Schedule()
}

func TestConvertReadsEachDefinitionThatMapsExactly(t *testing.T) {
	utc := time.UTC
	cases := []struct {
		def      gocron.JobDefinition
		schedule string
		zone     string
	}{
		{gocron.CronJob("0 2 * * *", false), "0 2 * * *", "UTC"},
		{gocron.CronJob("*/10 * * * * *", true), "*/10 * * * * *", "UTC"},
		{gocron.CronJob("CRON_TZ=Asia/Tokyo 0 9 * * 1-5", false), "0 9 * * 1-5", "Asia/Tokyo"},
		{gocron.CronJob("@hourly", false), "0 * * * *", "UTC"},
		{gocron.DurationJob(90 * time.Minute), "every 1h30m", ""},
		{gocron.DailyJob(1, at([3]uint{2, 30, 0}, [3]uint{14, 30, 0})), "30 2,14 * * *", "UTC"},
		{gocron.DailyJob(1, at([3]uint{6, 0, 15})), "15 0 6 * * *", "UTC"},
		{gocron.WeeklyJob(1, gocron.NewWeekdays(time.Monday, time.Friday), at([3]uint{9, 0, 0})), "0 9 * * 1,5", "UTC"},
		{gocron.MonthlyJob(1, gocron.NewDaysOfTheMonth(1, 15), at([3]uint{0, 0, 0})), "0 0 1,15 * *", "UTC"},
		{gocron.MonthlyJob(1, gocron.NewDaysOfTheMonth(-1), at([3]uint{23, 0, 0})), "0 23 L * *", "UTC"},
		{gocron.MonthlyJob(1, gocron.NewDaysOfTheMonth(1, -1), at([3]uint{12, 0, 0})), "0 12 1,L * *", "UTC"},
	}
	for _, c := range cases {
		s := scheduleOf(t, c.def, utc)
		got, err := cwgocron.Convert(s, utc, "cronwatch: x")
		if err != nil {
			t.Errorf("%#v: %v", s, err)
			continue
		}
		if got.Schedule != c.schedule || got.Timezone != c.zone {
			t.Errorf("%#v: got %q in %q, want %q in %q", s, got.Schedule, got.Timezone, c.schedule, c.zone)
		}
	}
}

func TestConvertRefusesWhatDoesNotMap(t *testing.T) {
	utc := time.UTC
	cases := []struct {
		def  gocron.JobDefinition
		want string
	}{
		{gocron.DailyJob(2, at([3]uint{2, 0, 0})), "runs every 2 days, which a cron cannot say"},
		{gocron.WeeklyJob(3, gocron.NewWeekdays(time.Monday), at([3]uint{2, 0, 0})), "runs every 3 weeks"},
		{gocron.MonthlyJob(2, gocron.NewDaysOfTheMonth(1), at([3]uint{2, 0, 0})), "runs every 2 months"},
		{gocron.MonthlyJob(1, gocron.NewDaysOfTheMonth(-2), at([3]uint{2, 0, 0})), "runs 2 days from the end of the month"},
		{gocron.DailyJob(1, at([3]uint{2, 0, 0}, [3]uint{14, 30, 0})), "times of day a cron cannot say at once"},
		{gocron.DurationRandomJob(time.Minute, time.Hour), "runs at random intervals of 1m0s to 1h0m0s"},
		{gocron.OneTimeJob(gocron.OneTimeJobStartDateTime(time.Now().Add(time.Hour))), "runs once, so it has no schedule"},
	}
	for _, c := range cases {
		_, err := cwgocron.Convert(scheduleOf(t, c.def, utc), utc, "cronwatch: x")
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("want %q, got %v", c.want, err)
		}
	}
	// A cron job at a time daylight saving skips: robfig/cron, which gocron
	// runs it with, skips the run.
	newYork := load(t, "America/New_York")
	_, err := cwgocron.Convert(scheduleOf(t, gocron.CronJob("30 2 * * *", false), newYork), newYork, "cronwatch: x")
	if err == nil || !strings.Contains(err.Error(), "due at a time that does not exist in America/New_York") {
		t.Errorf("a cron job in the gap: %v", err)
	}
	// A daily job there: gocron runs it an hour early that night
	// (time.Date puts 02:30 at 01:30 EST), where croner moves it past the jump.
	_, err = cwgocron.Convert(scheduleOf(t, gocron.DailyJob(1, at([3]uint{2, 30, 0})), newYork), newYork, "cronwatch: x")
	if err == nil || !strings.Contains(err.Error(), "due at a time that does not exist in America/New_York on 2026-03-08") {
		t.Errorf("a daily job in the gap: %v", err)
	}
	// Outside the gap, and in the hour that repeats, the zone converts.
	for _, hour := range []uint{1, 4} {
		got, err := cwgocron.Convert(scheduleOf(t, gocron.DailyJob(1, at([3]uint{hour, 30, 0})), newYork), newYork, "cronwatch: x")
		if err != nil || got.Schedule != fmt.Sprintf("30 %d * * *", hour) || got.Timezone != "America/New_York" {
			t.Errorf("daily at %d:30 in New York: %v %v", hour, got, err)
		}
	}
}

func NightlyReport() {}

func TestJobsAreDeclaredAndRunsRecorded(t *testing.T) {
	t.Setenv("CRONWATCH_APP_ID", "billing")
	k := newKit(t)
	w := cwgocron.New(k.cw, cwgocron.Options{
		Defaults: []cronwatch.JobOption{cronwatch.Grace("5m")},
		Jobs:     map[string][]cronwatch.JobOption{"gocron_test.NightlyReport": {cronwatch.Timeout("2h")}},
		Exclude:  []string{"left-out"},
	})
	s, err := gocron.NewScheduler(w.Option(), gocron.WithLocation(time.UTC))
	check(t, err)
	defer func() { _ = s.Shutdown() }()
	newJob := func(def gocron.JobDefinition, task any, options ...gocron.JobOption) gocron.Job {
		t.Helper()
		job, err := s.NewJob(def, gocron.NewTask(task), options...)
		check(t, err)
		return job
	}
	newJob(gocron.CronJob("0 2 * * *", false), NightlyReport)
	immediately := gocron.WithStartAt(gocron.WithStartImmediately())
	newJob(gocron.DurationJob(time.Hour), func() {}, gocron.WithName("hourly"), immediately)
	newJob(gocron.DurationJob(time.Hour), func() error { return errors.New("disk full") }, gocron.WithName("fails"), immediately)
	newJob(gocron.DurationJob(time.Hour), func() {}, gocron.WithName("left-out"), immediately)
	unnamed := newJob(gocron.DurationJob(time.Hour), func() {})
	s.Start()
	waitFor(t, "the runs", func() bool {
		hourly, fails := k.runs(t, "hourly"), k.runs(t, "fails")
		return len(hourly) > 0 && hourly[0].Status != cronwatch.StatusRunning && len(fails) > 0 && fails[0].Status != cronwatch.StatusRunning
	})
	w.Wait()
	check(t, w.Sync(context.Background()))

	eq(t, "nightly", string(must(k.stored(t, "gocron_test.NightlyReport").MarshalJSON())),
		`{"grace":"5m","schedule":"0 2 * * *","timezone":"UTC","timeout":"2h","tags":["gocron","gocron:billing"],"name":"gocron_test.NightlyReport"}`)
	eq(t, "hourly", k.stored(t, "hourly").Schedule(), "every 1h")
	hourly := k.runs(t, "hourly")[0]
	eq(t, "ok", hourly.Status, cronwatch.StatusOK)
	eq(t, "trigger", hourly.Trigger, cwgocron.Trigger)
	fails := k.runs(t, "fails")[0]
	eq(t, "an error fails the run", fails.Status, cronwatch.StatusFailed)
	eq(t, "with it", *fails.Error, "Error: disk full")
	eq(t, "an alert", strings.Join(k.alerts.Types(), ","), "failed")
	eq(t, "left out", len(k.runs(t, "left-out")), 0)
	errs := strings.Join(k.errors.List(), "\n")
	contains(t, "a closure is reported", errs, fmt.Sprintf("gocron job %s is a function literal", unnamed.ID()))
	contains(t, "with the fix", errs, "give it a name with gocron.WithName")

	// A job removed from the scheduler loses its schedule at the next sync.
	check(t, s.RemoveJob(k.jobID(t, s, "hourly")))
	check(t, w.Sync(context.Background()))
	gone := k.stored(t, "hourly")
	eq(t, "unscheduled", gone.Schedule(), "")
	eq(t, "said so", gone.Description(), "A scheduled task (no longer scheduled)")
}

func (k *kit) jobID(t *testing.T, s gocron.Scheduler, name string) (id [16]byte) {
	t.Helper()
	for _, job := range s.Jobs() {
		if job.Name() == name {
			return job.ID()
		}
	}
	t.Fatalf("no job %s", name)
	return
}

func TestTheSchedulersZoneIsReadOnceItStarts(t *testing.T) {
	k := newKit(t)
	tokyo := load(t, "Asia/Tokyo")
	w := cwgocron.New(k.cw, cwgocron.Options{})
	s, err := gocron.NewScheduler(w.Option(), gocron.WithLocation(tokyo))
	check(t, err)
	defer func() { _ = s.Shutdown() }()
	_, err = s.NewJob(gocron.DailyJob(1, at([3]uint{9, 0, 0})), gocron.NewTask(func() {}), gocron.WithName("morning"))
	check(t, err)
	s.Start()
	w.Wait()
	check(t, w.Sync(context.Background()))
	morning := k.stored(t, "morning")
	eq(t, "the schedule", morning.Schedule(), "0 9 * * *")
	eq(t, "in the scheduler's zone", morning.Timezone(), "Asia/Tokyo")
}

// TestAPanicFailsTheRunAndCarriesOn runs a scheduler whose job panics in a
// process of its own, since the panic carries on as it would without
// CronWatch and ends that process.
func TestAPanicFailsTheRunAndCarriesOn(t *testing.T) {
	if os.Getenv("CRONWATCH_GOCRON_PANIC") == "1" {
		cw, err := cronwatch.New(cronwatch.WithAlerts(cronwatch.ChannelFunc("print", func(_ context.Context, a cronwatch.Alert) error {
			fmt.Printf("ALERT %s %s\n", a.Type, *a.Run.Error)
			return nil
		})))
		check(t, err)
		s, err := gocron.NewScheduler(cwgocron.Watch(cw, cwgocron.Options{}))
		check(t, err)
		_, err = s.NewJob(gocron.DurationJob(time.Hour), gocron.NewTask(func() { panic("boom") }), gocron.WithName("panics"),
			gocron.WithStartAt(gocron.WithStartImmediately()))
		check(t, err)
		s.Start()
		time.Sleep(5 * time.Second)
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestAPanicFailsTheRunAndCarriesOn$")
	cmd.Env = append(os.Environ(), "CRONWATCH_GOCRON_PANIC=1")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("the process did not end with the panic:\n%s", out)
	}
	contains(t, "recorded and alerted", string(out), "ALERT failed Panic: boom")
	contains(t, "then panicked", string(out), "panic: boom")
}

// The audit: a scheduler shut down answers Jobs() with nil, which a sync
// took for every job gone, taking each schedule out of the store.
func TestASyncAfterShutdownUnschedulesNothing(t *testing.T) {
	k := newKit(t)
	w := cwgocron.New(k.cw, cwgocron.Options{})
	s, err := gocron.NewScheduler(w.Option(), gocron.WithLocation(time.UTC))
	check(t, err)
	_, err = s.NewJob(gocron.CronJob("0 4 * * *", false), gocron.NewTask(func() {}), gocron.WithName("early"))
	check(t, err)
	s.Start()
	w.Wait()
	check(t, w.Sync(context.Background()))
	eq(t, "scheduled", k.stored(t, "early").Schedule(), "0 4 * * *")
	check(t, s.Shutdown())
	check(t, w.Sync(context.Background()))
	eq(t, "still scheduled", k.stored(t, "early").Schedule(), "0 4 * * *")
}

// The audit: a job with a panic listener of its own (which replaces
// CronWatch's) left its run running, to be reported stuck, and the next
// end of that job was paired with it.
func TestAPanicAJobsOwnListenerTookFailsTheRun(t *testing.T) {
	k := newKit(t)
	w := cwgocron.New(k.cw, cwgocron.Options{})
	s, err := gocron.NewScheduler(w.Option(), gocron.WithLocation(time.UTC))
	check(t, err)
	defer func() { _ = s.Shutdown() }()
	_, err = s.NewJob(gocron.DurationJob(time.Hour), gocron.NewTask(func() { panic("boom") }), gocron.WithName("panics"),
		gocron.WithStartAt(gocron.WithStartImmediately()),
		gocron.WithEventListeners(gocron.AfterJobRunsWithPanic(func(uuid.UUID, string, any) {})))
	check(t, err)
	s.Start()
	waitFor(t, "the run to end", func() bool {
		runs := k.runs(t, "panics")
		return len(runs) > 0 && runs[0].Status != cronwatch.StatusRunning
	})
	run := k.runs(t, "panics")[0]
	eq(t, "failed", run.Status, cronwatch.StatusFailed)
	contains(t, "with the panic", *run.Error, "boom")
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func check(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func must(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

func eq[T comparable](t *testing.T, what string, got, want T) {
	t.Helper()
	if got != want {
		t.Errorf("%s: got %v, want %v", what, got, want)
	}
}

func contains(t *testing.T, what, got, want string) {
	t.Helper()
	if !strings.Contains(got, want) {
		t.Errorf("%s: %q is not in %q", what, want, got)
	}
}
