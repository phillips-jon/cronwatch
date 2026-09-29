//! The schema, statements and parameters: stores/sql.ts's text for text, so
//! a Node, Ruby, Python, PHP, Go and Rust process can share one database and
//! `sqlite_master` reads the same whoever made the tables. Only SQLite is
//! built so far; Postgres (`$n` placeholders, `BIGINT`, `JSONB`, `seq
//! BIGSERIAL`, names sorted `COLLATE "C"`) and MySQL (the PHP and Go ports'
//! dialect) are the variants still to come, and every text here is written
//! from the dialect so each is a case of its own.

#![cfg_attr(not(feature = "sqlite"), allow(dead_code))]

use std::sync::Arc;

/// The database's SQL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum Dialect {
    /// SQLite, as the SDK's `sqlite()` store writes it.
    Sqlite,
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
            "cronwatch: invalid table prefix {}. Use lowercase letters, digits and underscores, not starting with a digit, at most {MAX_PREFIX} characters.",
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

/// The queries by name, with `?` placeholders.
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
    pub prune: Arc<str>,
    pub delete_run_if: Arc<str>,
    prefix: String,
}

impl Statements {
    pub(crate) fn new(dialect: Dialect, p: &str) -> Statements {
        // Insertion order, to break ties between runs that started in the
        // same millisecond, and the version inside a state's JSON, 0 when it
        // has none.
        let (seq, by_name) = match dialect {
            Dialect::Sqlite => ("rowid", "name"),
        };
        let version = |column: &str| match dialect {
            Dialect::Sqlite => format!("COALESCE(json_extract({column}, '$.version'), 0)"),
        };
        let s = |text: String| -> Arc<str> { Arc::from(text) };
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
            prefix: p.to_string(),
        }
    }

    /// The update, only while the stored status is one of `count` statuses.
    /// Built per count, since the list is bound value by value.
    pub(crate) fn update_run_if(&self, count: usize) -> String {
        let marks = vec!["?"; count].join(", ");
        format!(
            "UPDATE {}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ? AND status IN ({marks})",
            self.prefix
        )
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
            "cronwatch: invalid table prefix \"Monitoring_\". Use lowercase letters, digits and underscores, not starting with a digit, at most 47 characters."
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
}
