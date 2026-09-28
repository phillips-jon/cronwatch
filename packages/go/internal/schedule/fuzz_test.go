package schedule

// The croner port against croner itself: thousands of generated cron
// expressions (valid and not, nicknames, names, ranges, steps, lists, L, W,
// LW, #, ?, +, six and seven fields, in zones with and without daylight
// saving, from times around the clock changes) answered by the SDK in Node
// (testdata/schedule_fuzz.mjs, which imports packages/sdk/dist) and by this
// package, which must agree on every error message and every fire time.
// Seeded, so a failure repeats; the generator is the Python and PHP ports'.

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"

	"cronwatch.dev/go/internal/js"
)

var (
	fuzzZones     = []string{"", "UTC", "America/New_York", "Europe/London", "Australia/Lord_Howe", "America/Santiago", "Asia/Kolkata", "Pacific/Chatham", "Europe/Berlin"}
	fuzzMonths    = []string{"jan", "FEB", "Mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}
	fuzzDays      = []string{"sun", "MON", "Tue", "wed", "thu", "fri", "sat"}
	fuzzNicknames = []string{"@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly", "@HOURLY", "@reboot", "@every"}
)

type fuzzer struct{ r *rand.Rand }

func (f fuzzer) chance() float64        { return f.r.Float64() }
func (f fuzzer) between(lo, hi int) int { return lo + f.r.IntN(hi-lo+1) }
func pick[T any](f fuzzer, items []T) T { return items[f.r.IntN(len(items))] }

// field is one cron field: mostly valid, sometimes out of range or malformed.
func (f fuzzer) field(low, high int, names []string) string {
	size := high - low + 1
	value := func() string {
		if names != nil && f.chance() < 0.3 {
			return pick(f, names)
		}
		if f.chance() < 0.05 {
			return strconv.Itoa(pick(f, []int{high + 1, low - 1, 99}))
		}
		return strconv.Itoa(f.between(low, high))
	}
	pair := func() (int, int) {
		a, b := f.between(low, high), f.between(low, high)
		if a > b {
			a, b = b, a
		}
		return a, b
	}
	switch kind := f.chance(); {
	case kind < 0.3:
		return "*"
	case kind < 0.45:
		return value()
	case kind < 0.6:
		a, b := pair()
		if f.chance() < 0.05 {
			a, b = b+1, a
		}
		return fmt.Sprintf("%d-%d", a, b)
	case kind < 0.75:
		return "*/" + strconv.Itoa(pick(f, []int{1, 2, 3, 5, 7, 10, 15, 30, size, size + 1, 0}))
	case kind < 0.85:
		a, b := pair()
		return fmt.Sprintf("%d-%d/%d", a, b, f.between(1, max(1, size/2)))
	case kind < 0.97:
		items := make([]string, f.between(2, 4))
		for i := range items {
			items[i] = value()
		}
		return strings.Join(items, ",")
	}
	return pick(f, []string{"?", "x", "", "5/15", "/5", "1-", "-1"})
}

func (f fuzzer) dayOfMonth() string {
	switch kind := f.chance(); {
	case kind < 0.1:
		return pick(f, []string{"L", "LW", "15W", "1W", "31W", "5L", "L,15"})
	case kind < 0.2:
		return "?"
	}
	return f.field(1, 31, nil)
}

func (f fuzzer) dayOfWeek() string {
	switch kind := f.chance(); {
	case kind < 0.1:
		return fmt.Sprintf("%d#%d", f.between(0, 7), f.between(0, 6))
	case kind < 0.18:
		return fmt.Sprintf("%dL", f.between(0, 6))
	case kind < 0.24:
		return "+" + f.field(0, 7, fuzzDays)
	case kind < 0.3:
		return pick(f, fuzzDays) + "-" + pick(f, fuzzDays)
	}
	return f.field(0, 7, fuzzDays)
}

func (f fuzzer) expression() string {
	if f.chance() < 0.05 {
		return pick(f, fuzzNicknames)
	}
	parts := []string{f.field(0, 59, nil), f.field(0, 23, nil), f.dayOfMonth(), f.field(1, 12, fuzzMonths), f.dayOfWeek()}
	if f.chance() < 0.25 {
		parts = append([]string{f.field(0, 59, nil)}, parts...)
	}
	if f.chance() < 0.02 {
		parts = append(parts, "*")
	}
	return strings.Join(parts, " ")
}

// fuzzSeeds are the seeds run, a thousand cases each.
var fuzzSeeds = []uint64{1, 2, 3}

type fuzzCase struct {
	Schedule string  `json:"schedule"`
	Timezone *string `json:"timezone"`
	From     int64   `json:"from"`
	Count    int     `json:"count"`
}

type fuzzAnswer struct {
	Error  *string  `json:"error,omitempty"`
	Fires  []*int64 `json:"fires,omitempty"`
	Throws *string  `json:"throws,omitempty"`
}

func fuzzCases(seed uint64, count int) []fuzzCase {
	f := fuzzer{rand.New(rand.NewPCG(seed, seed))}
	// Around the nights clocks change in the zones above, and ordinary days.
	starts := []int64{
		js.DateUTC(2026, 2, 8, 6, 30, 0, 0), js.DateUTC(2026, 10, 1, 5, 10, 0, 0), js.DateUTC(2026, 2, 29, 0, 45, 0, 0),
		js.DateUTC(2026, 9, 25, 0, 50, 0, 0), js.DateUTC(2026, 9, 3, 15, 20, 0, 0), js.DateUTC(2026, 3, 4, 14, 55, 0, 0),
		js.DateUTC(2026, 0, 5, 9, 30, 0, 0), js.DateUTC(2027, 1, 27, 23, 59, 59, 0), js.DateUTC(2028, 1, 28, 12, 0, 0, 0),
	}
	out := make([]fuzzCase, count)
	for i := range out {
		from := pick(f, starts) + int64(f.between(-3, 3))*3_600_000 + int64(f.between(0, 3_599))*1000 + pick(f, []int64{0, 0, 500, 999})
		c := fuzzCase{Schedule: f.expression(), From: from, Count: f.between(1, 6)}
		if zone := pick(f, fuzzZones); zone != "" {
			c.Timezone = &zone
		}
		out[i] = c
	}
	return out
}

func goAnswer(c fuzzCase) fuzzAnswer {
	zone := ""
	if c.Timezone != nil {
		zone = *c.Timezone
	}
	p, err := Parse(c.Schedule, zone)
	if err != nil {
		msg := err.Error()
		return fuzzAnswer{Error: &msg}
	}
	fires := []*int64{}
	at := c.From
	for i := 0; i < c.Count; i++ {
		next, ok := NextFire(p, at, nil)
		if !ok {
			fires = append(fires, nil)
			break
		}
		fires = append(fires, &next)
		at = next
	}
	return fuzzAnswer{Fires: fires}
}

func show(a fuzzAnswer) string {
	if a.Error != nil {
		return "error " + *a.Error
	}
	var parts []string
	for _, t := range a.Fires {
		if t == nil {
			parts = append(parts, "null")
		} else {
			parts = append(parts, js.ISOString(*t))
		}
	}
	return "[" + strings.Join(parts, " ") + "]"
}

func TestThePortAgreesWithCroner(t *testing.T) {
	if testing.Short() {
		t.Skip("croner parity: skipped in -short mode")
	}
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("croner parity: node is not installed")
	}
	helper, _ := filepath.Abs(filepath.Join("testdata", "schedule_fuzz.mjs"))
	if _, err := os.Stat(filepath.Join("..", "..", "..", "sdk", "dist", "index.js")); err != nil {
		t.Skip("croner parity: packages/sdk/dist is not built (npm run build --workspace packages/sdk)")
	}
	for _, seed := range fuzzSeeds {
		t.Run(fmt.Sprintf("seed %d", seed), func(t *testing.T) {
			generated := fuzzCases(seed, 1000)
			file := filepath.Join(t.TempDir(), "cases.json")
			data, _ := json.Marshal(generated)
			if err := os.WriteFile(file, data, 0o600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(node, helper, file)
			cmd.Env = append(os.Environ(), "TZ=UTC")
			cmd.Stderr = os.Stderr
			out, err := cmd.Output()
			if err != nil {
				t.Fatalf("node: %v", err)
			}
			var expected []fuzzAnswer
			if err := json.Unmarshal(out, &expected); err != nil {
				t.Fatal(err)
			}
			var differences []string
			valid, refused, threw := 0, 0, 0
			for i, c := range generated {
				want, got := expected[i], goAnswer(c)
				if want.Error != nil {
					refused++
				} else {
					valid++
				}
				if want.Throws != nil {
					threw++
					// croner walks by recursion, a year at a time, so a date no
					// month has (February 30) runs out of stack before the year
					// 3000. The port walks in a loop and finds nothing: the
					// schedule never fires.
					n := len(want.Fires)
					prefix := append(append([]*int64{}, want.Fires...), nil)
					if len(got.Fires) < n+1 || !reflect.DeepEqual(got.Fires[:n+1], prefix) {
						differences = append(differences, fmt.Sprintf("%+v\n    croner threw %s after %s\n    go %s", c, *want.Throws, show(want), show(got)))
					}
					continue
				}
				if !reflect.DeepEqual(want, got) {
					differences = append(differences, fmt.Sprintf("%+v tz=%v\n    croner %s\n    go     %s", c, c.Timezone, show(want), show(got)))
				}
			}
			if len(differences) > 0 {
				sort.Strings(differences)
				t.Errorf("%d of %d differ:\n%s", len(differences), len(generated), strings.Join(differences[:min(10, len(differences))], "\n"))
			}
			if valid < 300 {
				t.Errorf("only %d generated expressions were valid; the walk needs more exercise", valid)
			}
			t.Logf("%d cases: %d valid (%d where croner ran out of stack), %d refused with croner's message", len(generated), valid, threw, refused)
		})
	}
}
