//! The store over sqlx.

use std::fmt;

use cronwatch::js::{self, Value};
use cronwatch::{BoxError, BoxFuture, Definition, JobState, Metrics, Run, RunStatus, Store, StoredJob};
use sqlx::AssertSqlSafe;
#[cfg(feature = "mysql")]
use sqlx::MySqlPool;
#[cfg(feature = "postgres")]
use sqlx::PgPool;
#[cfg(feature = "sqlite")]
use sqlx::SqlitePool;

use crate::rows::{Param, Row};
use crate::sql::{DEFAULT_PREFIX, Dialect, Statements, schema, table_prefix};

/// The database a store writes to, with what it holds of it.
enum Backend {
    #[cfg(feature = "sqlite")]
    Sqlite(crate::sqlite::Conn),
    #[cfg(feature = "postgres")]
    Postgres(PgPool),
    #[cfg(feature = "mysql")]
    Mysql(MySqlPool),
}

/// Keeps CronWatch's jobs, runs and state in the app's own database through
/// sqlx, with the app's pool: the SDK's tables (stores/sql.ts), the same
/// names, columns and statements, and the SDK's JSON in the JSON columns byte
/// for byte, so a Rust process shares a database with a Node, Ruby, Python,
/// PHP or Go one.
///
/// On SQLite it holds one connection of the pool for its statements, in
/// turn, as the SDK's store and the Go port's do: an in-memory database is
/// one per connection, a pool's connections would each need the pragmas, and
/// SQLite allows one writer at a time anyway. That connection is put in WAL
/// mode (with the SDK's retry of a busy database while switching), with
/// `busy_timeout` 5000 and `synchronous` NORMAL. So a pool limited to one
/// connection leaves the app none: give it room for the store too.
///
/// On Postgres and MySQL it uses the pool, each statement on its own
/// (autocommit), so its writes never join a transaction the app has open;
/// `delete_job` is one transaction of the store's own. A pool with one
/// connection waits on an app's open transaction, so give it room there too.
pub struct SqlStore {
    dialect: Dialect,
    prefix: String,
    sql: Statements,
    backend: Backend,
}

impl fmt::Debug for SqlStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SqlStore").field("dialect", &self.dialect).field("prefix", &self.prefix).finish()
    }
}

impl SqlStore {
    fn new(dialect: Dialect, backend: Backend) -> SqlStore {
        SqlStore { dialect, prefix: DEFAULT_PREFIX.into(), sql: Statements::new(dialect, DEFAULT_PREFIX), backend }
    }

    /// A store over the app's SQLite pool, with the tables named
    /// `cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`. Nothing is
    /// read or written until the client's first use calls `init`.
    #[cfg(feature = "sqlite")]
    pub fn sqlite(pool: SqlitePool) -> SqlStore {
        SqlStore::new(Dialect::Sqlite, Backend::Sqlite(crate::sqlite::Conn::new(pool)))
    }

    /// A store over the app's Postgres pool, with the SDK's tables and
    /// statements (`JSONB` for the JSON, `BIGINT` times, names sorted
    /// `COLLATE "C"`). Many processes can start at once: `init` makes the
    /// tables under an advisory lock per prefix. Nothing is read or written
    /// until the client's first use calls `init`.
    #[cfg(feature = "postgres")]
    pub fn postgres(pool: PgPool) -> SqlStore {
        SqlStore::new(Dialect::Postgres, Backend::Postgres(pool))
    }

    /// A store over the app's MySQL pool, for MySQL 8.0.13 or newer or
    /// MariaDB 10.6 or newer, in the PHP and Go ports' dialect: the JSON
    /// columns are `LONGTEXT` holding the SDK's bytes (never MySQL's `JSON`
    /// type, which rewrites them), names compare by byte (`utf8mb4_bin`), and
    /// a run's trigger is cut to 255 characters. MySQL commits `CREATE TABLE`
    /// at once, which is why the tables are made on their own, at the
    /// client's first use.
    #[cfg(feature = "mysql")]
    pub fn mysql(pool: MySqlPool) -> SqlStore {
        SqlStore::new(Dialect::Mysql, Backend::Mysql(pool))
    }

    /// Starts every table name with `prefix`: lowercase letters, digits and
    /// underscores, not starting with a digit. Default `cronwatch_`. Anything
    /// else is refused with the SDK's message.
    pub fn prefix(mut self, prefix: &str) -> Result<SqlStore, cronwatch::Error> {
        let p = table_prefix(prefix).map_err(cronwatch::Error::Invalid)?;
        self.sql = Statements::new(self.dialect, &p);
        self.prefix = p;
        Ok(self)
    }

    /// The store's dialect.
    pub fn dialect(&self) -> Dialect {
        self.dialect
    }

    /// The prefix of the store's tables.
    pub fn table_prefix(&self) -> &str {
        &self.prefix
    }

    /// Runs a statement, answering how many rows it changed (or matched, on
    /// MySQL, whose connections sqlx opens asking for found rows).
    async fn run(&self, text: &str, params: Vec<Param>) -> Result<u64, BoxError> {
        let text = AssertSqlSafe(text.to_string());
        match &self.backend {
            #[cfg(feature = "sqlite")]
            Backend::Sqlite(conn) => conn.run(text, params).await,
            #[cfg(feature = "postgres")]
            Backend::Postgres(pool) => {
                let args = crate::rows::pg_arguments(params)?;
                Ok(sqlx::query_with(text, args).execute(pool).await?.rows_affected())
            }
            #[cfg(feature = "mysql")]
            Backend::Mysql(pool) => {
                let args = crate::rows::mysql_arguments(params)?;
                Ok(sqlx::query_with(text, args).execute(pool).await?.rows_affected())
            }
        }
    }

    /// Runs a query, answering its rows.
    async fn query(&self, text: &str, params: Vec<Param>) -> Result<Vec<Row>, BoxError> {
        let text = AssertSqlSafe(text.to_string());
        match &self.backend {
            #[cfg(feature = "sqlite")]
            Backend::Sqlite(conn) => conn.query(text, params).await,
            #[cfg(feature = "postgres")]
            Backend::Postgres(pool) => {
                let args = crate::rows::pg_arguments(params)?;
                sqlx::query_with(text, args).fetch_all(pool).await?.iter().map(crate::rows::pg_row).collect()
            }
            #[cfg(feature = "mysql")]
            Backend::Mysql(pool) => {
                let args = crate::rows::mysql_arguments(params)?;
                sqlx::query_with(text, args).fetch_all(pool).await?.iter().map(crate::rows::mysql_row).collect()
            }
        }
    }

    async fn runs(&self, text: &str, params: Vec<Param>) -> Result<Vec<Run>, BoxError> {
        self.query(text, params).await?.iter().map(run_of).collect()
    }

    /// Runs statements, each with `params`, in one transaction of the
    /// store's own; on Postgres, `lock` first takes an advisory lock for the
    /// transaction.
    async fn transaction(&self, statements: &[&str], params: &[Param], lock: Option<String>) -> Result<(), BoxError> {
        match &self.backend {
            #[cfg(feature = "sqlite")]
            Backend::Sqlite(conn) => {
                let _ = lock;
                conn.transaction(statements, params).await
            }
            #[cfg(feature = "postgres")]
            Backend::Postgres(pool) => {
                let mut tx = pool.begin().await?;
                if let Some(key) = lock {
                    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))").bind(key).execute(&mut *tx).await?;
                }
                for statement in statements {
                    let args = crate::rows::pg_arguments(params.to_vec())?;
                    sqlx::query_with(AssertSqlSafe(statement.to_string()), args).execute(&mut *tx).await?;
                }
                Ok(tx.commit().await?)
            }
            #[cfg(feature = "mysql")]
            Backend::Mysql(pool) => {
                let _ = lock;
                let mut tx = pool.begin().await?;
                for statement in statements {
                    let args = crate::rows::mysql_arguments(params.to_vec())?;
                    sqlx::query_with(AssertSqlSafe(statement.to_string()), args).execute(&mut *tx).await?;
                }
                Ok(tx.commit().await?)
            }
        }
    }
}

fn job_of(row: &Row) -> Result<StoredJob, BoxError> {
    let name = row.text("name").unwrap_or_default();
    let text = row.text("definition").unwrap_or_default();
    // JSON of another shape (another writer's, or a hand edit) is a
    // definition with nothing in it, as the SDK reads it: one such row must
    // not fail every read of the jobs, and with it every check.
    let definition = match js::parse(&text) {
        Ok(Value::Object(o)) => Definition::from_object(o),
        Ok(_) => Definition::default(),
        Err(err) => return Err(format!("job {name}: {err}").into()),
    };
    let mut job = StoredJob::new(definition, row.int("created_at").unwrap_or(0), row.int("updated_at").unwrap_or(0));
    job.name = name;
    Ok(job)
}

fn run_of(row: &Row) -> Result<Run, BoxError> {
    let id = row.text("id").unwrap_or_default();
    let mut metrics = Metrics::new();
    if let Some(text) = row.text("metrics") {
        metrics = match Metrics::from_json(&text) {
            Ok(m) => m,
            // Metrics another writer stored that are not all numbers keep the
            // ones that are, so one such row (a running one especially, which
            // every check reads) cannot fail the reads it is part of.
            Err(err) => match js::parse(&text) {
                Ok(Value::Object(o)) => o.iter().filter_map(|(k, v)| v.as_f64().map(|n| (k.to_string(), n))).collect(),
                Ok(_) => Metrics::new(),
                Err(_) => return Err(format!("run {id}: {err}").into()),
            },
        };
    }
    let mut run = Run::new(
        id,
        row.text("job").unwrap_or_default(),
        RunStatus::parse(&row.text("status").unwrap_or_default()),
        row.int("started_at").unwrap_or(0),
    );
    run.finished_at = row.int("finished_at");
    run.duration_ms = row.int("duration_ms");
    run.error = row.text("error");
    run.output = row.text("output");
    run.metrics = metrics;
    run.trigger = row.text("trigger").unwrap_or_default();
    Ok(run)
}

// Parameters in statement order, so every dialect binds the same values.
// Postgres refuses U+0000 in TEXT and JSONB, and a refused write loses the
// whole row, so every dialect writes text without it (stores/sql.ts): a
// run's trigger, output, error and metric names (Run::without_nul), and
// every key and string of a definition and a state. Identifiers are written
// as given; the client refuses one with a NUL before it gets here.

fn insert_run_params(r: &Run) -> Vec<Param> {
    vec![
        Param::Text(r.id.clone()),
        Param::Text(r.job.clone()),
        Param::Text(r.status.as_str().into()),
        Param::Int(r.started_at),
        Param::OptInt(r.finished_at),
        Param::OptInt(r.duration_ms),
        Param::OptText(r.error.clone()),
        Param::OptText(r.output.clone()),
        Param::Json(r.metrics.to_json()),
        Param::Text(r.trigger.clone()),
    ]
}

fn update_run_params(r: &Run) -> Vec<Param> {
    vec![
        Param::Text(r.status.as_str().into()),
        Param::OptInt(r.finished_at),
        Param::OptInt(r.duration_ms),
        Param::OptText(r.error.clone()),
        Param::OptText(r.output.clone()),
        Param::Json(r.metrics.to_json()),
        Param::Text(r.id.clone()),
    ]
}

/// What an update of a run writes, compared whatever order a JSON column
/// gave an object's keys back in.
fn written(r: &Run) -> String {
    let metrics = js::parse(&r.metrics.to_json()).map(|v| canonical(&v)).unwrap_or_default();
    format!(
        "{:?}|{:?}|{:?}|{:?}|{:?}|{metrics}|{}",
        r.status.as_str(),
        r.finished_at,
        r.duration_ms,
        r.error,
        r.output,
        r.id
    )
}

/// JSON with every object's keys sorted.
fn canonical(v: &Value) -> String {
    match v {
        Value::Object(o) => {
            let mut keys: Vec<&str> = o.keys().collect();
            keys.sort_unstable();
            let parts: Vec<String> = keys
                .iter()
                .map(|k| format!("{}:{}", Value::from(*k).to_json(), canonical(o.get(k).expect("a key"))))
                .collect();
            format!("{{{}}}", parts.join(","))
        }
        Value::Array(a) => format!("[{}]", a.iter().map(canonical).collect::<Vec<_>>().join(",")),
        other => other.to_json(),
    }
}

impl Store for SqlStore {
    /// Makes the tables. On Postgres many processes starting at once would
    /// race `CREATE TABLE IF NOT EXISTS`, which Postgres can reject with a
    /// unique violation on `pg_type`, so they take turns under an advisory
    /// lock per prefix.
    fn init(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        Box::pin(async move {
            let statements = schema(self.dialect, &self.prefix);
            if self.dialect == Dialect::Postgres {
                let list: Vec<&str> = statements.iter().map(String::as_str).collect();
                return self.transaction(&list, &[], Some(format!("cronwatch:{}", self.prefix))).await;
            }
            for statement in statements {
                self.run(&statement, Vec::new()).await?;
            }
            Ok(())
        })
    }

    fn upsert_job<'a>(&'a self, definition: &'a Definition, now: i64) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let params = vec![
                Param::Text(definition.name().into()),
                Param::Json(definition.to_json_without_nul()),
                Param::Int(now),
                Param::Int(now),
            ];
            self.run(&self.sql.upsert_job, params).await.map(|_| ())
        })
    }

    fn get_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<Option<StoredJob>, BoxError>> {
        Box::pin(async move {
            let rows = self.query(&self.sql.get_job, vec![Param::Text(name.into())]).await?;
            rows.first().map(job_of).transpose()
        })
    }

    fn list_jobs(&self) -> BoxFuture<'_, Result<Vec<StoredJob>, BoxError>> {
        Box::pin(async move { self.query(&self.sql.list_jobs, Vec::new()).await?.iter().map(job_of).collect() })
    }

    /// Removes the job, its runs and its state in one transaction.
    fn delete_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let statements = [&*self.sql.delete_runs, &*self.sql.delete_state, &*self.sql.delete_job];
            self.transaction(&statements, &[Param::Text(name.into())], None).await
        })
    }

    fn insert_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let run = &run.without_nul();
            let mut params = insert_run_params(run);
            // MySQL's trigger column is VARCHAR(255), which refuses anything
            // longer (the others are TEXT): a long trigger is cut to fit
            // rather than lose the whole run.
            if self.dialect == Dialect::Mysql && run.trigger.chars().count() > 255 {
                params[9] = Param::Text(run.trigger.chars().take(255).collect());
            }
            self.run(&self.sql.insert_run, params).await.map(|_| ())
        })
    }

    fn update_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move { self.run(&self.sql.update_run, update_run_params(&run.without_nul())).await.map(|_| ()) })
    }

    fn update_run_if<'a>(&'a self, run: &'a Run, from: &'a [RunStatus]) -> BoxFuture<'a, Result<bool, BoxError>> {
        Box::pin(async move {
            if from.is_empty() {
                return Ok(false);
            }
            let run = &run.without_nul();
            let mut params = update_run_params(run);
            params.extend(from.iter().map(|s| Param::Text(s.as_str().into())));
            let n = self.run(&self.sql.update_run_if(from.len()), params).await?;
            if n > 0 || self.dialect != Dialect::Mysql {
                return Ok(n > 0);
            }
            // A MySQL connection that counts only the rows an UPDATE changed
            // answers 0 for a row that already held these values (and
            // matched): it was written all the same. sqlx asks for found
            // rows, so this is for a server or proxy that does not honour it.
            let Some(stored) = self.get_run(&run.id).await? else {
                return Ok(false);
            };
            Ok(from.contains(&stored.status) && written(&stored) == written(run))
        })
    }

    /// Deletes a run only while it is of `job` and in `status`, in one
    /// statement, and says whether it did. A DELETE counts the rows it
    /// matched on every dialect.
    fn delete_run_if<'a>(
        &'a self,
        id: &'a str,
        job: &'a str,
        status: &'a RunStatus,
    ) -> BoxFuture<'a, Result<bool, BoxError>> {
        Box::pin(async move {
            let params = vec![Param::Text(id.into()), Param::Text(job.into()), Param::Text(status.as_str().into())];
            Ok(self.run(&self.sql.delete_run_if, params).await? > 0)
        })
    }

    fn get_run<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
        Box::pin(
            async move { Ok(self.runs(&self.sql.get_run, vec![Param::Text(id.into())]).await?.into_iter().next()) },
        )
    }

    fn list_runs<'a>(&'a self, job: &'a str, limit: usize) -> BoxFuture<'a, Result<Vec<Run>, BoxError>> {
        Box::pin(async move {
            let limit = i64::try_from(limit).unwrap_or(i64::MAX);
            self.runs(&self.sql.list_runs, vec![Param::Text(job.into()), Param::Int(limit)]).await
        })
    }

    fn last_run<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
        Box::pin(async move {
            Ok(self.runs(&self.sql.list_runs, vec![Param::Text(job.into()), Param::Int(1)]).await?.into_iter().next())
        })
    }

    fn running_runs(&self) -> BoxFuture<'_, Result<Vec<Run>, BoxError>> {
        Box::pin(async move { self.runs(&self.sql.running_runs, Vec::new()).await })
    }

    fn get_state<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<JobState>, BoxError>> {
        Box::pin(async move {
            let rows = self.query(&self.sql.get_state, vec![Param::Text(job.into())]).await?;
            let Some(row) = rows.first() else {
                return Ok(None);
            };
            let text = row.text("state").unwrap_or_default();
            Ok(Some(JobState::from_json(&text)?))
        })
    }

    fn set_state<'a>(&'a self, state: &'a JobState) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let params = vec![Param::Text(state.job.clone()), Param::Json(state.to_json_without_nul())];
            self.run(&self.sql.set_state, params).await.map(|_| ())
        })
    }

    fn compare_and_set_state<'a>(
        &'a self,
        state: &'a JobState,
        expected: i64,
    ) -> BoxFuture<'a, Result<bool, BoxError>> {
        Box::pin(async move {
            let body = state.to_json_without_nul();
            let job = || Param::Text(state.job.clone());
            if expected != 0 {
                let params = vec![Param::Json(body), job(), Param::Int(expected)];
                return Ok(self.run(&self.sql.cas_update, params).await? > 0);
            }
            if self.dialect != Dialect::Mysql {
                return Ok(self.run(&self.sql.cas_insert, vec![job(), Param::Json(body)]).await? > 0);
            }
            // Version 0 on MySQL is a row at version 0 (or with none), or no
            // row at all.
            if self.run(&self.sql.cas_from_zero, vec![Param::Json(body.clone()), job()]).await? > 0 {
                return Ok(true);
            }
            match self.run(&self.sql.cas_insert, vec![job(), Param::Json(body.clone())]).await {
                Ok(_) => Ok(true),
                Err(err) => {
                    // A row is there: another process wrote first, unless it
                    // holds exactly what this write sent, when the write landed
                    // and only its answer was lost (a row at version 0 that
                    // already held these values, which a connection counting
                    // changed rows answers 0 for, or a connection dropped after
                    // the commit), as the PHP port's stateLanded() reads it.
                    // Counting that as refused would have the client work the
                    // change out again over its own write, and the alert the
                    // first attempt opened would never go out.
                    match self.get_state(&state.job).await {
                        Ok(Some(stored)) => Ok(stored.to_json() == body),
                        _ => Err(err),
                    }
                }
            }
        })
    }

    fn prune(&self, before: i64) -> BoxFuture<'_, Result<u64, BoxError>> {
        Box::pin(async move { self.run(&self.sql.prune, vec![Param::Int(before)]).await })
    }

    /// Gives SQLite's connection back to the pool. The pool is the app's, and
    /// stays open.
    fn close(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        Box::pin(async move {
            match &self.backend {
                #[cfg(feature = "sqlite")]
                Backend::Sqlite(conn) => conn.close().await,
                #[cfg(feature = "postgres")]
                Backend::Postgres(_) => {}
                #[cfg(feature = "mysql")]
                Backend::Mysql(_) => {}
            }
            Ok(())
        })
    }
}
