package schedule

// The SDK's schedule.test.ts and duration.test.ts, and what only the Go
// port has: time.Duration values, zone names in any case, fixed offsets.

import (
	"strings"
	"sync"
	"testing"
	"time"

	"cronwatch.dev/go/internal/js"
)

const (
	minute = 60_000
	hour   = 3_600_000
	day    = 86_400_000
)

func utc(y, mo, d, h, mi, s int64) int64 { return js.DateUTC(y, mo, d, h, mi, s, 0) }

func mustParse(t *testing.T, schedule, zone string) *Parsed {
	t.Helper()
	p, err := Parse(schedule, zone)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func due(t *testing.T, p *Parsed, lastRunAt *int64, registeredAt int64, grace float64) int64 {
	t.Helper()
	e, ok := Expect(p, lastRunAt, registeredAt, grace)
	if !ok {
		t.Fatal("no expectation")
	}
	return e.DueAt
}

func at(n int64) *int64 { return &n }

func TestParseAcceptsCronNicknamesAndIntervals(t *testing.T) {
	for _, s := range []string{"0 2 * * *", "@hourly", "*/5 * * * *"} {
		if mustParse(t, s, "").Kind != "cron" {
			t.Errorf("%s is not a cron", s)
		}
	}
	every := mustParse(t, "every 5m", "")
	if every.Kind != "interval" || every.EveryMs != 5*minute {
		t.Errorf("every 5m: %+v", every)
	}
	for bad, want := range map[string]string{"every 500ms": "shorter than one second", "banana": "not a cron expression", "every banana": "not a duration"} {
		if _, err := Parse(bad, ""); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v", bad, err)
		}
	}
}

func TestAParsedScheduleIsPlainData(t *testing.T) {
	if got := js.Stringify(mustParse(t, "0 2 * * *", "UTC")); got != `{"kind":"cron","source":"0 2 * * *","timezone":"UTC"}` {
		t.Error(got)
	}
	if got := js.Stringify(mustParse(t, " every 90s ", "UTC")); got != `{"kind":"interval","source":"every 90s","everyMs":90000}` {
		t.Error(got)
	}
}

func TestNextFire(t *testing.T) {
	daily := mustParse(t, "0 2 * * *", "")
	if got, _ := NextFire(daily, utc(2026, 0, 5, 9, 30, 0), nil); got != utc(2026, 0, 6, 2, 0, 0) {
		t.Error(js.ISOString(got))
	}
	every := mustParse(t, "every 1h", "")
	if got, _ := NextFire(every, 1_000, at(500)); got != 500+hour {
		t.Error(got)
	}
	if got, _ := NextFire(every, 1_000, nil); got != 1_000+hour {
		t.Error(got)
	}
	// July, EDT (UTC-4): 02:00 local is 06:00Z.
	toronto := mustParse(t, "0 2 * * *", "America/Toronto")
	if got, _ := NextFire(toronto, utc(2026, 6, 10, 0, 0, 0), nil); got != utc(2026, 6, 10, 6, 0, 0) {
		t.Error(js.ISOString(got))
	}
}

func TestExpectationForACronCountsForwardFromTheLastRun(t *testing.T) {
	daily := mustParse(t, "0 2 * * *", "")
	registered := utc(2026, 0, 4, 12, 0, 0)
	first, _ := Expect(daily, nil, registered, 10*minute)
	if first.DueAt != utc(2026, 0, 5, 2, 0, 0) || first.Deadline != float64(utc(2026, 0, 5, 2, 10, 0)) {
		t.Errorf("never ran: %+v", first)
	}
	if got := due(t, daily, nil, utc(2026, 0, 5, 2, 0, 0), 0); got != utc(2026, 0, 5, 2, 0, 0) {
		t.Error("a fire at registration counts")
	}
	cases := []struct{ ran, want int64 }{
		{utc(2026, 0, 5, 2, 0, 5), utc(2026, 0, 6, 2, 0, 0)},   // ran at 02:00:05: the 6th is next
		{utc(2026, 0, 5, 1, 59, 30), utc(2026, 0, 6, 2, 0, 0)}, // 30 seconds early still covers 02:00
		{utc(2026, 0, 5, 1, 58, 0), utc(2026, 0, 5, 2, 0, 0)},  // two minutes early does not
	}
	for _, c := range cases {
		if got := due(t, daily, at(c.ran), registered, 0); got != c.want {
			t.Errorf("ran %s: due %s", js.ISOString(c.ran), js.ISOString(got))
		}
	}
}

func TestOneRunOfAnEveryMinuteCronCoversOneFire(t *testing.T) {
	minutely := mustParse(t, "* * * * *", "")
	t0 := utc(2026, 0, 5, 9, 0, 0)
	if got := due(t, minutely, at(t0), t0-hour, 0); got != t0+minute {
		t.Error("a run on 09:00 covers 09:00 only")
	}
	if got := due(t, minutely, at(t0+50_000), t0-hour, 0); got != t0+2*minute {
		t.Error("a run at 09:00:50 is an early start for 09:01")
	}
}

func TestExpectationForYearlyCronsAndIntervals(t *testing.T) {
	yearly := mustParse(t, "0 0 1 1 *", "UTC")
	last := utc(2026, 0, 1, 0, 0, 3)
	if got := due(t, yearly, at(last), last-day, 10*minute); got != utc(2027, 0, 1, 0, 0, 0) {
		t.Error(js.ISOString(got))
	}
	leap := mustParse(t, "0 0 29 2 *", "UTC")
	if got := due(t, leap, at(utc(2024, 1, 29, 0, 0, 1)), 0, 0); got != utc(2028, 1, 29, 0, 0, 0) {
		t.Error(js.ISOString(got))
	}
	every := mustParse(t, "every 1h", "")
	now := utc(2026, 0, 5, 9, 30, 0)
	if e, _ := Expect(every, at(now-2*hour), now-day, 5*minute); e.DueAt != now-hour || e.Deadline != float64(now-hour+5*minute) {
		t.Errorf("%+v", e)
	}
	if got := due(t, every, nil, now-30*minute, 5*minute); got != now+30*minute {
		t.Error(got)
	}
}

func TestSpringForwardRunAtTheJumpCoversAMovedFire(t *testing.T) {
	// 2026-03-08, America/New_York: 02:00 EST jumps to 03:00 EDT at 07:00Z.
	// croner moves the nonexistent 02:30 to 03:30 EDT (07:30Z); vixie cron
	// runs it at 03:00 EDT.
	tz := "America/New_York"
	daily := mustParse(t, "30 2 * * *", tz)
	if got := due(t, daily, at(utc(2026, 2, 7, 7, 30, 0)), 0, 0); got != utc(2026, 2, 8, 7, 30, 0) {
		t.Error(js.ISOString(got))
	}
	if got := due(t, daily, at(utc(2026, 2, 8, 7, 0, 2)), 0, 0); got != utc(2026, 2, 9, 6, 30, 0) {
		t.Error("the vixie run covers the day")
	}
	if got := due(t, daily, at(utc(2026, 2, 8, 7, 30, 1)), 0, 0); got != utc(2026, 2, 9, 6, 30, 0) {
		t.Error("so does a run at croner's time")
	}
	// A cron that fires at the jump itself was not moved: a run then covers only that fire.
	if got := due(t, mustParse(t, "*/10 * * * *", tz), at(utc(2026, 2, 8, 7, 0, 2)), 0, 0); got != utc(2026, 2, 8, 7, 10, 0) {
		t.Error(js.ISOString(got))
	}
	if got := due(t, mustParse(t, "0 * * * *", tz), at(utc(2026, 2, 8, 7, 0, 2)), 0, 0); got != utc(2026, 2, 8, 8, 0, 0) {
		t.Error(js.ISOString(got))
	}
}

func TestRunCoversAllowsAMinuteAtMostHalfTheGap(t *testing.T) {
	d := utc(2026, 0, 5, 2, 0, 0)
	for _, c := range []struct {
		started   int64
		following *int64
		want      bool
	}{
		{d, nil, true}, {d - 59_000, nil, true}, {d + 5*minute, nil, true}, {d - 61_000, nil, false},
		{d - 30_000, at(d + minute), true}, {d - 31_000, at(d + minute), false},
	} {
		if RunCovers(c.started, d, c.following) != c.want {
			t.Errorf("RunCovers(%d) should be %v", c.started-d, c.want)
		}
	}
}

func TestFiresBetween(t *testing.T) {
	hourly := mustParse(t, "0 * * * *", "UTC")
	from := utc(2026, 0, 5, 9, 30, 0)
	fires, ok := FiresBetween(hourly, from, from+24*hour, 100)
	if !ok || len(fires) != 24 {
		t.Fatalf("%d fires", len(fires))
	}
	next := from
	for _, fire := range fires {
		next, _ = NextFire(hourly, next, nil)
		if fire != next {
			t.Error("firesBetween and nextFire disagree")
		}
	}
	if _, ok := FiresBetween(hourly, from, from+24*hour, 23); ok {
		t.Error("more than the limit is null")
	}
	if none, ok := FiresBetween(mustParse(t, "0 3 * * *", "UTC"), from, from+hour, 5); !ok || len(none) != 0 {
		t.Error("an empty span is empty")
	}
	// The night clocks go back in New York: fires only ever move forward.
	night, _ := FiresBetween(mustParse(t, "30 * * * *", "America/New_York"), utc(2026, 10, 1, 4, 0, 0), utc(2026, 10, 1, 9, 0, 0), 20)
	for i := 1; i < len(night); i++ {
		if night[i] <= night[i-1] {
			t.Error("fires went backwards")
		}
	}
	if len(night) < 4 || len(night) > 5 {
		t.Errorf("%d fires in the night", len(night))
	}
}

func TestADateNoMonthHasNeverFires(t *testing.T) {
	// croner runs out of stack here; the port walks in a loop and gives up
	// at the year croner does.
	p := mustParse(t, "0 0 30 2 *", "UTC")
	if _, ok := NextFire(p, utc(2026, 0, 1, 0, 0, 0), nil); ok {
		t.Error("February 30 fired")
	}
	if _, ok := Expect(p, nil, utc(2026, 0, 1, 0, 0, 0), 0); ok {
		t.Error("February 30 is due")
	}
}

func TestOneTimeDatesAreRefused(t *testing.T) {
	for text, want := range map[string]string{
		"2026-12-01T00:00:00": "CronPattern: a one-time date is not supported by the Go port",
		"0 2:30 * * *":        "Invalid ISO8601 passed to timezone parser.",
	} {
		_, err := Parse(text, "")
		if err == nil || !strings.HasSuffix(err.Error(), ": "+want) {
			t.Errorf("%s: %v", text, err)
		}
	}
}

func TestZones(t *testing.T) {
	for _, name := range []string{"America/New_York", "america/new_york", "AMERICA/NEW_YORK", "utc", "UTC", "Etc/GMT+5", "etc/gmt+5", "+05:30", "-0800", "+05"} {
		if !IsTimezone(name) {
			t.Errorf("%s should be a zone", name)
		}
	}
	for _, name := range []string{"", "Local", "local", "Bogus/Zone", "+25:00", "+5", "America/New_York/../New_York", "a\x00b"} {
		if IsTimezone(name) {
			t.Errorf("%q should not be a zone", name)
		}
	}
	// A zone named in another case reads the same as its own spelling.
	lower := mustParse(t, "0 2 * * *", "america/new_york")
	right := mustParse(t, "0 2 * * *", "America/New_York")
	from := utc(2026, 6, 10, 0, 0, 0)
	a, _ := NextFire(lower, from, nil)
	b, _ := NextFire(right, from, nil)
	if a != b || a != utc(2026, 6, 10, 6, 0, 0) {
		t.Errorf("%s and %s", js.ISOString(a), js.ISOString(b))
	}
	if js.Stringify(lower) != `{"kind":"cron","source":"0 2 * * *","timezone":"america/new_york"}` {
		t.Error("the zone is kept as given")
	}
	offset := mustParse(t, "0 2 * * *", "+05:30")
	if got, _ := NextFire(offset, utc(2026, 0, 1, 0, 0, 0), nil); got != utc(2026, 0, 1, 20, 30, 0) {
		t.Error(js.ISOString(got))
	}
	if _, err := Parse("0 2 * * *", "Bogus/Zone"); err == nil || !strings.HasPrefix(err.Error(), "CronDate: Failed to convert date to timezone 'Bogus/Zone'") {
		t.Errorf("a bad zone: %v", err)
	}
	if loc, err := LoadZone(""); err != nil || loc != time.Local {
		t.Error("no zone is the process's")
	}
	if _, err := LoadZone("nowhere"); err == nil || err.Error() != `timezone "nowhere" is not an IANA timezone` {
		t.Error(err)
	}
}

func TestParseIsSafeFromManyGoroutines(t *testing.T) {
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				p, err := Parse("*/15 * * * *", "Europe/London")
				if err != nil {
					t.Error(err)
					return
				}
				NextFire(p, utc(2026, 9, 25, 0, 0, int64(j)), nil)
			}
		}()
	}
	wg.Wait()
}

func TestParseDuration(t *testing.T) {
	good := map[string]float64{"15m": 900_000, "1h30m": 5_400_000, "90s": 90_000, "2d": 172_800_000, "1w": 604_800_000, "250ms": 250, " 1h 5m ": 3_900_000, "1.5h": 5_400_000}
	for in, want := range good {
		if got, err := ParseDuration(in, ""); err != nil || got != want {
			t.Errorf("%q: %v %v", in, got, err)
		}
	}
	values := []struct {
		in   any
		want float64
	}{{1234, 1234}, {int64(5), 5}, {1.5, 1.5}, {15 * time.Minute, 900_000}, {1500 * time.Microsecond, 1.5}}
	for _, c := range values {
		if got, err := ParseDuration(c.in, ""); err != nil || got != c.want {
			t.Errorf("%v: %v %v", c.in, got, err)
		}
	}
	for _, bad := range []string{"", "abc", "5", "5 minutes", "-1m", "1m2"} {
		if _, err := ParseDuration(bad, ""); err == nil || !strings.Contains(err.Error(), "duration") {
			t.Errorf("%q: %v", bad, err)
		}
	}
	if _, err := ParseDuration(-5, "grace"); err == nil || err.Error() != "grace must be a non-negative number of milliseconds" {
		t.Error(err)
	}
	if _, err := ParseDuration(-time.Second, "timeout"); err == nil || err.Error() != "timeout must be a non-negative number of milliseconds" {
		t.Error(err)
	}
	if _, err := ParseDuration(true, "grace"); err == nil || err.Error() != `grace "true" is not a duration like "15m", "1h30m" or "90s"` {
		t.Error(err)
	}
}

func TestFormatDurationAndRelative(t *testing.T) {
	for ms, want := range map[float64]string{500: "500ms", 1_000: "1s", 90_000: "1m 30s", hour*26 + minute*5: "1d 2h"} {
		if got := FormatDuration(ms); got != want {
			t.Errorf("%v: %s", ms, got)
		}
	}
	if FormatRelative(1_000_000, 1_120_000) != "2m ago" || FormatRelative(1_120_000, 1_000_000) != "in 2m" || FormatRelative(1_000_000, 1_002_000) != "now" {
		t.Error("formatRelative")
	}
}
