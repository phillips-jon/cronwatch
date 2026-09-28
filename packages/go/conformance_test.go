package cronwatch

// Replays conformance/*.json, the cases scripts/conformance.mjs writes by
// running the TypeScript SDK. evaluate, format and health have their own
// test files here (conformance_<name>_test.go), store.json is replayed
// against every store (storetest.ReplayFixture), and duration, schedule and
// output are replayed by the internal packages that port them
// (internal/schedule, internal/output), and channels, triage and pgcron by
// the packages that port them (alerts, triage, pgcron). This file holds
// what the tests here share, and fails when the SDK writes a fixture this
// port does not replay.

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"cronwatch.dev/go/internal/js"
)

// conformanceDir is the repository's conformance/ directory.
var conformanceDir = filepath.Join("..", "..", "conformance")

// replayed are the fixtures this package and the internal ones replay;
// elsewhere are those the alerts, triage and pgcron packages replay.
var (
	replayed  = []string{"duration", "evaluate", "format", "health", "output", "schedule", "store"}
	elsewhere = []string{"channels", "pgcron", "triage"}
)

func TestConformanceFixturesAreReplayed(t *testing.T) {
	entries, err := os.ReadDir(conformanceDir)
	if err != nil {
		t.Fatal(err)
	}
	known := map[string]bool{}
	for _, name := range append(append([]string{}, replayed...), elsewhere...) {
		known[name] = true
	}
	var unknown []string
	for _, e := range entries {
		name, ok := strings.CutSuffix(e.Name(), ".json")
		if ok && !known[name] {
			unknown = append(unknown, e.Name())
		}
	}
	sort.Strings(unknown)
	if len(unknown) > 0 {
		t.Fatalf("conformance/ has fixtures this port does not replay: %v", unknown)
	}
}

// fixture reads conformance/<name>.json, in JavaScript's key order.
func fixture(t *testing.T, name string) *js.Object {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(conformanceDir, name+".json"))
	if err != nil {
		t.Fatal(err)
	}
	v, err := js.Parse(string(data))
	if err != nil {
		t.Fatalf("%s.json: %v", name, err)
	}
	return v.(*js.Object)
}

// field is o[key].
func field(o *js.Object, key string) any {
	v, _ := o.Get(key)
	return v
}

// objects is o[key] as a list of objects.
func objects(o *js.Object, key string) []*js.Object {
	list, _ := field(o, key).([]any)
	out := make([]*js.Object, len(list))
	for i, v := range list {
		out[i], _ = v.(*js.Object)
	}
	return out
}

// optInt is a number or null as *int64.
func optInt(v any) *int64 {
	f, ok := v.(float64)
	if !ok {
		return nil
	}
	n := int64(f)
	return &n
}

// sameJSON fails unless got and want are the same JSON, byte for byte.
func sameJSON(t *testing.T, what string, got, want any) bool {
	t.Helper()
	g, w := js.Stringify(got), js.Stringify(want)
	if g != w {
		t.Errorf("%s:\n got %s\nwant %s", what, g, w)
		return false
	}
	return true
}
