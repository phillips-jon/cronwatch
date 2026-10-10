package sqlstore

// The schema, statements, and parameters. SQLite's and Postgres's are
// stores/sql.ts's text for text, so a Node, Ruby, Python, PHP, and Go
// process can share one database and sqlite_master reads the same whoever
// made the tables. MySQL (and MariaDB) has a dialect of its own, the PHP
// port's, since it has no ON CONFLICT, no partial index, and no TEXT
// primary key: the same tables, columns, and values, with the JSON columns
// as text holding the SDK's JSON byte for byte, never MySQL's JSON type,
// which would rewrite it.

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"cronwatch.dev/go/internal/js"
)

// DefaultPrefix starts every table name unless Prefix says otherwise.
const DefaultPrefix = "cronwatch_"

// maxPrefix: Postgres truncates identifiers past 63 bytes; the longest name
// built is the prefix plus "runs_job_started".
const maxPrefix = 63 - len("runs_job_started")

var prefixRE = regexp.MustCompile(`^[a-z_][a-z0-9_]*$`)

// tablePrefix checks a prefix. Table names are built from it, so it must be
// a plain lowercase identifier. Uppercase is refused rather than folded:
// Postgres lowercases unquoted names, so "Monitoring_" would quietly become
// "monitoring_".
func tablePrefix(prefix string) (string, error) {
	if !prefixRE.MatchString(prefix) || len(prefix) > maxPrefix {
		//lint:ignore ST1005 the SDK's message, word for word
		return "", fmt.Errorf("cronwatch: invalid table prefix %s. Use lowercase letters, digits, and underscores, not starting with a digit, at most %d characters.", js.Quote(prefix), maxPrefix)
	}
	return prefix, nil
}

// schema is the tables, one statement each (run in turn, since not every
// driver takes several statements in one Exec).
func schema(d Dialect, p string) []string {
	if d == MySQL {
		table := "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
		return []string{
			`CREATE TABLE IF NOT EXISTS ` + p + `jobs (
      name VARCHAR(255) NOT NULL,
      definition LONGTEXT NOT NULL,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      PRIMARY KEY (name)
    ) ` + table,
			`CREATE TABLE IF NOT EXISTS ` + p + `runs (
      seq BIGINT NOT NULL AUTO_INCREMENT,
      id VARCHAR(255) NOT NULL,
      job VARCHAR(255) NOT NULL,
      status VARCHAR(255) NOT NULL,
      started_at BIGINT NOT NULL,
      finished_at BIGINT,
      duration_ms BIGINT,
      error MEDIUMTEXT,
      output MEDIUMTEXT,
      metrics LONGTEXT NOT NULL DEFAULT ('{}'),
      ` + "`trigger`" + ` VARCHAR(255) NOT NULL DEFAULT 'run',
      PRIMARY KEY (id),
      UNIQUE KEY ` + p + `runs_seq (seq),
      KEY ` + p + `runs_job_started (job, started_at DESC),
      KEY ` + p + `runs_running (status)
    ) ` + table,
			`CREATE TABLE IF NOT EXISTS ` + p + `state (
      job VARCHAR(255) NOT NULL,
      state LONGTEXT NOT NULL,
      PRIMARY KEY (job)
    ) ` + table,
		}
	}
	pg := d == Postgres
	integer, json, seq := "INTEGER", "TEXT", ""
	if pg {
		integer, json, seq = "BIGINT", "JSONB", "\n      seq BIGSERIAL,"
	}
	// sql.ts's template, whitespace and all, cut into its statements.
	text := `
    CREATE TABLE IF NOT EXISTS ` + p + `jobs (
      name TEXT PRIMARY KEY,
      definition ` + json + ` NOT NULL,
      created_at ` + integer + ` NOT NULL,
      updated_at ` + integer + ` NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ` + p + `runs (` + seq + `
      id TEXT PRIMARY KEY,
      job TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at ` + integer + ` NOT NULL,
      finished_at ` + integer + `,
      duration_ms ` + integer + `,
      error TEXT,
      output TEXT,
      metrics ` + json + ` NOT NULL DEFAULT '{}',
      trigger TEXT NOT NULL DEFAULT 'run'
    );
    CREATE INDEX IF NOT EXISTS ` + p + `runs_job_started ON ` + p + `runs (job, started_at DESC);
    CREATE INDEX IF NOT EXISTS ` + p + `runs_running ON ` + p + `runs (status) WHERE status = 'running';
    CREATE TABLE IF NOT EXISTS ` + p + `state (
      job TEXT PRIMARY KEY,
      state ` + json + ` NOT NULL
    );
  `
	var out []string
	for _, s := range strings.Split(text, ";") {
		if strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
	}
	return out
}

// statements are the queries by name, with ? placeholders (numbered $1,
// $2 ... for Postgres, as sql.ts numbers them).
type statements struct {
	upsertJob, getJob, listJobs, deleteRuns, deleteState, deleteJob string
	insertRun, updateRun, getRun, listRuns, runningRuns             string
	getState, setState, casInsert, casUpdate, casFromZero, prune    string
}

func newStatements(d Dialect, p string) statements {
	if d == MySQL {
		// The version inside a state's JSON text, as the SDK's stateVersion()
		// reads it: a whole number from 0 to 2^53 - 1, else 0. MySQL's
		// JSON_EXTRACT answers JSON and MariaDB's text; plus 0, both are a
		// number, and the CASE tests the JSON type before any arithmetic. The
		// column is text, which may hold text that is not JSON at all (a
		// damaged row's): that counts as 0, tested before JSON_EXTRACT, which
		// fails on it.
		version := func(column string) string {
			v := "JSON_EXTRACT(" + column + ", '$.version')"
			return "CASE WHEN NOT JSON_VALID(" + column + ") THEN 0 WHEN JSON_TYPE(" + v + ") NOT IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 WHEN " +
				v + " + 0 = FLOOR(" + v + " + 0) AND " + v + " + 0 BETWEEN 0 AND 9007199254740991 THEN CAST(" + v + " + 0 AS SIGNED) ELSE 0 END"
		}
		return statements{
			upsertJob: `INSERT INTO ` + p + `jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE definition = VALUES(definition), updated_at = VALUES(updated_at)`,
			getJob:      `SELECT * FROM ` + p + `jobs WHERE name = ?`,
			listJobs:    `SELECT * FROM ` + p + `jobs ORDER BY name`,
			deleteRuns:  `DELETE FROM ` + p + `runs WHERE job = ?`,
			deleteState: `DELETE FROM ` + p + `state WHERE job = ?`,
			deleteJob:   `DELETE FROM ` + p + `jobs WHERE name = ?`,
			insertRun: `INSERT INTO ` + p + "runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, `trigger`)" + `
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			updateRun:   `UPDATE ` + p + `runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?`,
			getRun:      `SELECT * FROM ` + p + `runs WHERE id = ?`,
			listRuns:    `SELECT * FROM ` + p + `runs WHERE job = ? ORDER BY started_at DESC, seq DESC LIMIT ?`,
			runningRuns: `SELECT * FROM ` + p + `runs WHERE status = 'running' ORDER BY started_at, seq`,
			getState:    `SELECT state FROM ` + p + `state WHERE job = ?`,
			setState:    `INSERT INTO ` + p + `state (job, state) VALUES (?, ?) ON DUPLICATE KEY UPDATE state = VALUES(state)`,
			// CompareAndSetState from version 0, in two steps that each decide
			// alone: a row at version 0 (or without one) is updated, and
			// failing that the row is inserted, which a row already there
			// refuses. Neither leans on how the connection counts affected rows.
			casFromZero: `UPDATE ` + p + `state SET state = ? WHERE job = ? AND ` + version("state") + ` = 0`,
			casInsert:   `INSERT INTO ` + p + `state (job, state) VALUES (?, ?)`,
			casUpdate:   `UPDATE ` + p + `state SET state = ? WHERE job = ? AND ` + version("state") + ` = ?`,
			// MySQL refuses a subquery on the table a DELETE deletes from, so
			// the newest start per job is a derived table joined in (grouped,
			// so it is materialized rather than merged).
			prune: `DELETE r FROM ` + p + `runs r
      JOIN (SELECT job, MAX(started_at) AS newest FROM ` + p + `runs GROUP BY job) n ON n.job = r.job
      WHERE r.status <> 'running' AND r.started_at < ? AND r.started_at < n.newest`,
		}
	}
	pg := d == Postgres
	// Insertion order, to break ties between runs that started in the same millisecond.
	seq := "rowid"
	// Byte order on both, so names sort the same whatever the database's collation.
	byName := "name"
	// The version inside a state's JSON, as the SDK's stateVersion() reads
	// it: a whole number from 0 to 2^53 - 1, else 0 (none, or a foreign
	// row's 1.5 or "x", which must neither fail the statement nor refuse
	// every write for good; on SQLite, also text that is not JSON, before
	// json_type could fail on it). Each CASE tests the JSON type before any
	// cast.
	version := func(column string) string {
		v := "json_extract(" + column + ", '$.version')"
		return "CASE WHEN NOT json_valid(" + column + ") THEN 0 WHEN json_type(" + column + ", '$.version') NOT IN ('integer', 'real') THEN 0 WHEN " +
			v + " = CAST(" + v + " AS INTEGER) AND " + v + " BETWEEN 0 AND 9007199254740991 THEN CAST(" + v + " AS INTEGER) ELSE 0 END"
	}
	if pg {
		seq, byName = "seq", `name COLLATE "C"`
		version = func(column string) string {
			v := "(" + column + "->>'version')::numeric"
			return "CASE WHEN jsonb_typeof(" + column + "->'version') <> 'number' THEN 0 WHEN " +
				v + " % 1 = 0 AND " + v + " BETWEEN 0 AND 9007199254740991 THEN " + v + "::bigint ELSE 0 END"
		}
	}
	s := statements{
		upsertJob: `INSERT INTO ` + p + `jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
      ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at`,
		getJob:      `SELECT * FROM ` + p + `jobs WHERE name = ?`,
		listJobs:    `SELECT * FROM ` + p + `jobs ORDER BY ` + byName,
		deleteRuns:  `DELETE FROM ` + p + `runs WHERE job = ?`,
		deleteState: `DELETE FROM ` + p + `state WHERE job = ?`,
		deleteJob:   `DELETE FROM ` + p + `jobs WHERE name = ?`,
		insertRun: `INSERT INTO ` + p + `runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		updateRun:   `UPDATE ` + p + `runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?`,
		getRun:      `SELECT * FROM ` + p + `runs WHERE id = ?`,
		listRuns:    `SELECT * FROM ` + p + `runs WHERE job = ? ORDER BY started_at DESC, ` + seq + ` DESC LIMIT ?`,
		runningRuns: `SELECT * FROM ` + p + `runs WHERE status = 'running' ORDER BY started_at, ` + seq,
		getState:    `SELECT state FROM ` + p + `state WHERE job = ?`,
		setState:    `INSERT INTO ` + p + `state (job, state) VALUES (?, ?) ON CONFLICT (job) DO UPDATE SET state = excluded.state`,
		// compareAndSetState. Expecting version 0 also matches a missing row,
		// so that case inserts; any other version must find its row.
		casInsert: `INSERT INTO ` + p + `state (job, state) VALUES (?, ?)
      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE ` + version(p+"state.state") + ` = 0`,
		casUpdate: `UPDATE ` + p + `state SET state = ? WHERE job = ? AND ` + version("state") + ` = ?`,
		// Each job's newest run is kept whatever its age: without it, a job
		// that runs less often than the retention looks like it never ran.
		prune: `DELETE FROM ` + p + `runs WHERE status <> 'running' AND started_at < ?
      AND started_at < (SELECT MAX(r.started_at) FROM ` + p + `runs r WHERE r.job = ` + p + `runs.job)`,
	}
	if pg {
		for _, q := range []*string{&s.upsertJob, &s.getJob, &s.listJobs, &s.deleteRuns, &s.deleteState, &s.deleteJob, &s.insertRun,
			&s.updateRun, &s.getRun, &s.listRuns, &s.runningRuns, &s.getState, &s.setState, &s.casInsert, &s.casUpdate, &s.prune} {
			*q = number(*q)
		}
	}
	return s
}

// number writes ? placeholders as $1, $2, ..., as sql.ts does for Postgres.
func number(text string) string {
	var b strings.Builder
	n := 0
	for _, r := range text {
		if r == '?' {
			n++
			b.WriteString("$" + strconv.Itoa(n))
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// updateRunIfSQL is the update, only while the stored status is one of
// count statuses. Built per count, since the list is bound value by value.
func updateRunIfSQL(d Dialect, p string, count int) string {
	marks := make([]string, count)
	for i := range marks {
		marks[i] = "?"
	}
	text := `UPDATE ` + p + `runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ? AND status IN (` + strings.Join(marks, ", ") + `)`
	if d == Postgres {
		return number(text)
	}
	return text
}

// deleteRunIfSQL takes back a run only while it is of one job and in one
// status (the PHP port's deleteRunIf), the same text on every dialect.
func deleteRunIfSQL(d Dialect, p string) string {
	text := `DELETE FROM ` + p + `runs WHERE id = ? AND job = ? AND status = ?`
	if d == Postgres {
		return number(text)
	}
	return text
}
