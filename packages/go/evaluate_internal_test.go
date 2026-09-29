package cronwatch

// evaluate.test.ts where it adds to conformance/evaluate.json and
// health.json, and correctness.test.ts's "a failed alert names the error
// once" (composeAlert).

import (
	"math"
	"regexp"
	"strings"
	"testing"

	"cronwatch.dev/go/internal/js"
)

const (
	t0    int64 = 1767605400000
	tHour int64 = 3_600_000
	tMin  int64 = 60_000
)

var counter int

func testRun(job string, status RunStatus, startedAt int64, durationMs int64) Run {
	counter++
	r := Run{ID: "r" + js.FormatNumber(float64(counter)), Job: job, Status: status, StartedAt: startedAt, Metrics: Metrics{}, Trigger: "run"}
	if durationMs >= 0 {
		r.FinishedAt, r.DurationMs = ptr(startedAt+durationMs), ptr(durationMs)
	}
	if status == StatusFailed {
		r.Error = ptr("boom")
	}
	return r
}

func def(t *testing.T, text string) Definition {
	v, err := js.Parse(text)
	if err != nil {
		t.Fatal(err)
	}
	d, err := definitionFrom(v)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func types(drafts []alertDraft) []string {
	out := []string{}
	for _, d := range drafts {
		out = append(out, string(d.Type))
	}
	return out
}

func TestNoScheduleAndNoOpenMissedGetsNothingFromACheck(t *testing.T) {
	bare := def(t, `{"name":"j"}`)
	stored := StoredJob{Name: "j", Definition: bare, CreatedAt: t0 - tHour, UpdatedAt: t0}
	state := emptyState("j")
	state.Open = []OpenCondition{{ConditionFailed, t0}}
	state.PendingRecovery = []Condition{ConditionMissed}
	out, err := onCheck(bare, stored, nil, state, t0)
	if err != nil {
		t.Fatal(err)
	}
	if len(out.alerts) != 0 || js.Stringify(out.state) != js.Stringify(state) {
		t.Errorf("a missed already closed waits for the next successful run: %s", js.Stringify(out.state))
	}
}

func TestMissedClosedByARunStartStillRecovers(t *testing.T) {
	d := def(t, `{"name":"j","schedule":"every 1h","failuresBeforeAlert":3}`)
	stored := StoredJob{Name: "j", Definition: d, CreatedAt: t0 - 3*tHour, UpdatedAt: t0}
	missed, err := onCheck(d, stored, nil, emptyState("j"), t0)
	if err != nil || strings.Join(types(missed.alerts), ",") != "missed" {
		t.Fatal(types(missed.alerts), err)
	}
	// A run starts (closing missed without a message) and fails, below the alert threshold.
	started := onRunStart(missed.state)
	if len(started.Open) != 0 {
		t.Error("missed closed")
	}
	failed, _ := onRunFinish(d, testRun("j", StatusFailed, t0, 1000), started, nil, t0+1000)
	if len(failed.alerts) != 0 {
		t.Error(types(failed.alerts))
	}
	// The next success owes the recovery.
	good, _ := onRunFinish(d, testRun("j", StatusOK, t0+tHour, 1000), onRunStart(failed.state), nil, t0+tHour+1000)
	if strings.Join(types(good.alerts), ",") != "recovered" || js.Stringify(good.alerts[0].Details.jsValue()) != `{"after":["missed"]}` {
		t.Error(types(good.alerts))
	}
}

func TestStuckClosedByTheNextStartIsRecoveredByALaterSuccess(t *testing.T) {
	d := def(t, `{"name":"j"}`)
	stuck, _ := onRunFinish(d, testRun("j", StatusTimeout, t0-tHour, 1000), emptyState("j"), nil, t0)
	if strings.Join(types(stuck.alerts), ",") != "stuck" {
		t.Fatal(types(stuck.alerts))
	}
	// The next run starts in another process, so its finish sees stuck already closed.
	good, _ := onRunFinish(d, testRun("j", StatusOK, t0+tMin, 1000), onRunStart(stuck.state), nil, t0+2*tMin)
	if js.Stringify(good.alerts[0].Details.jsValue()) != `{"after":["stuck"]}` {
		t.Error(js.Stringify(good.alerts[0].Details.jsValue()))
	}
}

func TestARecoveryWaitsWhileAnotherConditionIsOpen(t *testing.T) {
	d := def(t, `{"name":"j","maxDuration":"5s"}`)
	failed, _ := onRunFinish(d, testRun("j", StatusFailed, t0, 1000), emptyState("j"), nil, t0)
	slowOK, _ := onRunFinish(d, testRun("j", StatusOK, t0+tHour, 6000), failed.state, nil, t0+tHour)
	if strings.Join(types(slowOK.alerts), ",") != "slow" {
		t.Errorf("failed closed, slow opened: not recovered yet: %v", types(slowOK.alerts))
	}
	fine, _ := onRunFinish(d, testRun("j", StatusOK, t0+2*tHour, 1000), slowOK.state, nil, t0+2*tHour)
	if js.Stringify(fine.alerts[0].Details.jsValue()) != `{"after":["failed","slow"]}` {
		t.Error(js.Stringify(fine.alerts[0].Details.jsValue()))
	}
}

func TestSummarizeTakesTheNewestTwentyRuns(t *testing.T) {
	stored := StoredJob{Name: "j", Definition: def(t, `{"name":"j"}`), CreatedAt: t0 - 30*tHour, UpdatedAt: t0}
	recent := []Run{testRun("j", StatusRunning, t0-tMin, -1), testRun("j", StatusFailed, t0-tHour, 1000)}
	for i := 0; i < 25; i++ {
		recent = append(recent, testRun("j", StatusOK, t0-int64(i+2)*tHour, 1000*int64(i+1)))
	}
	s, err := summarize(stored, recent, emptyState("j"), nil, t0)
	if err != nil {
		t.Fatal(err)
	}
	if s.LastRun.ID != recent[0].ID || s.Health != HealthHealthy {
		t.Errorf("last run %s, health %s", s.LastRun.ID, s.Health)
	}
	// Twenty runs in the window: one running, one failed, eighteen ok (1s to 18s).
	if s.Stats.Runs != 19 || s.Stats.OkRate != 18.0/19 || *s.Stats.P50Ms != 9000 || *s.Stats.P95Ms != 18000 {
		t.Errorf("%+v", s.Stats)
	}
}

func TestAFailedAlertNamesTheErrorOnce(t *testing.T) {
	message := func(err string) string {
		r := Run{ID: "r", Job: "j", Status: StatusFailed, StartedAt: t0, FinishedAt: ptr(t0), DurationMs: ptr(int64(5)), Error: ptr(err), Metrics: Metrics{}, Trigger: "run"}
		return composeAlert(alertDraft{AlertFailed, &r, FailureDetails{1, 1}}, def(t, `{"name":"j"}`), t0).Message
	}
	for _, c := range []struct{ err, want string }{
		{"Error: connect ECONNREFUSED 10.0.0.12:5432", `(?m)^Error: connect ECONNREFUSED`},
		{"TypeError: x is undefined", `(?m)^TypeError: x is undefined`},
		{`Output did not contain "wrote"`, `(?m)^Error: Output did not contain "wrote"`},
		{"HTTP 503 Service Unavailable", `(?m)^Error: HTTP 503`},
		{"panic: boom\n    at main.work (/app/work.go:12)", `(?m)^panic: boom`},
	} {
		m := message(c.err)
		if !regexp.MustCompile(c.want).MatchString(m) || strings.Contains(m, "Error: Error:") {
			t.Errorf("%q: %q", c.err, m)
		}
	}
}

// A foreign row's times at the 64-bit limits: no wrap, and a duration every
// store can write.
func TestRunDurationAndIsStuckAtTheInt64Limits(t *testing.T) {
	cases := []struct{ from, to, want int64 }{
		{math.MinInt64, t0, maxDurationMs},
		{math.MinInt64, math.MaxInt64, maxDurationMs},
		{math.MaxInt64, t0, 0},
		{math.MaxInt64, math.MinInt64, 0},
		{t0 - 1500, t0, 1500},
		{t0, t0, 0},
		{0, maxDurationMs + 1, maxDurationMs},
	}
	for _, c := range cases {
		if got := runDuration(c.from, c.to); got != c.want {
			t.Errorf("runDuration(%d, %d) = %d, want %d", c.from, c.to, got, c.want)
		}
	}
	running := Run{Status: StatusRunning, StartedAt: math.MinInt64}
	if stuck, err := isStuck(def(t, `{"name":"j","timeout":"5m"}`), running, t0); err != nil || !stuck {
		t.Errorf("a start at the lowest int64 is stuck: %v %v", stuck, err)
	}
	running.StartedAt = math.MaxInt64
	if stuck, _ := isStuck(def(t, `{"name":"j","timeout":"5m"}`), running, t0); stuck {
		t.Error("a start at the highest int64 is not stuck")
	}
	for _, v := range []int64{-1, maxDurationMs + 1, math.MaxInt64, math.MinInt64} {
		if got := (JobState{Version: &v}).version(); got != 0 {
			t.Errorf("version %d counts as %d, want 0", v, got)
		}
	}
}
