package bridge

// The check that a schedule converted from a scheduler's own (robfig/cron's
// SpecSchedule, gocron's cron job, River's periodic schedule, an Asynq
// cronspec) makes CronWatch expect runs exactly when the scheduler makes
// them, as the gem checks Solid Queue's and sidekiq-cron's against Fugit and
// the Python port Celery's and APScheduler's (_scheduler_check.py): the
// scheduler's own runs, from its own code, walked beside CronWatch's fires
// around every clock change in the next few years and from the start of
// each month of a sample year, so the answer does not depend on when the
// app starts.
//
// Between two runs of the scheduler, CronWatch must not want one of its
// own, or it would report it missed: a fire CronWatch has and the scheduler
// does not (a time the scheduler skips when clocks go forward, a run its
// steps drop that day) is refused unless the run before it covers it (a
// minute of early slack, or a fire moved past a spring-forward jump). Away
// from clock changes every run the scheduler makes must also be one
// CronWatch expects; near one, the scheduler may run a repeated time twice,
// which CronWatch takes as an early run.

import (
	"errors"
	"fmt"
	"time"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/schedule"
)

const (
	// How far ahead the daylight saving check looks, and how far either
	// side of each clock change it compares the scheduler's runs with
	// CronWatch's.
	horizonYears   = 5
	changeWindowMs = 2 * 86_400_000
	// Away from clock changes, sampleRuns runs from the start of each month
	// of a fixed year are compared too.
	sampleYear  = 2026
	sampleRuns  = 8
	dayMs       = 86_400_000
	stampLayout = "2006-01-02 15:04:05"
)

// SampleRuns is how many runs a Runs function gives after start when it is
// asked without an end.
const SampleRuns = sampleRuns

// Runs is a scheduler's own runs, from its own code: the one at or before
// start and every one after it up to the first past end, or SampleRuns of
// them after that first one when end is nil. Epoch milliseconds,
// ascending. An error from NeverFires says the schedule never fires again.
type Runs func(start int64, end *int64) ([]int64, error)

// ScheduleError is a scheduler's schedule that cannot be read, or cannot be
// converted exactly: the job is watched without a schedule, and the error
// reported once.
type ScheduleError struct{ Message string }

func (e *ScheduleError) Error() string { return e.Message }

// Refuse is a ScheduleError.
func Refuse(format string, args ...any) error {
	return &ScheduleError{Message: fmt.Sprintf(format, args...)}
}

type neverFires struct{ why string }

func (e *neverFires) Error() string { return e.why }

// NeverFires is what a Runs function returns for a schedule that never
// fires again.
func NeverFires(why string) error { return &neverFires{why} }

// transition is a clock change: when, and the zone's offset in seconds
// before and after it.
type transition struct{ at, before, after int64 }

// transitions are the zone's clock changes between two instants.
func transitions(loc *time.Location, startMs, endMs int64) []transition {
	var found []transition
	t := time.UnixMilli(startMs).In(loc)
	for {
		_, end := t.ZoneBounds()
		if end.IsZero() || end.UnixMilli() > endMs {
			return found
		}
		_, before := t.Zone()
		_, after := end.Zone()
		if after != before {
			found = append(found, transition{end.UnixMilli(), int64(before), int64(after)})
		}
		t = end
	}
}

func yearStart(year int) int64 {
	return time.Date(year, time.January, 1, 0, 0, 0, 0, time.UTC).UnixMilli()
}

// CheckFires refuses a cron CronWatch would not expect runs of when the
// scheduler makes them, with a ScheduleError naming where (the job, for the
// message) and scheduler (its name). expr and zone are the converted
// schedule, zone "" for the process's own. daily is a cron that names no
// day or month, which meets every clock change of one kind alike, so one of
// each is walked. now is the epoch milliseconds the horizon starts from.
func CheckFires(runs Runs, expr, zone, where, scheduler string, daily bool, now int64) error {
	parsed, err := schedule.Parse(expr, zone)
	if err != nil {
		return Refuse("%s is %s, which CronWatch cannot read: %v", where, js.Quote(expr), err)
	}
	loc, err := schedule.LoadZone(zone)
	if err != nil {
		return Refuse("%s: %v", where, err)
	}
	c := &checker{runs: runs, parsed: parsed, loc: loc, zone: zone, where: where + " is " + js.Quote(expr), scheduler: scheduler}
	if err := c.check(daily, now); err != nil {
		var never *neverFires
		if errors.As(err, &never) {
			return Refuse("%s, which never fires: %s", c.where, never.why)
		}
		return err
	}
	return nil
}

type checker struct {
	runs      Runs
	parsed    *schedule.Parsed
	loc       *time.Location
	zone      string
	where     string
	scheduler string
}

func (c *checker) check(daily bool, now int64) error {
	year := time.UnixMilli(now).UTC().Year()
	type kind struct{ wall, gap int64 }
	seen := map[kind]bool{}
	for _, change := range transitions(c.loc, yearStart(year), yearStart(year+horizonYears+1)) {
		k := kind{((change.at/1000+change.before)%86_400 + 86_400) % 86_400, change.after - change.before}
		if daily && seen[k] {
			continue
		}
		seen[k] = true
		start := change.at - changeWindowMs
		end := start + 2*changeWindowMs
		// Near a change only CronWatch's own fires can be refused, so a
		// stretch where it has none needs no walk.
		first, ok := schedule.FireAfter(c.parsed, start-1)
		if !ok || first > end {
			continue
		}
		found, err := c.runs(start, &end)
		if err != nil {
			return err
		}
		if err := c.compare(found, false); err != nil {
			return err
		}
	}

	var comparedUntil *int64
	for month := time.January; month <= time.December; month++ {
		start := time.Date(sampleYear, month, 1, 0, 0, 0, 0, time.UTC).UnixMilli()
		if comparedUntil != nil && start < *comparedUntil {
			continue // a sparse cron's earlier sample reached past this month
		}
		found, err := c.runs(start, nil)
		if err != nil {
			return err
		}
		if len(found) == 0 {
			continue
		}
		last := found[len(found)-1]
		comparedUntil = &last
		near := len(transitions(c.loc, found[0]-dayMs, last+dayMs)) > 0
		if err := c.compare(found, !near); err != nil {
			return err
		}
	}
	return nil
}

// fires are CronWatch's fires after start, up to and including end.
func (c *checker) fires(start, end int64) []int64 {
	var out []int64
	at := start
	for {
		fire, ok := schedule.FireAfter(c.parsed, at)
		if !ok || fire > end {
			return out
		}
		out = append(out, fire)
		at = fire
	}
}

// compare refuses the conversion where, after one of the scheduler's runs,
// CronWatch would want a run before the scheduler's next (or, when strict,
// where the scheduler's next is not a time CronWatch fires).
func (c *checker) compare(runs []int64, strict bool) error {
	if len(runs) < 2 {
		return nil
	}
	fires := c.fires(runs[0], runs[len(runs)-1])
	expected := map[int64]bool{}
	if strict {
		for _, f := range fires {
			expected[f] = true
		}
	}
	i := 0
	for n := 0; n+1 < len(runs); n++ {
		at, following := runs[n], runs[n+1]
		for i < len(fires) && fires[i] <= at {
			i++
		}
		own := i >= len(fires) || fires[i] < following
		unexpected := strict && !expected[following]
		if !own && !unexpected {
			continue
		}
		due, hasDue := schedule.DueAfterRun(c.parsed, at)
		if !unexpected && hasDue && due >= following {
			continue
		}
		return c.mismatch(at, following, due, hasDue)
	}
	return nil
}

func (c *checker) zoneName() string {
	if c.zone == "" {
		return "the process's zone"
	}
	return c.zone
}

func (c *checker) stamp(ms int64) string { return time.UnixMilli(ms).In(c.loc).Format(stampLayout) }

func (c *checker) mismatch(at, following, due int64, hasDue bool) error {
	var skipped *transition
	if hasDue {
		for _, change := range transitions(c.loc, due-dayMs, due+1000) {
			gap := change.after - change.before
			if gap > 0 && due < change.at+gap*1000 {
				skipped = &change
				break
			}
		}
	}
	if skipped == nil {
		expected := "nothing"
		if hasDue {
			expected = c.stamp(due)
		}
		return Refuse("%s in %s, but after a run at %s %s runs it next at %s and CronWatch would expect %s, so it cannot be converted exactly; give the job a schedule of its own",
			c.where, c.zoneName(), c.stamp(at), c.scheduler, c.stamp(following), expected)
	}
	old := time.UnixMilli(skipped.at + skipped.before*1000).UTC()
	now := time.UnixMilli(skipped.at + skipped.after*1000).UTC()
	return Refuse("%s, due at a time that does not exist in %s on %s, when clocks go forward from %s to %s. "+
		"%s does not run it then and CronWatch would expect it at %s, so it would be reported missed. Move the time outside the change, "+
		"give the schedule a zone without daylight saving (such as UTC), or give the job a schedule of its own",
		c.where, c.zoneName(), old.Format("2006-01-02"), old.Format("15:04"), now.Format("15:04"), c.scheduler, c.stamp(due))
}
