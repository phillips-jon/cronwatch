package cron

import (
	"regexp"
	"strings"
	"time"
)

var isoDate = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}`)

// Cron is what the schedule uses of croner's Cron: an expression that
// schedules nothing and only answers NextRuns.
type Cron struct {
	pattern *Pattern
	loc     *time.Location
}

// New reads an expression, to be walked in the zone loc (nil is
// time.Local). Its errors are croner's, word for word.
func New(text string, loc *time.Location) (*Cron, error) {
	if text != "" && strings.Contains(text[1:], ":") {
		// Croner reads a string with a colon after its first character as a
		// one-time date to fire at, not as a cron expression.
		if isoDate.MatchString(text) {
			return nil, fail("CronPattern: a one-time date is not supported")
		}
		return nil, fail("Invalid ISO8601 passed to timezone parser.")
	}
	p, err := NewPattern(text)
	if err != nil {
		return nil, err
	}
	if loc == nil {
		loc = time.Local
	}
	return &Cron{pattern: p, loc: loc}, nil
}

// NextRuns is croner's nextRuns: up to count fires after start (epoch ms),
// each found from the one before. Fewer when the expression stops firing.
func (c *Cron) NextRuns(count int, start int64) []int64 {
	runs := make([]int64, 0, count)
	previous := dateFromMs(start, c.loc)
	for i := 0; i < count; i++ {
		next := *previous
		found, err := next.increment(c.pattern)
		if err != nil || found == nil {
			break
		}
		runs = append(runs, found.timeMs())
		previous = found
	}
	return runs
}
