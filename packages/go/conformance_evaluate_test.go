package cronwatch

// conformance/evaluate.json: each scenario plays a job's life through the
// pure functions the way the client does (a run's start and finish, a check
// with stuck runs first and then missed, a silence, a changed definition),
// and every event's alerts and state must be the SDK's, byte for byte.

import (
	"fmt"
	"sort"
	"testing"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/schedule"
)

// sim is scripts/conformance.mjs's Sim: one job, its runs, and its state.
type sim struct {
	def    Definition
	stored StoredJob
	state  JobState
	runs   []*Run
	order  map[string]int
	seq    int
}

func newSim(def Definition, createdAt int64) *sim {
	return &sim{def: def, stored: StoredJob{Name: def.Name(), Definition: def, CreatedAt: createdAt, UpdatedAt: createdAt}, state: emptyState(def.Name()), order: map[string]int{}}
}

// sorted is the runs newest first, ties broken by insertion.
func (s *sim) sorted() []Run {
	out := make([]Run, len(s.runs))
	for i, r := range s.runs {
		out[i] = r.clone()
	}
	sort.SliceStable(out, func(a, b int) bool {
		if out[a].StartedAt != out[b].StartedAt {
			return out[a].StartedAt > out[b].StartedAt
		}
		return s.order[out[a].ID] > s.order[out[b].ID]
	})
	return out
}

func (s *sim) settle(previous JobState, e evaluation, now int64) []any {
	if isSilenced(previous, now) {
		e = evaluation{muteOpens(previous, e.state), nil}
	}
	s.state = e.state
	alerts := []any{}
	for _, d := range e.alerts {
		alerts = append(alerts, composeAlert(d, s.def, now).JSValue())
	}
	return alerts
}

func (s *sim) finishRun(t *testing.T, run *Run, now int64) []any {
	history := []Run{}
	for _, r := range s.sorted() {
		if r.ID != run.ID {
			history = append(history, r)
		}
	}
	previous := s.state
	e, err := onRunFinish(s.def, run.clone(), previous, history, now)
	if err != nil {
		t.Fatal(err)
	}
	return s.settle(previous, e, now)
}

func (s *sim) find(id string) *Run {
	for _, r := range s.runs {
		if r.ID == id {
			return r
		}
	}
	return nil
}

func TestConformanceEvaluate(t *testing.T) {
	scenarios := objects(fixture(t, "evaluate"), "scenarios")
	events := 0
	for _, sc := range scenarios {
		name := field(sc, "name").(string)
		t.Run(name, func(t *testing.T) {
			def, _ := definitionFrom(field(sc, "definition"))
			s := newSim(def, int64(field(sc, "createdAt").(float64)))
			for i, ev := range objects(sc, "events") {
				events++
				what := fmt.Sprintf("event %d (%s)", i, field(ev, "op"))
				expect, _ := field(ev, "expect").(*js.Object)
				switch field(ev, "op") {
				case "start":
					at := int64(field(ev, "at").(float64))
					id := field(ev, "id").(string)
					s.runs = append(s.runs, &Run{ID: id, Job: s.def.Name(), Status: StatusRunning, StartedAt: at, Metrics: Metrics{}, Trigger: "run"})
					s.seq++
					s.order[id] = s.seq
					s.state = onRunStart(s.state)
					sameJSON(t, what, js.NewObject("state", s.state.JSValue()), expect)
				case "finish":
					at := int64(field(ev, "at").(float64))
					run := s.find(field(ev, "id").(string))
					if run.Status == StatusOK || run.Status == StatusFailed {
						sameJSON(t, what, js.NewObject("alerts", []any{}, "state", s.state.JSValue(), "ignored", "was already finished as "+string(run.Status)), expect)
						continue
					}
					marked := run.Status == StatusTimeout
					run.FinishedAt = ptr(at)
					run.DurationMs = ptr(max(0, at-run.StartedAt))
					run.Metrics, run.Output, run.Error = Metrics{}, nil, nil
					run.Status = RunStatus(field(ev, "status").(string))
					if m, ok := ev.Get("metrics"); ok {
						run.Metrics, _ = metricsFrom(m)
					}
					if ev.Has("output") {
						run.Output = nullableStr(ev, "output")
					}
					if ev.Has("error") {
						run.Error = nullableStr(ev, "error")
					}
					if marked && run.Status != StatusOK {
						sameJSON(t, what, js.NewObject("alerts", []any{}, "state", s.state.JSValue()), expect)
						continue
					}
					alerts := s.finishRun(t, run, at)
					sameJSON(t, what, js.NewObject("alerts", alerts, "state", s.state.JSValue()), expect)
				case "check":
					now := int64(field(ev, "at").(float64))
					alerts := []any{}
					var running []*Run
					for _, r := range s.runs {
						if r.Status == StatusRunning {
							running = append(running, r)
						}
					}
					sort.SliceStable(running, func(a, b int) bool {
						if running[a].StartedAt != running[b].StartedAt {
							return running[a].StartedAt < running[b].StartedAt
						}
						return s.order[running[a].ID] < s.order[running[b].ID]
					})
					for _, r := range running {
						stuck, err := isStuck(s.def, *r, now)
						if err != nil {
							t.Fatal(err)
						}
						if !stuck {
							continue
						}
						timeout, _ := timeoutMs(s.def)
						r.Status = StatusTimeout
						r.FinishedAt = ptr(now)
						r.DurationMs = ptr(now - r.StartedAt)
						r.Error = ptr(fmt.Sprintf("Still running after %s; marked as timed out", schedule.FormatDuration(timeout)))
						alerts = append(alerts, s.finishRun(t, r, now)...)
					}
					recent := s.sorted()
					if len(recent) > 20 {
						recent = recent[:20]
					}
					var last *Run
					if len(recent) > 0 {
						last = &recent[0]
					}
					previous := s.state
					out, err := onCheck(s.def, s.stored, last, previous, now)
					if err != nil {
						t.Fatal(err)
					}
					alerts = append(alerts, s.settle(previous, out.evaluation, now)...)
					summary, err := summarize(s.stored, recent, s.state, out.nextExpectedAt, now)
					if err != nil {
						t.Fatal(err)
					}
					sameJSON(t, what, js.NewObject("alerts", alerts, "state", s.state.JSValue(), "nextExpectedAt", intOrNull(out.nextExpectedAt),
						"dueAt", intOrNull(out.dueAt), "summary", summary.JSValue()), expect)
				case "silence":
					s.state.SilencedUntil = ptr(int64(field(ev, "until").(float64)))
					sameJSON(t, what, js.NewObject("state", s.state.JSValue()), expect)
				case "unsilence":
					s.state.SilencedUntil = nil
					sameJSON(t, what, js.NewObject("state", s.state.JSValue()), expect)
				case "define":
					s.def, _ = definitionFrom(field(ev, "definition"))
					s.stored.Definition = s.def
				default:
					t.Fatalf("unknown op %v", field(ev, "op"))
				}
			}
		})
	}
	if events == 0 {
		t.Fatal("no events replayed")
	}
	t.Logf("%d scenarios, %d events", len(scenarios), events)
}
