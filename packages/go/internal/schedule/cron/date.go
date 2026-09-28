package cron

import (
	"time"

	"cronwatch.dev/go/internal/js"
)

var daysInMonth = [12]int64{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

// date is croner's CronDate: a wall-clock time whose fields are moved
// forward to the next match, a field at a time, spilling into the next
// month or year as croner does. Month is 0 based.
type date struct {
	loc                                            *time.Location
	year, month, day, hour, minute, second, millis int64
}

// A step of the walk: the field, the field above it, and the offset from a
// field value to its pattern index (croner's fieldOrder).
type step struct {
	field, above int // indexes into fields()
	k            kind
	offset       int64
}

const (
	fYear = iota
	fMonth
	fDay
	fHour
	fMinute
	fSecond
)

var order = []step{
	{fMonth, fYear, kMonth, 0},
	{fDay, fMonth, kDay, -1},
	{fHour, fDay, kHour, 0},
	{fMinute, fHour, kMinute, 0},
	{fSecond, fMinute, kSecond, 0},
}

func (d *date) ref(f int) *int64 {
	switch f {
	case fYear:
		return &d.year
	case fMonth:
		return &d.month
	case fDay:
		return &d.day
	case fHour:
		return &d.hour
	case fMinute:
		return &d.minute
	}
	return &d.second
}

// dateFromMs is new CronDate(new Date(at), tz).
func dateFromMs(at int64, loc *time.Location) *date {
	sec := js.FloorDiv(at, 1000)
	w := wallAt(sec, loc)
	return &date{loc: loc, year: w[0], month: w[1] - 1, day: w[2], hour: w[3], minute: w[4], second: w[5], millis: at - sec*1000}
}

// lastDayOfMonth is croner's getLastDayOfMonth, month 0 based; ok is false
// for a month outside 0 to 11 (croner's undefined).
func lastDayOfMonth(year, month int64) (int64, bool) {
	if month != 1 {
		if month >= 0 && month < 12 {
			return daysInMonth[month], true
		}
		return 0, false
	}
	_, _, d := js.CivilFromDays(js.FloorDiv(js.DateUTC(year, month+1, 0, 0, 0, 0, 0), 86_400_000))
	return d, true
}

// weekday is new Date(Date.UTC(year, month, day)).getUTCDay(), month 0
// based and free to overflow. 0 is Sunday.
func weekday(year, month, day int64) int64 {
	return js.Mod(js.FloorDiv(js.DateUTC(year, month, day, 0, 0, 0, 0), 86_400_000)+4, 7)
}

// apply is croner's apply(): fields out of their range are carried into
// the fields above, as a Date made from them would be. It says whether it
// changed anything.
func (d *date) apply() bool {
	m := d.month
	if m > 11 || m < 0 || d.day > daysInMonth[m] || d.day < 1 ||
		d.hour > 59 || d.minute > 59 || d.second > 59 || d.hour < 0 || d.minute < 0 || d.second < 0 {
		at := js.DateUTC(d.year, d.month, d.day, d.hour, d.minute, d.second, d.millis)
		sec := js.FloorDiv(at, 1000)
		d.millis = at - sec*1000
		days := js.FloorDiv(sec, 86_400)
		rest := sec - days*86_400
		y, mo, dd := js.CivilFromDays(days)
		d.year, d.month, d.day = y, mo-1, dd
		d.hour, d.minute, d.second = rest/3600, rest%3600/60, rest%60
		return true
	}
	return false
}

func (d *date) lastWeekday(year, month int64) int64 {
	last, _ := lastDayOfMonth(year, month)
	switch weekday(year, month, last) {
	case 0:
		return last - 2
	case 6:
		return last - 1
	}
	return last
}

func (d *date) nearestWeekday(year, month, day int64) int64 {
	last, ok := lastDayOfMonth(year, month)
	if ok && day > last {
		return -1
	}
	switch weekday(year, month, day) {
	case 0:
		if ok && day == last {
			return day - 2
		}
		return day + 1
	case 6:
		if day == 1 {
			return day + 2
		}
		return day - 1
	}
	return day
}

func (d *date) isNthWeekday(year, month, day int64, bits int) bool {
	wd := weekday(year, month, day)
	count := 0
	for x := int64(1); x <= day; x++ {
		if weekday(year, month, x) == wd {
			count++
		}
	}
	if bits&anyBits != 0 && count >= 1 && count <= len(nthBits) && nthBits[count-1]&bits != 0 {
		return true
	}
	if bits&lastBit != 0 {
		last, _ := lastDayOfMonth(year, month)
		for x := day + 1; x <= last; x++ {
			if weekday(year, month, x) == wd {
				return false
			}
		}
		return true
	}
	return false
}

// findNext is croner's findNext: 1 when the field already matches, 2 when
// it was moved forward to a match, 3 when none is left in its range.
func (d *date) findNext(p *Pattern, s step) (int, error) {
	field := d.ref(s.field)
	before := *field
	table := p.table(s.k)
	size := int64(len(table))
	var last int64
	hasLast := false
	if p.lastDayOfMonth {
		last, hasLast = lastDayOfMonth(d.year, d.month)
	}
	var firstWeekday int64
	if !p.starDOW && s.k == kDay {
		firstWeekday = weekday(d.year, d.month, 1)
	}
	for u := before + s.offset; u < size; u++ {
		match := 0
		if u >= 0 {
			match = table[u]
		}
		if s.k == kDay && match == 0 {
			for c, nearest := range p.nearestWeekdays {
				if nearest != 0 {
					m := d.nearestWeekday(d.year, d.month, int64(c)-s.offset)
					if m == -1 {
						continue
					}
					if m == u-s.offset {
						match = 1
						break
					}
				}
			}
		}
		if s.k == kDay && p.lastWeekday && u-s.offset == d.lastWeekday(d.year, d.month) {
			match = 1
		}
		if s.k == kDay && p.lastDayOfMonth && hasLast && u-s.offset == last {
			match = 1
		}
		if s.k == kDay && !p.starDOW {
			bits := p.dayOfWeek[js.Mod(firstWeekday+(u-s.offset-1), 7)]
			if bits != 0 && bits&anyBits != 0 {
				if d.isNthWeekday(d.year, d.month, u-s.offset, bits) {
					bits = 1
				} else {
					bits = 0
				}
			} else if bits != 0 {
				return 0, fail("CronDate: Invalid value for dayOfWeek encountered. %d", bits)
			}
			switch {
			case p.useAndLogic:
				if match != 0 {
					match = bits
				}
			case !p.starDOM:
				if match == 0 {
					match = bits
				}
			default:
				if match != 0 {
					match = bits
				}
			}
		}
		if match != 0 {
			*field = u - s.offset
			if before != *field {
				return 2, nil
			}
			return 1, nil
		}
	}
	return 3, nil
}

// recurse is croner's recurse(), walked in a loop: each field in turn from
// the month down is moved to its next match, a field that runs out carries
// into the one above and the walk starts again from the month. Croner
// recurses a year at a time, so for a date no month has it runs out of
// stack; the loop answers nil (never) at the year croner gives up at.
func (d *date) recurse(p *Pattern) (*date, error) {
	level := 0
	const years = 10_000
	for {
		if level == 0 && !p.starYear {
			if d.year >= 0 && d.year < years && !p.hasYear(d.year) {
				found := int64(-1)
				for y := d.year + 1; y < years; y++ {
					if p.hasYear(y) {
						found = y
						break
					}
				}
				if found == -1 {
					return nil, nil
				}
				d.year, d.month, d.day = found, 0, 1
				d.hour, d.minute, d.second, d.millis = 0, 0, 0, 0
			}
			if d.year >= years {
				return nil, nil
			}
		}
		// A level below 0 counts from the end, as a negative index does in
		// the Python port and in croner's own array lookup of it.
		s := order[(level+len(order))%len(order)]
		n, err := d.findNext(p, s)
		if err != nil {
			return nil, err
		}
		if n > 1 {
			for i := level + 1; i < len(order); i++ {
				f := order[(i+len(order))%len(order)]
				*d.ref(f.field) = -f.offset
			}
			if n == 3 {
				*d.ref(s.above)++
				*d.ref(s.field) = -s.offset
				d.apply()
				if level == 0 && !p.starYear {
					for d.year >= 0 && d.year < years && !p.hasYear(d.year) {
						d.year++
					}
					if d.year >= years {
						return nil, nil
					}
				}
				level = 0
				continue
			}
			if d.apply() {
				level--
				continue
			}
		}
		level++
		if level >= len(order) {
			return d, nil
		}
		if p.starYear && d.year >= 3000 || !p.starYear && d.year >= years {
			return nil, nil
		}
	}
}

// increment is croner's increment(): one second on, then the next match.
func (d *date) increment(p *Pattern) (*date, error) {
	d.second++
	d.millis = 0
	d.apply()
	return d.recurse(p)
}

// timeMs is getDate(false).getTime(): the instant this wall-clock time names.
func (d *date) timeMs() int64 {
	return toUTC(wall{d.year, d.month + 1, d.day, d.hour, d.minute, d.second}, d.loc) * 1000
}
