// Package clientreplay replays conformance/client.json's unknownFields
// through the client's public API over a store, so the package's tests
// replay it over the memory store and sqltest's over the SQL store on each
// dialect. What a newer release wrote (a definition or state key, a run
// status, a trigger, an open condition this release does not know)
// survives a check, a silence, an unsilence and a run, and the alerts carry
// the definition as stored.
package clientreplay

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"sort"
	"sync"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// UnknownFields replays the unknownFields cases of the client.json at path
// over store, which must be empty.
func UnknownFields(t *testing.T, path string, store cronwatch.Store) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	root, err := js.Parse(string(data))
	if err != nil {
		t.Fatal(err)
	}
	fix := get(root, "unknownFields")
	seed := get(fix, "seed")
	ctx := context.Background()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	decode := func(v any, into any) {
		t.Helper()
		must(json.Unmarshal([]byte(js.Stringify(v)), into))
	}

	must(store.Init(ctx))
	var def cronwatch.Definition
	decode(get(seed, "definition"), &def)
	must(store.UpsertJob(ctx, def, int64(get(seed, "createdAt").(float64))))
	for _, r := range get(seed, "runs").([]any) {
		var run cronwatch.Run
		decode(r, &run)
		must(store.InsertRun(ctx, run))
	}
	var state cronwatch.JobState
	decode(get(seed, "state"), &state)
	must(store.SetState(ctx, state))

	var (
		mu     sync.Mutex
		now    int64
		sent   []any
		errors []any
	)
	clock := func() int64 { mu.Lock(); defer mu.Unlock(); return now }
	setNow := func(at any) { mu.Lock(); now = int64(at.(float64)); mu.Unlock() }
	cw, err := cronwatch.New(
		cronwatch.WithStore(store),
		cronwatch.WithClock(clock),
		cronwatch.WithoutCronSecret(),
		cronwatch.WithAlerts(cronwatch.ChannelFunc("capture", func(_ context.Context, alert cronwatch.Alert) error {
			mu.Lock()
			defer mu.Unlock()
			sent = append(sent, canonical(t, alert))
			return nil
		})),
		cronwatch.WithErrorHandler(func(err error, where string) {
			mu.Lock()
			defer mu.Unlock()
			errors = append(errors, fmt.Sprintf("%s: %v", where, err))
		}),
	)
	must(err)
	defer cw.Close()

	for i, step := range get(fix, "steps").([]any) {
		op := get(step, "op").(string)
		if at := get(step, "at"); at != nil {
			setNow(at)
		}
		switch op {
		case "check":
			_, err := cw.Check(ctx)
			must(err)
		case "silence":
			d, err := time.ParseDuration(get(step, "for").(string))
			must(err)
			_, err = cw.Silence(ctx, "keep", d)
			must(err)
		case "unsilence":
			_, err := cw.Unsilence(ctx, "keep")
			must(err)
		case "summary":
			summary, err := cw.JobSummary(ctx, "keep")
			must(err)
			got, want := canonical(t, summary), canonical(t, get(step, "summary"))
			sortOpen(got)
			sortOpen(want)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("step %d summary:\n got %s\nwant %s", i, js.Stringify(summary), js.Stringify(get(step, "summary")))
			}
		case "declareAndRun":
			declared := get(step, "declared").(*js.Object)
			var options []cronwatch.JobOption
			for _, k := range declared.Keys() {
				v, _ := declared.Get(k)
				switch k {
				case "timeout":
					options = append(options, cronwatch.Timeout(v.(string)))
				case "tags":
					var tags []string
					for _, tag := range v.([]any) {
						tags = append(tags, tag.(string))
					}
					options = append(options, cronwatch.Tags(tags...))
				default:
					t.Fatalf("step %d: declared option %q is not replayed", i, k)
				}
			}
			job, err := cw.Job("keep", options...)
			must(err)
			setNow(get(step, "startedAt"))
			handle, err := job.Start(ctx, cronwatch.WithRunID(get(step, "id").(string)))
			must(err)
			setNow(get(step, "finishedAt"))
			handle.FinishWith(ctx, get(step, "output").(string))
		default:
			t.Fatalf("step %d: unknown op %q", i, op)
		}

		stored, err := store.GetJob(ctx, "keep")
		must(err)
		st, err := store.GetState(ctx, "keep")
		must(err)
		runs, err := store.ListRuns(ctx, "keep", 10)
		must(err)
		mu.Lock()
		alerts, reported := sent, errors
		sent, errors = nil, nil
		mu.Unlock()
		if alerts == nil {
			alerts = []any{}
		}
		if reported == nil {
			reported = []any{}
		}
		got := map[string]any{
			"job": map[string]any{
				"name": stored.Name, "definition": canonical(t, stored.Definition),
				"createdAt": float64(stored.CreatedAt), "updatedAt": float64(stored.UpdatedAt),
			},
			"state":  canonical(t, st),
			"runs":   canonical(t, runs),
			"alerts": alerts,
			"errors": reported,
		}
		want := canonical(t, get(step, "expect"))
		for _, key := range []string{"job", "state", "runs", "alerts", "errors"} {
			g, w := got[key], want.(map[string]any)[key]
			if !reflect.DeepEqual(g, w) {
				gb, _ := json.Marshal(g)
				wb, _ := json.Marshal(w)
				t.Errorf("step %d (%s) %s:\n got %s\nwant %s", i, op, key, gb, wb)
			}
		}
	}
}

// get is o[key] for a parsed object.
func get(o any, key string) any {
	v, _ := o.(*js.Object).Get(key)
	return v
}

// canonical is v as encoding/json reads its JSON back, so two values
// compare as JSON whatever their key order.
func canonical(t *testing.T, v any) any {
	t.Helper()
	var text []byte
	if o, ok := v.(*js.Object); ok {
		text = []byte(js.Stringify(o))
	} else {
		var err error
		if text, err = json.Marshal(v); err != nil {
			t.Fatal(err)
		}
	}
	var out any
	if err := json.Unmarshal(text, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// sortOpen sorts a summary's open conditions, compared as a set: Postgres's
// JSONB does not keep their order.
func sortOpen(summary any) {
	m, ok := summary.(map[string]any)
	if !ok {
		return
	}
	if list, ok := m["open"].([]any); ok {
		sort.Slice(list, func(i, j int) bool { return fmt.Sprint(list[i]) < fmt.Sprint(list[j]) })
	}
}
