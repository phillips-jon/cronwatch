//! The schema, statements, and parameters. SQLite's and Postgres's are
//! stores/sql.ts's text for text, so a Node, Ruby, Python, PHP, Go, and Rust
//! process can share one database and `sqlite_master` reads the same whoever
//! made the tables. MySQL (and MariaDB) has a dialect of its own, the PHP and
//! Go ports' (`packages/go/sqlstore/sql.go`), since it has no `ON CONFLICT`,
//! no partial index and no `TEXT` primary key: the same tables, columns, and
//! values, with the JSON columns as text holding the SDK's JSON byte for
//! byte, never MySQL's `JSON` type, which would rewrite it.

#![cfg_attr(not(any(feature = "sqlite", feature = "postgres", feature = "mysql")), allow(dead_code))]

use std::sync::Arc;

/// The database's SQL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum Dialect {
    /// SQLite, as the SDK's `sqlite()` store writes it.
    Sqlite,
    /// Postgres, as the SDK's `postgres()` store writes it.
    Postgres,
    /// MySQL 8.0.13 or newer, or MariaDB 10.6 or newer, as the PHP and Go
    /// ports write it.
    Mysql,
}

/// Starts every table name unless `SqlStore::prefix` says otherwise.
pub const DEFAULT_PREFIX: &str = "cronwatch_";

/// Postgres truncates identifiers past 63 bytes; the longest name built is
/// the prefix plus `runs_job_started`. The SDK holds every dialect to it.
const MAX_PREFIX: usize = 63 - "runs_job_started".len();

/// Checks a prefix. Table names are built from it, so it must be a plain
/// lowercase identifier. Uppercase is refused rather than folded: Postgres
/// lowercases unquoted names, so `Monitoring_` would quietly become
/// `monitoring_`. The message is the SDK's, word for word.
pub(crate) fn table_prefix(prefix: &str) -> Result<String, String> {
    let b = prefix.as_bytes();
    let ok = !b.is_empty()
        && (b[0].is_ascii_lowercase() || b[0] == b'_')
        && b.iter().all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
        && b.len() <= MAX_PREFIX;
    if !ok {
        return Err(format!(
            "cronwatch: invalid table prefix {}. Use lowercase letters, digits, and underscores, not starting with a digit, at most {MAX_PREFIX} characters.",
            quote(prefix)
        ));
    }
    Ok(prefix.to_string())
}

/// `JSON.stringify` of a string, for the SDK's messages.
fn quote(s: &str) -> String {
    cronwatch::js::Value::from(s).to_json()
}

/// The tables, one statement each, run in turn.
pub(crate) fn schema(dialect: Dialect, p: &str) -> Vec<String> {
    let (integer, json, seq) = match dialect {
        Dialect::Sqlite => ("INTEGER", "TEXT", ""),
        Dialect::Postgres => ("BIGINT", "JSONB", "\n      seq BIGSERIAL,"),
        Dialect::Mysql => return mysql_schema(p),
    };
    // sql.ts's template, whitespace and all, cut into its statements.
    let text = format!(
        "
    CREATE TABLE IF NOT EXISTS {p}jobs (
      name TEXT PRIMARY KEY,
      definition {json} NOT NULL,
      created_at {integer} NOT NULL,
      updated_at {integer} NOT NULL
    );
    CREATE TABLE IF NOT EXISTS {p}runs ({seq}
      id TEXT PRIMARY KEY,
      job TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at {integer} NOT NULL,
      finished_at {integer},
      duration_ms {integer},
      error TEXT,
      output TEXT,
      metrics {json} NOT NULL DEFAULT '{{}}',
      trigger TEXT NOT NULL DEFAULT 'run'
    );
    CREATE INDEX IF NOT EXISTS {p}runs_job_started ON {p}runs (job, started_at DESC);
    CREATE INDEX IF NOT EXISTS {p}runs_running ON {p}runs (status) WHERE status = 'running';
    CREATE TABLE IF NOT EXISTS {p}state (
      job TEXT PRIMARY KEY,
      state {json} NOT NULL
    );
  "
    );
    text.split(';').filter(|s| !s.trim().is_empty()).map(str::to_string).collect()
}

/// MySQL's tables (the PHP and Go ports'): `VARCHAR(255)` keys, `BIGINT`
/// times, `LONGTEXT` JSON, `utf8mb4_bin` so names compare and sort by byte,
/// `seq` for insertion order, and a plain index where the others have a
/// partial one.
fn mysql_schema(p: &str) -> Vec<String> {
    let table = "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin";
    vec![
        format!(
            "CREATE TABLE IF NOT EXISTS {p}jobs (
      name VARCHAR(255) NOT NULL,
      definition LONGTEXT NOT NULL,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      PRIMARY KEY (name)
    ) {table}"
        ),
        format!(
            "CREATE TABLE IF NOT EXISTS {p}runs (
      seq BIGINT NOT NULL AUTO_INCREMENT,
      id VARCHAR(255) NOT NULL,
      job VARCHAR(255) NOT NULL,
      status VARCHAR(255) NOT NULL,
      started_at BIGINT NOT NULL,
      finished_at BIGINT,
      duration_ms BIGINT,
      error MEDIUMTEXT,
      output MEDIUMTEXT,
      metrics LONGTEXT NOT NULL DEFAULT ('{{}}'),
      `trigger` VARCHAR(255) NOT NULL DEFAULT 'run',
      PRIMARY KEY (id),
      UNIQUE KEY {p}runs_seq (seq),
      KEY {p}runs_job_started (job, started_at DESC),
      KEY {p}runs_running (status)
    ) {table}"
        ),
        format!(
            "CREATE TABLE IF NOT EXISTS {p}state (
      job VARCHAR(255) NOT NULL,
      state LONGTEXT NOT NULL,
      PRIMARY KEY (job)
    ) {table}"
        ),
    ]
}

/// Writes `?` placeholders as `$1`, `$2`, ..., as sql.ts does for Postgres.
fn number(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    let mut n = 0;
    for c in text.chars() {
        if c == '?' {
            n += 1;
            out.push('$');
            out.push_str(&n.to_string());
        } else {
            out.push(c);
        }
    }
    out
}

/// The queries by name, with `?` placeholders (numbered `$1`, `$2` ... for
/// Postgres, as sql.ts numbers them).
#[derive(Clone, Debug)]
pub(crate) struct Statements {
    pub upsert_job: Arc<str>,
    pub get_job: Arc<str>,
    pub list_jobs: Arc<str>,
    pub delete_runs: Arc<str>,
    pub delete_state: Arc<str>,
    pub delete_job: Arc<str>,
    pub insert_run: Arc<str>,
    pub update_run: Arc<str>,
    pub get_run: Arc<str>,
    pub list_runs: Arc<str>,
    pub running_runs: Arc<str>,
    pub get_state: Arc<str>,
    pub set_state: Arc<str>,
    pub cas_insert: Arc<str>,
    pub cas_update: Arc<str>,
    /// MySQL's first step of a compare-and-set from version 0; the others do
    /// it in one statement, `cas_insert`.
    pub cas_from_zero: Arc<str>,
    pub prune: Arc<str>,
    pub delete_run_if: Arc<str>,
    dialect: Dialect,
    prefix: String,
}

impl Statements {
    pub(crate) fn new(dialect: Dialect, p: &str) -> Statements {
        if dialect == Dialect::Mysql {
            return Statements::mysql(p);
        }
        let pg = dialect == Dialect::Postgres;
        // Insertion order, to break ties between runs that started in the
        // same millisecond, and byte order for names on both, whatever the
        // database's collation.
        let (seq, by_name) = if pg { ("seq", "name COLLATE \"C\"") } else { ("rowid", "name") };
        // The version inside a state's JSON, as cronwatch's state_version
        // reads it: a whole number from 0 to 2^53 - 1, else 0 (none, or a
        // foreign row's 1.5 or "x", which must neither fail the statement
        // nor refuse every write for good; on SQLite, also text that is not
        // JSON, before json_type could fail on it). Each CASE tests the JSON
        // type before any cast. The SDK's text, byte for byte.
        let version = |column: &str| {
            if pg {
                let v = format!("({column}->>'version')::numeric");
                format!(
                    "CASE WHEN jsonb_typeof({column}->'version') <> 'number' THEN 0 WHEN {v} % 1 = 0 AND {v} BETWEEN 0 AND 9007199254740991 THEN {v}::bigint ELSE 0 END"
                )
            } else {
                let v = format!("json_extract({column}, '$.version')");
                format!(
                    "CASE WHEN NOT json_valid({column}) THEN 0 WHEN json_type({column}, '$.version') NOT IN ('integer', 'real') THEN 0 WHEN {v} = CAST({v} AS INTEGER) AND {v} BETWEEN 0 AND 9007199254740991 THEN CAST({v} AS INTEGER) ELSE 0 END"
                )
            }
        };
        let s = |text: String| -> Arc<str> { Arc::from(if pg { number(&text) } else { text }) };
        Statements {
            upsert_job: s(format!(
                "INSERT INTO {p}jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
      ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at"
            )),
            get_job: s(format!("SELECT * FROM {p}jobs WHERE name = ?")),
            list_jobs: s(format!("SELECT * FROM {p}jobs ORDER BY {by_name}")),
            delete_runs: s(format!("DELETE FROM {p}runs WHERE job = ?")),
            delete_state: s(format!("DELETE FROM {p}state WHERE job = ?")),
            delete_job: s(format!("DELETE FROM {p}jobs WHERE name = ?")),
            insert_run: s(format!(
                "INSERT INTO {p}runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            )),
            update_run: s(format!(
                "UPDATE {p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?"
            )),
            get_run: s(format!("SELECT * FROM {p}runs WHERE id = ?")),
            list_runs: s(format!("SELECT * FROM {p}runs WHERE job = ? ORDER BY started_at DESC, {seq} DESC LIMIT ?")),
            running_runs: s(format!("SELECT * FROM {p}runs WHERE status = 'running' ORDER BY started_at, {seq}")),
            get_state: s(format!("SELECT state FROM {p}state WHERE job = ?")),
            set_state: s(format!(
                "INSERT INTO {p}state (job, state) VALUES (?, ?) ON CONFLICT (job) DO UPDATE SET state = excluded.state"
            )),
            // compareAndSetState. Expecting version 0 also matches a missing
            // row, so that case inserts; any other version must find its row.
            cas_insert: s(format!(
                "INSERT INTO {p}state (job, state) VALUES (?, ?)
      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE {} = 0",
                version(&format!("{p}state.state"))
            )),
            cas_update: s(format!("UPDATE {p}state SET state = ? WHERE job = ? AND {} = ?", version("state"))),
            cas_from_zero: Arc::from(""),
            // Each job's newest run is kept whatever its age: without it, a
            // job that runs less often than the retention looks like it never
            // ran.
            prune: s(format!(
                "DELETE FROM {p}runs WHERE status <> 'running' AND started_at < ?
      AND started_at < (SELECT MAX(r.started_at) FROM {p}runs r WHERE r.job = {p}runs.job)"
            )),
            // Takes back a run only while it is of one job and in one status
            // (the PHP and Go ports' deleteRunIf).
            delete_run_if: s(format!("DELETE FROM {p}runs WHERE id = ? AND job = ? AND status = ?")),
            dialect,
            prefix: p.to_string(),
        }
    }

    /// MySQL's statements, the PHP and Go ports' text.
    fn mysql(p: &str) -> Statements {
        // The version inside a state's JSON text, as cronwatch's state_version
        // reads it: a whole number from 0 to 2^53 - 1, else 0. JSON_TYPE is
        // tested before any arithmetic; MySQL's JSON_EXTRACT answers JSON and
        // MariaDB's text, and `+ 0` makes either a number. The column is
        // text, which may hold text that is not JSON at all (a damaged row's):
        // that counts as 0, tested before JSON_EXTRACT, which fails on it.
        let version = |column: &str| {
            let v = format!("JSON_EXTRACT({column}, '$.version')");
            format!(
                "CASE WHEN NOT JSON_VALID({column}) THEN 0 WHEN JSON_TYPE({v}) NOT IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 WHEN {v} + 0 = FLOOR({v} + 0) AND {v} + 0 BETWEEN 0 AND 9007199254740991 THEN CAST({v} + 0 AS SIGNED) ELSE 0 END"
            )
        };
        let s = |text: String| -> Arc<str> { Arc::from(text) };
        Statements {
            upsert_job: s(format!(
                "INSERT INTO {p}jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE definition = VALUES(definition), updated_at = VALUES(updated_at)"
            )),
            get_job: s(format!("SELECT * FROM {p}jobs WHERE name = ?")),
            list_jobs: s(format!("SELECT * FROM {p}jobs ORDER BY name")),
            delete_runs: s(format!("DELETE FROM {p}runs WHERE job = ?")),
            delete_state: s(format!("DELETE FROM {p}state WHERE job = ?")),
            delete_job: s(format!("DELETE FROM {p}jobs WHERE name = ?")),
            insert_run: s(format!(
                "INSERT INTO {p}runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, `trigger`)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            )),
            update_run: s(format!(
                "UPDATE {p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?"
            )),
            get_run: s(format!("SELECT * FROM {p}runs WHERE id = ?")),
            list_runs: s(format!("SELECT * FROM {p}runs WHERE job = ? ORDER BY started_at DESC, seq DESC LIMIT ?")),
            running_runs: s(format!("SELECT * FROM {p}runs WHERE status = 'running' ORDER BY started_at, seq")),
            get_state: s(format!("SELECT state FROM {p}state WHERE job = ?")),
            set_state: s(format!(
                "INSERT INTO {p}state (job, state) VALUES (?, ?) ON DUPLICATE KEY UPDATE state = VALUES(state)"
            )),
            // compareAndSetState from version 0, in two steps that each
            // decide alone: a row at version 0 (or without one) is updated,
            // and failing that the row is inserted, which a row already there
            // refuses. Neither leans on how the connection counts affected
            // rows.
            cas_from_zero: s(format!("UPDATE {p}state SET state = ? WHERE job = ? AND {} = 0", version("state"))),
            cas_insert: s(format!("INSERT INTO {p}state (job, state) VALUES (?, ?)")),
            cas_update: s(format!("UPDATE {p}state SET state = ? WHERE job = ? AND {} = ?", version("state"))),
            // MySQL refuses a subquery on the table a DELETE deletes from, so
            // the newest start per job is a derived table joined in (grouped,
            // so it is materialized rather than merged).
            prune: s(format!(
                "DELETE r FROM {p}runs r
      JOIN (SELECT job, MAX(started_at) AS newest FROM {p}runs GROUP BY job) n ON n.job = r.job
      WHERE r.status <> 'running' AND r.started_at < ? AND r.started_at < n.newest"
            )),
            delete_run_if: s(format!("DELETE FROM {p}runs WHERE id = ? AND job = ? AND status = ?")),
            dialect: Dialect::Mysql,
            prefix: p.to_string(),
        }
    }

    /// The update, only while the stored status is one of `count` statuses.
    /// Built per count, since the list is bound value by value.
    pub(crate) fn update_run_if(&self, count: usize) -> String {
        let marks = vec!["?"; count].join(", ");
        let text = format!(
            "UPDATE {}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ? AND status IN ({marks})",
            self.prefix
        );
        if self.dialect == Dialect::Postgres { number(&text) } else { text }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefixes_follow_the_sdks_rule() {
        assert_eq!(table_prefix("cw_"), Ok("cw_".into()));
        assert_eq!(table_prefix("_x9"), Ok("_x9".into()));
        assert_eq!(
            table_prefix("Monitoring_").unwrap_err(),
            "cronwatch: invalid table prefix \"Monitoring_\". Use lowercase letters, digits, and underscores, not starting with a digit, at most 47 characters."
        );
        assert!(table_prefix("9x").is_err());
        assert!(table_prefix("").is_err());
        assert!(table_prefix(&"a".repeat(48)).is_err());
        assert!(table_prefix(&"a".repeat(47)).is_ok());
    }

    #[test]
    fn the_schema_is_five_statements() {
        let s = schema(Dialect::Sqlite, "cw_");
        assert_eq!(s.len(), 5);
        assert!(s[1].contains("metrics TEXT NOT NULL DEFAULT '{}'"));
    }

    #[test]
    fn postgres_is_sql_ts_text_for_text() {
        let s = schema(Dialect::Postgres, "cw_");
        assert_eq!(s.len(), 5);
        assert!(s[1].starts_with(
            "\n    CREATE TABLE IF NOT EXISTS cw_runs (\n      seq BIGSERIAL,\n      id TEXT PRIMARY KEY,"
        ));
        assert!(s[1].contains("started_at BIGINT NOT NULL") && s[1].contains("metrics JSONB NOT NULL DEFAULT '{}'"));
        let q = Statements::new(Dialect::Postgres, "cw_");
        assert_eq!(&*q.list_jobs, "SELECT * FROM cw_jobs ORDER BY name COLLATE \"C\"");
        assert_eq!(
            &*q.cas_update,
            "UPDATE cw_state SET state = $1 WHERE job = $2 AND CASE WHEN jsonb_typeof(state->'version') <> 'number' THEN 0 WHEN (state->>'version')::numeric % 1 = 0 AND (state->>'version')::numeric BETWEEN 0 AND 9007199254740991 THEN (state->>'version')::numeric::bigint ELSE 0 END = $3"
        );
        assert_eq!(
            &*q.cas_insert,
            "INSERT INTO cw_state (job, state) VALUES ($1, $2)\n      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE CASE WHEN jsonb_typeof(cw_state.state->'version') <> 'number' THEN 0 WHEN (cw_state.state->>'version')::numeric % 1 = 0 AND (cw_state.state->>'version')::numeric BETWEEN 0 AND 9007199254740991 THEN (cw_state.state->>'version')::numeric::bigint ELSE 0 END = 0"
        );
        let q = Statements::new(Dialect::Sqlite, "cw_");
        assert_eq!(
            &*q.cas_update,
            "UPDATE cw_state SET state = ? WHERE job = ? AND CASE WHEN NOT json_valid(state) THEN 0 WHEN json_type(state, '$.version') NOT IN ('integer', 'real') THEN 0 WHEN json_extract(state, '$.version') = CAST(json_extract(state, '$.version') AS INTEGER) AND json_extract(state, '$.version') BETWEEN 0 AND 9007199254740991 THEN CAST(json_extract(state, '$.version') AS INTEGER) ELSE 0 END = ?"
        );
        let q = Statements::new(Dialect::Postgres, "cw_");
        assert_eq!(&*q.list_runs, "SELECT * FROM cw_runs WHERE job = $1 ORDER BY started_at DESC, seq DESC LIMIT $2");
        assert!(q.update_run_if(2).ends_with("WHERE id = $7 AND status IN ($8, $9)"));
    }

    #[test]
    fn mysql_is_the_php_and_go_ports_dialect() {
        let s = schema(Dialect::Mysql, "cw_");
        assert_eq!(s.len(), 3);
        assert!(s[1].contains(
            "metrics LONGTEXT NOT NULL DEFAULT ('{}'),\n      `trigger` VARCHAR(255) NOT NULL DEFAULT 'run',"
        ));
        assert!(s[2].ends_with(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"));
        let q = Statements::new(Dialect::Mysql, "cw_");
        assert!(q.insert_run.contains("metrics, `trigger`)"));
        assert_eq!(
            &*q.cas_from_zero,
            "UPDATE cw_state SET state = ? WHERE job = ? AND CASE WHEN NOT JSON_VALID(state) THEN 0 WHEN JSON_TYPE(JSON_EXTRACT(state, '$.version')) NOT IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 WHEN JSON_EXTRACT(state, '$.version') + 0 = FLOOR(JSON_EXTRACT(state, '$.version') + 0) AND JSON_EXTRACT(state, '$.version') + 0 BETWEEN 0 AND 9007199254740991 THEN CAST(JSON_EXTRACT(state, '$.version') + 0 AS SIGNED) ELSE 0 END = 0"
        );
        assert!(q.update_run_if(1).ends_with("status IN (?)"));
    }
}
