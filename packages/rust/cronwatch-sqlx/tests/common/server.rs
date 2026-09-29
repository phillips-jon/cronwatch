//! The database servers from the environment, each a URL:
//!
//! ```text
//! CRONWATCH_TEST_PG       postgres://user:password@127.0.0.1:5432/db
//! CRONWATCH_TEST_MYSQL    mysql://user:password@127.0.0.1:3306/db
//! CRONWATCH_TEST_MARIADB  the same, for MariaDB (mysql:// or mariadb://)
//! ```
//!
//! A test of a server that is not set says so on standard error and passes.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use cronwatch_sqlx::{Dialect, SqlStore};
use sqlx::AssertSqlSafe;

/// A database server, whose tables each test names by a prefix of its own
/// and drops when it is done.
#[derive(Clone)]
pub struct Server {
    pub name: &'static str,
    pub dialect: Dialect,
    url: String,
    prefixes: Arc<Mutex<Vec<String>>>,
}

/// A table prefix no other test uses, so tests on one server never see each
/// other's tables, and tables a failed run left behind never meet the next.
pub fn prefix(label: &str) -> String {
    static N: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
    format!("cwrs_{label}_{}_{}_{}_", std::process::id() % 100_000, nanos % 10_000, N.fetch_add(1, Ordering::Relaxed))
}

/// The servers that are set; those that are not are said to be skipped.
pub fn servers() -> Vec<Server> {
    let mut out = Vec::new();
    for (name, variable, dialect) in [
        ("postgres", "CRONWATCH_TEST_PG", Dialect::Postgres),
        ("mysql", "CRONWATCH_TEST_MYSQL", Dialect::Mysql),
        ("mariadb", "CRONWATCH_TEST_MARIADB", Dialect::Mysql),
    ] {
        match std::env::var(variable) {
            Ok(url) if !url.is_empty() => {
                let url = match url.strip_prefix("mariadb://") {
                    Some(rest) => format!("mysql://{rest}"),
                    None => url,
                };
                out.push(Server { name, dialect, url, prefixes: Arc::default() });
            }
            _ => eprintln!("{name}: skipped; set {variable} to run"),
        }
    }
    out
}

/// The Postgres server, if it is set.
pub fn postgres() -> Option<Server> {
    servers().into_iter().find(|s| s.name == "postgres")
}

/// MySQL and MariaDB, those that are set.
pub fn mysqls() -> Vec<Server> {
    servers().into_iter().filter(|s| s.dialect == Dialect::Mysql).collect()
}

/// Statements and queries on a server outside any store.
pub enum Db {
    Pg(sqlx::PgPool),
    My(sqlx::MySqlPool),
}

impl Db {
    pub async fn exec(&self, text: &str) {
        let q = AssertSqlSafe(text.to_string());
        match self {
            Db::Pg(p) => sqlx::raw_sql(q).execute(p).await.map(|_| ()),
            Db::My(p) => sqlx::raw_sql(q).execute(p).await.map(|_| ()),
        }
        .unwrap_or_else(|e| panic!("{text}: {e}"));
    }

    /// The first column of each row, as text (NULL as "").
    pub async fn column(&self, text: &str) -> Vec<String> {
        use sqlx::Row;
        let q = AssertSqlSafe(text.to_string());
        match self {
            Db::Pg(p) => sqlx::query(q)
                .fetch_all(p)
                .await
                .unwrap_or_else(|e| panic!("{text}: {e}"))
                .iter()
                .map(|r| r.try_get_unchecked::<Option<String>, _>(0).expect("text").unwrap_or_default())
                .collect(),
            Db::My(p) => sqlx::query(q)
                .fetch_all(p)
                .await
                .unwrap_or_else(|e| panic!("{text}: {e}"))
                .iter()
                .map(|r| {
                    let bytes = r.try_get_unchecked::<Option<Vec<u8>>, _>(0).expect("bytes").unwrap_or_default();
                    String::from_utf8(bytes).expect("UTF-8")
                })
                .collect(),
        }
    }
}

impl Server {
    /// A new pool on the server, as another process would have.
    pub fn db(&self) -> Db {
        match self.dialect {
            Dialect::Postgres => Db::Pg(sqlx::PgPool::connect_lazy(&self.url).expect("a Postgres URL")),
            _ => Db::My(sqlx::MySqlPool::connect_lazy(&self.url).expect("a MySQL URL")),
        }
    }

    /// A fresh prefix, remembered so its tables are dropped by `cleanup`.
    pub fn prefix(&self, label: &str) -> String {
        let p = prefix(label);
        self.prefixes.lock().unwrap().push(p.clone());
        p
    }

    /// A store over tables of their own.
    pub fn store(&self, label: &str) -> SqlStore {
        let p = self.prefix(label);
        self.store_on(&p)
    }

    /// Another store, on a pool of its own, over the tables of `prefix`.
    pub fn store_on(&self, prefix: &str) -> SqlStore {
        let store = match self.db() {
            Db::Pg(pool) => SqlStore::postgres(pool),
            Db::My(pool) => SqlStore::mysql(pool),
        };
        store.prefix(prefix).expect("a prefix")
    }

    /// Drops the tables of every prefix this server handed out.
    pub async fn cleanup(&self) {
        let prefixes = std::mem::take(&mut *self.prefixes.lock().unwrap());
        let db = self.db();
        for p in prefixes {
            for table in ["jobs", "runs", "state", "orders"] {
                db.exec(&format!("DROP TABLE IF EXISTS {p}{table}")).await;
            }
        }
    }
}
