package sqltest

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

// A Node process and a Go process sharing one SQLite file: the SDK's store
// (from the built packages/sdk/dist) and sqlstore replay the same store
// calls (testdata/shared_store.json, the Ruby and Python ports' fixture),
// and each must read what the other wrote exactly as it reads its own, down
// to the bytes and SQLite type of every column. Then a Node client and a Go
// client take turns on one file, and on one job's state version.
//
// Needs node on the PATH, the SDK built and its SQLite driver installed
// (`npm ci && npm run build` at the repository root); skipped, with the
// reason, without them.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
	"cronwatch.dev/go/storetest"
)

var (
	nodeScript  = filepath.Join("testdata", "node_store.mjs")
	fixtureFile = filepath.Join("testdata", "shared_store.json")
	repo        = filepath.Join("..", "..", "..")
)

func needNode(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("Node compatibility: node is not on the PATH")
	}
	if _, err := os.Stat(filepath.Join(repo, "packages", "sdk", "dist", "sqlite.js")); err != nil {
		t.Skip("Node compatibility: packages/sdk/dist is not built: run `npm ci && npm run build` at the repository root")
	}
	if _, err := os.Stat(filepath.Join(repo, "node_modules", "better-sqlite3")); err != nil {
		t.Skip("Node compatibility: the SDK's SQLite driver is not installed: run `npm ci` at the repository root")
	}
}

func node(t *testing.T, action, file, prefix string, args ...string) string {
	t.Helper()
	cmd := exec.Command("node", append([]string{nodeScript, action, file, prefix}, args...)...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("node %s: %v: %s", action, err, stderr.String())
	}
	return string(out)
}

type sharedFixture struct {
	Ops []struct {
		Op         string          `json:"op"`
		Now        int64           `json:"now"`
		Definition json.RawMessage `json:"definition"`
		Run        json.RawMessage `json:"run"`
		State      json.RawMessage `json:"state"`
		Name       string          `json:"name"`
		Before     int64           `json:"before"`
	} `json:"ops"`
	Read struct {
		Jobs []string `json:"jobs"`
		Runs []string `json:"runs"`
	} `json:"read"`
}

func loadShared(t *testing.T) sharedFixture {
	data, err := os.ReadFile(fixtureFile)
	must(t, err)
	var f sharedFixture
	must(t, json.Unmarshal(data, &f))
	return f
}

func sqliteStore(t *testing.T, file, prefix string) *sqlstore.Store {
	return newStore(t, sqliteDB(t, file), sqlstore.SQLite, prefix)
}

// goWrite replays the fixture's store calls, as node_store.mjs write does.
func goWrite(t *testing.T, store cronwatch.Store, f sharedFixture) string {
	must(t, store.Init(ctx))
	pruned := []int{}
	for _, step := range f.Ops {
		switch step.Op {
		case "upsertJob":
			var d cronwatch.Definition
			must(t, json.Unmarshal(step.Definition, &d))
			must(t, store.UpsertJob(ctx, d, step.Now))
		case "insertRun", "updateRun":
			var r cronwatch.Run
			must(t, json.Unmarshal(step.Run, &r))
			if step.Op == "insertRun" {
				must(t, store.InsertRun(ctx, r))
			} else {
				must(t, store.UpdateRun(ctx, r))
			}
		case "setState":
			var s cronwatch.JobState
			must(t, json.Unmarshal(step.State, &s))
			must(t, store.SetState(ctx, s))
		case "deleteJob":
			must(t, store.DeleteJob(ctx, step.Name))
		case "prune":
			n, err := store.Prune(ctx, step.Before)
			must(t, err)
			pruned = append(pruned, n)
		default:
			t.Fatalf("unknown op %s", step.Op)
		}
	}
	b, _ := json.Marshal(map[string]any{"pruned": pruned})
	return string(b)
}

// object writes a JSON object with its keys in the order given.
func object(pairs ...string) string {
	var b strings.Builder
	b.WriteByte('{')
	for i := 0; i+1 < len(pairs); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		k, _ := json.Marshal(pairs[i])
		b.Write(k)
		b.WriteByte(':')
		b.WriteString(pairs[i+1])
	}
	b.WriteByte('}')
	return b.String()
}

func storedJSON(t *testing.T, j *cronwatch.StoredJob) string {
	if j == nil {
		return "null"
	}
	return object("name", jsonOf(t, j.Name), "definition", jsonOf(t, j.Definition),
		"createdAt", strconv.FormatInt(j.CreatedAt, 10), "updatedAt", strconv.FormatInt(j.UpdatedAt, 10))
}

func list[T any](t *testing.T, items []T, write func(T) string) string {
	parts := make([]string, len(items))
	for i, it := range items {
		parts[i] = write(it)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

func nullable[T any](t *testing.T, v *T) string {
	if v == nil {
		return "null"
	}
	return jsonOf(t, v)
}

// goRead is what node_store.mjs read prints, from the Go store, in the same
// key order.
func goRead(t *testing.T, store cronwatch.Store, f sharedFixture) string {
	jobs, err := store.ListJobs(ctx)
	must(t, err)
	runJSON := func(r cronwatch.Run) string { return jsonOf(t, r) }
	var job, runs, limited, last, state []string
	for _, name := range f.Read.Jobs {
		j, err := store.GetJob(ctx, name)
		must(t, err)
		job = append(job, name, storedJSON(t, j))
		all, err := store.ListRuns(ctx, name, 100)
		must(t, err)
		runs = append(runs, name, list(t, all, runJSON))
		one, err := store.ListRuns(ctx, name, 1)
		must(t, err)
		limited = append(limited, name, list(t, one, runJSON))
		l, err := store.LastRun(ctx, name)
		must(t, err)
		last = append(last, name, nullable(t, l))
		s, err := store.GetState(ctx, name)
		must(t, err)
		state = append(state, name, nullable(t, s))
	}
	running, err := store.RunningRuns(ctx)
	must(t, err)
	var byID []string
	for _, id := range f.Read.Runs {
		r, err := store.GetRun(ctx, id)
		must(t, err)
		byID = append(byID, id, nullable(t, r))
	}
	return object(
		"jobs", list(t, jobs, func(j cronwatch.StoredJob) string { return storedJSON(t, &j) }),
		"job", object(job...), "runs", object(runs...), "limited", object(limited...), "last", object(last...), "state", object(state...),
		"running", list(t, running, runJSON), "run", object(byID...),
	)
}

// rawRows are every row of the three tables with each value's SQLite type,
// the JSON columns as the text the database holds.
func rawRows(t *testing.T, file, p string) []string {
	db := sqliteDB(t, file)
	typed := func(columns ...string) string {
		var out []string
		for _, c := range columns {
			out = append(out, "quote("+c+")", "typeof("+c+")")
		}
		return strings.Join(out, ", ")
	}
	var out []string
	for _, q := range []string{
		"SELECT " + typed("name", "definition", "created_at", "updated_at") + " FROM " + p + "jobs ORDER BY created_at, name",
		"SELECT rowid, " + typed("id", "job", "status", "started_at", "finished_at", "duration_ms", "error", "output", "metrics", "trigger") + " FROM " + p + "runs ORDER BY rowid",
		"SELECT " + typed("job", "state") + " FROM " + p + "state ORDER BY job",
	} {
		rows, err := db.QueryContext(ctx, q)
		must(t, err)
		cols, _ := rows.Columns()
		for rows.Next() {
			values := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range values {
				ptrs[i] = &values[i]
			}
			must(t, rows.Scan(ptrs...))
			out = append(out, fmt.Sprintf("%v", values))
		}
		rows.Close()
	}
	return out
}

func schemaOf(t *testing.T, file, p string) []string {
	rows := column(t, sqliteDB(t, file), "SELECT type || '|' || name || '|' || tbl_name || '|' || coalesce(sql, '') FROM sqlite_master WHERE name LIKE ? ORDER BY name", p+"%")
	for i, r := range rows {
		rows[i] = strings.ReplaceAll(r, p, "PREFIX_")
	}
	return rows
}

func TestGoReadsWhatNodeWrote(t *testing.T) {
	needNode(t)
	f := loadShared(t)
	file := tempFile(t, "shared.db")
	if written := node(t, "write", file, "cw_", fixtureFile); written != `{"pruned":[1]}` {
		t.Fatalf("node wrote %s", written)
	}
	store := sqliteStore(t, file, "cw_")
	must(t, store.Init(ctx))
	nodeView := node(t, "read", file, "cw_", fixtureFile)
	if strings.Contains(nodeView, "never stored") {
		t.Fatal("an update of a run that is not there was stored")
	}
	if got := goRead(t, store, f); got != nodeView {
		t.Errorf("Go reads Node's rows differently:\n  go %s\nnode %s", got, nodeView)
	}
	must(t, store.Close())
}

func TestNodeReadsWhatGoWroteAndTheRowsAreTheSame(t *testing.T) {
	needNode(t)
	f := loadShared(t)
	nodeFile, goFile := tempFile(t, "node.db"), tempFile(t, "go.db")
	written := node(t, "write", nodeFile, "cw_", fixtureFile)
	store := sqliteStore(t, goFile, "cw_")
	if got := goWrite(t, store, f); got != written {
		t.Errorf("pruned %s, node %s", got, written)
	}
	must(t, store.Close())
	if a, b := node(t, "read", goFile, "cw_", fixtureFile), node(t, "read", nodeFile, "cw_", fixtureFile); a != b {
		t.Errorf("Node reads Go's rows differently from its own:\n  go %s\nnode %s", a, b)
	}
	goRows, nodeRows := rawRows(t, goFile, "cw_"), rawRows(t, nodeFile, "cw_")
	if !reflect.DeepEqual(goRows, nodeRows) {
		for i := range max(len(goRows), len(nodeRows)) {
			var g, n string
			if i < len(goRows) {
				g = goRows[i]
			}
			if i < len(nodeRows) {
				n = nodeRows[i]
			}
			if g != n {
				t.Errorf("row %d:\n  go %s\nnode %s", i, g, n)
			}
		}
	}
}

func TestTheTablesAreTheSameWhoeverCreatesThem(t *testing.T) {
	needNode(t)
	file := tempFile(t, "both.db")
	node(t, "write", file, "node_", fixtureFile)
	store := sqliteStore(t, file, "go_")
	must(t, store.Init(ctx))
	must(t, store.Close())
	if a, b := schemaOf(t, file, "go_"), schemaOf(t, file, "node_"); !reflect.DeepEqual(a, b) || len(a) != 5 {
		t.Errorf("schema:\n  go %v\nnode %v", a, b)
	}
}

func TestNodeCarriesOnFromGoAndGoFromNode(t *testing.T) {
	needNode(t)
	f := loadShared(t)
	file := tempFile(t, "turns.db")
	node(t, "write", file, "cw_", fixtureFile)
	store := sqliteStore(t, file, "cw_")
	// A Go client finishes a run of a job Node wrote, and checks every job.
	clock := storetest.NewClock(1_767_606_100_000)
	p := process(t, store, clock.Now)
	job := p.Client.MustJob("every-5", cronwatch.Schedule("every 5m"), cronwatch.Timeout("2m"), cronwatch.MaxDuration("90s"))
	must(t, job.Run(ctx, func(_ context.Context, j *cronwatch.JobContext) error { j.Log("from go"); return nil }))
	clock.Advance(10 * 60_000)
	result, err := p.Client.Check(ctx)
	must(t, err)
	names := map[string]bool{}
	for _, j := range result.Jobs {
		names[j.Name] = true
	}
	if !names["nightly-report"] {
		t.Errorf("checked %v", names)
	}
	last, err := store.LastRun(ctx, "every-5")
	must(t, err)
	if *last.Output != "from go" {
		t.Errorf("last output %q", *last.Output)
	}
	var nodeView struct {
		Last  map[string]struct{ Output string } `json:"last"`
		State map[string]json.RawMessage         `json:"state"`
	}
	raw := node(t, "read", file, "cw_", fixtureFile)
	must(t, json.Unmarshal([]byte(raw), &nodeView))
	if nodeView.Last["every-5"].Output != "from go" {
		t.Errorf("node reads output %q", nodeView.Last["every-5"].Output)
	}
	if got := goRead(t, store, f); got != raw {
		t.Errorf("after Go's turn, Go and Node read the file differently:\n  go %s\nnode %s", got, raw)
	}

	// And Node takes a turn on the same file: Go reads its run and state.
	clock.Advance(10 * 60_000)
	nodeRun := node(t, "run", file, "cw_", strconv.FormatInt(clock.Now(), 10))
	if !strings.Contains(nodeRun, `"every-5"`) {
		t.Errorf("node run %s", nodeRun)
	}
	last, err = store.LastRun(ctx, "every-5")
	must(t, err)
	if *last.Output != "from node" {
		t.Errorf("last output %q", *last.Output)
	}
	if got, want := goRead(t, store, f), node(t, "read", file, "cw_", fixtureFile); got != want {
		t.Errorf("after Node's turn:\n  go %s\nnode %s", got, want)
	}
	again, err := p.Client.Check(ctx)
	must(t, err)
	if len(again.Jobs) == 0 {
		t.Error("no jobs checked")
	}
	if errs := p.Errors.List(); len(errs) > 0 {
		t.Errorf("errors: %v", errs)
	}
	must(t, store.Close())
}

func TestNodeAndGoTakeTurnsOnOneJobsStateVersion(t *testing.T) {
	needNode(t)
	file := tempFile(t, "versions.db")
	store := sqliteStore(t, file, "cw_")
	must(t, store.Init(ctx))
	v := func(version, failures int, job string) cronwatch.JobState {
		return stateOf(t, fmt.Sprintf(`{"job":%q,"open":{},"consecutiveFailures":%d,"silencedUntil":null,"lastAlertAt":null,"version":%d}`, job, failures, version))
	}
	type answer struct {
		Written bool            `json:"written"`
		State   json.RawMessage `json:"state"`
	}
	nodeCAS := func(s cronwatch.JobState, expected int) answer {
		var a answer
		must(t, json.Unmarshal([]byte(node(t, "cas", file, "cw_", jsonOf(t, s), strconv.Itoa(expected))), &a))
		return a
	}
	cas := func(s cronwatch.JobState, expected int64) bool {
		ok, err := store.CompareAndSetState(ctx, s, expected)
		must(t, err)
		return ok
	}
	if !cas(v(1, 1, "v"), 0) {
		t.Error("Go writes the first version")
	}
	if nodeCAS(v(1, 9, "v"), 0).Written {
		t.Error("Node's write from before it is refused")
	}
	if a := nodeCAS(v(2, 2, "v"), 1); !a.Written || !strings.Contains(string(a.State), `"version":2`) {
		t.Errorf("Node's fresh write %v %s", a.Written, a.State)
	}
	if cas(v(2, 7, "v"), 1) {
		t.Error("Go's stale write is refused")
	}
	if !cas(v(3, 3, "v"), 2) {
		t.Error("Go writes the next version")
	}
	late := nodeCAS(v(3, 0, "v"), 2)
	stored, err := store.GetState(ctx, "v")
	must(t, err)
	if late.Written || string(late.State) != jsonOf(t, stored) {
		t.Errorf("Node reads Go's version: %v %s, Go %s", late.Written, late.State, jsonOf(t, stored))
	}
	// State written before versions existed counts as 0 for both.
	must(t, store.SetState(ctx, stateOf(t, `{"job":"old","open":{},"consecutiveFailures":4,"silencedUntil":null,"lastAlertAt":null}`)))
	if !nodeCAS(v(1, 5, "old"), 0).Written {
		t.Error("Node writes over state without a version")
	}
	old, err := store.GetState(ctx, "old")
	must(t, err)
	if *old.Version != 1 {
		t.Errorf("version %d", *old.Version)
	}
	must(t, store.Close())
}
