package schedule

// Replays conformance/duration.json and conformance/schedule.json, the
// cases scripts/conformance.mjs writes by running the TypeScript SDK (in
// UTC), comparing every answer as the JSON the SDK writes, byte for byte.

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"cronwatch.dev/go/internal/js"
)

func TestMain(m *testing.M) {
	// The fixtures are made with TZ=UTC; a schedule without a timezone is
	// read in the process's zone.
	time.Local = time.UTC
	os.Exit(m.Run())
}

func fixture(t *testing.T, name string) *js.Object {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "conformance", name+".json"))
	if err != nil {
		t.Fatal(err)
	}
	v, err := js.Parse(string(data))
	if err != nil {
		t.Fatal(err)
	}
	return v.(*js.Object)
}

func field(o *js.Object, key string) any {
	v, _ := o.Get(key)
	return v
}

func cases(o *js.Object, key string) []*js.Object {
	list, _ := field(o, key).([]any)
	out := make([]*js.Object, len(list))
	for i, v := range list {
		out[i] = v.(*js.Object)
	}
	return out
}

func text(o *js.Object, key string) string {
	s, _ := field(o, key).(string)
	return s
}

// number reads a number that may travel as { "special": "NaN" }.
func number(v any) float64 {
	if o, ok := v.(*js.Object); ok {
		switch field(o, "special") {
		case "NaN":
			return math.NaN()
		case "Infinity":
			return math.Inf(1)
		case "-Infinity":
			return math.Inf(-1)
		}
	}
	return v.(float64)
}

func integer(v any) int64 { return int64(v.(float64)) }

func optional(v any) *int64 {
	if v == nil {
		return nil
	}
	n := integer(v)
	return &n
}

func orNull(n int64, ok bool) any {
	if !ok {
		return nil
	}
	return n
}

func same(t *testing.T, what string, got, want any) {
	t.Helper()
	if g, w := js.Stringify(got), js.Stringify(want); g != w {
		t.Errorf("%s:\n got %s\nwant %s", what, g, w)
	}
}

func TestConformanceDuration(t *testing.T) {
	f := fixture(t, "duration")
	n := 0
	for _, c := range cases(f, "parse") {
		input := field(c, "input")
		if _, isString := input.(string); !isString {
			input = number(input)
		}
		ms, err := ParseDuration(input, text(c, "label"))
		got := js.NewObject("input", field(c, "input"))
		if c.Has("label") {
			got.Set("label", text(c, "label"))
		}
		if err != nil {
			got.Set("error", err.Error())
		} else {
			got.Set("ms", ms)
		}
		same(t, "parse", got, c)
		n++
	}
	for _, c := range cases(f, "format") {
		same(t, "format", js.NewObject("ms", field(c, "ms"), "text", FormatDuration(number(field(c, "ms")))), c)
		n++
	}
	for _, c := range cases(f, "relative") {
		same(t, "relative", js.NewObject("at", field(c, "at"), "now", field(c, "now"), "text", FormatRelative(integer(field(c, "at")), integer(field(c, "now")))), c)
		n++
	}
	t.Logf("%d duration cases", n)
}

func TestConformanceSchedule(t *testing.T) {
	f := fixture(t, "schedule")
	counts := map[string]int{}

	for _, c := range cases(f, "parse") {
		p, err := Parse(text(c, "schedule"), text(c, "timezone"))
		got := js.NewObject("schedule", text(c, "schedule"))
		if c.Has("timezone") {
			got.Set("timezone", text(c, "timezone"))
		}
		if err != nil {
			got.Set("error", err.Error())
		} else {
			got.Set("parsed", p.JSValue())
		}
		same(t, "parse", got, c)
		counts["parse"]++
	}

	for _, c := range cases(f, "fires") {
		p, err := Parse(text(c, "schedule"), text(c, "timezone"))
		if err != nil {
			t.Fatal(err)
		}
		want := field(c, "fires").([]any)
		out := []any{}
		at := integer(field(c, "from"))
		for range want {
			next, ok := NextFire(p, at, nil)
			out = append(out, orNull(next, ok))
			if !ok {
				break
			}
			at = next
		}
		same(t, fmt.Sprintf("fires of %s in %s", text(c, "schedule"), text(c, "timezone")), out, want)
		counts["fires"]++
	}

	for _, c := range cases(f, "nextFire") {
		p, err := Parse(text(c, "schedule"), "")
		if err != nil {
			t.Fatal(err)
		}
		next, ok := NextFire(p, integer(field(c, "from")), optional(field(c, "lastRunAt")))
		same(t, "nextFire", orNull(next, ok), field(c, "expected"))
		counts["nextFire"]++
	}

	for _, c := range cases(f, "expectation") {
		p, err := Parse(text(c, "schedule"), text(c, "timezone"))
		if err != nil {
			t.Fatal(err)
		}
		e, ok := Expect(p, optional(field(c, "lastRunAt")), integer(field(c, "registeredAt")), number(field(c, "graceMs")))
		var got any
		if ok {
			got = js.NewObject("dueAt", e.DueAt, "deadline", e.Deadline)
		}
		same(t, fmt.Sprintf("expectation of %s in %s after %v", text(c, "schedule"), text(c, "timezone"), field(c, "lastRunAt")), got, field(c, "expected"))
		counts["expectation"]++
	}

	for _, c := range cases(f, "runCovers") {
		got := RunCovers(integer(field(c, "startedAt")), integer(field(c, "dueAt")), optional(field(c, "followingAt")))
		same(t, "runCovers", got, field(c, "expected"))
		counts["runCovers"]++
	}

	for _, c := range cases(f, "autumn") {
		p, err := Parse(text(c, "schedule"), text(c, "timezone"))
		if err != nil {
			t.Fatal(err)
		}
		from, step := integer(field(c, "from")), integer(field(c, "stepMs"))
		out := []any{}
		for at := from; at < from+8*3_600_000; at += step {
			next, ok := NextFire(p, at, nil)
			out = append(out, orNull(next, ok))
		}
		same(t, fmt.Sprintf("autumn %s in %s", text(c, "schedule"), text(c, "timezone")), out, field(c, "next"))
		counts["autumn"]++
	}
	t.Logf("schedule cases: %v", counts)
}
