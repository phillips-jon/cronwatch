package robfigcron

import (
	"fmt"
	"sync"
	"time"

	"cronwatch.dev/go/bridge"
	"github.com/robfig/cron/v3"
)

// starBit is robfig/cron's mark on a field written "*" or "?" (its own
// unexported constant): a day of the month or of the week holding it makes
// the two days match together, rather than either.
const starBit = 1 << 63

// Converted is a robfig/cron schedule as CronWatch reads it.
type Converted struct {
	// Schedule is the cron expression or "every <interval>".
	Schedule string
	// Timezone is the IANA zone a cron is read in, "" for the process's own.
	Timezone string
}

var (
	convertedMu sync.Mutex
	converted   = map[string]Converted{}
)

// Convert is a robfig/cron schedule as CronWatch reads it: a SpecSchedule
// becomes the cron expression croner reads, written from the values each
// field matches (a sixth field for seconds when they are not just 0; a day
// of the month or week written as every value, which robfig/cron matches
// with either day, as every day), in the schedule's zone, else loc (the
// cron's Location, which robfig/cron reads a schedule without a zone in);
// a ConstantDelaySchedule (@every) becomes "every <interval>". Each cron is checked against
// robfig/cron's own Next around every clock change in the next five years
// and through a sample year (bridge.CheckFires), and anything CronWatch
// would expect at other times is refused, as is a schedule of any other
// type. where names the entry in the error.
func Convert(s cron.Schedule, loc *time.Location, where string) (Converted, error) {
	switch spec := s.(type) {
	case cron.ConstantDelaySchedule:
		return Converted{Schedule: bridge.EveryText(spec.Delay)}, nil
	case *cron.ConstantDelaySchedule:
		return Converted{Schedule: bridge.EveryText(spec.Delay)}, nil
	case *cron.SpecSchedule:
		return convertSpec(spec, loc, where)
	case nil:
		return Converted{}, bridge.Refuse("%s has no schedule", where)
	}
	return Converted{}, bridge.Refuse("%s has a %T schedule, which CronWatch cannot read; give the job a schedule of its own", where, s)
}

func convertSpec(spec *cron.SpecSchedule, loc *time.Location, where string) (Converted, error) {
	// robfig/cron reads a schedule without a zone of its own in the time it
	// is asked from, which the cron gives in its Location.
	in := spec.Location
	if in == nil || in == time.Local {
		in = loc
	}
	if in == nil {
		in = time.Local
	}
	zone, ok := bridge.Zone(in)
	if !ok {
		return Converted{}, bridge.Refuse("%s is read in %s, which is not an IANA timezone; give the cron one, such as UTC or Europe/London", where, in)
	}
	text, daily := specText(spec)
	key := text + "\x00" + zone + "\x00" + in.String()
	convertedMu.Lock()
	hit, cached := converted[key]
	convertedMu.Unlock()
	if cached {
		return hit, nil
	}
	if err := bridge.CheckFires(runs(spec, in), text, zone, where, "robfig/cron", daily, time.Now().UnixMilli()); err != nil {
		return Converted{}, err
	}
	made := Converted{Schedule: text, Timezone: zone}
	convertedMu.Lock()
	converted[key] = made
	convertedMu.Unlock()
	return made, nil
}

// values are the numbers a field's bits hold from lo to hi.
func values(bits uint64, lo, hi int) []int {
	var out []int
	for v := lo; v <= hi; v++ {
		if bits&(1<<uint(v)) != 0 {
			out = append(out, v)
		}
	}
	return out
}

// specText is the cron croner reads for a SpecSchedule's bits, and whether
// it names no day or month.
func specText(spec *cron.SpecSchedule) (string, bool) {
	second := bridge.FieldText(values(spec.Second, 0, 59), 0, 59)
	minute := bridge.FieldText(values(spec.Minute, 0, 59), 0, 59)
	hour := bridge.FieldText(values(spec.Hour, 0, 23), 0, 23)
	dom := bridge.FieldText(values(spec.Dom, 1, 31), 1, 31)
	month := bridge.FieldText(values(spec.Month, 1, 12), 1, 12)
	dow := bridge.FieldText(values(spec.Dow, 0, 6), 0, 6)
	// robfig/cron matches both days when one was written "*" or "?" (every
	// value, marked), which croner reads the same; otherwise either, as
	// croner does, so a day written as every value ("1-31") makes it every
	// day.
	if spec.Dom&starBit == 0 && spec.Dow&starBit == 0 && (dom == "*" || dow == "*") {
		dom, dow = "*", "*"
	}
	daily := dom == "*" && month == "*" && dow == "*"
	five := fmt.Sprintf("%s %s %s %s %s", minute, hour, dom, month, dow)
	if second == "0" {
		return five, daily
	}
	return second + " " + five, daily
}

// runs are robfig/cron's own fire times for a schedule read in loc.
func runs(s cron.Schedule, loc *time.Location) bridge.Runs {
	at := func(ms int64) time.Time { return time.UnixMilli(ms).In(loc) }
	return func(start int64, end *int64) ([]int64, error) {
		var before time.Time
		for _, lookback := range []int64{3_600_000, 86_400_000, 8 * 86_400_000, 32 * 86_400_000, 367 * 86_400_000, 5 * 366 * 86_400_000} {
			found := s.Next(at(start - lookback))
			for !found.IsZero() && found.UnixMilli() <= start {
				before = found
				found = s.Next(found)
			}
			if !before.IsZero() {
				break
			}
		}
		if before.IsZero() {
			return nil, bridge.NeverFires("robfig/cron finds no fire time in the five years before it")
		}
		out := []int64{before.UnixMilli()}
		current := before
		for {
			current = s.Next(current)
			if current.IsZero() {
				break
			}
			out = append(out, current.UnixMilli())
			if (end == nil && len(out) > bridge.SampleRuns) || (end != nil && current.UnixMilli() > *end) {
				break
			}
		}
		return out, nil
	}
}
