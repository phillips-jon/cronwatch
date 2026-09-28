package cron

// The walk's habits, each checked against what croner answers (the fuzz
// test in the schedule package checks thousands more against croner
// itself).

import (
	"testing"
	"time"

	"cronwatch.dev/go/internal/js"
)

func runs(t *testing.T, text, zone string, count int, from int64) []string {
	t.Helper()
	loc, err := LoadZone(zone)
	if err != nil {
		t.Fatal(err)
	}
	c, err := New(text, loc)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, ms := range c.NextRuns(count, from) {
		out = append(out, js.ISOString(ms))
	}
	return out
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestCronersHabits(t *testing.T) {
	jan := js.DateUTC(2026, 0, 1, 0, 0, 0, 0)
	cases := []struct {
		name, text, zone string
		count            int
		want             []string
	}{
		{"a wall-clock time in a spring-forward gap moves forward by the gap", "30 2 8 3 *", "America/New_York", 1, []string{"2026-03-08T07:30:00.000Z"}},
		{"a time that happens twice is the earlier one", "30 1 1 11 *", "America/New_York", 2, []string{"2026-11-01T05:30:00.000Z", "2027-11-01T05:30:00.000Z"}},
		{"a year field fires in that year only", "0 0 0 1 1 * 2030", "UTC", 2, []string{"2030-01-01T00:00:00.000Z"}},
		{"a fixed offset is a zone", "0 2 * * *", "+05:30", 1, []string{"2026-01-01T20:30:00.000Z"}},
		{"a date no month has never fires", "0 0 30 2 *", "UTC", 1, nil},
		{"the last weekday of the month", "0 0 LW * *", "UTC", 2, []string{"2026-01-30T00:00:00.000Z", "2026-02-27T00:00:00.000Z"}},
		{"the nearest weekday to the first", "0 0 1W * *", "UTC", 2, []string{"2026-02-02T00:00:00.000Z", "2026-03-02T00:00:00.000Z"}},
		{"the second Friday", "0 0 * * 5#2", "UTC", 2, []string{"2026-01-09T00:00:00.000Z", "2026-02-13T00:00:00.000Z"}},
	}
	for _, c := range cases {
		if got := runs(t, c.text, c.zone, c.count, jan); !equal(got, c.want) {
			t.Errorf("%s: %s gave %v, want %v", c.name, c.text, got, c.want)
		}
	}
}

func TestCronersMessages(t *testing.T) {
	cases := map[string]string{
		"":              "CronPattern: invalid configuration format (''), exactly five, six, or seven space separated parts are required.",
		"0 0 * * 5W":    "CronPattern: configuration entry 5 (5W) contains illegal characters.",
		"0 0 1#2 * *":   "CronPattern: configuration entry 3 (1#2) contains illegal characters.",
		"0 0 * 2L *":    "CronPattern: configuration entry 4 (2L) contains illegal characters.",
		"0 0 1-5W * *":  "CronPattern: Syntax error, W is not allowed in a range.",
		"* * * * * * 0": "CronPattern: Invalid value for year: 0 (supported range: 1-9999)",
		"0 0 * * 1#2.5": "CronPattern: configuration entry 5 (1#2.5) contains illegal characters.",
		"@reboot":       "CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection.",
		// Croner takes this for a one-time date; the port refuses it (see the package doc).
		"0 12:30 * * *": "Invalid ISO8601 passed to timezone parser.",
	}
	for text, want := range cases {
		if _, err := New(text, time.UTC); err == nil || err.Error() != want {
			t.Errorf("%q: %v, want %s", text, err, want)
		}
	}
}

func TestFromTZ(t *testing.T) {
	ny, err := LoadZone("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	// 02:30 does not exist on 2026-03-08: croner's fromTZ moves it to 03:30 EDT.
	if got := toUTC(wall{2026, 3, 8, 2, 30, 0}, ny); got*1000 != js.DateUTC(2026, 2, 8, 7, 30, 0, 0) {
		t.Error(js.ISOString(got * 1000))
	}
	// 01:30 happens twice on 2026-11-01: the earlier, EDT.
	if got := toUTC(wall{2026, 11, 1, 1, 30, 0}, ny); got*1000 != js.DateUTC(2026, 10, 1, 5, 30, 0, 0) {
		t.Error(js.ISOString(got * 1000))
	}
	if w := wallAt(js.DateUTC(2026, 6, 1, 12, 0, 0, 0)/1000, ny); w != (wall{2026, 7, 1, 8, 0, 0}) {
		t.Error(w)
	}
}

func TestToNumberAndParseInt(t *testing.T) {
	for in, want := range map[string]float64{"5": 5, " 7x": 7, "-3": -3, "+2": 2} {
		if got := parseInt(in); got != want {
			t.Errorf("parseInt(%q) = %v", in, got)
		}
	}
	for in, want := range map[string]float64{"": 0, " 2 ": 2, "1e1": 10, "2.": 2, ".5": 0.5} {
		if got := toNumber(in); got != want {
			t.Errorf("Number(%q) = %v", in, got)
		}
	}
	for _, in := range []string{"x", "1L", "e1", ".", "1e", "--1"} {
		if got := toNumber(in); got == got {
			t.Errorf("Number(%q) = %v, want NaN", in, got)
		}
	}
}
