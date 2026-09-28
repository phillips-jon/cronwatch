package gocron

import (
	"slices"
	"testing"
	"time"

	"github.com/go-co-op/gocron/v2"
	"github.com/jonboulle/clockwork"
)

// TestWallRunsAreGocronsOwn holds the runs the daily, weekly and monthly
// checks walk to gocron's own: a scheduler on a fake clock, set before each
// of New York's clock changes and a month end, asked for its next runs.
func TestWallRunsAreGocronsOwn(t *testing.T) {
	newYork, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	at := func(h, m, s uint) gocron.AtTimes { return gocron.NewAtTimes(gocron.NewAtTime(h, m, s)) }
	everyDay := func(time.Time) bool { return true }
	cases := []struct {
		name    string
		job     gocron.JobDefinition
		times   []hms
		matches func(time.Time) bool
	}{
		{"daily 02:30", gocron.DailyJob(1, at(2, 30, 0)), []hms{{2, 30, 0}}, everyDay},
		{"daily 01:30", gocron.DailyJob(1, at(1, 30, 0)), []hms{{1, 30, 0}}, everyDay},
		{"daily 02:00 and 14:00", gocron.DailyJob(1, gocron.NewAtTimes(gocron.NewAtTime(2, 0, 0), gocron.NewAtTime(14, 0, 0))), []hms{{2, 0, 0}, {14, 0, 0}}, everyDay},
		{"weekly Sunday 02:15", gocron.WeeklyJob(1, gocron.NewWeekdays(time.Sunday), at(2, 15, 0)), []hms{{2, 15, 0}},
			func(t time.Time) bool { return t.Weekday() == time.Sunday }},
		{"monthly last day 23:00", gocron.MonthlyJob(1, gocron.NewDaysOfTheMonth(-1), at(23, 0, 0)), []hms{{23, 0, 0}},
			func(t time.Time) bool { return t.AddDate(0, 0, 1).Day() == 1 }},
	}
	for _, c := range cases {
		for _, from := range []time.Time{
			time.Date(2026, 3, 5, 12, 0, 0, 0, newYork),
			time.Date(2026, 10, 29, 12, 0, 0, 0, newYork),
			time.Date(2026, 1, 20, 12, 0, 0, 0, newYork),
		} {
			s, err := gocron.NewScheduler(gocron.WithLocation(newYork), gocron.WithClock(clockwork.NewFakeClockAt(from)))
			if err != nil {
				t.Fatal(err)
			}
			job, err := s.NewJob(c.job, gocron.NewTask(func() {}))
			if err != nil {
				t.Fatal(err)
			}
			s.Start()
			var next []time.Time
			for deadline := time.Now().Add(5 * time.Second); len(next) < 6 && time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
				next, _ = job.NextRuns(6)
			}
			_ = s.Shutdown()
			if len(next) < 6 {
				t.Fatalf("%s: gocron gave %d runs", c.name, len(next))
			}
			var want []int64
			for _, n := range next {
				want = append(want, n.UnixMilli())
			}
			end := want[len(want)-1]
			got, err := wallRuns(newYork, c.times, c.matches)(from.UnixMilli(), &end)
			if err != nil {
				t.Fatal(err)
			}
			// wallRuns starts with the run at or before its start.
			got = slices.DeleteFunc(got, func(ms int64) bool { return ms <= from.UnixMilli() })
			// and ends with the first past its end.
			got = got[:min(len(got), len(want))]
			if !slices.Equal(got, want) {
				t.Errorf("%s from %s:\n got %v\nwant %v", c.name, from, stamps(got, newYork), stamps(want, newYork))
			}
		}
	}
}

func stamps(list []int64, loc *time.Location) []string {
	var out []string
	for _, ms := range list {
		out = append(out, time.UnixMilli(ms).In(loc).Format("2006-01-02 15:04:05 MST"))
	}
	return out
}
