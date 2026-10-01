package sqltest

// conformance/store.json's foreignRows on SQLite, which keeps whatever type
// it is given in any column: each foreign, hand-edited or damaged row reads
// leniently, and one affects only its own job (stores.test.ts, "each
// foreign row reads leniently" and "a check, a silence and every page over
// foreign rows").

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
)

type foreignRow struct {
	Table    string          `json:"table"`
	Row      json.RawMessage `json:"row"`
	Read     json.RawMessage `json:"read"`
	Readable *bool           `json:"readable"`
}

type foreignFixture struct {
	Rows  []foreignRow `json:"rows"`
	Check struct {
		Now       int64             `json:"now"`
		ExtraJobs []json.RawMessage `json:"extraJobs"`
		ExtraRuns []json.RawMessage `json:"extraRuns"`
		Reported  []string          `json:"reported"`
		Alerts    []struct {
			Type string `json:"type"`
			Job  string `json:"job"`
			At   int64  `json:"at"`
		} `json:"alerts"`
		Health  map[string]string `json:"health"`
		Silence struct {
			Job      string          `json:"job"`
			For      string          `json:"for"`
			Reported []string        `json:"reported"`
			State    json.RawMessage `json:"state"`
		} `json:"silence"`
		States map[string]json.RawMessage `json:"states"`
		Read   struct {
			Reported []string `json:"reported"`
			Pages    []struct {
				Path   string `json:"path"`
				Status int    `json:"status"`
			} `json:"pages"`
		} `json:"read"`
	} `json:"check"`
}

func readForeignRows(t *testing.T) foreignFixture {
	t.Helper()
	data, err := os.ReadFile(fixturePath)
	must(t, err)
	var root struct {
		ForeignRows foreignFixture `json:"foreignRows"`
	}
	must(t, json.Unmarshal(data, &root))
	if len(root.ForeignRows.Rows) == 0 {
		t.Fatal("no foreignRows")
	}
	return root.ForeignRows
}

// insertRaw writes one row with each value as SQLite holds it: a string as
// TEXT, a whole number as INTEGER, another number as REAL, null as NULL.
func insertRaw(t *testing.T, db *sql.DB, table string, row json.RawMessage) {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(string(row)))
	dec.UseNumber()
	// Column order as written, so the statement reads like the fixture.
	var cols []string
	var args []any
	_, err := dec.Token()
	must(t, err)
	for dec.More() {
		k, err := dec.Token()
		must(t, err)
		var v any
		must(t, dec.Decode(&v))
		cols = append(cols, k.(string))
		switch n := v.(type) {
		case json.Number:
			if i, err := n.Int64(); err == nil {
				v = i
			} else {
				f, _ := n.Float64()
				v = f
			}
		}
		args = append(args, v)
	}
	marks := strings.TrimSuffix(strings.Repeat("?, ", len(cols)), ", ")
	_, err = db.ExecContext(ctx, "INSERT INTO cronwatch_"+table+" ("+strings.Join(cols, ", ")+") VALUES ("+marks+")", args...)
	must(t, err)
}

// canonical is JSON with every object's keys sorted, for comparing values.
func canonical(t *testing.T, data []byte) string {
	t.Helper()
	var v any
	must(t, json.Unmarshal(data, &v))
	out, err := json.Marshal(v)
	must(t, err)
	return string(out)
}

func sameValue(t *testing.T, what string, got []byte, want []byte) {
	t.Helper()
	if g, w := canonical(t, got), canonical(t, want); g != w {
		t.Errorf("%s:\n got %s\nwant %s", what, g, w)
	}
}

// normalized is a state as the client reads it (normalizeState): none is
// an empty state, and the lists a state lacks are empty.
func normalized(t *testing.T, job string, s *cronwatch.JobState) []byte {
	t.Helper()
	if s == nil {
		return []byte(`{"job":` + jsonString(job) + `,"open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"pendingRecovery":[],"undelivered":[]}`)
	}
	data, err := s.MarshalJSON()
	must(t, err)
	var m map[string]any
	must(t, json.Unmarshal(data, &m))
	for _, k := range []string{"pendingRecovery", "undelivered"} {
		if _, ok := m[k]; !ok {
			m[k] = []any{}
		}
	}
	out, err := json.Marshal(m)
	must(t, err)
	return out
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func TestSQLiteForeignRowsReadLeniently(t *testing.T) {
	f := readForeignRows(t)
	for i, c := range f.Rows {
		label := c.Table + " " + string(c.Row)
		db := sqliteDB(t, tempFile(t, "row"+string(rune('a'+i%26))+".db"))
		store := newStore(t, db, sqlstore.SQLite, sqlstore.DefaultPrefix)
		must(t, store.Init(ctx))
		insertRaw(t, db, c.Table, c.Row)
		var row map[string]any
		must(t, json.Unmarshal(c.Row, &row))
		switch c.Table {
		case "jobs":
			name := row["name"].(string)
			var read struct {
				Name       string          `json:"name"`
				Definition json.RawMessage `json:"definition"`
				CreatedAt  int64           `json:"createdAt"`
				UpdatedAt  int64           `json:"updatedAt"`
			}
			must(t, json.Unmarshal(c.Read, &read))
			got, err := store.GetJob(ctx, name)
			must(t, err)
			list, err := store.ListJobs(ctx)
			must(t, err)
			if got == nil || len(list) != 1 {
				t.Fatalf("%s: got %v, listed %d", label, got, len(list))
			}
			for _, j := range []cronwatch.StoredJob{*got, list[0]} {
				if j.Name != read.Name || j.CreatedAt != read.CreatedAt || j.UpdatedAt != read.UpdatedAt {
					t.Errorf("%s: %s %d %d", label, j.Name, j.CreatedAt, j.UpdatedAt)
				}
				// The store reads a definition that is not an object as the
				// zero Definition, which the client reads as unreadable
				// (readStoredJob, replayed in the core module); one that is
				// an object as stored.
				zero := reflect.ValueOf(j.Definition).IsZero()
				if zero != !*c.Readable {
					t.Errorf("%s: the zero Definition is %v, readable %v", label, zero, *c.Readable)
				}
				if !zero {
					stored, err := j.Definition.MarshalJSON()
					must(t, err)
					sameValue(t, label+" definition", stored, []byte(row["definition"].(string)))
				}
			}
		case "runs":
			got, err := store.GetRun(ctx, row["id"].(string))
			must(t, err)
			data, err := json.Marshal(got)
			must(t, err)
			sameValue(t, label+" GetRun", data, c.Read)
			list, err := store.ListRuns(ctx, row["job"].(string), 10)
			must(t, err)
			data, err = json.Marshal(list)
			must(t, err)
			sameValue(t, label+" ListRuns", data, []byte("["+string(c.Read)+"]"))
		case "state":
			job := row["job"].(string)
			got, err := store.GetState(ctx, job)
			must(t, err)
			sameValue(t, label, normalized(t, job, got), c.Read)
		}
		must(t, store.Close())
	}
}

func TestSQLiteCheckSilenceAndPagesOverForeignRows(t *testing.T) {
	f := readForeignRows(t)
	c := f.Check
	db := sqliteDB(t, tempFile(t, "foreign.db"))
	store := newStore(t, db, sqlstore.SQLite, sqlstore.DefaultPrefix)
	must(t, store.Init(ctx))
	var names []string
	insert := func(table string, row json.RawMessage) {
		insertRaw(t, db, table, row)
		if table == "jobs" {
			var r struct {
				Name string `json:"name"`
			}
			must(t, json.Unmarshal(row, &r))
			names = append(names, r.Name)
		}
	}
	for _, table := range []string{"jobs", "runs", "state"} {
		for _, r := range f.Rows {
			if r.Table == table {
				insert(table, r.Row)
			}
		}
	}
	for _, r := range c.ExtraJobs {
		insert("jobs", r)
	}
	for _, r := range c.ExtraRuns {
		insert("runs", r)
	}

	proc := process(t, store, func() int64 { return c.Now })
	seen := 0
	// The jobs reported since the last call, by the name each where ends with.
	reported := func() []string {
		all := proc.Errors.List()
		set := map[string]bool{}
		for _, e := range all[seen:] {
			where, _, _ := strings.Cut(e, ": ")
			name := where
			for _, n := range names {
				if strings.HasSuffix(where, " "+n) {
					name = n
				}
			}
			set[name] = true
		}
		seen = len(all)
		out := []string{}
		for n := range set {
			out = append(out, n)
		}
		sort.Strings(out)
		return out
	}
	sameList := func(what string, got, want []string) {
		t.Helper()
		if want == nil {
			want = []string{}
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %v, want %v", what, got, want)
		}
	}

	result, err := proc.Client.Check(ctx)
	must(t, err)
	sameList("reported by the check", reported(), c.Reported)
	var alerts []string
	for _, a := range proc.Alerts.List() {
		alerts = append(alerts, string(a.Type)+" "+a.Job+" "+itoa(a.At))
	}
	var want []string
	for _, a := range c.Alerts {
		want = append(want, a.Type+" "+a.Job+" "+itoa(a.At))
	}
	sameList("alerts", alerts, want)
	health := map[string]string{}
	for _, j := range result.Jobs {
		health[j.Name] = string(j.Health)
	}
	if !reflect.DeepEqual(health, c.Health) {
		t.Errorf("health: %v\nwant %v", health, c.Health)
	}

	duration, err := time.ParseDuration(c.Silence.For)
	must(t, err)
	_, err = proc.Client.Silence(ctx, c.Silence.Job, duration)
	must(t, err)
	sameList("reported by the silence", reported(), c.Silence.Reported)
	silenced, err := store.GetState(ctx, c.Silence.Job)
	must(t, err)
	data, err := json.Marshal(silenced)
	must(t, err)
	sameValue(t, "the silenced state", data, c.Silence.State)

	// The stored states as they are, some still the foreign values: a read
	// that changes nothing writes nothing.
	for job, state := range c.States {
		var raw string
		must(t, db.QueryRowContext(ctx, "SELECT state FROM cronwatch_state WHERE job = ?", job).Scan(&raw))
		sameValue(t, job+"'s stored state", []byte(raw), state)
	}

	routes, err := proc.Client.Routes(cronwatch.WithToken("tok"), cronwatch.WithBasePath("/cronwatch"))
	must(t, err)
	for _, page := range c.Read.Pages {
		r := httptest.NewRequest(http.MethodGet, "http://app.test"+page.Path, nil)
		r.Header.Set("Authorization", "Bearer tok")
		w := httptest.NewRecorder()
		routes.ServeHTTP(w, r)
		if w.Code != page.Status {
			t.Errorf("%s: %d, want %d", page.Path, w.Code, page.Status)
		}
	}
	sameList("reported by the pages", reported(), c.Read.Reported)
	must(t, proc.Client.Close())
}

func itoa(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}
