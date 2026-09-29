//! SQLite's one connection, held for the store's statements in turn.

use std::time::Duration;

use cronwatch::BoxError;
use sqlx::pool::PoolConnection;
use sqlx::sqlite::{Sqlite, SqliteArguments};
use sqlx::{AssertSqlSafe, SqlitePool};
use tokio::sync::{Mutex, MutexGuard};

use crate::rows::{Param, Row, sqlite_row};

/// How long opening SQLite keeps retrying a busy database before it gives up
/// (busy.ts).
const BUSY_RETRY: Duration = Duration::from_secs(2);

/// The pool, and the one connection of it the store holds.
pub(crate) struct Conn {
    pool: SqlitePool,
    conn: Mutex<Option<PoolConnection<Sqlite>>>,
}

impl Conn {
    pub(crate) fn new(pool: SqlitePool) -> Conn {
        Conn { pool, conn: Mutex::new(None) }
    }

    /// The connection, opened (and its pragmas set) on first use and held
    /// for the caller's statements. A failed open is tried afresh next time.
    async fn open(&self) -> Result<MutexGuard<'_, Option<PoolConnection<Sqlite>>>, BoxError> {
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
    pub(crate) async fn run(&self, text: AssertSqlSafe<String>, params: Vec<Param>) -> Result<u64, BoxError> {
        let mut guard = self.open().await?;
        let conn = guard.as_mut().expect("an open connection");
        let result = sqlx::query_with(text, arguments(params)?).execute(&mut **conn).await;
        forget_if_broken(&mut guard, &result);
        Ok(result?.rows_affected())
    }

    /// Runs a query, answering its rows.
    pub(crate) async fn query(&self, text: AssertSqlSafe<String>, params: Vec<Param>) -> Result<Vec<Row>, BoxError> {
        let mut guard = self.open().await?;
        let conn = guard.as_mut().expect("an open connection");
        let result = sqlx::query_with(text, arguments(params)?).fetch_all(&mut **conn).await;
        forget_if_broken(&mut guard, &result);
        result?.iter().map(sqlite_row).collect()
    }

    /// Runs statements, each with `params`, in one transaction.
    pub(crate) async fn transaction(&self, statements: &[&str], params: &[Param]) -> Result<(), BoxError> {
        let mut guard = self.open().await?;
        let conn = guard.as_mut().expect("an open connection");
        let result: Result<(), BoxError> = async {
            let mut tx = sqlx::Connection::begin(&mut **conn).await?;
            for statement in statements {
                let args = arguments(params.to_vec())?;
                sqlx::query_with(AssertSqlSafe(statement.to_string()), args).execute(&mut *tx).await?;
            }
            Ok(tx.commit().await?)
        }
        .await;
        if let Err(err) = &result
            && let Some(e) = err.downcast_ref::<sqlx::Error>()
            && broken(e)
        {
            *guard = None;
        }
        result
    }

    /// Gives the connection back to the pool.
    pub(crate) async fn close(&self) {
        self.conn.lock().await.take();
    }
}

fn arguments(params: Vec<Param>) -> Result<SqliteArguments, BoxError> {
    use sqlx::Arguments;
    let mut args = SqliteArguments::default();
    for p in params {
        match p {
            Param::Text(s) | Param::Json(s) => args.add(s)?,
            Param::OptText(s) => args.add(s)?,
            Param::Int(n) => args.add(n)?,
            Param::OptInt(n) => args.add(n)?,
        }
    }
    Ok(args)
}

fn broken(err: &sqlx::Error) -> bool {
    matches!(err, sqlx::Error::Io(_) | sqlx::Error::PoolClosed | sqlx::Error::WorkerCrashed)
}

/// A connection that failed as a connection (not as a statement) is given
/// back, and the next statement opens another.
fn forget_if_broken<T>(guard: &mut Option<PoolConnection<Sqlite>>, result: &Result<T, sqlx::Error>) {
    if let Err(err) = result
        && broken(err)
    {
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
