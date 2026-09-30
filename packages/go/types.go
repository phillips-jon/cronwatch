package cronwatch

import (
	"fmt"
	"math"

	"cronwatch.dev/go/internal/js"
)

// Everything public about a job, a run and an alert. Each type writes the
// SDK's JSON (MarshalJSON): the same field names, in the same order, with
// numbers as JavaScript prints them, so a Go process and a Node, Ruby,
// Python or PHP process can share one store and @cronwatch/mcp reads any of
// them.

// RunStatus is where a run stands.
type RunStatus string

// The statuses a run moves through.
const (
	StatusRunning RunStatus = "running"
	StatusOK      RunStatus = "ok"
	StatusFailed  RunStatus = "failed"
	StatusTimeout RunStatus = "timeout"
)

// Condition is something wrong with a job that opens once, alerts, and
// closes with a recovery.
type Condition string

// The conditions, in the SDK's order.
const (
	ConditionMissed     Condition = "missed"
	ConditionFailed     Condition = "failed"
	ConditionStuck      Condition = "stuck"
	ConditionSlow       Condition = "slow"
	ConditionOverBudget Condition = "over_budget"
)

// AlertType is a condition opening, or "recovered".
type AlertType string

// The alert types.
const (
	AlertMissed     AlertType = "missed"
	AlertFailed     AlertType = "failed"
	AlertStuck      AlertType = "stuck"
	AlertSlow       AlertType = "slow"
	AlertOverBudget AlertType = "over_budget"
	AlertRecovered  AlertType = "recovered"
)

// JobHealth is how a job looks at a glance.
type JobHealth string

// The healths a summary reports.
const (
	HealthHealthy  JobHealth = "healthy"
	HealthLate     JobHealth = "late"
	HealthFailing  JobHealth = "failing"
	HealthStuck    JobHealth = "stuck"
	HealthSilenced JobHealth = "silenced"
	HealthNeverRan JobHealth = "never_ran"
)

// Metric is one number a run reported.
type Metric struct {
	Name  string
	Value float64
}

// Metrics are a run's numbers in JavaScript's key order: names that are
// array indices ("10", "200") first in ascending order, then the rest in
// the order they were first reported. Budgets use the same type.
type Metrics []Metric

// Get is the value reported for name.
func (m Metrics) Get(name string) (float64, bool) {
	for _, e := range m {
		if e.Name == name {
			return e.Value, true
		}
	}
	return 0, false
}

// Set reports a value for name: a later value replaces an earlier one in
// its place, and a new name takes its place in JavaScript's order.
func (m *Metrics) Set(name string, value float64) {
	for i, e := range *m {
		if e.Name == name {
			(*m)[i].Value = value
			return
		}
	}
	n, isIndex := js.ArrayIndex(name)
	at := len(*m)
	if isIndex {
		for i, e := range *m {
			if k, ok := js.ArrayIndex(e.Name); !ok || k > n {
				at = i
				break
			}
		}
	}
	*m = append(*m, Metric{})
	copy((*m)[at+1:], (*m)[at:])
	(*m)[at] = Metric{name, value}
}

// Clone is a copy that shares nothing.
func (m Metrics) Clone() Metrics {
	if m == nil {
		return Metrics{}
	}
	return append(Metrics{}, m...)
}

// merged is {...m, ...over}.
func (m Metrics) merged(over Metrics) Metrics {
	out := m.Clone()
	for _, e := range over {
		out.Set(e.Name, e.Value)
	}
	return out
}

// JSValue is the metrics as a JSON object.
func (m Metrics) JSValue() any {
	o := &js.Object{}
	for _, e := range m {
		o.Set(e.Name, e.Value)
	}
	return o
}

// MarshalJSON writes the SDK's JSON.
func (m Metrics) MarshalJSON() ([]byte, error) { return []byte(js.Stringify(m)), nil }

// UnmarshalJSON reads a JSON object of numbers.
func (m *Metrics) UnmarshalJSON(b []byte) error { return unmarshal(b, m, metricsFrom) }

func metricsFrom(v any) (Metrics, error) {
	o, ok := v.(*js.Object)
	if !ok {
		if v == nil {
			return Metrics{}, nil
		}
		return nil, fmt.Errorf("metrics must be an object, not %s", kind(v))
	}
	out := Metrics{}
	for _, k := range o.Keys() {
		x, _ := o.Get(k)
		f, ok := x.(float64)
		if !ok {
			return nil, fmt.Errorf("metric %q must be a number, not %s", k, kind(x))
		}
		out.Set(k, f)
	}
	return out, nil
}

// numberMetrics is a stored row's metrics as the SDK reads them: the
// numbers of an object, whatever else it holds, and none for anything else.
func numberMetrics(v any) Metrics {
	out := Metrics{}
	if o, ok := v.(*js.Object); ok {
		for _, k := range o.Keys() {
			x, _ := o.Get(k)
			if f, ok := x.(float64); ok {
				out.Set(k, f)
			}
		}
	}
	return out
}

// Run is one execution of a job, as a store keeps it. Times are epoch
// milliseconds.
type Run struct {
	ID         string
	Job        string
	Status     RunStatus
	StartedAt  int64
	FinishedAt *int64
	DurationMs *int64
	Error      *string
	// Lines logged, or the string the job returned. Capped at 16 KB.
	Output  *string
	Metrics Metrics
	// What started the run: "run", "handler", "start" or a value of yours.
	Trigger string
}

// clone is a copy that shares nothing.
func (r Run) clone() Run {
	c := r
	c.FinishedAt = copyInt(r.FinishedAt)
	c.DurationMs = copyInt(r.DurationMs)
	c.Error = copyStr(r.Error)
	c.Output = copyStr(r.Output)
	c.Metrics = r.Metrics.Clone()
	return c
}

// JSValue is the run as the SDK writes it.
func (r Run) JSValue() any {
	return js.NewObject(
		"id", r.ID, "job", r.Job, "status", string(r.Status), "startedAt", r.StartedAt,
		"finishedAt", intOrNull(r.FinishedAt), "durationMs", intOrNull(r.DurationMs),
		"error", strOrNull(r.Error), "output", strOrNull(r.Output), "metrics", r.Metrics.JSValue(), "trigger", r.Trigger,
	)
}

// MarshalJSON writes the SDK's JSON.
func (r Run) MarshalJSON() ([]byte, error) { return []byte(js.Stringify(r)), nil }

// UnmarshalJSON reads the SDK's JSON.
func (r *Run) UnmarshalJSON(b []byte) error { return unmarshal(b, r, runFrom) }

func runFrom(v any) (Run, error) {
	o, ok := v.(*js.Object)
	if !ok {
		return Run{}, fmt.Errorf("a run must be an object, not %s", kind(v))
	}
	var r Run
	var err error
	r.ID = str(o, "id")
	r.Job = str(o, "job")
	r.Status = RunStatus(str(o, "status"))
	r.StartedAt = integer(o, "startedAt")
	r.FinishedAt = nullableInt(o, "finishedAt")
	r.DurationMs = nullableInt(o, "durationMs")
	r.Error = nullableStr(o, "error")
	r.Output = nullableStr(o, "output")
	m, _ := o.Get("metrics")
	if r.Metrics, err = metricsFrom(m); err != nil {
		return Run{}, err
	}
	r.Trigger = str(o, "trigger")
	return r, nil
}

// Definition is a job's definition as a store holds it: the SDK's JSON
// object, its fields in the order they were given (defaults, then the
// job's options, then name), `expect` described in words. Fields a newer
// writer added are kept.
type Definition struct {
	o *js.Object
}

// Name is the job's name.
func (d Definition) Name() string { return str(d.o, "name") }

// Schedule is the cron expression or "every <duration>", or "".
func (d Definition) Schedule() string { return str(d.o, "schedule") }

// Timezone is the IANA zone the schedule is read in, or "".
func (d Definition) Timezone() string { return str(d.o, "timezone") }

// Description is the job's description, or "".
func (d Definition) Description() string { return str(d.o, "description") }

// Expect describes the expect rule ("contains \"done\""), or "".
func (d Definition) Expect() string { return str(d.o, "expect") }

// Tags are the job's tags.
func (d Definition) Tags() []string {
	v, _ := d.o.Get("tags")
	list, _ := v.([]any)
	var out []string
	for _, t := range list {
		if s, ok := t.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// Get is a field as JSON reads it (a string, a float64, a bool, nil, a
// []any or a map), and whether it is there.
func (d Definition) Get(key string) (any, bool) {
	v, ok := d.o.Get(key)
	return plain(v), ok
}

// Keys are the fields present, in order.
func (d Definition) Keys() []string { return d.o.Keys() }

func (d Definition) get(key string) (any, bool) { return d.o.Get(key) }

func (d Definition) clone() Definition { return Definition{d.o.Clone()} }

// JSValue is the definition as a JSON object.
func (d Definition) JSValue() any {
	if d.o == nil {
		return &js.Object{}
	}
	return d.o
}

// MarshalJSON writes the SDK's JSON.
func (d Definition) MarshalJSON() ([]byte, error) { return []byte(js.Stringify(d)), nil }

// UnmarshalJSON reads a JSON object.
func (d *Definition) UnmarshalJSON(b []byte) error { return unmarshal(b, d, definitionFrom) }

func definitionFrom(v any) (Definition, error) {
	o, ok := v.(*js.Object)
	if !ok {
		return Definition{}, fmt.Errorf("a definition must be an object, not %s", kind(v))
	}
	return Definition{o}, nil
}

// StoredJob is a job as a store knows it.
type StoredJob struct {
	Name       string
	Definition Definition
	CreatedAt  int64
	UpdatedAt  int64
}

// OpenCondition is a condition that is open, and when it opened.
type OpenCondition struct {
	Condition Condition
	Since     int64
}

// JobState is what the checks remember about a job between runs.
type JobState struct {
	Job string
	// Conditions currently open, in the order they opened.
	Open                []OpenCondition
	ConsecutiveFailures int
	SilencedUntil       *int64
	// When an alert last reached at least one channel.
	LastAlertAt *int64
	// Conditions that alerted and have since closed, waiting for the
	// recovered alert the next successful run sends. Nil is a state written
	// before the field existed (absent from the JSON).
	PendingRecovery []Condition
	// Alerts no channel accepted, each retried once per check. Nil is absent.
	Undelivered []Alert
	// Goes up by one on every write (see Store.CompareAndSetState). Nil is
	// a state written before versions, which counts as 0, as does a
	// version outside 0 to 2^53 - 1. One that is not a whole number (a
	// foreign row's 1.5 or "x") reads as nil.
	Version *int64

	// Keys after the known ones, in stored order: "version" and any a newer
	// writer added (their values in extra), so a state is written back as
	// the SDK's spread would write it.
	tail  []string
	extra map[string]any
}

func (s JobState) openAt(c Condition) (int64, bool) {
	for _, o := range s.Open {
		if o.Condition == c {
			return o.Since, true
		}
	}
	return 0, false
}

// version is the version the state counts as for CompareAndSetState, as
// the SDK's stateVersion() reads it: a whole number from 0 to 2^53 - 1,
// else 0. The SQL stores read it the same way, so a foreign row's 1.5, "x"
// or -1 is written over by the next update instead of refusing every
// compare-and-set of its job for good.
func (s JobState) version() int64 {
	if s.Version == nil || *s.Version < 0 || *s.Version > maxDurationMs {
		return 0
	}
	return *s.Version
}

// clone is a copy that shares nothing.
func (s JobState) clone() JobState {
	c := s
	c.Open = append([]OpenCondition(nil), s.Open...)
	if s.Open != nil && len(s.Open) == 0 {
		c.Open = []OpenCondition{}
	}
	c.SilencedUntil = copyInt(s.SilencedUntil)
	c.LastAlertAt = copyInt(s.LastAlertAt)
	if s.PendingRecovery != nil {
		c.PendingRecovery = append([]Condition{}, s.PendingRecovery...)
	}
	if s.Undelivered != nil {
		c.Undelivered = make([]Alert, len(s.Undelivered))
		for i, a := range s.Undelivered {
			c.Undelivered[i] = a.clone()
		}
	}
	c.Version = copyInt(s.Version)
	c.tail = append([]string(nil), s.tail...)
	if s.extra != nil {
		c.extra = map[string]any{}
		for k, v := range s.extra {
			c.extra[k] = js.CloneValue(v)
		}
	}
	return c
}

// JSValue is the state as the SDK writes it.
func (s JobState) JSValue() any {
	open := &js.Object{}
	for _, c := range s.Open {
		open.Set(string(c.Condition), c.Since)
	}
	o := js.NewObject("job", s.Job, "open", open, "consecutiveFailures", s.ConsecutiveFailures,
		"silencedUntil", intOrNull(s.SilencedUntil), "lastAlertAt", intOrNull(s.LastAlertAt))
	if s.PendingRecovery != nil {
		list := make([]any, len(s.PendingRecovery))
		for i, c := range s.PendingRecovery {
			list[i] = string(c)
		}
		o.Set("pendingRecovery", list)
	}
	if s.Undelivered != nil {
		list := make([]any, len(s.Undelivered))
		for i, a := range s.Undelivered {
			list[i] = a.JSValue()
		}
		o.Set("undelivered", list)
	}
	wroteVersion := false
	for _, k := range s.tail {
		if k == "version" {
			if s.Version != nil {
				o.Set("version", *s.Version)
				wroteVersion = true
			}
			continue
		}
		if v, ok := s.extra[k]; ok {
			o.Set(k, v)
		}
	}
	if s.Version != nil && !wroteVersion {
		o.Set("version", *s.Version)
	}
	return o
}

// MarshalJSON writes the SDK's JSON.
func (s JobState) MarshalJSON() ([]byte, error) { return []byte(js.Stringify(s)), nil }

// UnmarshalJSON reads the SDK's JSON.
func (s *JobState) UnmarshalJSON(b []byte) error { return unmarshal(b, s, stateFrom) }

var stateKeys = map[string]bool{
	"job": true, "open": true, "consecutiveFailures": true, "silencedUntil": true, "lastAlertAt": true,
	"pendingRecovery": true, "undelivered": true,
}

func stateFrom(v any) (JobState, error) {
	o, ok := v.(*js.Object)
	if !ok {
		return JobState{}, fmt.Errorf("a job state must be an object, not %s", kind(v))
	}
	s := JobState{Job: str(o, "job"), Open: []OpenCondition{}}
	if open, ok := get(o, "open").(*js.Object); ok {
		for _, k := range open.Keys() {
			at, _ := open.Get(k)
			s.Open = append(s.Open, OpenCondition{Condition(k), toInt(at)})
		}
	}
	s.ConsecutiveFailures = failureCount(get(o, "consecutiveFailures"))
	s.SilencedUntil = nullableInt(o, "silencedUntil")
	s.LastAlertAt = nullableInt(o, "lastAlertAt")
	if list, ok := get(o, "pendingRecovery").([]any); ok {
		s.PendingRecovery = []Condition{}
		for _, c := range list {
			if name, ok := c.(string); ok {
				s.PendingRecovery = append(s.PendingRecovery, Condition(name))
			}
		}
	}
	if list, ok := get(o, "undelivered").([]any); ok {
		s.Undelivered = []Alert{}
		for _, a := range list {
			// An entry that is not an alert is dropped rather than fail
			// every read of the state: it could never be delivered.
			if alert, err := alertFrom(a); err == nil {
				s.Undelivered = append(s.Undelivered, alert)
			}
		}
	}
	for _, k := range o.Keys() {
		if stateKeys[k] {
			continue
		}
		s.tail = append(s.tail, k)
		if k == "version" {
			// A whole number is kept as it is (version() counts one outside
			// 0 to 2^53 - 1 as 0); anything else (a foreign row's 1.5 or
			// "x") reads as none, which counts as 0 too.
			if f, ok := get(o, "version").(float64); ok && f == math.Trunc(f) && f >= math.MinInt64 && f < math.MaxInt64 {
				s.Version = ptr(int64(f))
			}
			continue
		}
		if s.extra == nil {
			s.extra = map[string]any{}
		}
		s.extra[k], _ = o.Get(k)
	}
	return s, nil
}

// BudgetBreach is one metric over its ceiling or its baseline.
type BudgetBreach struct {
	Metric string
	Value  float64
	Limit  float64
	// "budget", or how the baseline was worked out.
	Basis string
}

func (b BudgetBreach) jsValue() any {
	return js.NewObject("metric", b.Metric, "value", b.Value, "limit", b.Limit, "basis", b.Basis)
}

// AlertDetails is what an alert carries beyond its title and message: a
// MissedDetails, FailureDetails (failed and stuck), SlowDetails,
// OverBudgetDetails or RecoveredDetails.
type AlertDetails interface {
	jsValue() any
}

// MissedDetails says which run was missed.
type MissedDetails struct {
	DueAt     int64
	Deadline  float64
	GraceMs   float64
	LastRunAt *int64
}

func (d MissedDetails) jsValue() any {
	return js.NewObject("dueAt", d.DueAt, "deadline", d.Deadline, "graceMs", d.GraceMs, "lastRunAt", intOrNull(d.LastRunAt))
}

// FailureDetails counts the failures behind a failed or stuck alert.
type FailureDetails struct {
	ConsecutiveFailures int
	Threshold           int
}

func (d FailureDetails) jsValue() any {
	return js.NewObject("consecutiveFailures", d.ConsecutiveFailures, "threshold", d.Threshold)
}

// SlowDetails says how slow a run was.
type SlowDetails struct {
	DurationMs  int64
	ThresholdMs float64
	// "maxDuration", or how the baseline was worked out.
	Basis string
}

func (d SlowDetails) jsValue() any {
	return js.NewObject("durationMs", d.DurationMs, "thresholdMs", d.ThresholdMs, "basis", d.Basis)
}

// OverBudgetDetails lists the metrics over their limits.
type OverBudgetDetails struct {
	Breaches []BudgetBreach
}

func (d OverBudgetDetails) jsValue() any {
	list := make([]any, len(d.Breaches))
	for i, b := range d.Breaches {
		list[i] = b.jsValue()
	}
	return js.NewObject("breaches", list)
}

// RecoveredDetails names the conditions that closed. Reason "unscheduled"
// closes missed alone because the job no longer has a schedule; Since is
// when missed opened.
type RecoveredDetails struct {
	After  []Condition
	Reason string
	Since  *int64
}

func (d RecoveredDetails) jsValue() any {
	after := make([]any, len(d.After))
	for i, c := range d.After {
		after[i] = string(c)
	}
	o := js.NewObject("after", after)
	if d.Reason != "" {
		o.Set("reason", d.Reason)
	}
	if d.Since != nil {
		o.Set("since", *d.Since)
	}
	return o
}

// Alert is a condition opening or closing, with the text every channel shows.
type Alert struct {
	Type AlertType
	// The run behind the alert, when there is one.
	Run     *Run
	Details AlertDetails
	Job     string
	// The job's definition when the alert was made.
	Definition Definition
	// One line, suitable as a notification title.
	Title string
	// A few lines of plain text with the specifics.
	Message string
	// A short diagnosis from the triage function, when one is configured.
	// Nil with TriageTried set means triage was tried and gave nothing; it
	// is not tried again for this alert.
	Triage      *string
	TriageTried bool
	At          int64
}

func (a Alert) clone() Alert {
	c := a
	if a.Run != nil {
		r := a.Run.clone()
		c.Run = &r
	}
	c.Definition = a.Definition.clone()
	c.Triage = copyStr(a.Triage)
	// The details' slices and pointers too, so a channel that changes what
	// it was given changes nothing another channel or a store holds.
	switch d := a.Details.(type) {
	case MissedDetails:
		d.LastRunAt = copyInt(d.LastRunAt)
		c.Details = d
	case OverBudgetDetails:
		d.Breaches = append([]BudgetBreach(nil), d.Breaches...)
		c.Details = d
	case RecoveredDetails:
		d.After = append([]Condition(nil), d.After...)
		d.Since = copyInt(d.Since)
		c.Details = d
	}
	return c
}

// JSValue is the alert as the SDK writes it.
func (a Alert) JSValue() any {
	var run any
	if a.Run != nil {
		run = a.Run.JSValue()
	}
	var details any = &js.Object{}
	if a.Details != nil {
		details = a.Details.jsValue()
	}
	o := js.NewObject("type", string(a.Type), "run", run, "details", details, "job", a.Job,
		"definition", a.Definition.JSValue(), "title", a.Title, "message", a.Message, "at", a.At)
	if a.TriageTried || a.Triage != nil {
		o.Set("triage", strOrNull(a.Triage))
	}
	return o
}

// MarshalJSON writes the SDK's JSON.
func (a Alert) MarshalJSON() ([]byte, error) { return []byte(js.Stringify(a)), nil }

// UnmarshalJSON reads the SDK's JSON.
func (a *Alert) UnmarshalJSON(b []byte) error { return unmarshal(b, a, alertFrom) }

func alertFrom(v any) (Alert, error) {
	o, ok := v.(*js.Object)
	if !ok {
		return Alert{}, fmt.Errorf("an alert must be an object, not %s", kind(v))
	}
	a := Alert{Type: AlertType(str(o, "type")), Job: str(o, "job"), Title: str(o, "title"), Message: str(o, "message"), At: integer(o, "at")}
	if r := get(o, "run"); r != nil {
		// A queued alert's run keeps the metrics that are numbers, as a
		// stored run row does, so one another writer stored otherwise
		// cannot fail every read of the job's state.
		if ro, ok := r.(*js.Object); ok {
			ro = ro.Clone()
			m, _ := ro.Get("metrics")
			ro.Set("metrics", numberMetrics(m).JSValue())
			r = ro
		}
		run, err := runFrom(r)
		if err != nil {
			return Alert{}, err
		}
		a.Run = &run
	}
	details, _ := get(o, "details").(*js.Object)
	a.Details = detailsFrom(a.Type, details)
	if d, ok := get(o, "definition").(*js.Object); ok {
		a.Definition = Definition{d}
	} else {
		a.Definition = Definition{&js.Object{}}
	}
	if o.Has("triage") {
		a.TriageTried = true
		a.Triage = nullableStr(o, "triage")
	}
	return a, nil
}

func detailsFrom(t AlertType, o *js.Object) AlertDetails {
	switch t {
	case AlertMissed:
		return MissedDetails{DueAt: integer(o, "dueAt"), Deadline: toFloat(get(o, "deadline")), GraceMs: toFloat(get(o, "graceMs")), LastRunAt: nullableInt(o, "lastRunAt")}
	case AlertFailed, AlertStuck:
		return FailureDetails{ConsecutiveFailures: int(integer(o, "consecutiveFailures")), Threshold: int(integer(o, "threshold"))}
	case AlertSlow:
		return SlowDetails{DurationMs: integer(o, "durationMs"), ThresholdMs: toFloat(get(o, "thresholdMs")), Basis: str(o, "basis")}
	case AlertOverBudget:
		var d OverBudgetDetails
		d.Breaches = []BudgetBreach{}
		list, _ := get(o, "breaches").([]any)
		for _, b := range list {
			bo, _ := b.(*js.Object)
			d.Breaches = append(d.Breaches, BudgetBreach{Metric: str(bo, "metric"), Value: toFloat(get(bo, "value")), Limit: toFloat(get(bo, "limit")), Basis: str(bo, "basis")})
		}
		return d
	case AlertRecovered:
		d := RecoveredDetails{After: []Condition{}, Reason: str(o, "reason"), Since: nullableInt(o, "since")}
		list, _ := get(o, "after").([]any)
		for _, c := range list {
			if s, ok := c.(string); ok {
				d.After = append(d.After, Condition(s))
			}
		}
		return d
	}
	return FailureDetails{}
}

// Stats summarize a job's last twenty runs of any status; the percentiles
// are over the successful ones among them.
type Stats struct {
	Runs   int
	OkRate float64
	P50Ms  *int64
	P95Ms  *int64
}

// JobSummary is a job and its health, as the dashboard shows it.
type JobSummary struct {
	Name       string
	Definition Definition
	Health     JobHealth
	Open       []Condition
	LastRun    *Run
	// When the schedule says the next run is due. Nil without a schedule.
	NextExpectedAt      *int64
	ConsecutiveFailures int
	SilencedUntil       *int64
	Stats               Stats
}

// JSValue is the summary as the SDK writes it.
func (s JobSummary) JSValue() any {
	open := make([]any, len(s.Open))
	for i, c := range s.Open {
		open[i] = string(c)
	}
	var last any
	if s.LastRun != nil {
		last = s.LastRun.JSValue()
	}
	stats := js.NewObject("runs", s.Stats.Runs, "okRate", s.Stats.OkRate, "p50Ms", intOrNull(s.Stats.P50Ms), "p95Ms", intOrNull(s.Stats.P95Ms))
	return js.NewObject("name", s.Name, "definition", s.Definition.JSValue(), "health", string(s.Health), "open", open,
		"lastRun", last, "nextExpectedAt", intOrNull(s.NextExpectedAt), "consecutiveFailures", s.ConsecutiveFailures,
		"silencedUntil", intOrNull(s.SilencedUntil), "stats", stats)
}

// MarshalJSON writes the SDK's JSON.
func (s JobSummary) MarshalJSON() ([]byte, error) { return []byte(js.Stringify(s)), nil }

// CheckResult is what a check found and sent.
type CheckResult struct {
	CheckedAt int64
	Jobs      []JobSummary
	Alerts    []Alert
	Pruned    int
}

// JSValue is the result as the SDK writes it.
func (c CheckResult) JSValue() any {
	jobs := make([]any, len(c.Jobs))
	for i, j := range c.Jobs {
		jobs[i] = j.JSValue()
	}
	alerts := make([]any, len(c.Alerts))
	for i, a := range c.Alerts {
		alerts[i] = a.JSValue()
	}
	return js.NewObject("checkedAt", c.CheckedAt, "jobs", jobs, "alerts", alerts, "pruned", c.Pruned)
}

// MarshalJSON writes the SDK's JSON.
func (c CheckResult) MarshalJSON() ([]byte, error) { return []byte(js.Stringify(c)), nil }

// ---- JSON helpers

func unmarshal[T any](b []byte, into *T, from func(any) (T, error)) error {
	v, err := js.Parse(string(b))
	if err != nil {
		return err
	}
	out, err := from(v)
	if err != nil {
		return err
	}
	*into = out
	return nil
}

func get(o *js.Object, key string) any {
	v, _ := o.Get(key)
	return v
}

func str(o *js.Object, key string) string {
	s, _ := get(o, key).(string)
	return s
}

// failureCount is the failures in a row a stored state counts as, as the
// SDK's failureCount() reads it: a whole number, held at 2^53 - 1, and 0
// when it is negative or not a whole number. A foreign row's count at a
// 64-bit limit stays at the top instead of wrapping negative, and a 1.5,
// "3" or -1 counts as none.
func failureCount(v any) int {
	f := toFloat(v)
	if math.IsNaN(f) || math.IsInf(f, 0) || f != math.Trunc(f) || f <= 0 {
		return 0
	}
	if f >= float64(maxFailureCount) {
		return maxFailureCount
	}
	return int(f)
}

// maxFailureCount is the most failures in a row counted: 2^53 - 1, or the
// largest int where an int is narrower.
const maxFailureCount = int(min(maxDurationMs, math.MaxInt))

func toFloat(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case int64:
		return float64(t)
	case int:
		return float64(t)
	}
	return math.NaN()
}

func toInt(v any) int64 {
	f := toFloat(v)
	if math.IsNaN(f) {
		return 0
	}
	return int64(f)
}

func integer(o *js.Object, key string) int64 { return toInt(get(o, key)) }

func nullableInt(o *js.Object, key string) *int64 {
	v, ok := get(o, key).(float64)
	if !ok {
		return nil
	}
	// Held at int64's ends: a foreign row's 6e28 (a silence an older SDK
	// wrote) would otherwise convert as the platform likes, to a time long
	// past on amd64.
	var n int64
	switch {
	case v >= math.MaxInt64:
		n = math.MaxInt64
	case v <= math.MinInt64:
		n = math.MinInt64
	default:
		n = int64(v)
	}
	return &n
}

func nullableStr(o *js.Object, key string) *string {
	s, ok := get(o, key).(string)
	if !ok {
		return nil
	}
	return &s
}

func intOrNull(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

func strOrNull(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}

func copyInt(p *int64) *int64 {
	if p == nil {
		return nil
	}
	n := *p
	return &n
}

func copyStr(p *string) *string {
	if p == nil {
		return nil
	}
	s := *p
	return &s
}

func ptr[T any](v T) *T { return &v }

// kind names a JSON value's type as JavaScript's typeof would, for messages.
func kind(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case float64, int, int64:
		return "number"
	case string:
		return "string"
	}
	return "object"
}

// plain is a JSON value with objects as maps, for callers outside the package.
func plain(v any) any {
	switch t := v.(type) {
	case *js.Object:
		m := map[string]any{}
		for _, k := range t.Keys() {
			x, _ := t.Get(k)
			m[k] = plain(x)
		}
		return m
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = plain(e)
		}
		return out
	}
	return v
}
