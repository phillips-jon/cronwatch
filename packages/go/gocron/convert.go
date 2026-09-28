package gocron

import (
	"fmt"
	"slices"
	"strings"
	"time"

	"cronwatch.dev/go/bridge"
	"cronwatch.dev/go/robfigcron"
	"github.com/go-co-op/gocron/v2"
	"github.com/robfig/cron/v3"
)

// Converted is a gocron schedule as CronWatch reads it.
type Converted = robfigcron.Converted

// cronParser reads a crontab as gocron does, with or without a seconds
// field (gocron's withSeconds parser takes both).
var cronParser = cron.NewParser(cron.SecondOptional | cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)

// Convert is a gocron job's schedule (Job.Schedule()) as CronWatch reads
// it, in loc, the scheduler's zone:
//
//   - CronJob: the crontab as robfig/cron (which gocron runs it with) reads
//     it, in its CRON_TZ or loc, checked against robfig/cron's own fire
//     times (robfigcron.Convert).
//   - DurationJob: "every <duration>".
//   - DailyJob, WeeklyJob and MonthlyJob with an interval of 1: a cron of
//     their times of day (when they are every combination of their hours,
//     minutes and seconds, as a cron's fields are), days of the week and
//     days of the month (the last as "L"), checked against gocron's own rule
//     for the times of a day (time.Date in loc) around every clock change.
//
// Anything else, a random duration, an interval of more than one day, week
// or month, other days from the end of the month, a one-time job, is
// refused, and the job is watched without a schedule. where names the job
// in the error.
func Convert(s gocron.JobSchedule, loc *time.Location, where string) (Converted, error) {
	if loc == nil {
		loc = time.Local
	}
	switch v := s.(type) {
	case gocron.CronJobSchedule:
		spec := strings.TrimSpace(v.Crontab)
		if !strings.HasPrefix(spec, "TZ=") && !strings.HasPrefix(spec, "CRON_TZ=") {
			spec = "CRON_TZ=" + loc.String() + " " + spec
		}
		parsed, err := cronParser.Parse(spec)
		if err != nil {
			return Converted{}, bridge.Refuse("%s has the crontab %q, which robfig/cron cannot read: %v", where, v.Crontab, err)
		}
		return robfigcron.Convert(parsed, loc, where)
	case gocron.DurationJobSchedule:
		if v.Duration < time.Second {
			return Converted{}, bridge.Refuse("%s runs every %s; CronWatch watches intervals of one second or more", where, v.Duration)
		}
		return Converted{Schedule: bridge.EveryText(v.Duration)}, nil
	case gocron.DailyJobSchedule:
		if v.Interval != 1 {
			return Converted{}, bridge.Refuse("%s runs every %d days, which a cron cannot say; give the job a schedule of its own", where, v.Interval)
		}
		return wall(where, loc, v.AtTimes, "*", "*", "*", func(time.Time) bool { return true })
	case gocron.WeeklyJobSchedule:
		if v.Interval != 1 {
			return Converted{}, bridge.Refuse("%s runs every %d weeks, which a cron cannot say; give the job a schedule of its own", where, v.Interval)
		}
		var days []int
		for _, d := range v.DaysOfWeek {
			days = append(days, int(d))
		}
		dow := bridge.FieldText(days, 0, 6)
		return wall(where, loc, v.AtTimes, "*", "*", dow, func(t time.Time) bool { return slices.Contains(v.DaysOfWeek, t.Weekday()) })
	case gocron.MonthlyJobSchedule:
		if v.Interval != 1 {
			return Converted{}, bridge.Refuse("%s runs every %d months, which a cron cannot say; give the job a schedule of its own", where, v.Interval)
		}
		last := false
		for _, d := range v.DaysFromEnd {
			if d != -1 {
				return Converted{}, bridge.Refuse("%s runs %d days from the end of the month, which CronWatch cannot read; give the job a schedule of its own", where, -d)
			}
			last = true
		}
		dom := bridge.FieldText(v.Days, 1, 31)
		switch {
		case last && dom == "":
			dom = "L"
		case last:
			dom += ",L"
		}
		return wall(where, loc, v.AtTimes, dom, "*", "*", func(t time.Time) bool {
			return slices.Contains(v.Days, t.Day()) || (last && t.AddDate(0, 0, 1).Day() == 1)
		})
	case gocron.DurationRandomJobSchedule:
		return Converted{}, bridge.Refuse("%s runs at random intervals of %s to %s, so it has no schedule CronWatch can hold it to", where, v.Min, v.Max)
	case gocron.OneTimeJobSchedule:
		return Converted{}, bridge.Refuse("%s runs once, so it has no schedule", where)
	case nil:
		return Converted{}, bridge.Refuse("%s has no schedule gocron reports", where)
	}
	return Converted{}, bridge.Refuse("%s has a %T schedule, which CronWatch cannot read", where, s)
}

// hms is a time of day.
type hms struct{ h, m, s int }

// wall is the cron for a daily, weekly or monthly job's times on the days
// matches allows, checked against gocron's rule for them.
func wall(where string, loc *time.Location, at []time.Time, dom, month, dow string, matches func(time.Time) bool) (Converted, error) {
	if len(at) == 0 {
		return Converted{}, bridge.Refuse("%s has no times of day", where)
	}
	zone, ok := bridge.Zone(loc)
	if !ok {
		return Converted{}, bridge.Refuse("%s runs in %s, which is not an IANA timezone; give the scheduler one, such as UTC or Europe/London", where, loc)
	}
	var times []hms
	var hours, minutes, seconds []int
	for _, t := range at {
		times = append(times, hms{t.Hour(), t.Minute(), t.Second()})
		hours, minutes, seconds = append(hours, t.Hour()), append(minutes, t.Minute()), append(seconds, t.Second())
	}
	slices.SortFunc(times, func(a, b hms) int { return (a.h*3600 + a.m*60 + a.s) - (b.h*3600 + b.m*60 + b.s) })
	times = slices.Compact(times)
	hours, minutes, seconds = unique(hours), unique(minutes), unique(seconds)
	if len(hours)*len(minutes)*len(seconds) != len(times) {
		return Converted{}, bridge.Refuse("%s runs at times of day a cron cannot say at once (not every combination of their hours, minutes and seconds); give the job a schedule of its own", where)
	}
	text := fmt.Sprintf("%s %s %s %s %s", bridge.FieldText(minutes, 0, 59), bridge.FieldText(hours, 0, 23), dom, month, dow)
	if s := bridge.FieldText(seconds, 0, 59); s != "0" {
		text = s + " " + text
	}
	daily := dom == "*" && month == "*" && dow == "*"
	if err := bridge.CheckFires(wallRuns(loc, times, matches), text, zone, where, "gocron", daily, time.Now().UnixMilli()); err != nil {
		return Converted{}, err
	}
	return Converted{Schedule: text, Timezone: zone}, nil
}

func unique(values []int) []int {
	out := slices.Clone(values)
	slices.Sort(out)
	return slices.Compact(out)
}

// wallRuns are gocron's runs for times of day on the days matches allows:
// each time made with time.Date in loc, as gocron makes it (a time a clock
// change skips is where time.Date puts it).
func wallRuns(loc *time.Location, times []hms, matches func(time.Time) bool) bridge.Runs {
	day := func(t time.Time) []int64 {
		if !matches(t) {
			return nil
		}
		var out []int64
		for _, at := range times {
			out = append(out, time.Date(t.Year(), t.Month(), t.Day(), at.h, at.m, at.s, 0, loc).UnixMilli())
		}
		slices.Sort(out)
		return slices.Compact(out)
	}
	midnight := func(ms int64) time.Time {
		t := time.UnixMilli(ms).In(loc)
		return time.Date(t.Year(), t.Month(), t.Day(), 12, 0, 0, 0, loc)
	}
	return func(start int64, end *int64) ([]int64, error) {
		var before int64
		found := false
		for back, t := 0, midnight(start); back <= 5*366 && !found; back, t = back+1, t.AddDate(0, 0, -1) {
			for _, run := range day(t) {
				if run <= start {
					before, found = run, true
				}
			}
		}
		if !found {
			return nil, bridge.NeverFires("gocron finds no fire time in the five years before it")
		}
		out := []int64{before}
		for t := midnight(before); ; t = t.AddDate(0, 0, 1) {
			for _, run := range day(t) {
				if run <= out[len(out)-1] {
					continue
				}
				out = append(out, run)
				if (end == nil && len(out) > bridge.SampleRuns) || (end != nil && run > *end) {
					return out, nil
				}
			}
			if t.Sub(midnight(before)) > 6*366*24*time.Hour {
				return out, nil
			}
		}
	}
}
