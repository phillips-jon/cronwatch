package cronwatch

// conformance/health.json: health, summaries, percentiles, state
// normalization, silence and which queued alerts a retry drops.

import (
	"fmt"
	"testing"

	"cronwatch.dev/go/internal/js"
)

func fixtureRun(t *testing.T, v any) *Run {
	if v == nil {
		return nil
	}
	r, err := runFrom(v)
	if err != nil {
		t.Fatal(err)
	}
	return &r
}

func fixtureRuns(t *testing.T, v any) []Run {
	out := []Run{}
	list, _ := v.([]any)
	for _, r := range list {
		out = append(out, *fixtureRun(t, r))
	}
	return out
}

func fixtureState(t *testing.T, v any) JobState {
	s, err := stateFrom(v)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func fixtureStored(t *testing.T, v any) StoredJob {
	o := v.(*js.Object)
	def, err := definitionFrom(field(o, "definition"))
	if err != nil {
		t.Fatal(err)
	}
	return StoredJob{Name: field(o, "name").(string), Definition: def, CreatedAt: int64(field(o, "createdAt").(float64)), UpdatedAt: int64(field(o, "updatedAt").(float64))}
}

func numbers(v any) []float64 {
	out := []float64{}
	for _, n := range v.([]any) {
		out = append(out, n.(float64))
	}
	return out
}

func TestConformanceHealth(t *testing.T) {
	f := fixture(t, "health")
	now := func(c *js.Object) int64 { return int64(field(c, "now").(float64)) }
	for i, c := range objects(f, "jobHealth") {
		def, _ := definitionFrom(field(c, "definition"))
		h, err := jobHealth(def, fixtureRun(t, field(c, "lastRun")), fixtureState(t, field(c, "state")), now(c))
		if err != nil || string(h) != field(c, "health") {
			t.Errorf("jobHealth %d: %s %v, want %v", i, h, err, field(c, "health"))
		}
	}
	for i, c := range objects(f, "summarize") {
		s, err := summarize(fixtureStored(t, field(c, "stored")), fixtureRuns(t, field(c, "recent")), fixtureState(t, field(c, "state")), optInt(field(c, "nextExpectedAt")), now(c))
		if err != nil {
			t.Fatal(err)
		}
		sameJSON(t, fmt.Sprintf("summarize %d", i), s.JSValue(), field(c, "summary"))
	}
	for _, c := range objects(f, "percentile") {
		v, ok := percentile(numbers(field(c, "values")), field(c, "p").(float64))
		var got any
		if ok {
			got = v
		}
		sameJSON(t, fmt.Sprintf("percentile(%s, %v)", js.Stringify(field(c, "values")), field(c, "p")), got, field(c, "percentile"))
	}
	for _, c := range objects(f, "median") {
		v, ok := median(numbers(field(c, "values")))
		var got any
		if ok {
			got = v
		}
		sameJSON(t, "median", got, field(c, "median"))
	}
	for i, c := range objects(f, "normalizeState") {
		var in *JobState
		if field(c, "state") != nil {
			s := fixtureState(t, field(c, "state"))
			in = &s
		}
		sameJSON(t, fmt.Sprintf("normalizeState %d", i), normalizeState(in, "j").JSValue(), field(c, "normalized"))
	}
	for i, c := range objects(f, "muteOpens") {
		got := muteOpens(fixtureState(t, field(c, "previous")), fixtureState(t, field(c, "next")))
		sameJSON(t, fmt.Sprintf("muteOpens %d", i), got.JSValue(), field(c, "muted"))
	}
	for i, c := range objects(f, "isStuck") {
		def, _ := definitionFrom(field(c, "definition"))
		stuck, err := isStuck(def, *fixtureRun(t, field(c, "run")), now(c))
		if err != nil || stuck != field(c, "stuck") {
			t.Errorf("isStuck %d: %v %v", i, stuck, err)
		}
	}
	durations := 0
	for i, c := range objects(f, "runDuration") {
		got := runDuration(int64(field(c, "startedAt").(float64)), int64(field(c, "finishedAt").(float64)))
		if want := int64(field(c, "durationMs").(float64)); got != want {
			t.Errorf("runDuration %d: %d, want %d", i, got, want)
		}
		durations++
	}
	versions := 0
	for i, c := range objects(f, "stateVersion") {
		parsed, err := js.Parse(field(c, "state").(string))
		if err != nil {
			t.Fatal(err)
		}
		// The state reads (a foreign version reads as none), and counts as the SDK counts it.
		s := fixtureState(t, parsed)
		if want := int64(field(c, "version").(float64)); s.version() != want {
			t.Errorf("stateVersion %d (%s): %d, want %d", i, field(c, "state"), s.version(), want)
		}
		versions++
	}
	if durations == 0 || versions == 0 {
		t.Error("no runDuration or stateVersion cases")
	}
	for i, c := range objects(f, "unevaluableSummary") {
		s := unevaluableSummary(fixtureStored(t, field(c, "stored")), fixtureRuns(t, field(c, "recent")), fixtureState(t, field(c, "state")), now(c))
		sameJSON(t, fmt.Sprintf("unevaluableSummary %d", i), s.JSValue(), field(c, "summary"))
	}
	for i, c := range objects(f, "applySilence") {
		e := field(c, "evaluation").(*js.Object)
		in := evaluation{state: fixtureState(t, field(e, "state"))}
		for _, d := range field(e, "alerts").([]any) {
			in.alerts = append(in.alerts, draftFrom(t, d))
		}
		out := applySilence(fixtureState(t, field(c, "previous")), in, now(c))
		alerts := []any{}
		for _, d := range out.alerts {
			alerts = append(alerts, d.JSValue())
		}
		sameJSON(t, fmt.Sprintf("applySilence %d", i), js.NewObject("state", out.state.JSValue(), "alerts", alerts), field(c, "result"))
	}
	for i, c := range objects(f, "staleAlert") {
		a, err := alertFrom(field(c, "alert"))
		if err != nil {
			t.Fatal(err)
		}
		if got := staleAlert(a, fixtureState(t, field(c, "state"))); got != field(c, "stale") {
			t.Errorf("staleAlert %d: %v", i, got)
		}
	}
}
