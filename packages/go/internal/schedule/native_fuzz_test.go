package schedule

// Go's own fuzzing of the two parsers that read text an app (or another
// process sharing the store) wrote: schedules and durations. The seeds run
// with every `go test`; `go test -fuzz FuzzSchedule` (or FuzzDuration)
// explores further. Each input must parse or fail without a panic, and what
// parses must answer sensibly: fire times strictly after the time asked and
// ascending, durations never negative, an interval never shorter than a
// second.

import (
	"math"
	"strings"
	"testing"
	"time"
)

func FuzzSchedule(f *testing.F) {
	for _, seed := range []string{
		"0 2 * * *", "*/5 * * * *", "@hourly", "@yearly", "every 5m", "every 1h30m",
		"0 0 30 2 *", "0 0 L * *", "0 0 LW * *", "0 0 * * 5#3", "0 0 * * 5L", "0 0 15W * *",
		"0 0 0 * * *", "0 0 0 * * * 2030", "0 0 ? * MON-FRI", "0 12 * JAN,jul sun",
		"* * * * * *", "59 23 31 12 *", "0 0 29 2 *", "every 20000000000w", "every 1ms",
		"1-5/2 */3 1,15 * *", "0 0 1 1 * 2100", "", " ", "x", "0 0 * * 8", "2030-01-01T00:00",
	} {
		for _, zone := range []string{"", "UTC", "America/New_York", "Australia/Lord_Howe", "Mars/Base"} {
			f.Add(seed, zone, int64(1_700_000_000_000))
		}
	}
	f.Fuzz(func(t *testing.T, text, zone string, from int64) {
		if len(text) > 200 {
			return
		}
		// Times the SDK meets: 1970 to 2200.
		from = 1 + int64(uint64(from)%7_258_118_400_000)
		p, err := parse(text, zone)
		if err != nil {
			if err.Error() == "" {
				t.Fatalf("%q in %q: an empty error", text, zone)
			}
			return
		}
		if p.Kind == "interval" {
			if p.EveryMs < 1000 {
				t.Fatalf("%q: an interval of %d ms", text, p.EveryMs)
			}
			next, ok := NextFire(p, from, nil)
			if !ok || next <= from {
				t.Fatalf("%q: next %d after %d", text, next, from)
			}
			return
		}
		fires, ok := FiresBetween(p, from, from+400*24*3_600_000, 40)
		if ok {
			for i, fire := range fires {
				if fire <= from || (i > 0 && fire <= fires[i-1]) {
					t.Fatalf("%q in %q from %d: fires %v not ascending after the start", text, zone, from, fires)
				}
			}
		}
		if next, ok := FireAfter(p, from); ok && next <= from {
			t.Fatalf("%q in %q: next %d not after %d", text, zone, next, from)
		}
	})
}

func FuzzDuration(f *testing.F) {
	for _, seed := range []string{"15m", "1h30m", "90s", "1.5s", "0", "0ms", " 2 h 3 m ", "1e3ms", "1w2d", "-5m", "5", "ms", "1.m", " 1h", "9" + strings.Repeat("9", 400) + "ms", "1h 1h 1h"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, text string) {
		ms, err := ParseDuration(text, "")
		if err != nil {
			if !strings.HasPrefix(err.Error(), "duration ") {
				t.Fatalf("%q: error %q does not name the duration", text, err)
			}
			return
		}
		if math.IsNaN(ms) || ms < 0 || ms != math.Round(ms) {
			t.Fatalf("%q: %v", text, ms)
		}
		// A duration always gives a time.Duration and a formatted text.
		if FormatDuration(ms) == "" {
			t.Fatalf("%q: formatted as nothing", text)
		}
		_ = time.Duration(ms)
	})
}
