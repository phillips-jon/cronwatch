package schedule

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/schedule/cron"
)

// EarlySlackMs is how early a run may start and still count for the fire it
// was meant for.
const EarlySlackMs = 60_000

// Parsed is a schedule as parseSchedule returns it: plain data (JSValue is
// the SDK's JSON of it), with the croner expression behind a cron kept out
// of view.
type Parsed struct {
	// "cron" or "interval".
	Kind   string
	Source string
	// The IANA zone a cron is read in, "" when none was given.
	Timezone string
	// An interval's period in milliseconds.
	EveryMs int64

	cron *cron.Cron
}

// JSValue is the SDK's JSON of a parsed schedule: {kind, source, timezone}
// for a cron (timezone only when given) and {kind, source, everyMs} for an
// interval.
func (p *Parsed) JSValue() any {
	o := js.NewObject("kind", p.Kind, "source", p.Source)
	if p.Kind == "interval" {
		o.Set("everyMs", p.EveryMs)
	} else if p.Timezone != "" {
		o.Set("timezone", p.Timezone)
	}
	return o
}

var (
	cacheMu sync.Mutex
	cache   = map[string]*Parsed{}
)

// Parse is the SDK's parseSchedule: "0 2 * * *" (a cron of five or six
// fields), a nickname ("@hourly"), or "every 5m". Each (schedule, timezone)
// pair is parsed once and kept. Without a timezone a cron is read in the
// process's zone (time.Local), as crontab reads the system's; Vercel and
// GitHub Actions run their crons in UTC, so pass "UTC" for those. The
// errors are the SDK's, word for word.
//
// A zone the database does not have is refused here with the message
// croner throws for it when asked for a fire time, since the SDK reads the
// zone only then: call IsTimezone first to report a bad zone as the SDK's
// client does.
func Parse(schedule, timezone string) (*Parsed, error) {
	key := timezone + "|" + schedule
	cacheMu.Lock()
	hit := cache[key]
	cacheMu.Unlock()
	if hit != nil {
		return hit, nil
	}
	parsed, err := parse(schedule, timezone)
	if err != nil {
		return nil, err
	}
	cacheMu.Lock()
	// A long-running process parses a handful of schedules; the bound only
	// keeps one fed endless distinct schedules from growing without end.
	if len(cache) >= 1000 {
		cache = map[string]*Parsed{}
	}
	cache[key] = parsed
	cacheMu.Unlock()
	return parsed, nil
}

func parse(schedule, timezone string) (*Parsed, error) {
	text := js.Trim(schedule)
	if rest, ok := every(text); ok {
		ms, err := ParseDuration(rest, "schedule interval")
		if err != nil {
			return nil, err
		}
		if ms < 1000 {
			return nil, fmt.Errorf("schedule \"%s\" is shorter than one second", schedule)
		}
		return &Parsed{Kind: "interval", Source: text, EveryMs: int64(ms)}, nil
	}
	c, err := cron.New(text, nil)
	if err != nil {
		return nil, fmt.Errorf("schedule \"%s\" is not a cron expression or \"every <duration>\": %s", schedule, err.Error())
	}
	if timezone != "" {
		loc, err := cron.LoadZone(timezone)
		if err != nil {
			return nil, errors.New("CronDate: Failed to convert date to timezone '" + timezone + "'. This may happen with invalid timezone names or dates. " +
				"Original error: toTZ: Invalid timezone '" + timezone + "' or date. Please provide a valid IANA timezone (e.g., 'America/New_York', 'Europe/Stockholm'). " +
				"Original error: Invalid time zone specified: " + timezone)
		}
		if c, err = cron.New(text, loc); err != nil {
			return nil, err
		}
	}
	return &Parsed{Kind: "cron", Source: text, Timezone: timezone, cron: c}, nil
}

// every is /^every\s+(.+)$/i: "every" in any ASCII case, whitespace, and
// the rest, which must hold no line terminator (JavaScript's "." matches
// none).
func every(text string) (string, bool) {
	if len(text) < 5 || !strings.EqualFold(text[:5], "every") || strings.ContainsFunc(text[:5], func(r rune) bool { return r > 127 }) {
		return "", false
	}
	rest := text[5:]
	trimmed := strings.TrimLeftFunc(rest, js.IsSpace)
	if trimmed == rest || trimmed == "" || strings.ContainsAny(trimmed, "\n\r  ") {
		return "", false
	}
	return trimmed, true
}

// fireAfter is the first fire strictly after from, or false when the cron
// never fires again. Croner answers with times in the past when asked from
// inside the hour that repeats when clocks go back, so its answers are
// filtered, and a stretch of nothing but past times is stepped over an
// hour at a time.
func fireAfter(p *Parsed, from int64) (int64, bool) {
	probe := from
	for attempt := 0; attempt < 4; attempt++ {
		runs := p.cron.NextRuns(8, probe)
		if len(runs) == 0 {
			return 0, false
		}
		for _, t := range runs {
			if t > from {
				return t, true
			}
		}
		probe += 3_600_000
	}
	return 0, false
}

// FiresBetween is every fire of a cron strictly after from and at or
// before to, ascending, or false when there are more than limit. It asks
// for fires in batches, far cheaper than one NextFire each, and drops any
// that do not move forward (see fireAfter).
func FiresBetween(p *Parsed, from, to int64, limit int) ([]int64, bool) {
	out := []int64{}
	probe, last := from, from
	for guard := 0; guard < 1000; guard++ {
		batch := p.cron.NextRuns(min(limit+1-len(out), 24), probe)
		if len(batch) == 0 {
			return out, true
		}
		for _, t := range batch {
			if t <= last {
				continue
			}
			if t > to {
				return out, true
			}
			out = append(out, t)
			last = t
			if len(out) > limit {
				return nil, false
			}
		}
		end := batch[len(batch)-1]
		if end > probe {
			probe = end
		} else {
			probe += 3_600_000
		}
	}
	return out, true
}

// NextFire is the next time the schedule fires strictly after from; for an
// interval, counted from the last run when there is one. False when a cron
// never fires again.
func NextFire(p *Parsed, from int64, lastRunAt *int64) (int64, bool) {
	if p.Kind == "interval" {
		base := from
		if lastRunAt != nil {
			base = *lastRunAt
		}
		return base + p.EveryMs, true
	}
	return fireAfter(p, from)
}

// Expectation is when the next run is due, and when it is missed.
type Expectation struct {
	DueAt int64
	// Missed once now passes this.
	Deadline float64
}

// Expect is the SDK's expectation(): when the schedule next wants a run,
// given the last one. For a cron that is the first fire the last run does
// not already cover; with no run yet, the first fire at or after
// registration. For an interval it is the last run's start (or
// registration) plus the interval. False for a cron that never fires again.
//
// Counting forward from the last run, rather than back from now, is what
// lets a job whose period is shorter than its grace be missed at all, and
// it works for a cron that fires once a year or less.
func Expect(p *Parsed, lastRunAt *int64, registeredAt int64, graceMs float64) (Expectation, bool) {
	var due int64
	var ok bool
	switch {
	case p.Kind == "interval":
		base := registeredAt
		if lastRunAt != nil {
			base = *lastRunAt
		}
		due, ok = base+p.EveryMs, true
	case lastRunAt == nil:
		due, ok = fireAfter(p, registeredAt-1)
	default:
		due, ok = dueAfterRun(p, *lastRunAt)
	}
	if !ok {
		return Expectation{}, false
	}
	return Expectation{DueAt: due, Deadline: float64(due) + graceMs}, true
}

// dueAfterRun is the first fire that a run starting at startedAt does not
// cover.
func dueAfterRun(p *Parsed, startedAt int64) (int64, bool) {
	// A fire at or before the start is covered by the run itself.
	next, ok := fireAfter(p, startedAt)
	if !ok {
		return 0, false
	}
	following, hasFollowing := fireAfter(p, next)
	var f *int64
	if hasFollowing {
		f = &following
	}
	if RunCovers(startedAt, next, f) || inSpringForwardGap(p, startedAt, next) {
		return following, hasFollowing
	}
	return next, true
}

// RunCovers is whether a run starting at startedAt covers the fire at
// dueAt. A minute of slack before the tick absorbs schedulers that fire a
// touch early. When the fire after dueAt is known, the slack is at most
// half the gap between the two, so one run of an every-minute cron never
// covers two fires.
func RunCovers(startedAt, dueAt int64, followingAt *int64) bool {
	slack := int64(EarlySlackMs)
	if followingAt != nil {
		slack = min(EarlySlackMs, js.FloorDiv(*followingAt-dueAt, 2))
	}
	return startedAt >= dueAt-slack
}

// inSpringForwardGap: on the night clocks spring forward, a fire whose local
// time does not exist (02:30 when 02:00 jumps to 03:00) is moved by croner
// to the same distance past the jump (03:30), while vixie cron runs it at
// the jump itself (03:00). A run that starts at or after the jump, and
// before the first fire after it when that fire lies within one gap of it,
// is taken to cover that fire, so neither scheduler's run is reported as
// missed. A cron that really fires at 03:30 that night is treated the same
// way, which only matters if it also ran early by up to an hour.
func inSpringForwardGap(p *Parsed, startedAt, fireAt int64) bool {
	const lookback = 3 * 3_600_000
	loc := zoneOf(p)
	after := utcOffset(fireAt, loc)
	before := utcOffset(fireAt-lookback, loc)
	gap := after - before
	if gap <= 0 {
		return false
	}
	// Find the jump: the first minute in the window with the later offset.
	lo, hi := fireAt-lookback, fireAt
	for hi-lo > 60_000 {
		mid := lo + (hi-lo)/2
		if utcOffset(mid, loc) == after {
			hi = mid
		} else {
			lo = mid
		}
	}
	jumpAt := js.FloorDiv(hi, 60_000) * 60_000
	if fireAt-jumpAt >= gap || startedAt < jumpAt-EarlySlackMs || startedAt >= fireAt {
		return false
	}
	// Only the first fire after the jump can be a moved one; a cron that
	// also fires at the jump (every 10 minutes, say) was not moved at all.
	first, ok := fireAfter(p, jumpAt-1)
	return ok && first == fireAt
}

func zoneOf(p *Parsed) *time.Location {
	loc, err := cron.LoadZone(p.Timezone)
	if err != nil {
		return time.UTC
	}
	return loc
}

// utcOffset is the milliseconds the zone's wall clock is ahead of UTC at at.
func utcOffset(at int64, loc *time.Location) int64 {
	return cron.Offset(js.FloorDiv(at, 1000), loc) * 1000
}

// IsTimezone reports whether new Intl.DateTimeFormat("en-US", { timeZone })
// accepts the name: an IANA zone, matched without regard to case, "UTC",
// or a fixed offset such as "+05:30".
func IsTimezone(name string) bool {
	if name == "" {
		return false
	}
	_, err := cron.LoadZone(name)
	return err == nil
}

// LoadZone is the zone an IANA name names, matched without regard to case
// as Intl matches it; "" is the process's own zone, time.Local.
func LoadZone(name string) (*time.Location, error) {
	loc, err := cron.LoadZone(name)
	if err != nil {
		return nil, fmt.Errorf("timezone \"%s\" is not an IANA timezone", name)
	}
	return loc, nil
}
