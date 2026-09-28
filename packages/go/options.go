package cronwatch

// Job options and client options. Both are functional options, which in
// Go is also what keeps a definition's fields in the order they were given:
// the stored definition is the SDK's JSON, and the SDK writes a job's
// options in the order its object literal had them, so a Go process and a
// Node process declaring the same job write the same bytes.

import (
	"fmt"
	"math"
	"reflect"
	"regexp"
	"time"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/schedule"
)

// Duration is what a duration option takes: text like "15m", "1h30m",
// "90s" or "2d" (the SDK's form, kept as written in the stored
// definition), a time.Duration, or a whole or fractional number of
// milliseconds. A time.Duration is stored as its milliseconds, as the SDK
// stores a number.
type Duration interface {
	~string | ~int | ~int64 | ~float64
}

// durationValue is a Duration as a JSON value: a string, or a number of
// milliseconds.
func durationValue[D Duration](d D) any {
	v := reflect.ValueOf(d)
	if dur, ok := any(d).(time.Duration); ok {
		return float64(dur) / float64(time.Millisecond)
	}
	switch v.Kind() {
	case reflect.String:
		return v.String()
	case reflect.Int, reflect.Int64:
		if v.Type() == reflect.TypeOf(time.Duration(0)) {
			return float64(v.Int()) / float64(time.Millisecond)
		}
		return float64(v.Int())
	case reflect.Float64:
		return v.Float()
	}
	return nil
}

// JobOption configures a job: when it runs and what counts as trouble.
type JobOption func(*jobConfig)

// jobConfig collects a job's options in the order they are given.
type jobConfig struct {
	fields *js.Object
	expect expectRule
	// set is the option names given, for WithDefaults to refuse others.
	set []string
}

func (c *jobConfig) put(key string, value any) {
	if c.fields == nil {
		c.fields = &js.Object{}
	}
	c.fields.Set(key, value)
	c.set = append(c.set, key)
}

// Schedule is when the job is supposed to run: a five or six field cron
// expression ("0 2 * * *"), a nickname ("@hourly"), or an interval
// ("every 5m"). Leave it out for a job with no fixed cadence: failures,
// duration and budgets are still watched, but nothing is ever missed.
func Schedule(expr string) JobOption { return func(c *jobConfig) { c.put("schedule", expr) } }

// Timezone is the IANA zone the cron expression is read in. The default is
// the process's zone (time.Local). Vercel and GitHub Actions run their
// crons in UTC.
func Timezone(name string) JobOption { return func(c *jobConfig) { c.put("timezone", name) } }

// Grace is how late a run may start before it counts as missed. Default 10m.
func Grace[D Duration](d D) JobOption {
	return func(c *jobConfig) { c.put("grace", durationValue(d)) }
}

// Timeout is how long a run may go on before it is treated as stuck and
// marked timeout. Default 1h. The context a job's function gets is
// cancelled when it passes.
func Timeout[D Duration](d D) JobOption {
	return func(c *jobConfig) { c.put("timeout", durationValue(d)) }
}

// MaxDuration alerts when a successful run takes longer. Without it, a run
// is slow when it takes more than twice the p95 of recent runs (and over
// 10s), once there are five runs to compare against.
func MaxDuration[D Duration](d D) JobOption {
	return func(c *jobConfig) { c.put("maxDuration", durationValue(d)) }
}

// Budget sets a ceiling for a metric reported with Metric: Budget("cost", 2)
// alerts when a run reports cost above 2. Give it once per metric. Metrics
// without a ceiling alert when a run reports more than three times the
// recent median, once there are five runs to compare against.
func Budget(metric string, ceiling float64) JobOption {
	return func(c *jobConfig) {
		if c.fields == nil {
			c.fields = &js.Object{}
		}
		budget, ok := get(c.fields, "budget").(*js.Object)
		if !ok {
			budget = &js.Object{}
		}
		budget.Set(metric, ceiling)
		c.put("budget", budget)
	}
}

// Expect makes a successful run fail unless its output contains text.
// Catches the job that exits cleanly and did nothing.
func Expect(text string) JobOption {
	return func(c *jobConfig) { c.expect = containsRule(text); c.set = append(c.set, "expect") }
}

// ExpectMatch makes a successful run fail unless the regular expression
// matches its output.
func ExpectMatch(re *regexp.Regexp) JobOption {
	return func(c *jobConfig) {
		if re != nil {
			c.expect = regexpRule{re}
		}
		c.set = append(c.set, "expect")
	}
}

// ExpectFunc makes a successful run fail unless fn returns true for its
// output. A panic in fn fails the run with what it panicked with.
func ExpectFunc(fn func(output string) bool) JobOption {
	return func(c *jobConfig) {
		if fn != nil {
			c.expect = funcRule(fn)
		}
		c.set = append(c.set, "expect")
	}
}

// FailuresBeforeAlert alerts on the nth consecutive failure rather than the
// first. Default 1.
func FailuresBeforeAlert(n int) JobOption {
	return func(c *jobConfig) { c.put("failuresBeforeAlert", float64(n)) }
}

// Description describes the job on the dashboard.
func Description(text string) JobOption { return func(c *jobConfig) { c.put("description", text) } }

// Tags label the job.
func Tags(tags ...string) JobOption {
	return func(c *jobConfig) {
		list := make([]any, len(tags))
		for i, t := range tags {
			list[i] = t
		}
		c.put("tags", list)
	}
}

// validateDefinition returns the SDK's error for options that would
// otherwise quietly turn a check off.
func validateDefinition(name string, def Definition) error {
	if v, ok := def.get("schedule"); ok {
		s, isString := v.(string)
		if !isString || js.Trim(s) == "" {
			return fmt.Errorf("job %s: schedule must be a non-empty string", js.Quote(name))
		}
		// Croner takes any zone when it reads an expression and fails on a
		// bad one only when asked for a fire time, so the SDK reports a bad
		// zone after the expression, with a message of its own (below).
		// This port's parser checks the zone at once, so a zone that is not
		// one is left out here.
		tz, _ := get(def.o, "timezone").(string)
		if !isTimezone(tz) {
			tz = ""
		}
		if _, err := schedule.Parse(s, tz); err != nil {
			return err
		}
	}
	if v, ok := def.get("timezone"); ok {
		s, _ := v.(string)
		if !isTimezone(s) {
			return fmt.Errorf("job %s: timezone %s is not an IANA timezone", js.Quote(name), js.Quote(s))
		}
	}
	if _, ok := def.get("grace"); ok {
		if _, err := graceMs(def); err != nil {
			return err
		}
	}
	if _, ok := def.get("timeout"); ok {
		ms, err := timeoutMs(def)
		if err != nil {
			return err
		}
		if ms <= 0 {
			return fmt.Errorf("job %s: timeout must be longer than zero", js.Quote(name))
		}
	}
	if _, ok := def.get("maxDuration"); ok {
		ms, _, _, err := slowThreshold(def, nil)
		if err != nil {
			return err
		}
		if ms <= 0 {
			return fmt.Errorf("job %s: maxDuration must be longer than zero", js.Quote(name))
		}
	}
	if v, ok := def.get("failuresBeforeAlert"); ok {
		n, _ := v.(float64)
		if !js.IsInteger(n) || n < 1 {
			return fmt.Errorf("job %s: failuresBeforeAlert must be a whole number, 1 or more (got %s)", js.Quote(name), jsText(v, true))
		}
	}
	if budget, ok := get(def.o, "budget").(*js.Object); ok {
		for _, metric := range budget.Keys() {
			v, _ := budget.Get(metric)
			ceiling, _ := v.(float64)
			if math.IsNaN(ceiling) || math.IsInf(ceiling, 0) || ceiling < 0 {
				return fmt.Errorf("job %s: budget.%s must be a finite number, 0 or more (got %s)", js.Quote(name), metric, js.FormatNumber(ceiling))
			}
		}
	}
	return nil
}

// Option configures a client.
type Option func(*Client) error

// DeliverMode says where alerts are sent from.
type DeliverMode string

const (
	// DeliverNow sends each alert from the process that produced it. The default.
	DeliverNow DeliverMode = "now"
	// DeliverAtCheck sends nothing from this process: each alert is queued
	// in the store, and the next check in a process that delivers now sends
	// it (with triage). For a process that records runs but cannot reach
	// the network, such as a sandboxed backup job.
	DeliverAtCheck DeliverMode = "check"
)

// WithStore is where jobs, runs and state live. The default is a
// MemoryStore, which forgets on restart.
func WithStore(store Store) Option {
	return func(c *Client) error {
		if store == nil {
			return fmt.Errorf("WithStore needs a store")
		}
		c.store = store
		c.defaultStore = false
		return nil
	}
}

// WithAlerts is where alerts go, replacing the default console channel.
// WithAlerts() with none sends nowhere.
func WithAlerts(channels ...Channel) Option {
	return func(c *Client) error {
		c.alerts = append([]Channel{}, channels...)
		return nil
	}
}

// WithTriage adds a short diagnosis to every alert except recoveries.
func WithTriage(fn TriageFunc) Option {
	return func(c *Client) error { c.triage = fn; return nil }
}

// WithSources adds sources of runs this process does not wrap (the pg_cron
// source). Each is synced at the start of every check; one that fails is
// reported to the error handler and the check carries on.
func WithSources(sources ...Source) Option {
	return func(c *Client) error { c.sources = append(c.sources, sources...); return nil }
}

// WithCronSecret is the shared secret job handlers' requests must carry.
// The default is $CRON_SECRET; "" counts as unset.
func WithCronSecret(secret string) Option {
	return func(c *Client) error { c.cronSecret, c.secretOptOut = secret, false; return nil }
}

// WithoutCronSecret lets job handlers run without a secret.
func WithoutCronSecret() Option {
	return func(c *Client) error { c.cronSecret, c.secretOptOut = "", true; return nil }
}

// WithRetention is how long finished runs are kept. Default "30d".
func WithRetention[D Duration](d D) Option {
	return func(c *Client) error { c.retention = durationValue(d); return nil }
}

// defaultable are the options WithDefaults takes, as the SDK's defaults.
var defaultable = map[string]bool{"grace": true, "timeout": true, "timezone": true, "failuresBeforeAlert": true}

// WithDefaults applies Grace, Timeout, Timezone and FailuresBeforeAlert to
// every job that does not set its own.
func WithDefaults(options ...JobOption) Option {
	return func(c *Client) error {
		var cfg jobConfig
		for _, o := range options {
			o(&cfg)
		}
		for _, key := range cfg.set {
			if !defaultable[key] {
				return fmt.Errorf("WithDefaults takes grace, timeout, timezone and failuresBeforeAlert, not %s", key)
			}
		}
		c.defaults = cfg.fields
		return nil
	}
}

// WithRedact replaces the default redaction (see RedactSecrets) of every run's
// output and error before it is stored, shown or sent anywhere. A redact
// function that panics is reported to the error handler and the default is
// used.
func WithRedact(fn func(text string) string) Option {
	return func(c *Client) error {
		if fn == nil {
			return fmt.Errorf("WithRedact needs a function; use WithoutRedaction to keep output as logged")
		}
		c.customRedact = fn
		c.noRedact = false
		return nil
	}
}

// WithoutRedaction keeps output and errors exactly as logged.
func WithoutRedaction() Option {
	return func(c *Client) error { c.customRedact, c.noRedact = nil, true; return nil }
}

// WithDeliver sets where alerts are sent from: DeliverNow (the default) or
// DeliverAtCheck.
func WithDeliver(mode DeliverMode) Option {
	return func(c *Client) error {
		if mode != DeliverNow && mode != DeliverAtCheck {
			return fmt.Errorf("deliver must be \"now\" or \"check\", not %s", js.Quote(string(mode)))
		}
		c.deferDelivery = mode == DeliverAtCheck
		return nil
	}
}

// WithErrorHandler is called with anything that goes wrong outside a job:
// the store failing, an alert channel failing, a triage timeout. where says
// what was being done ("recording nightly", "alert channel slack"). The
// default writes to standard error.
func WithErrorHandler(fn func(err error, where string)) Option {
	return func(c *Client) error {
		if fn != nil {
			c.onError = fn
		}
		return nil
	}
}

// WithClock replaces the clock, in epoch milliseconds. Tests use it.
func WithClock(now func() int64) Option {
	return func(c *Client) error {
		if now != nil {
			c.now = now
		}
		return nil
	}
}
