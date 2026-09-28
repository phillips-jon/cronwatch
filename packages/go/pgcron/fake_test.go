package pgcron_test

// cron.job and cron.job_run_details in memory, as the SDK's pgcron.test.ts
// has them, behind a database/sql driver of the test's own that answers the
// source's queries, so the source reads through a real *sql.DB and scans
// what a driver hands back (ids as text, as the SDK's fake gives them).

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeJob struct {
	jobid    int64
	jobname  *string
	schedule string
	active   bool
}

type detail struct {
	runid, jobid int64
	status       string
	message      *string
	start, end   *time.Time
}

// fakeCron is the two tables and the settings a role can read.
type fakeCron struct {
	mu       sync.Mutex
	jobs     []*fakeJob
	details  []*detail
	settings map[string]string
	runid    int64
	queries  []string
}

func newFakeCron() *fakeCron {
	return &fakeCron{settings: map[string]string{"cron.timezone": "GMT", "cron.log_run": "on"}}
}

func name(s string) *string { return &s }

func (f *fakeCron) job(jobid int64, jobname *string, schedule string, active bool) *fakeJob {
	f.mu.Lock()
	defer f.mu.Unlock()
	j := &fakeJob{jobid, jobname, schedule, active}
	f.jobs = append(f.jobs, j)
	return j
}

func at(ms int64) *time.Time {
	t := time.UnixMilli(ms).UTC()
	return &t
}

// add is a run detail; start and end are epoch milliseconds, or -1 for NULL.
func (f *fakeCron) add(jobid int64, status string, start, end int64, message ...string) *detail {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.runid++
	d := &detail{runid: f.runid, jobid: jobid, status: status}
	if start >= 0 {
		d.start = at(start)
	}
	if end >= 0 {
		d.end = at(end)
	}
	if len(message) > 0 {
		d.message = &message[0]
	}
	f.details = append(f.details, d)
	return d
}

// update changes a detail as pg_cron would, under the lock.
func (f *fakeCron) update(change func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change()
}

// db is a *sql.DB on this fake.
func (f *fakeCron) db(t *testing.T) *sql.DB {
	t.Helper()
	dsn := strconv.FormatInt(seq.Add(1), 10)
	crons.Store(dsn, f)
	db, err := sql.Open("cwfakecron", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

var (
	crons sync.Map
	seq   atomic.Int64
)

func init() { sql.Register("cwfakecron", fakeDriver{}) }

type fakeDriver struct{}

func (fakeDriver) Open(dsn string) (driver.Conn, error) {
	f, ok := crons.Load(dsn)
	if !ok {
		return nil, errors.New("no such fake")
	}
	return &fakeConn{f.(*fakeCron)}, nil
}

type fakeConn struct{ f *fakeCron }

func (c *fakeConn) Prepare(string) (driver.Stmt, error) { return nil, errors.New("not supported") }
func (c *fakeConn) Close() error                        { return nil }
func (c *fakeConn) Begin() (driver.Tx, error)           { return nil, errors.New("not supported") }

// arrayOf reads a Postgres array literal of integers.
func arrayOf(v driver.Value) []int64 {
	s, _ := v.(string)
	var out []int64
	for _, part := range strings.Split(strings.Trim(s, "{}"), ",") {
		if part != "" {
			n, _ := strconv.ParseInt(part, 10, 64)
			out = append(out, n)
		}
	}
	return out
}

func (c *fakeConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	f := c.f
	f.mu.Lock()
	defer f.mu.Unlock()
	f.queries = append(f.queries, query)
	switch {
	case strings.Contains(query, "pg_settings"):
		value, ok := f.settings[args[0].Value.(string)]
		if !ok {
			return &fakeRows{columns: []string{"setting"}}, nil
		}
		return &fakeRows{columns: []string{"setting"}, rows: [][]driver.Value{{value}}}, nil
	case strings.Contains(query, "FROM cron.job ORDER BY"):
		rows := &fakeRows{columns: []string{"jobid", "jobname", "schedule", "database", "username", "active"}}
		for _, j := range f.jobs {
			var jobname driver.Value
			if j.jobname != nil {
				jobname = *j.jobname
			}
			rows.rows = append(rows.rows, []driver.Value{strconv.FormatInt(j.jobid, 10), jobname, j.schedule, "postgres", "postgres", j.active})
		}
		return rows, nil
	case strings.Contains(query, "ORDER BY d.runid DESC"):
		jobid := args[0].Value.(int64)
		var list []*detail
		for _, d := range f.details {
			if d.jobid == jobid {
				list = append(list, d)
			}
		}
		sort.Slice(list, func(i, j int) bool { return list[i].runid > list[j].runid })
		return detailRows(list[:min(len(list), 20)]), nil
	case strings.Contains(query, "unnest"):
		ids, afters, open := arrayOf(args[0].Value), arrayOf(args[1].Value), arrayOf(args[2].Value)
		after := map[int64]int64{}
		for i, id := range ids {
			after[id] = afters[i]
		}
		var list []*detail
		for _, d := range f.details {
			cursor, tracked := after[d.jobid]
			if (tracked && d.runid > cursor) || contains(open, d.runid) {
				list = append(list, d)
			}
		}
		sort.Slice(list, func(i, j int) bool { return list[i].runid < list[j].runid })
		return detailRows(list[:min(len(list), 500)]), nil
	}
	return nil, fmt.Errorf("unexpected query %s", query)
}

func contains(list []int64, n int64) bool {
	for _, e := range list {
		if e == n {
			return true
		}
	}
	return false
}

func detailRows(list []*detail) *fakeRows {
	rows := &fakeRows{columns: []string{"runid", "jobid", "status", "return_message", "start_time", "end_time"}}
	for _, d := range list {
		var message, start, end driver.Value
		if d.message != nil {
			message = *d.message
		}
		if d.start != nil {
			start = *d.start
		}
		if d.end != nil {
			end = *d.end
		}
		rows.rows = append(rows.rows, []driver.Value{strconv.FormatInt(d.runid, 10), strconv.FormatInt(d.jobid, 10), d.status, message, start, end})
	}
	return rows
}

type fakeRows struct {
	columns []string
	rows    [][]driver.Value
	at      int
}

func (r *fakeRows) Columns() []string { return r.columns }
func (r *fakeRows) Close() error      { return nil }

func (r *fakeRows) Next(dest []driver.Value) error {
	if r.at >= len(r.rows) {
		return io.EOF
	}
	copy(dest, r.rows[r.at])
	r.at++
	return nil
}
