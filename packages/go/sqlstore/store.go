// Package sqlstore keeps CronWatch's jobs, runs and state in the app's own
// database through database/sql: SQLite, Postgres or MySQL (and MariaDB).
// The app brings its driver and its *sql.DB; this package imports none, so
// the cronwatch module needs no driver at all.
//
//	db, _ := sql.Open("sqlite", "file:data/app.db")    // modernc.org/sqlite
//	db, _ := sql.Open("pgx", os.Getenv("DATABASE_URL")) // github.com/jackc/pgx/v5/stdlib
//	db, _ := sql.Open("mysql", "app:pw@tcp(db:3306)/app") // github.com/go-sql-driver/mysql
//
//	store, err := sqlstore.New(db, sqlstore.Postgres)
//	cw, err := cronwatch.New(cronwatch.WithStore(store))
//
// The tables are the SDK's (stores/sql.ts): the same names, columns and
// statements, and the SDK's JSON in the JSON columns byte for byte, so a
// Go process shares a database with a Node, Ruby, Python or PHP one.
package sqlstore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"sync"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/output"
)

// Dialect is the database's SQL.
type Dialect string

// The dialects.
const (
	SQLite   Dialect = "sqlite"
	Postgres Dialect = "postgres"
	// MySQL 8.0.13 or newer, or MariaDB 10.6 or newer.
	MySQL Dialect = "mysql"
)

// Option configures a store.
type Option func(*Store)

// Prefix starts every table name: lowercase letters, digits and
// underscores. Default "cronwatch_".
func Prefix(prefix string) Option { return func(s *Store) { s.prefix = prefix } }

// Store is a cronwatch.Store over a *sql.DB. Safe for use by many
// goroutines at once.
//
// On SQLite it holds one connection of the pool (the SDK's store has one
// connection too): an in-memory database is one per connection, and one
// writer at a time is what SQLite allows anyway. That connection is put in
// WAL mode (with the SDK's retry of a busy database while switching), with
// busy_timeout 5000 and synchronous NORMAL. On Postgres and MySQL it uses
// the pool, each statement on its own (autocommit), so its writes never
// join a transaction the app has open. So a pool limited to one connection
// (db.SetMaxOpenConns(1)) leaves the app none on SQLite, and waits on an
// app's open transaction on the others: give it room for the store too.
//
// The tests are in the sqltest module beside this package (SQLite,
// Postgres, MySQL and MariaDB, and a file shared with the SDK in Node),
// kept apart so the drivers never become the cronwatch module's
// requirements.
type Store struct {
	db      *sql.DB
	dialect Dialect
	prefix  string
	sql     statements

	// SQLite's one connection, in turn.
	mu   sync.Mutex
	conn *sql.Conn
}

var (
	_ cronwatch.Store         = (*Store)(nil)
	_ cronwatch.RunUpdater    = (*Store)(nil)
	_ cronwatch.StateComparer = (*Store)(nil)
	_ cronwatch.RunDeleter    = (*Store)(nil)
)

// New is a store over db in the dialect given.
func New(db *sql.DB, dialect Dialect, options ...Option) (*Store, error) {
	if db == nil {
		return nil, errors.New("sqlstore: New needs a *sql.DB")
	}
	if dialect != SQLite && dialect != Postgres && dialect != MySQL {
		return nil, fmt.Errorf("sqlstore: unknown dialect %s; use sqlstore.SQLite, sqlstore.Postgres or sqlstore.MySQL", js.Quote(string(dialect)))
	}
	s := &Store{db: db, dialect: dialect, prefix: DefaultPrefix}
	for _, o := range options {
		o(s)
	}
	p, err := tablePrefix(s.prefix)
	if err != nil {
		return nil, err
	}
	s.prefix = p
	s.sql = newStatements(dialect, p)
	return s, nil
}

// Dialect is the store's dialect.
func (s *Store) Dialect() Dialect { return s.dialect }

// TablePrefix is the prefix of the store's tables.
func (s *Store) TablePrefix() string { return s.prefix }

// querier is what a statement runs on: the pool, SQLite's connection, or a
// transaction.
type querier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

// busyRetry is how long opening SQLite keeps retrying a busy database
// before it gives up (busy.ts).
const busyRetry = 2 * time.Second

func isBusy(err error) bool {
	if err == nil {
		return false
	}
	text := err.Error()
	return strings.Contains(text, "SQLITE_BUSY") || strings.Contains(text, "SQLITE_LOCKED") || strings.Contains(text, "database is locked") || strings.Contains(text, "database table is locked")
}

// retryBusy runs fn, retrying while SQLite answers busy, with a short
// growing pause, for up to busyRetry in all (busy.ts retryBusy).
func retryBusy(ctx context.Context, fn func() error) error {
	waited := time.Duration(0)
	for attempt := 0; ; attempt++ {
		err := fn()
		if !isBusy(err) || waited >= busyRetry {
			return err
		}
		pause := min(10*time.Millisecond<<attempt, 200*time.Millisecond, busyRetry-waited)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(pause):
		}
		waited += pause
	}
}

// with runs fn with what statements go through: SQLite's one connection,
// held for the call, or the pool.
func (s *Store) with(ctx context.Context, fn func(q querier) error) error {
	if s.dialect != SQLite {
		return fn(s.db)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn == nil {
		conn, err := s.db.Conn(ctx)
		if err != nil {
			return err
		}
		// No busy handler until WAL is on: switching journal mode can answer
		// busy at once while another process is doing the same on a new
		// file, so that is retried. The connection is kept only once every
		// pragma has gone through; a failed open is tried afresh next time.
		err = retryBusy(ctx, func() error { return exec(ctx, conn, "PRAGMA journal_mode = WAL") })
		if err == nil {
			err = exec(ctx, conn, "PRAGMA busy_timeout = 5000")
		}
		if err == nil {
			err = exec(ctx, conn, "PRAGMA synchronous = NORMAL")
		}
		if err != nil {
			conn.Close()
			return err
		}
		s.conn = conn
	}
	err := fn(s.conn)
	if errors.Is(err, driver.ErrBadConn) || errors.Is(err, sql.ErrConnDone) {
		s.conn.Close()
		s.conn = nil
	}
	return err
}

// exec runs a statement whose rows, if any, are not wanted (PRAGMA
// journal_mode answers one).
func exec(ctx context.Context, q querier, text string, args ...any) error {
	rows, err := q.QueryContext(ctx, text, args...)
	if err != nil {
		return err
	}
	for rows.Next() {
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	return rows.Close()
}

// run executes a statement and answers how many rows it changed.
func (s *Store) run(ctx context.Context, text string, args ...any) (int64, error) {
	var n int64
	err := s.with(ctx, func(q querier) error {
		res, err := q.ExecContext(ctx, text, args...)
		if err != nil {
			return err
		}
		n, err = res.RowsAffected()
		return err
	})
	return n, err
}

// row is one row by column name, each value as the driver gave it.
type row map[string]any

func (s *Store) query(ctx context.Context, text string, args ...any) ([]row, error) {
	var out []row
	err := s.with(ctx, func(q querier) error {
		rows, err := q.QueryContext(ctx, text, args...)
		if err != nil {
			return err
		}
		defer rows.Close()
		cols, err := rows.Columns()
		if err != nil {
			return err
		}
		for rows.Next() {
			values := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range values {
				ptrs[i] = &values[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				return err
			}
			r := row{}
			for i, c := range cols {
				r[strings.ToLower(c)] = values[i]
			}
			out = append(out, r)
		}
		return rows.Err()
	})
	return out, err
}

// text is a column as text: drivers hand back strings or bytes.
func text(v any) (string, bool) {
	switch t := v.(type) {
	case string:
		return t, true
	case []byte:
		return string(t), true
	case nil:
		return "", false
	}
	// A driver that decoded a JSON column itself: written back as JSON,
	// though a map loses the order of its keys on the way. pgx's stdlib,
	// go-sql-driver/mysql and modernc.org/sqlite all hand JSON back as
	// text (the sqltest module checks it), so this is for other drivers.
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v), true
	}
	return string(b), true
}

// Rows are read leniently, as the SDK's stores/sql.ts reads them: a
// foreign, hand-edited or damaged row (SQLite keeps whatever type it is
// given, in any column) must affect only its own job, never every read.

// numeric is a time or a count of milliseconds as a column holds it: a
// number as it is, text (Postgres's BIGINT, or a foreign row's) as
// JavaScript's Number() reads it once it is more than whitespace, and NaN
// for anything else.
func numeric(v any) float64 {
	switch t := v.(type) {
	case int64:
		return float64(t)
	case int32:
		return float64(t)
	case int:
		return float64(t)
	case float64:
		return t
	case string:
		if js.Trim(t) != "" {
			return js.Number(t)
		}
	case []byte:
		if s := string(t); js.Trim(s) != "" {
			return js.Number(s)
		}
	}
	return math.NaN()
}

// finite is a column's number as an int64 (held at its ends), or false
// when it is not a finite number.
func finite(v any) (int64, bool) {
	if n, ok := v.(int64); ok {
		return n, true
	}
	f := numeric(v)
	switch {
	case math.IsNaN(f) || math.IsInf(f, 0):
		return 0, false
	case f >= math.MaxInt64:
		return math.MaxInt64, true
	case f <= math.MinInt64:
		return math.MinInt64, true
	}
	return int64(f), true
}

// timeOf is a time that must be there: one that is not a finite number
// reads as 0.
func timeOf(v any) int64 {
	n, _ := finite(v)
	return n
}

// maybeTime is a time or duration that may be absent: one that is not a
// finite number reads as nil.
func maybeTime(v any) *int64 {
	n, ok := finite(v)
	if !ok {
		return nil
	}
	return &n
}

// textOrNil is a text column, or nil when it is not text (NULL, a
// number). Bytes are text: drivers hand TEXT back that way too.
func textOrNil(v any) *string {
	switch t := v.(type) {
	case string:
		return &t
	case []byte:
		s := string(t)
		return &s
	}
	return nil
}

// parsed is a JSON column parsed, or nil (JSON null) when it is NULL or
// its text does not parse.
func parsed(v any) any {
	t, ok := text(v)
	if !ok {
		return nil
	}
	out, err := js.Parse(t)
	if err != nil {
		return nil
	}
	return out
}

// job is a job's row. A definition that is not a JSON object (text that
// does not parse, null, a string, a list) is the zero Definition, which
// the client reads as a job it cannot evaluate: reported and shown as
// failing while the others carry on.
func (r row) job() (cronwatch.StoredJob, error) {
	name, _ := text(r["name"])
	var d cronwatch.Definition
	if _, ok := parsed(r["definition"]).(*js.Object); ok {
		def, _ := text(r["definition"])
		if err := json.Unmarshal([]byte(def), &d); err != nil {
			return cronwatch.StoredJob{}, fmt.Errorf("job %s: %w", name, err)
		}
	}
	return cronwatch.StoredJob{Name: name, Definition: d, CreatedAt: timeOf(r["created_at"]), UpdatedAt: timeOf(r["updated_at"])}, nil
}

// run is a run's row. A start that is not a finite number reads as 0, a
// finish or duration as nil; an error or output that is not text as nil;
// metrics that do not parse to an object as none (of those that do, the
// numbers); a trigger that is not text as "run".
func (r row) run() (cronwatch.Run, error) {
	var out cronwatch.Run
	out.ID, _ = text(r["id"])
	out.Job, _ = text(r["job"])
	status, _ := text(r["status"])
	out.Status = cronwatch.RunStatus(status)
	out.StartedAt = timeOf(r["started_at"])
	out.FinishedAt = maybeTime(r["finished_at"])
	out.DurationMs = maybeTime(r["duration_ms"])
	out.Error = textOrNil(r["error"])
	out.Output = textOrNil(r["output"])
	out.Metrics = numbersOf(parsed(r["metrics"]))
	out.Trigger = "run"
	if t := textOrNil(r["trigger"]); t != nil {
		out.Trigger = *t
	}
	return out, nil
}

// numbersOf is the numeric entries of a parsed JSON object, in order.
func numbersOf(v any) cronwatch.Metrics {
	out := cronwatch.Metrics{}
	if o, ok := v.(*js.Object); ok {
		for _, k := range o.Keys() {
			if x, _ := o.Get(k); x != nil {
				if f, ok := x.(float64); ok {
					out.Set(k, f)
				}
			}
		}
	}
	return out
}

// state is a state's row, or nil (no state) when it is not a JSON object:
// text that does not parse, a number, a list. The next write replaces it.
func (r row) state() (*cronwatch.JobState, error) {
	if _, ok := parsed(r["state"]).(*js.Object); !ok {
		return nil, nil
	}
	t, _ := text(r["state"])
	var s cronwatch.JobState
	if err := json.Unmarshal([]byte(t), &s); err != nil {
		return nil, err
	}
	return &s, nil
}

// Postgres refuses U+0000 in TEXT and JSONB, and a refused write loses the
// whole row, so every dialect writes text without it: a run's trigger,
// output, error and metric names, and every key and string of a definition
// and a state. Identifiers (a job's name, a run's id) are written as given;
// the client refuses one with a NUL before it gets here.

// jsonText is the SDK's JSON of a value, without NUL.
func jsonText(v json.Marshaler) string {
	b, _ := v.MarshalJSON()
	return output.StripJSONNul(string(b))
}

// textValue is a TEXT value as a JavaScript driver writes it: valid UTF-8,
// without NUL.
func textValue(p *string) any {
	if p == nil {
		return nil
	}
	return output.StripNul(js.WellFormed(*p))
}

func intValue(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

// Parameters in statement order, so every driver binds the same values.

func insertRunArgs(r cronwatch.Run) []any {
	return []any{r.ID, r.Job, string(r.Status), r.StartedAt, intValue(r.FinishedAt), intValue(r.DurationMs), textValue(r.Error), textValue(r.Output), jsonText(r.Metrics), output.StripNul(r.Trigger)}
}

func updateRunArgs(r cronwatch.Run) []any {
	return []any{string(r.Status), intValue(r.FinishedAt), intValue(r.DurationMs), textValue(r.Error), textValue(r.Output), jsonText(r.Metrics), r.ID}
}

// Init makes the tables. On Postgres many processes starting at once would
// race CREATE TABLE IF NOT EXISTS, which Postgres can reject with a unique
// violation on pg_type, so they take turns under an advisory lock per
// prefix. MySQL commits CREATE TABLE at once, so call Init when nothing is
// open (it runs at the client's first use).
func (s *Store) Init(ctx context.Context) error {
	statements := schema(s.dialect, s.prefix)
	if s.dialect != Postgres {
		return s.with(ctx, func(q querier) error {
			for _, st := range statements {
				if _, err := q.ExecContext(ctx, st); err != nil {
					return err
				}
			}
			return nil
		})
	}
	return s.transaction(ctx, func(q querier) error {
		if err := exec(ctx, q, "SELECT pg_advisory_xact_lock(hashtext($1))", "cronwatch:"+s.prefix); err != nil {
			return err
		}
		for _, st := range statements {
			if _, err := q.ExecContext(ctx, st); err != nil {
				return err
			}
		}
		return nil
	})
}

// transaction runs fn in a transaction of the store's own.
func (s *Store) transaction(ctx context.Context, fn func(q querier) error) error {
	begin := func(q interface {
		BeginTx(context.Context, *sql.TxOptions) (*sql.Tx, error)
	}) error {
		tx, err := q.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if err := fn(tx); err != nil {
			_ = tx.Rollback()
			return err
		}
		return tx.Commit()
	}
	if s.dialect != SQLite {
		return begin(s.db)
	}
	return s.with(ctx, func(q querier) error { return begin(q.(*sql.Conn)) })
}

func (s *Store) UpsertJob(ctx context.Context, def cronwatch.Definition, now int64) error {
	_, err := s.run(ctx, s.sql.upsertJob, def.Name(), jsonText(def), now, now)
	return err
}

func (s *Store) GetJob(ctx context.Context, name string) (*cronwatch.StoredJob, error) {
	rows, err := s.query(ctx, s.sql.getJob, name)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	j, err := rows[0].job()
	if err != nil {
		return nil, err
	}
	return &j, nil
}

func (s *Store) ListJobs(ctx context.Context) ([]cronwatch.StoredJob, error) {
	rows, err := s.query(ctx, s.sql.listJobs)
	if err != nil {
		return nil, err
	}
	out := []cronwatch.StoredJob{}
	for _, r := range rows {
		j, err := r.job()
		if err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, nil
}

// DeleteJob removes the job, its runs and its state in one transaction.
func (s *Store) DeleteJob(ctx context.Context, name string) error {
	return s.transaction(ctx, func(q querier) error {
		for _, st := range []string{s.sql.deleteRuns, s.sql.deleteState, s.sql.deleteJob} {
			if _, err := q.ExecContext(ctx, st, name); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Store) InsertRun(ctx context.Context, r cronwatch.Run) error {
	if s.dialect == MySQL {
		// MySQL's trigger column is VARCHAR(255), which refuses anything
		// longer (the others are TEXT): a long trigger is cut to fit rather
		// than lose the whole run.
		if runes := []rune(r.Trigger); len(runes) > 255 {
			r.Trigger = string(runes[:255])
		}
	}
	_, err := s.run(ctx, s.sql.insertRun, insertRunArgs(r)...)
	return err
}

func (s *Store) UpdateRun(ctx context.Context, r cronwatch.Run) error {
	_, err := s.run(ctx, s.sql.updateRun, updateRunArgs(r)...)
	return err
}

func (s *Store) UpdateRunIf(ctx context.Context, r cronwatch.Run, from []cronwatch.RunStatus) (bool, error) {
	if len(from) == 0 {
		return false, nil
	}
	args := updateRunArgs(r)
	for _, st := range from {
		args = append(args, string(st))
	}
	n, err := s.run(ctx, updateRunIfSQL(s.dialect, s.prefix, len(from)), args...)
	if err != nil || n > 0 || s.dialect != MySQL {
		return n > 0, err
	}
	// MySQL counts only the rows an UPDATE changed, so a row that already
	// held these values (and matched) answers 0: it was written all the same.
	stored, err := s.GetRun(ctx, r.ID)
	if err != nil || stored == nil {
		return false, err
	}
	matched := false
	for _, st := range from {
		matched = matched || stored.Status == st
	}
	return matched && canonical(updateRunArgs(*stored)) == canonical(updateRunArgs(r)), nil
}

// DeleteRunIf deletes a run only while it is of job and in status, in one
// statement, and says whether it did. A DELETE counts the rows it matched on
// every dialect, MySQL included.
func (s *Store) DeleteRunIf(ctx context.Context, id, job string, status cronwatch.RunStatus) (bool, error) {
	n, err := s.run(ctx, deleteRunIfSQL(s.dialect, s.prefix), id, job, string(status))
	return n > 0, err
}

// canonical is statement arguments compared whatever order a JSON column
// gave an object's keys back in.
func canonical(args []any) string {
	var b strings.Builder
	for _, a := range args {
		if t, ok := a.(string); ok && (strings.HasPrefix(t, "{") || strings.HasPrefix(t, "[")) {
			var v any
			if json.Unmarshal([]byte(t), &v) == nil {
				out, _ := json.Marshal(v)
				a = string(out)
			}
		}
		fmt.Fprintf(&b, "%#v\x00", a)
	}
	return b.String()
}

func (s *Store) GetRun(ctx context.Context, id string) (*cronwatch.Run, error) {
	rows, err := s.query(ctx, s.sql.getRun, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	r, err := rows[0].run()
	if err != nil {
		return nil, err
	}
	return &r, nil
}

func (s *Store) runs(ctx context.Context, text string, args ...any) ([]cronwatch.Run, error) {
	rows, err := s.query(ctx, text, args...)
	if err != nil {
		return nil, err
	}
	out := []cronwatch.Run{}
	for _, r := range rows {
		run, err := r.run()
		if err != nil {
			return nil, err
		}
		out = append(out, run)
	}
	return out, nil
}

func (s *Store) ListRuns(ctx context.Context, job string, limit int) ([]cronwatch.Run, error) {
	return s.runs(ctx, s.sql.listRuns, job, max(0, limit))
}

func (s *Store) LastRun(ctx context.Context, job string) (*cronwatch.Run, error) {
	list, err := s.runs(ctx, s.sql.listRuns, job, 1)
	if err != nil || len(list) == 0 {
		return nil, err
	}
	return &list[0], nil
}

func (s *Store) RunningRuns(ctx context.Context) ([]cronwatch.Run, error) {
	return s.runs(ctx, s.sql.runningRuns)
}

func (s *Store) GetState(ctx context.Context, job string) (*cronwatch.JobState, error) {
	rows, err := s.query(ctx, s.sql.getState, job)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return rows[0].state()
}

func (s *Store) SetState(ctx context.Context, st cronwatch.JobState) error {
	_, err := s.run(ctx, s.sql.setState, st.Job, jsonText(st))
	return err
}

func (s *Store) CompareAndSetState(ctx context.Context, st cronwatch.JobState, expected int64) (bool, error) {
	body := jsonText(st)
	if s.dialect != MySQL {
		var n int64
		var err error
		if expected == 0 {
			n, err = s.run(ctx, s.sql.casInsert, st.Job, body)
		} else {
			n, err = s.run(ctx, s.sql.casUpdate, body, st.Job, expected)
		}
		return n > 0, err
	}
	if expected != 0 {
		n, err := s.run(ctx, s.sql.casUpdate, body, st.Job, expected)
		return n > 0, err
	}
	// Version 0 is a row at version 0 (or with none), or no row at all.
	n, err := s.run(ctx, s.sql.casFromZero, body, st.Job)
	if err != nil || n > 0 {
		return n > 0, err
	}
	if _, err := s.run(ctx, s.sql.casInsert, st.Job, body); err != nil {
		// A row is there: another process wrote first, unless it holds
		// exactly what this write sent, when the insert landed and only its
		// answer was lost (a connection dropped after the commit), as the
		// PHP port's stateLanded() reads it. Counting that as refused would
		// have the client work the change out again over its own write, and
		// the alert the first attempt opened would never go out.
		if stored, gerr := s.GetState(ctx, st.Job); gerr == nil && stored != nil {
			return jsonText(*stored) == body, nil
		}
		return false, err
	}
	return true, nil
}

func (s *Store) Prune(ctx context.Context, before int64) (int, error) {
	n, err := s.run(ctx, s.sql.prune, before)
	return int(n), err
}

// Close gives SQLite's connection back to the pool. The *sql.DB is the
// app's, and stays open.
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn != nil {
		err := s.conn.Close()
		s.conn = nil
		return err
	}
	return nil
}
