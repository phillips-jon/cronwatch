package bridge

import (
	"context"
	"regexp"
	"slices"
	"strings"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// OptionsOf are the job options that declare a stored definition again, in
// its order: schedule, timezone, grace, timeout, maxDuration, budget,
// failuresBeforeAlert, description, tags, and expect ("contains" as
// Expect, a pattern Go wrote as ExpectMatch, a custom function as one that
// passes every output, since the function is the other process's). Fields
// no option gives are left out.
func OptionsOf(def cronwatch.Definition) []cronwatch.JobOption {
	var options []cronwatch.JobOption
	raw, _ := def.JSValue().(*js.Object)
	for _, key := range def.Keys() {
		value, _ := def.Get(key)
		switch key {
		case "schedule":
			if s, ok := value.(string); ok {
				options = append(options, cronwatch.Schedule(s))
			}
		case "timezone":
			if s, ok := value.(string); ok {
				options = append(options, cronwatch.Timezone(s))
			}
		case "grace":
			options = appendDuration(options, cronwatch.Grace[string], cronwatch.Grace[float64], value)
		case "timeout":
			options = appendDuration(options, cronwatch.Timeout[string], cronwatch.Timeout[float64], value)
		case "maxDuration":
			options = appendDuration(options, cronwatch.MaxDuration[string], cronwatch.MaxDuration[float64], value)
		case "budget":
			if raw == nil {
				continue
			}
			v, _ := raw.Get("budget")
			if budget, ok := v.(*js.Object); ok {
				for _, metric := range budget.Keys() {
					m, _ := budget.Get(metric)
					if ceiling, ok := m.(float64); ok {
						options = append(options, cronwatch.Budget(metric, ceiling))
					}
				}
			}
		case "failuresBeforeAlert":
			if n, ok := value.(float64); ok {
				options = append(options, cronwatch.FailuresBeforeAlert(int(n)))
			}
		case "description":
			if s, ok := value.(string); ok {
				options = append(options, cronwatch.Description(s))
			}
		case "tags":
			options = append(options, cronwatch.Tags(def.Tags()...))
		case "expect":
			if option := expectOf(value); option != nil {
				options = append(options, option)
			}
		}
	}
	return options
}

// expectOf is the expect option a stored description came from.
func expectOf(value any) cronwatch.JobOption {
	text, _ := value.(string)
	switch {
	case strings.HasPrefix(text, "contains "):
		if s, err := js.Parse(strings.TrimPrefix(text, "contains ")); err == nil {
			if want, ok := s.(string); ok {
				return cronwatch.Expect(want)
			}
		}
	case strings.HasPrefix(text, "matches /") && strings.HasSuffix(text, "/"):
		if re, err := regexp.Compile(strings.TrimSuffix(strings.TrimPrefix(text, "matches /"), "/")); err == nil {
			return cronwatch.ExpectMatch(re)
		}
	case text == "custom function":
		return cronwatch.ExpectFunc(func(string) bool { return true })
	}
	return nil
}

// Fallback is the job a run in this process belongs to when this process
// has not declared it from a scheduler of its own (a worker whose app
// schedules the job in another process): declared again from the
// definition the store holds, when that is this app's (tagged with its app
// tag), so the schedule another process stored is kept, else with options
// and this watch's tags. Declared once per name in this process; nil, with
// the reason reported, when the client refuses it.
func (w *Watch) Fallback(ctx context.Context, name string, options []cronwatch.JobOption) *cronwatch.Job {
	w.mu.Lock()
	if job, ok := w.fallback[name]; ok {
		w.mu.Unlock()
		return job
	}
	w.mu.Unlock()
	made := w.tagged(name, options)
	if summary, err := w.cw.JobSummary(ctx, name); err == nil && summary != nil && slices.Contains(summary.Definition.Tags(), w.appTag) {
		made = OptionsOf(summary.Definition)
	}
	job, err := w.cw.Job(name, made...)
	if err != nil {
		w.ReportOnce(err, "declaring "+name)
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if existing, ok := w.fallback[name]; ok {
		return existing
	}
	w.fallback[name] = job
	return job
}
