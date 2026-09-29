//! The store over sqlx.

use std::fmt;
use std::time::Duration;

use cronwatch::js::{self, Value};
use cronwatch::{BoxError, BoxFuture, Definition, JobState, Metrics, Run, RunStatus, Store, StoredJob};
use sqlx::pool::PoolConnection;
use sqlx::sqlite::{Sqlite, SqliteArguments, SqliteRow};
use sqlx::{AssertSqlSafe, Row, SqlitePool, TypeInfo, ValueRef};
use tokio::sync::{Mutex, MutexGuard};

use crate::sql::{DEFAULT_PREFIX, Dialect, Statements, schema, table_prefix};

/// How long opening SQLite keeps retrying a busy database before it gives up
/// (busy.ts).
const BUSY_RETRY: Duration = Duration::from_secs(2);

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
pub struct SqlStore {
    dialect: Dialect,
    prefix: String,
    sql: Statements,
    pool: SqlitePool,
    /// SQLite's one connection, in turn.
    conn: Mutex<Option<PoolConnection<Sqlite>>>,
}

impl fmt::Debug for SqlStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SqlStore").field("dialect", &self.dialect).field("prefix", &self.prefix).finish()
    }
}

impl SqlStore {
    /// A store over the app's SQLite pool, with the tables named
    /// `cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`. Nothing is
    /// read or written until the client's first use calls `init`.
    pub fn sqlite(pool: SqlitePool) -> SqlStore {
        SqlStore {
            dialect: Dialect::Sqlite,
            prefix: DEFAULT_PREFIX.into(),
            sql: Statements::new(Dialect::Sqlite, DEFAULT_PREFIX),
            pool,
            conn: Mutex::new(None),
        }
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

    /// SQLite's one connection, opened (and its pragmas set) on first use and
    /// held for the caller's statements. A failed open is tried afresh next
    /// time.
    async fn conn(&self) -> Result<MutexGuard<'_, Option<PoolConnection<Sqlite>>>, BoxError> {
        let mut guard = self.conn.lock().await;
        if guard.is_none() {
            let mut conn = self.pool.acquire().await?;
            // No busy handler until WAL is on: switching journal mode can
            // answer busy at once while another process is doing the same on
            // a new file, so that is retried. The connection is kept only once
            // every pragma has gone through.
            wal(&mut conn).await?;
            exec(&mut conn, "PRAGMA busy_timeout = 5000").await?;
            exec(&mut conn, "PRAGMA synchronous = NORMAL").await?;
            *guard = Some(conn);
        }
        Ok(guard)
    }

    /// Runs a statement, answering how many rows it changed.
    async fn run(&self, text: &str, params: Vec<Param>) -> Result<u64, BoxError> {
        let mut guard = self.conn().await?;
        let conn = guard.as_mut().expect("an open connection");
        let result = sqlx::query_with(AssertSqlSafe(text.to_string()), arguments(params)?).execute(&mut **conn).await;
        forget_if_broken(&mut guard, &result);
        Ok(result?.rows_affected())
    }

    /// Runs a query, answering its rows.
    async fn query(&self, text: &str, params: Vec<Param>) -> Result<Vec<SqliteRow>, BoxError> {
        let mut guard = self.conn().await?;
        let conn = guard.as_mut().expect("an open connection");
        let result = sqlx::query_with(AssertSqlSafe(text.to_string()), arguments(params)?).fetch_all(&mut **conn).await;
        forget_if_broken(&mut guard, &result);
        Ok(result?)
    }

    async fn runs(&self, text: &str, params: Vec<Param>) -> Result<Vec<Run>, BoxError> {
        self.query(text, params).await?.iter().map(run_of).collect()
    }
}

/// A connection that failed as a connection (not as a statement) is given
/// back, and the next statement opens another.
fn forget_if_broken<T>(guard: &mut Option<PoolConnection<Sqlite>>, result: &Result<T, sqlx::Error>) {
    if matches!(result, Err(sqlx::Error::Io(_) | sqlx::Error::PoolClosed | sqlx::Error::WorkerCrashed)) {
        *guard = None;
    }
}

/// Runs a statement whose rows, if any, are not wanted (`PRAGMA
/// journal_mode` answers one).
async fn exec(conn: &mut PoolConnection<Sqlite>, text: &'static str) -> Result<(), sqlx::Error> {
    sqlx::query(text).fetch_all(&mut **conn).await.map(|_| ())
}

fn is_busy(err: &sqlx::Error) -> bool {
    let text = err.to_string();
    let code = match err {
        sqlx::Error::Database(db) => db.code().map(|c| c.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    // SQLITE_BUSY is 5 and SQLITE_LOCKED 6, and their extended codes are
    // those plus a multiple of 256.
    let busy_code = code.parse::<i64>().is_ok_and(|c| c & 0xff == 5 || c & 0xff == 6);
    busy_code
        || text.contains("SQLITE_BUSY")
        || text.contains("SQLITE_LOCKED")
        || text.contains("database is locked")
        || text.contains("database table is locked")
}

/// Puts the connection in WAL mode, retrying while SQLite answers busy, with
/// a short growing pause, for up to `BUSY_RETRY` in all (busy.ts
/// `retryBusy`).
async fn wal(conn: &mut PoolConnection<Sqlite>) -> Result<(), sqlx::Error> {
    let mut waited = Duration::ZERO;
    let mut attempt = 0u32;
    loop {
        match exec(conn, "PRAGMA journal_mode = WAL").await {
            Err(err) if is_busy(&err) && waited < BUSY_RETRY => {
                let pause = Duration::from_millis(10u64 << attempt.min(10))
                    .min(Duration::from_millis(200))
                    .min(BUSY_RETRY - waited);
                tokio::time::sleep(pause).await;
                waited += pause;
                attempt += 1;
            }
            other => return other,
        }
    }
}

/// A statement's parameter, in the types a JavaScript driver binds: text,
/// integers and null.
#[derive(Clone, Debug)]
enum Param {
    Text(String),
    OptText(Option<String>),
    Int(i64),
    OptInt(Option<i64>),
}

fn arguments(params: Vec<Param>) -> Result<SqliteArguments, BoxError> {
    use sqlx::Arguments;
    let mut args = SqliteArguments::default();
    for p in params {
        match p {
            Param::Text(s) => args.add(s)?,
            Param::OptText(s) => args.add(s)?,
            Param::Int(n) => args.add(n)?,
            Param::OptInt(n) => args.add(n)?,
        }
    }
    Ok(args)
}

// Columns are read by name, whatever type another writer gave them.

fn column_text(row: &SqliteRow, name: &str) -> Result<Option<String>, BoxError> {
    let raw = row.try_get_raw(name)?;
    if raw.is_null() {
        return Ok(None);
    }
    let kind = raw.type_info().name().to_string();
    Ok(Some(match kind.as_str() {
        "INTEGER" => row.try_get_unchecked::<i64, _>(name)?.to_string(),
        "REAL" => js::Value::Number(row.try_get_unchecked::<f64, _>(name)?).to_json(),
        "BLOB" => String::from_utf8_lossy(&row.try_get_unchecked::<Vec<u8>, _>(name)?).into_owned(),
        _ => row.try_get_unchecked::<String, _>(name)?,
    }))
}

fn column_int(row: &SqliteRow, name: &str) -> Result<Option<i64>, BoxError> {
    let raw = row.try_get_raw(name)?;
    if raw.is_null() {
        return Ok(None);
    }
    let kind = raw.type_info().name().to_string();
    Ok(match kind.as_str() {
        "INTEGER" => Some(row.try_get_unchecked::<i64, _>(name)?),
        "REAL" => Some(row.try_get_unchecked::<f64, _>(name)? as i64),
        _ => column_text(row, name)?.and_then(|t| {
            let t = t.trim();
            t.parse::<i64>().ok().or_else(|| t.parse::<f64>().ok().map(|f| f as i64))
        }),
    })
}

fn job_of(row: &SqliteRow) -> Result<StoredJob, BoxError> {
    let name = column_text(row, "name")?.unwrap_or_default();
    let text = column_text(row, "definition")?.unwrap_or_default();
    // JSON of another shape (another writer's, or a hand edit) is a
    // definition with nothing in it, as the SDK reads it: one such row must
    // not fail every read of the jobs, and with it every check.
    let definition = match js::parse(&text) {
        Ok(Value::Object(o)) => Definition::from_object(o),
        Ok(_) => Definition::default(),
        Err(err) => return Err(format!("job {name}: {err}").into()),
    };
    Ok(StoredJob {
        name,
        definition,
        created_at: column_int(row, "created_at")?.unwrap_or(0),
        updated_at: column_int(row, "updated_at")?.unwrap_or(0),
    })
}

fn run_of(row: &SqliteRow) -> Result<Run, BoxError> {
    let id = column_text(row, "id")?.unwrap_or_default();
    let mut metrics = Metrics::new();
    if let Some(text) = column_text(row, "metrics")? {
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
    Ok(Run {
        job: column_text(row, "job")?.unwrap_or_default(),
        status: RunStatus::parse(&column_text(row, "status")?.unwrap_or_default()),
        started_at: column_int(row, "started_at")?.unwrap_or(0),
        finished_at: column_int(row, "finished_at")?,
        duration_ms: column_int(row, "duration_ms")?,
        error: column_text(row, "error")?,
        output: column_text(row, "output")?,
        metrics,
        trigger: column_text(row, "trigger")?.unwrap_or_default(),
        id,
    })
}

// Parameters in statement order, so every dialect binds the same values.

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
        Param::Text(r.metrics.to_json()),
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
        Param::Text(r.metrics.to_json()),
        Param::Text(r.id.clone()),
    ]
}

impl Store for SqlStore {
    /// Makes the tables.
    fn init(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        Box::pin(async move {
            for statement in schema(self.dialect, &self.prefix) {
                self.run(&statement, Vec::new()).await?;
            }
            Ok(())
        })
    }

    fn upsert_job<'a>(&'a self, definition: &'a Definition, now: i64) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let params = vec![
                Param::Text(definition.name().into()),
                Param::Text(definition.to_json()),
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
            let mut guard = self.conn().await?;
            let conn = guard.as_mut().expect("an open connection");
            let result = async {
                let mut tx = sqlx::Connection::begin(&mut **conn).await?;
                for statement in [&self.sql.delete_runs, &self.sql.delete_state, &self.sql.delete_job] {
                    sqlx::query(AssertSqlSafe(statement.to_string())).bind(name).execute(&mut *tx).await?;
                }
                tx.commit().await
            }
            .await;
            forget_if_broken(&mut guard, &result);
            Ok(result?)
        })
    }

    fn insert_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move { self.run(&self.sql.insert_run, insert_run_params(run)).await.map(|_| ()) })
    }

    fn update_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move { self.run(&self.sql.update_run, update_run_params(run)).await.map(|_| ()) })
    }

    fn update_run_if<'a>(&'a self, run: &'a Run, from: &'a [RunStatus]) -> BoxFuture<'a, Result<bool, BoxError>> {
        Box::pin(async move {
            if from.is_empty() {
                return Ok(false);
            }
            let mut params = update_run_params(run);
            params.extend(from.iter().map(|s| Param::Text(s.as_str().into())));
            Ok(self.run(&self.sql.update_run_if(from.len()), params).await? > 0)
        })
    }

    /// Deletes a run only while it is of `job` and in `status`, in one
    /// statement, and says whether it did.
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
            let text = column_text(row, "state")?.unwrap_or_default();
            Ok(Some(JobState::from_json(&text)?))
        })
    }

    fn set_state<'a>(&'a self, state: &'a JobState) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let params = vec![Param::Text(state.job.clone()), Param::Text(state.to_json())];
            self.run(&self.sql.set_state, params).await.map(|_| ())
        })
    }

    fn compare_and_set_state<'a>(
        &'a self,
        state: &'a JobState,
        expected: i64,
    ) -> BoxFuture<'a, Result<bool, BoxError>> {
        Box::pin(async move {
            let body = state.to_json();
            let n = if expected == 0 {
                self.run(&self.sql.cas_insert, vec![Param::Text(state.job.clone()), Param::Text(body)]).await?
            } else {
                let params = vec![Param::Text(body), Param::Text(state.job.clone()), Param::Int(expected)];
                self.run(&self.sql.cas_update, params).await?
            };
            Ok(n > 0)
        })
    }

    fn prune(&self, before: i64) -> BoxFuture<'_, Result<u64, BoxError>> {
        Box::pin(async move { self.run(&self.sql.prune, vec![Param::Int(before)]).await })
    }

    /// Gives SQLite's connection back to the pool. The pool is the app's, and
    /// stays open.
    fn close(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        Box::pin(async move {
            self.conn.lock().await.take();
            Ok(())
        })
    }
}
