// Package storetest is the test every CronWatch store passes: the memory
// store, and the sqlstore package on SQLite, Postgres and MySQL. It is the
// SDK's store-conformance.ts, and a replay of the store cases in the
// repository's conformance/store.json. Run it against a store of your own:
//
//	func TestMyStore(t *testing.T) {
//		storetest.Run(t, func(t *testing.T) cronwatch.Store { return mystore.New(...) })
//	}
//
// Run is the one name here the 1.x releases promise. The other exported
// names are the module's own test kit (its fixture replays, clocks and
// captures), deprecated, and go in 1.0.
package storetest

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// NewRun is a run as the contract test writes them: finished ten
// milliseconds after it started unless it is running, with one metric.
//
// Deprecated: only Run is promised; this is the module's own test kit, and
// goes in 1.0.
func NewRun(id, job string, status cronwatch.RunStatus, startedAt int64) cronwatch.Run {
	r := cronwatch.Run{ID: id, Job: job, Status: status, StartedAt: startedAt, Metrics: cronwatch.Metrics{{Name: "n", Value: 1}}, Trigger: "run"}
	if status != cronwatch.StatusRunning {
		r.FinishedAt, r.DurationMs = ptr(startedAt+10), ptr(int64(10))
	}
	return r
}

func ptr[T any](v T) *T { return &v }

// definition is a stored definition from its JSON.
func definition(t *testing.T, text string) cronwatch.Definition {
	t.Helper()
	var d cronwatch.Definition
	if err := json.Unmarshal([]byte(text), &d); err != nil {
		t.Fatal(err)
	}
	return d
}

func state(t *testing.T, text string) cronwatch.JobState {
	t.Helper()
	var s cronwatch.JobState
	if err := json.Unmarshal([]byte(text), &s); err != nil {
		t.Fatal(err)
	}
	return s
}

// jsonOf is a value's JSON as the SDK writes it, "null" for a nil pointer.
func jsonOf(v any) string {
	if rv := reflect.ValueOf(v); v == nil || (rv.Kind() == reflect.Pointer && rv.IsNil()) {
		return "null"
	}
	b, err := json.Marshal(v)
	if err != nil {
		return "error: " + err.Error()
	}
	return string(b)
}

// sameJSON compares the SDK's JSON of two values, whatever order a JSON
// column (Postgres's JSONB) gave an object's keys back in.
func sameJSON(t *testing.T, what string, got any, want string) {
	t.Helper()
	if canonical(jsonOf(got)) != canonical(want) {
		t.Errorf("%s:\n got %s\nwant %s", what, jsonOf(got), want)
	}
}

// canonical is JSON with every object's keys sorted, through encoding/json.
func canonical(text string) string {
	var v any
	if err := json.Unmarshal([]byte(text), &v); err != nil {
		return text
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func ids(runs []cronwatch.Run) []string {
	out := []string{}
	for _, r := range runs {
		out = append(out, r.ID)
	}
	return out
}

// Run is the contract test: store-conformance.ts, step for step. make is
// called once and must return an empty store (newStore).
func Run(t *testing.T, newStore func(t *testing.T) cronwatch.Store) {
	t.Helper()
	ctx := context.Background()
	store := newStore(t)
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	eq := func(what string, got, want any) {
		t.Helper()
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: got %v, want %v", what, got, want)
		}
	}
	must(store.Init(ctx))
	j, err := store.GetJob(ctx, "a")
	must(err)
	eq("no job yet", j == nil, true)
	must(store.UpsertJob(ctx, definition(t, `{"name":"a","schedule":"every 5m"}`), 100))
	must(store.UpsertJob(ctx, definition(t, `{"name":"a","schedule":"every 10m","tags":["x"]}`), 200))
	for _, name := range []string{"b", "B", "_c"} {
		must(store.UpsertJob(ctx, definition(t, `{"name":"`+name+`"}`), 300))
	}
	a, err := store.GetJob(ctx, "a")
	must(err)
	eq("createdAt survives upsert", a.CreatedAt, int64(100))
	eq("updatedAt", a.UpdatedAt, int64(200))
	sameJSON(t, "definition", a.Definition, `{"name":"a","schedule":"every 10m","tags":["x"]}`)
	jobs, err := store.ListJobs(ctx)
	must(err)
	names := []string{}
	for _, j := range jobs {
		names = append(names, j.Name)
	}
	eq("byte order, not locale", names, []string{"B", "_c", "a", "b"})

	for _, r := range []cronwatch.Run{
		NewRun("r1", "a", cronwatch.StatusOK, 1000), NewRun("r2", "a", cronwatch.StatusFailed, 2000),
		NewRun("r3", "a", cronwatch.StatusRunning, 3000), NewRun("r4", "b", cronwatch.StatusOK, 1500),
		NewRun("rb", "B", cronwatch.StatusRunning, 2000), NewRun("rc", "_c", cronwatch.StatusRunning, 2000),
	} {
		must(store.InsertRun(ctx, r))
	}
	list, err := store.ListRuns(ctx, "a", 10)
	must(err)
	eq("newest first", ids(list), []string{"r3", "r2", "r1"})
	list, err = store.ListRuns(ctx, "a", 2)
	must(err)
	eq("limit", ids(list), []string{"r3", "r2"})
	last, err := store.LastRun(ctx, "a")
	must(err)
	eq("last run", last.ID, "r3")
	none, err := store.LastRun(ctx, "none")
	must(err)
	eq("no last run", none == nil, true)
	running, err := store.RunningRuns(ctx)
	must(err)
	eq("oldest first, then insertion order", ids(running), []string{"rb", "rc", "r3"})
	r1, err := store.GetRun(ctx, "r1")
	must(err)
	sameJSON(t, "metrics", r1.Metrics, `{"n":1}`)
	eq("durationMs", *r1.DurationMs, int64(10))

	updated := NewRun("r3", "a", cronwatch.StatusOK, 3000)
	updated.Output = ptr("line1\nline2")
	updated.Metrics = cronwatch.Metrics{{Name: "cost", Value: 0.25}}
	must(store.UpdateRun(ctx, updated))
	r3, err := store.GetRun(ctx, "r3")
	must(err)
	eq("status", r3.Status, cronwatch.StatusOK)
	eq("output", *r3.Output, "line1\nline2")
	sameJSON(t, "updated metrics", r3.Metrics, `{"cost":0.25}`)
	running, err = store.RunningRuns(ctx)
	must(err)
	eq("running after update", ids(running), []string{"rb", "rc"})

	// UpdateRunIf writes only over a row whose status is one of those
	// given, and says whether it did.
	if err := store.InsertRun(ctx, NewRun("r3", "a", cronwatch.StatusRunning, 3000)); err == nil {
		t.Error("an id already recorded is refused")
	}
	must(store.UpsertJob(ctx, definition(t, `{"name":"q"}`), 300))
	must(store.InsertRun(ctx, NewRun("rx", "q", cronwatch.StatusRunning, 2500)))
	once, ok := store.(cronwatch.RunUpdater)
	if !ok {
		t.Fatal("the store is not a RunUpdater")
	}
	with := func(r cronwatch.Run, change func(*cronwatch.Run)) cronwatch.Run { change(&r); return r }
	running1 := []cronwatch.RunStatus{cronwatch.StatusRunning}
	both := []cronwatch.RunStatus{cronwatch.StatusRunning, cronwatch.StatusTimeout}
	wrote, err := once.UpdateRunIf(ctx, with(NewRun("rx", "q", cronwatch.StatusFailed, 2500), func(r *cronwatch.Run) { r.Error = ptr("first") }), running1)
	must(err)
	eq("first finish", wrote, true)
	wrote, err = once.UpdateRunIf(ctx, with(NewRun("rx", "q", cronwatch.StatusOK, 2500), func(r *cronwatch.Run) { r.Output = ptr("second") }), running1)
	must(err)
	eq("a second finish over the first is refused", wrote, false)
	rx, err := store.GetRun(ctx, "rx")
	must(err)
	eq("first error kept", *rx.Error, "first")
	wrote, err = once.UpdateRunIf(ctx, with(NewRun("rx", "q", cronwatch.StatusOK, 2500), func(r *cronwatch.Run) { r.Output = ptr("late") }), both)
	must(err)
	eq("not over failed", wrote, false)
	must(store.UpdateRun(ctx, with(NewRun("rx", "q", cronwatch.StatusTimeout, 2500), func(r *cronwatch.Run) { r.Error = ptr("stuck") })))
	wrote, err = once.UpdateRunIf(ctx, with(NewRun("rx", "q", cronwatch.StatusOK, 2500), func(r *cronwatch.Run) {
		r.Output = ptr("late")
		r.Metrics = cronwatch.Metrics{{Name: "m", Value: 2}}
	}), both)
	must(err)
	eq("any of the statuses given", wrote, true)
	late, err := store.GetRun(ctx, "rx")
	must(err)
	sameJSON(t, "late finish", late, `{"id":"rx","job":"q","status":"ok","startedAt":2500,"finishedAt":2510,"durationMs":10,"error":null,"output":"late","metrics":{"m":2},"trigger":"run"}`)
	wrote, err = once.UpdateRunIf(ctx, NewRun("missing", "q", cronwatch.StatusOK, 1), running1)
	must(err)
	eq("a run that is not there is not written", wrote, false)
	missing, err := store.GetRun(ctx, "missing")
	must(err)
	eq("still missing", missing == nil, true)
	wrote, err = once.UpdateRunIf(ctx, NewRun("rx", "q", cronwatch.StatusFailed, 2500), nil)
	must(err)
	eq("no statuses, no write", wrote, false)
	rx, err = store.GetRun(ctx, "rx")
	must(err)
	eq("still ok", rx.Status, cronwatch.StatusOK)

	// DeleteRunIf, for a store that has it, takes back only a run still of
	// the job and in the status given.
	if deleter, ok := store.(cronwatch.RunDeleter); ok {
		must(store.InsertRun(ctx, NewRun("rd", "q", cronwatch.StatusRunning, 2600)))
		deleted, err := deleter.DeleteRunIf(ctx, "rd", "a", cronwatch.StatusRunning)
		must(err)
		eq("not another job's", deleted, false)
		deleted, err = deleter.DeleteRunIf(ctx, "rd", "q", cronwatch.StatusOK)
		must(err)
		eq("not in another status", deleted, false)
		deleted, err = deleter.DeleteRunIf(ctx, "rx", "q", cronwatch.StatusRunning)
		must(err)
		eq("not a finished run", deleted, false)
		deleted, err = deleter.DeleteRunIf(ctx, "rd", "q", cronwatch.StatusRunning)
		must(err)
		eq("taken back", deleted, true)
		gone, err := store.GetRun(ctx, "rd")
		must(err)
		eq("gone", gone == nil, true)
		deleted, err = deleter.DeleteRunIf(ctx, "rd", "q", cronwatch.StatusRunning)
		must(err)
		eq("only once", deleted, false)
		kept, err := store.GetRun(ctx, "rx")
		must(err)
		eq("the finished run kept", kept != nil, true)
	}
	must(store.DeleteJob(ctx, "q"))

	// Forgetting a job while one of its runs is in flight: the run
	// finishing later changes nothing.
	must(store.DeleteJob(ctx, "B"))
	must(store.UpdateRun(ctx, with(NewRun("rb", "B", cronwatch.StatusOK, 2000), func(r *cronwatch.Run) { r.Output = ptr("late") })))
	rb, err := store.GetRun(ctx, "rb")
	must(err)
	eq("forgotten run stays gone", rb == nil, true)
	list, err = store.ListRuns(ctx, "B", 10)
	must(err)
	eq("no runs of a forgotten job", ids(list), []string{})
	running, err = store.RunningRuns(ctx)
	must(err)
	eq("running after forgetting", ids(running), []string{"rc"})
	must(store.DeleteJob(ctx, "_c"))

	s, err := store.GetState(ctx, "a")
	must(err)
	eq("no state yet", s == nil, true)
	must(store.SetState(ctx, state(t, `{"job":"a","open":{"failed":5},"consecutiveFailures":2,"silencedUntil":null,"lastAlertAt":6}`)))
	must(store.SetState(ctx, state(t, `{"job":"a","open":{},"consecutiveFailures":0,"silencedUntil":99,"lastAlertAt":6}`)))
	s, err = store.GetState(ctx, "a")
	must(err)
	sameJSON(t, "state", s, `{"job":"a","open":{},"consecutiveFailures":0,"silencedUntil":99,"lastAlertAt":6}`)
	alert := `{"type":"failed","run":null,"details":{"consecutiveFailures":1,"threshold":1},"job":"a","definition":{"name":"a"},"title":"a failed","message":"boom","at":7`
	full := `{"job":"a","open":{"stuck":7},"consecutiveFailures":1,"silencedUntil":null,"lastAlertAt":6,"pendingRecovery":["missed"],"undelivered":[` +
		alert + `,"triage":null}],"sending":[{"until":8,"alert":` + alert + `}}]}`
	must(store.SetState(ctx, state(t, full)))
	s, err = store.GetState(ctx, "a")
	must(err)
	sameJSON(t, "pendingRecovery, undelivered and sending round-trip", s, full)
	must(store.SetState(ctx, state(t, `{"job":"a","open":{},"consecutiveFailures":0,"silencedUntil":99,"lastAlertAt":6}`)))

	// CompareAndSetState writes only over the version it was told to expect.
	cas, ok := store.(cronwatch.StateComparer)
	if !ok {
		t.Fatal("the store is not a StateComparer")
	}
	v := func(version int64, extra string) cronwatch.JobState {
		return state(t, fmt.Sprintf(`{"job":"v","open":{},"consecutiveFailures":%s,"silencedUntil":null,"lastAlertAt":null,"version":%d}`, extra, version))
	}
	casIs := func(what string, st cronwatch.JobState, expected int64, want bool) {
		t.Helper()
		wrote, err := cas.CompareAndSetState(ctx, st, expected)
		must(err)
		eq(what, wrote, want)
	}
	casIs("no row matches only version 0", v(2, "0"), 1, false)
	s, err = store.GetState(ctx, "v")
	must(err)
	eq("nothing written", s == nil, true)
	casIs("no row counts as version 0", v(1, "0"), 0, true)
	casIs("a write from a stale read is refused", v(1, "9"), 0, false)
	casIs("the version read", v(2, "1"), 1, true)
	casIs("an older version", v(3, "0"), 1, false)
	s, err = store.GetState(ctx, "v")
	must(err)
	sameJSON(t, "state after writes", s, jsonOf(v(2, "1")))
	must(store.SetState(ctx, state(t, `{"job":"w","open":{},"consecutiveFailures":3,"silencedUntil":null,"lastAlertAt":null}`)))
	w1 := state(t, `{"job":"w","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"version":1}`)
	casIs("state written before versions counts as 0", w1, 1, false)
	casIs("from 0", w1, 0, true)
	s, err = store.GetState(ctx, "w")
	must(err)
	eq("version", *s.Version, int64(1))
	must(store.DeleteJob(ctx, "v"))
	casIs("a forgotten job's state is not written back", v(3, "0"), 2, false)
	s, err = store.GetState(ctx, "v")
	must(err)
	eq("gone", s == nil, true)
	must(store.DeleteJob(ctx, "w"))

	must(store.InsertRun(ctx, NewRun("r5", "a", cronwatch.StatusRunning, 500)))
	n, err := store.Prune(ctx, 2500)
	must(err)
	eq("r1 and r2 pruned; running r5 kept, and b's r4 kept as b's newest run", n, 2)
	list, err = store.ListRuns(ctx, "a", 10)
	must(err)
	eq("a after prune", ids(list), []string{"r3", "r5"})
	list, err = store.ListRuns(ctx, "b", 10)
	must(err)
	eq("b after prune", ids(list), []string{"r4"})
	n, err = store.Prune(ctx, 1_000_000)
	must(err)
	eq("however old, each job keeps its newest run, and running runs stay", n, 0)

	must(store.DeleteJob(ctx, "a"))
	j, err = store.GetJob(ctx, "a")
	must(err)
	eq("job deleted", j == nil, true)
	list, err = store.ListRuns(ctx, "a", 10)
	must(err)
	eq("runs deleted", ids(list), []string{})
	s, err = store.GetState(ctx, "a")
	must(err)
	eq("state deleted", s == nil, true)
	b, err := store.GetJob(ctx, "b")
	must(err)
	eq("b kept", b.Name, "b")
	must(store.Close())
}

// ReplayFixture replays the store cases of conformance/store.json (at
// path) against stores from newStore, which must each be empty: prune scripts,
// CompareAndSetState steps and UpdateRunIf steps, each read back and
// compared with what the SDK's memory store answered.
//
// Deprecated: only Run is promised; this is the module's own test kit, and
// goes in 1.0.
func ReplayFixture(t *testing.T, path string, newStore func(t *testing.T) cronwatch.Store) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	root, err := js.Parse(string(data))
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	fix := root.(*js.Object)
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	field := func(o *js.Object, key string) any { v, _ := o.Get(key); return v }
	objects := func(v any) []*js.Object {
		list, _ := v.([]any)
		out := make([]*js.Object, len(list))
		for i, e := range list {
			out[i], _ = e.(*js.Object)
		}
		return out
	}
	run := func(v any) cronwatch.Run {
		var r cronwatch.Run
		must(json.Unmarshal([]byte(js.Stringify(v)), &r))
		return r
	}
	cases := 0
	for _, script := range objects(field(fix, "prune")) {
		store := newStore(t)
		must(store.Init(ctx))
		jobs := map[string]bool{}
		for _, event := range objects(field(script, "events")) {
			if inserts, ok := event.Get("insert"); ok {
				for _, v := range inserts.([]any) {
					r := run(v)
					jobs[r.Job] = true
					must(store.InsertRun(ctx, r))
				}
				continue
			}
			before := int64(field(event, "prune").(float64))
			n, err := store.Prune(ctx, before)
			must(err)
			if want := int(field(event, "pruned").(float64)); n != want {
				t.Errorf("%s: pruned %d, want %d", field(script, "name"), n, want)
			}
			remaining := field(event, "remaining").(*js.Object)
			for _, job := range remaining.Keys() {
				list, err := store.ListRuns(ctx, job, 100)
				must(err)
				want := []string{}
				for _, id := range field(remaining, job).([]any) {
					want = append(want, id.(string))
				}
				if got := ids(list); !reflect.DeepEqual(got, want) {
					t.Errorf("%s: %s kept %v, want %v", field(script, "name"), job, got, want)
				}
			}
			cases++
		}
		must(store.Close())
	}

	store := newStore(t)
	must(store.Init(ctx))
	cas := store.(cronwatch.StateComparer)
	for i, step := range objects(field(fix, "compareAndSetState")) {
		switch {
		case step.Has("cas"):
			var st cronwatch.JobState
			must(json.Unmarshal([]byte(js.Stringify(field(step, "cas"))), &st))
			wrote, err := cas.CompareAndSetState(ctx, st, int64(field(step, "expected").(float64)))
			must(err)
			if wrote != field(step, "written").(bool) {
				t.Errorf("compareAndSetState step %d: wrote %v", i, wrote)
			}
		case step.Has("set"):
			var st cronwatch.JobState
			must(json.Unmarshal([]byte(js.Stringify(field(step, "set"))), &st))
			must(store.SetState(ctx, st))
		default:
			must(store.DeleteJob(ctx, field(step, "forget").(string)))
		}
		states := field(step, "states").(*js.Object)
		for _, job := range states.Keys() {
			got, err := store.GetState(ctx, job)
			must(err)
			sameJSON(t, fmt.Sprintf("compareAndSetState step %d, state of %s", i, job), got, js.Stringify(field(states, job)))
		}
		cases++
	}
	must(store.Close())

	store = newStore(t)
	must(store.Init(ctx))
	must(store.InsertRun(ctx, NewRunPlain("u1", "a", cronwatch.StatusRunning, 1000)))
	updater := store.(cronwatch.RunUpdater)
	for i, step := range objects(field(fix, "updateRunIf")) {
		switch {
		case step.Has("set"):
			must(store.UpdateRun(ctx, run(field(step, "set"))))
		case step.Has("insert"):
			outcome := "inserted"
			if store.InsertRun(ctx, run(field(step, "insert"))) != nil {
				outcome = "refused"
			}
			if outcome != field(step, "outcome") {
				t.Errorf("updateRunIf step %d: %s", i, outcome)
			}
		default:
			from := []cronwatch.RunStatus{}
			for _, s := range field(step, "from").([]any) {
				from = append(from, cronwatch.RunStatus(s.(string)))
			}
			wrote, err := updater.UpdateRunIf(ctx, run(field(step, "run")), from)
			must(err)
			if wrote != field(step, "outcome").(bool) {
				t.Errorf("updateRunIf step %d: wrote %v", i, wrote)
			}
		}
		got, err := store.GetRun(ctx, "u1")
		must(err)
		sameJSON(t, fmt.Sprintf("updateRunIf step %d", i), got, js.Stringify(field(step, "stored")))
		cases++
	}
	must(store.Close())

	// nul: text is written without U+0000, which Postgres refuses: a run's
	// trigger, output, error and metric names, and every key and string of
	// a definition and a state.
	store = newStore(t)
	must(store.Init(ctx))
	for i, step := range objects(field(fix, "nul")) {
		what := fmt.Sprintf("nul step %d", i)
		var got any
		wrote := func(ok bool, err error) {
			t.Helper()
			must(err)
			if want, _ := field(step, "written").(bool); ok != want {
				t.Errorf("%s: wrote %v", what, ok)
			}
		}
		switch {
		case step.Has("upsertJob"):
			must(store.UpsertJob(ctx, definition(t, js.Stringify(field(step, "upsertJob"))), int64(field(step, "now").(float64))))
			j, err := store.GetJob(ctx, "nul")
			must(err)
			if j == nil {
				t.Fatalf("%s: no job", what)
			}
			got = json.RawMessage(js.Stringify(js.NewObject("name", j.Name, "definition", js.ValueOf(j.Definition), "createdAt", j.CreatedAt, "updatedAt", j.UpdatedAt)))
		case step.Has("insertRun"), step.Has("updateRun"), step.Has("updateRunIf"):
			switch {
			case step.Has("insertRun"):
				must(store.InsertRun(ctx, run(field(step, "insertRun"))))
			case step.Has("updateRun"):
				must(store.UpdateRun(ctx, run(field(step, "updateRun"))))
			default:
				from := []cronwatch.RunStatus{}
				for _, s := range field(step, "from").([]any) {
					from = append(from, cronwatch.RunStatus(s.(string)))
				}
				wrote(store.(cronwatch.RunUpdater).UpdateRunIf(ctx, run(field(step, "updateRunIf")), from))
			}
			r, err := store.GetRun(ctx, "n1")
			must(err)
			got = r
		default:
			if step.Has("setState") {
				must(store.SetState(ctx, state(t, js.Stringify(field(step, "setState")))))
			} else {
				st := state(t, js.Stringify(field(step, "compareAndSetState")))
				wrote(store.(cronwatch.StateComparer).CompareAndSetState(ctx, st, int64(field(step, "expected").(float64))))
			}
			s, err := store.GetState(ctx, "nul")
			must(err)
			got = s
		}
		sameJSON(t, what, got, js.Stringify(field(step, "stored")))
		cases++
	}
	must(store.Close())
	if cases == 0 {
		t.Fatal("no cases replayed")
	}
}

// ReplayForeignVersions replays the foreignVersion cases of
// conformance/store.json (at path) against store, which must implement
// cronwatch.StateComparer: a state row another process wrote, its version
// in any shape (1.5, "x", -1, 2.0, 2^53), counts as the SDK's
// stateVersion() reads it, a whole number from 0 to 2^53 - 1 or else 0. So
// a write expecting any other version is refused, and one expecting it goes
// through, where a brittle cast would fail every write of the job for good.
// writeRaw stores a state row for job "v" holding the JSON text given as it
// is, as a store's own writes never would; the replay deletes job "v"
// before each case.
//
// Deprecated: only Run is promised; this is the module's own test kit, and
// goes in 1.0.
func ReplayForeignVersions(t *testing.T, path string, store cronwatch.Store, writeRaw func(text string) error) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	root, err := js.Parse(string(data))
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	field := func(o *js.Object, key string) any { v, _ := o.Get(key); return v }
	cas := store.(cronwatch.StateComparer)
	list, _ := field(root.(*js.Object), "foreignVersion").([]any)
	if len(list) == 0 {
		t.Fatal("no foreignVersion cases")
	}
	for _, v := range list {
		c := v.(*js.Object)
		stored := field(c, "stored").(string)
		if err := store.DeleteJob(ctx, "v"); err != nil {
			t.Fatal(err)
		}
		if err := writeRaw(stored); err != nil {
			t.Fatalf("%s: %v", stored, err)
		}
		for _, sv := range field(c, "steps").([]any) {
			step := sv.(*js.Object)
			var st cronwatch.JobState
			if err := json.Unmarshal([]byte(js.Stringify(field(step, "cas"))), &st); err != nil {
				t.Fatal(err)
			}
			expected := int64(field(step, "expected").(float64))
			wrote, err := cas.CompareAndSetState(ctx, st, expected)
			if err != nil {
				t.Fatalf("%s expecting %d: %v", stored, expected, err)
			}
			if wrote != field(step, "written").(bool) {
				t.Errorf("%s expecting %d: wrote %v", stored, expected, wrote)
			}
			if want, ok := step.Get("state"); ok {
				got, err := store.GetState(ctx, "v")
				if err != nil {
					t.Fatal(err)
				}
				sameJSON(t, stored+", the state written", got, js.Stringify(want))
			}
		}
	}
}

// NewRunPlain is the fixture script's run: as NewRun, with no metrics.
//
// Deprecated: only Run is promised; this is the module's own test kit, and
// goes in 1.0.
func NewRunPlain(id, job string, status cronwatch.RunStatus, startedAt int64) cronwatch.Run {
	r := NewRun(id, job, status, startedAt)
	r.Metrics = cronwatch.Metrics{}
	return r
}
