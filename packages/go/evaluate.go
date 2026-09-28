package cronwatch

// Pure decisions about a job's health (evaluate.ts). Each function takes the
// current state and returns the new state plus the alerts that should go
// out. Nothing here touches a store or a network, which is what makes it
// testable, and what lets conformance/evaluate.json replay a job's life
// through it event by event.

import (
	"errors"
	"fmt"
	"math"
	"strconv"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/schedule"
)

type evaluation struct {
	state  JobState
	alerts []alertDraft
}

// alertDraft is an alert before it has a title and message (composeAlert).
type alertDraft struct {
	Type    AlertType
	Run     *Run
	Details AlertDetails
}

const (
	defaultGraceMs   = 10 * 60_000
	defaultTimeoutMs = 60 * 60_000
	// Runs faster than this are never called slow, whatever the baseline says.
	slowFloorMs = 10_000
	// How many earlier runs a baseline needs before it is trusted.
	baselineMinRuns = 5
	// How many successful runs a baseline looks at, and how many runs a summary covers.
	baselineWindow = 20
)

func emptyState(job string) JobState {
	return JobState{Job: job, Open: []OpenCondition{}, PendingRecovery: []Condition{}, Undelivered: []Alert{}}
}

// normalizeState is a stored state with every field present, or a fresh
// one. State written by an older version lacks the newer fields.
func normalizeState(state *JobState, job string) JobState {
	if state == nil {
		return emptyState(job)
	}
	s := state.clone()
	if s.Job == "" {
		s.Job = job
	}
	if s.Open == nil {
		s.Open = []OpenCondition{}
	}
	if s.PendingRecovery == nil {
		s.PendingRecovery = []Condition{}
	}
	if s.Undelivered == nil {
		s.Undelivered = []Alert{}
	}
	return s
}

func cloneState(s JobState) JobState { return normalizeState(&s, s.Job) }

func openCondition(s *JobState, c Condition, now int64) bool {
	if _, ok := s.openAt(c); ok {
		return false
	}
	s.Open = append(s.Open, OpenCondition{c, now})
	return true
}

// closeCondition closes c. Every open condition has alerted, so closing one
// owes a recovered message; it is remembered until a successful run leaves
// nothing open and sends it.
func closeCondition(s *JobState, c Condition) bool {
	if !deleteOpen(s, c) {
		return false
	}
	if !hasCondition(s.PendingRecovery, c) {
		s.PendingRecovery = append(s.PendingRecovery, c)
	}
	return true
}

func deleteOpen(s *JobState, c Condition) bool {
	for i, o := range s.Open {
		if o.Condition == c {
			s.Open = append(s.Open[:i:i], s.Open[i+1:]...)
			return true
		}
	}
	return false
}

func hasCondition(list []Condition, c Condition) bool {
	for _, x := range list {
		if x == c {
			return true
		}
	}
	return false
}

func openConditions(s JobState) []Condition {
	out := make([]Condition, len(s.Open))
	for i, o := range s.Open {
		out[i] = o.Condition
	}
	return out
}

// durationField reads a duration option of a definition, or the default
// when it is absent. A present null is an error, as JavaScript's
// parseDuration(null) throws.
func durationField(def Definition, key string, fallback float64) (float64, error) {
	v, ok := def.get(key)
	if !ok {
		return fallback, nil
	}
	return schedule.ParseDuration(v, key)
}

func graceMs(def Definition) (float64, error) { return durationField(def, "grace", defaultGraceMs) }

func timeoutMs(def Definition) (float64, error) {
	return durationField(def, "timeout", defaultTimeoutMs)
}

// slowThreshold is the slow threshold for a successful run, or ok false
// when there is nothing to compare against yet.
func slowThreshold(def Definition, history []Run) (thresholdMs float64, basis string, ok bool, err error) {
	if v, has := def.get("maxDuration"); has {
		ms, err := schedule.ParseDuration(v, "maxDuration")
		if err != nil {
			return 0, "", false, err
		}
		return ms, "maxDuration", true, nil
	}
	var durations []float64
	for _, r := range history {
		if r.Status == StatusOK && r.DurationMs != nil && len(durations) < baselineWindow {
			durations = append(durations, float64(*r.DurationMs))
		}
	}
	if len(durations) < baselineMinRuns {
		return 0, "", false, nil
	}
	p95, _ := percentile(durations, 95)
	return math.Max(2*p95, slowFloorMs), fmt.Sprintf("twice the p95 of the last %d runs (%s)", len(durations), schedule.FormatDuration(p95)), true, nil
}

// budgetBreaches are the run's metrics over their ceiling, or, without one,
// over three times the job's usual value.
func budgetBreaches(def Definition, run Run, history []Run) []BudgetBreach {
	breaches := []BudgetBreach{}
	budget, _ := get(def.o, "budget").(*js.Object)
	for _, m := range run.Metrics {
		if v, ok := budget.Get(m.Name); ok {
			if ceiling := jsNumber(v); m.Value > ceiling {
				breaches = append(breaches, BudgetBreach{Metric: m.Name, Value: m.Value, Limit: jsLimit(v), Basis: "budget"})
			}
			continue
		}
		var past []float64
		for _, r := range history {
			if len(past) >= baselineWindow {
				break
			}
			if r.Status != StatusOK {
				continue
			}
			if value, ok := r.Metrics.Get(m.Name); ok {
				past = append(past, value)
			}
		}
		if len(past) < baselineMinRuns {
			continue
		}
		usual, _ := median(past)
		if usual > 0 && m.Value > 3*usual {
			breaches = append(breaches, BudgetBreach{Metric: m.Name, Value: m.Value, Limit: 3 * usual, Basis: "three times the usual " + formatNumber(usual)})
		}
	}
	return breaches
}

// jsLimit is a ceiling as it goes into an alert: the stored value when it is
// a number, which it is for every definition this package or the SDK writes.
func jsLimit(v any) float64 {
	if f, ok := v.(float64); ok {
		return f
	}
	return jsNumber(v)
}

// jsNumber is JavaScript's Number(v) for a JSON value, as a comparison
// with > coerces one.
func jsNumber(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case nil:
		return 0
	case bool:
		if t {
			return 1
		}
		return 0
	case string:
		text := js.Trim(t)
		if text == "" {
			return 0
		}
		f, err := strconv.ParseFloat(text, 64)
		if err != nil {
			return math.NaN()
		}
		return f
	}
	return math.NaN()
}

// hasFullBaseline reports whether history (newest first) holds a full
// baseline window of successful runs.
func hasFullBaseline(history []Run) bool {
	n := 0
	for _, r := range history {
		if r.Status == StatusOK {
			n++
		}
	}
	return n >= baselineWindow
}

// onRunStart is called when a run starts. Missed and stuck are about the
// absence of a run, so a run starting closes them without an alert; the
// recovered message waits for a successful finish.
func onRunStart(state JobState) JobState {
	next := cloneState(state)
	closeCondition(&next, ConditionMissed)
	closeCondition(&next, ConditionStuck)
	return next
}

// failuresBeforeAlert is Math.max(1, def.failuresBeforeAlert ?? 1).
func failuresBeforeAlert(def Definition) float64 {
	v, ok := def.get("failuresBeforeAlert")
	if !ok || v == nil {
		return 1
	}
	n := jsNumber(v)
	if math.IsNaN(n) {
		return n
	}
	return math.Max(1, n)
}

// onRunFinish is called when a run finishes with status ok, failed or
// timeout. history is the job's earlier runs, newest first, not including
// this one.
func onRunFinish(def Definition, run Run, state JobState, history []Run, now int64) (evaluation, error) {
	next := cloneState(state)
	alerts := []alertDraft{}
	r := run.clone()

	if run.Status == StatusOK {
		next.ConsecutiveFailures = 0
		closeCondition(&next, ConditionMissed)
		closeCondition(&next, ConditionStuck)
		closeCondition(&next, ConditionFailed)

		threshold, basis, ok, err := slowThreshold(def, history)
		if err != nil {
			return evaluation{}, err
		}
		if ok && run.DurationMs != nil && float64(*run.DurationMs) > threshold {
			if openCondition(&next, ConditionSlow, now) {
				alerts = append(alerts, alertDraft{AlertSlow, &r, SlowDetails{DurationMs: *run.DurationMs, ThresholdMs: threshold, Basis: basis}})
			}
		} else {
			closeCondition(&next, ConditionSlow)
		}

		if breaches := budgetBreaches(def, run, history); len(breaches) > 0 {
			if openCondition(&next, ConditionOverBudget, now) {
				alerts = append(alerts, alertDraft{AlertOverBudget, &r, OverBudgetDetails{Breaches: breaches}})
			}
		} else {
			closeCondition(&next, ConditionOverBudget)
		}

		if len(next.PendingRecovery) > 0 && len(next.Open) == 0 {
			after := append([]Condition{}, next.PendingRecovery...)
			alerts = append(alerts, alertDraft{AlertRecovered, &r, RecoveredDetails{After: after}})
			next.PendingRecovery = []Condition{}
		}
		return evaluation{next, alerts}, nil
	}

	// failed or timeout
	next.ConsecutiveFailures++
	closeCondition(&next, ConditionMissed)
	threshold := failuresBeforeAlert(def)
	condition, alertType := ConditionFailed, AlertFailed
	if run.Status == StatusTimeout {
		condition, alertType = ConditionStuck, AlertStuck
	}
	if float64(next.ConsecutiveFailures) >= threshold {
		if openCondition(&next, condition, now) {
			alerts = append(alerts, alertDraft{alertType, &r, FailureDetails{ConsecutiveFailures: next.ConsecutiveFailures, Threshold: int(threshold)}})
		}
	}
	return evaluation{next, alerts}, nil
}

// checkOutcome is what onCheck found besides the evaluation.
type checkOutcome struct {
	evaluation
	nextExpectedAt *int64
	dueAt          *int64
}

// truthy is JavaScript's truthiness of a JSON value.
func truthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	case float64:
		return t != 0 && !math.IsNaN(t)
	case string:
		return t != ""
	}
	return true
}

// parsedSchedule is parseSchedule(def.schedule, def.timezone) for a stored
// definition, which may hold anything another writer put there.
func parsedSchedule(def Definition) (*schedule.Parsed, error) {
	text, ok := get(def.o, "schedule").(string)
	if !ok {
		return nil, errors.New("schedule.trim is not a function")
	}
	tz := ""
	if v, has := def.get("timezone"); has && v != nil {
		s, ok := v.(string)
		if !ok {
			return nil, fmt.Errorf("timezone %s is not an IANA timezone", js.Stringify(v))
		}
		tz = s
	}
	return schedule.Parse(text, tz)
}

// onCheck is called by a check. It decides whether the schedule has been
// missed: the run the schedule wants next (see schedule.Expect) has not
// started and its grace has run out. lastRun is the most recent run of any
// status. A job with no schedule is never missed, and one whose schedule
// was removed while missed was open gets a recovered alert (reason
// "unscheduled") for missed alone.
func onCheck(def Definition, stored StoredJob, lastRun *Run, state JobState, now int64) (checkOutcome, error) {
	next := cloneState(state)
	alerts := []alertDraft{}
	if !truthy(get(def.o, "schedule")) {
		if since, open := next.openAt(ConditionMissed); open {
			// The schedule went away while missed was open (the job was
			// declared again without one, or a source retired it), so
			// nothing is due any more. Missed closes now with a recovery of
			// its own; other open conditions keep their own rules. Missed is
			// taken out of the pending recovery too, so the next successful
			// run does not name it again.
			deleteOpen(&next, ConditionMissed)
			pending := []Condition{}
			for _, c := range next.PendingRecovery {
				if c != ConditionMissed {
					pending = append(pending, c)
				}
			}
			next.PendingRecovery = pending
			alerts = append(alerts, alertDraft{AlertRecovered, cloneRun(lastRun), RecoveredDetails{After: []Condition{ConditionMissed}, Reason: "unscheduled", Since: ptr(since)}})
		}
		return checkOutcome{evaluation: evaluation{next, alerts}}, nil
	}

	parsed, err := parsedSchedule(def)
	if err != nil {
		return checkOutcome{}, err
	}
	grace, err := graceMs(def)
	if err != nil {
		return checkOutcome{}, err
	}
	var lastRunAt *int64
	if lastRun != nil {
		lastRunAt = ptr(lastRun.StartedAt)
	}
	exp, hasExp := schedule.Expect(parsed, lastRunAt, stored.CreatedAt, grace)
	var nextAt int64
	var hasNext bool
	if parsed.Kind == "interval" {
		nextAt, hasNext = schedule.NextFire(parsed, stored.CreatedAt, lastRunAt)
	} else {
		nextAt, hasNext = schedule.NextFire(parsed, now, nil)
	}
	out := checkOutcome{}
	if hasNext {
		out.nextExpectedAt = ptr(nextAt)
	}
	if !hasExp {
		out.evaluation = evaluation{next, alerts}
		return out, nil
	}
	out.dueAt = ptr(exp.DueAt)

	// An interval's next run is due a period after the last one started. If
	// that run is still going, the job is busy, not late; stuck covers one
	// that never ends.
	if parsed.Kind == "interval" && lastRun != nil && lastRun.Status == StatusRunning {
		out.evaluation = evaluation{next, alerts}
		return out, nil
	}

	if float64(now) > exp.Deadline {
		if openCondition(&next, ConditionMissed, now) {
			alerts = append(alerts, alertDraft{AlertMissed, cloneRun(lastRun), MissedDetails{DueAt: exp.DueAt, Deadline: exp.Deadline, GraceMs: grace, LastRunAt: lastRunAt}})
		}
	} else {
		// A run has started since it opened, or the grace was widened.
		closeCondition(&next, ConditionMissed)
	}
	out.evaluation = evaluation{next, alerts}
	return out, nil
}

func cloneRun(r *Run) *Run {
	if r == nil {
		return nil
	}
	c := r.clone()
	return &c
}

// isStuck reports whether a running run has gone on longer than the job's timeout.
func isStuck(def Definition, run Run, now int64) (bool, error) {
	if run.Status != StatusRunning {
		return false, nil
	}
	timeout, err := timeoutMs(def)
	if err != nil {
		return false, err
	}
	return float64(now-run.StartedAt) > timeout, nil
}

// muteOpens is next with nothing opened that was not open in previous.
// While a job is silenced nothing new is recorded as an incident:
// conditions may close (so a job that recovered during the silence shows
// as healthy) but none may open, so the first problem after the silence
// ends alerts normally.
func muteOpens(previous, next JobState) JobState {
	muted := cloneState(next)
	kept := []OpenCondition{}
	for _, o := range muted.Open {
		if _, was := previous.openAt(o.Condition); was {
			kept = append(kept, o)
		}
	}
	muted.Open = kept
	return muted
}

func isSilenced(state JobState, now int64) bool {
	return state.SilencedUntil != nil && *state.SilencedUntil > now
}

// applySilence is an evaluation as it is saved and sent: while the job was
// silenced when it began, nothing opens and nothing is sent.
func applySilence(previous JobState, e evaluation, now int64) evaluation {
	if !isSilenced(previous, now) {
		return e
	}
	return evaluation{muteOpens(previous, e.state), []alertDraft{}}
}

// staleAlert reports whether an alert waiting to be retried no longer
// describes the job, so it is dropped rather than sent late. An alert for a
// condition is stale once that condition has closed, or has closed and
// opened again (it opened at a time other than the alert's). A recovery is
// stale when any condition it names is open again; while they all stay
// closed it is kept.
func staleAlert(alert Alert, state JobState) bool {
	if alert.Type == AlertRecovered {
		d, _ := alert.Details.(RecoveredDetails)
		for _, c := range d.After {
			if _, open := state.openAt(c); open {
				return true
			}
		}
		return false
	}
	at, open := state.openAt(Condition(alert.Type))
	return !open || at != alert.At
}

// jobHealth is how a job looks at a glance. Silence wins, then stuck,
// failing and late.
func jobHealth(def Definition, lastRun *Run, state JobState, now int64) (JobHealth, error) {
	open := openConditions(state)
	if isSilenced(state, now) {
		return HealthSilenced, nil
	}
	if hasCondition(open, ConditionStuck) {
		return HealthStuck, nil
	}
	if lastRun != nil {
		stuck, err := isStuck(def, *lastRun, now)
		if err != nil {
			return "", err
		}
		if stuck {
			return HealthStuck, nil
		}
	}
	if hasCondition(open, ConditionFailed) || (lastRun != nil && (lastRun.Status == StatusFailed || lastRun.Status == StatusTimeout)) {
		return HealthFailing, nil
	}
	if hasCondition(open, ConditionMissed) {
		return HealthLate, nil
	}
	if lastRun == nil {
		return HealthNeverRan, nil
	}
	return HealthHealthy, nil
}

// summarize is a job's summary from its most recent runs (newest first;
// the first baselineWindow are used) and its state. Stats cover runs of any
// status; the percentiles are over the successful ones among them.
func summarize(stored StoredJob, recent []Run, state JobState, nextExpectedAt *int64, now int64) (JobSummary, error) {
	var herr error
	s := summary(stored, recent, state, nextExpectedAt, func(lastRun *Run) JobHealth {
		h, err := jobHealth(stored.Definition, lastRun, state, now)
		herr = err
		return h
	})
	return s, herr
}

// unevaluableSummary is the summary of a job that could not be evaluated,
// say because its stored schedule no longer parses. It reads nothing from
// the definition. The job shows as failing (or silenced, while it is),
// since it needs a look, and nothing is known about when it is next due.
func unevaluableSummary(stored StoredJob, recent []Run, state JobState, now int64) JobSummary {
	return summary(stored, recent, state, nil, func(*Run) JobHealth {
		if isSilenced(state, now) {
			return HealthSilenced
		}
		return HealthFailing
	})
}

func summary(stored StoredJob, recent []Run, state JobState, nextExpectedAt *int64, health func(*Run) JobHealth) JobSummary {
	window := recent
	if len(window) > baselineWindow {
		window = window[:baselineWindow]
	}
	var lastRun *Run
	if len(window) > 0 {
		lastRun = cloneRun(&window[0])
	}
	finished, ok := 0, 0
	var okDurations []float64
	for _, r := range window {
		if r.Status != StatusRunning {
			finished++
		}
		if r.Status == StatusOK {
			ok++
			if r.DurationMs != nil {
				okDurations = append(okDurations, float64(*r.DurationMs))
			}
		}
	}
	okRate := 1.0
	if finished > 0 {
		okRate = float64(ok) / float64(finished)
	}
	return JobSummary{
		Name:                stored.Name,
		Definition:          stored.Definition,
		Health:              health(lastRun),
		Open:                openConditions(state),
		LastRun:             lastRun,
		NextExpectedAt:      copyInt(nextExpectedAt),
		ConsecutiveFailures: state.ConsecutiveFailures,
		SilencedUntil:       copyInt(state.SilencedUntil),
		Stats:               Stats{Runs: finished, OkRate: okRate, P50Ms: percentileInt(okDurations, 50), P95Ms: percentileInt(okDurations, 95)},
	}
}

func percentileInt(values []float64, p float64) *int64 {
	v, ok := percentile(values, p)
	if !ok {
		return nil
	}
	n := int64(v)
	return &n
}
