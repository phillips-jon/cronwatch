//! What the SQL store's tests share: SQLite files in a directory of their own
//! and stores over them, and (in `server`) the database servers from the
//! environment.

#![allow(dead_code)]

#[cfg(all(feature = "postgres", feature = "mysql"))]
pub mod server;

use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};

use cronwatch::js::Value;
use cronwatch::{Definition, JobState};
use cronwatch_sqlx::SqlStore;
use sqlx::SqlitePool;
use sqlx::sqlite::SqliteConnectOptions;

/// A directory of its own under the system's temporary directory, removed
/// when dropped.
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new() -> TempDir {
        static N: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "cronwatch-sqlx-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).expect("a temporary directory");
        TempDir(dir)
    }

    pub fn file(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A pool over a SQLite file, made when first used.
pub fn pool(file: &Path) -> SqlitePool {
    SqlitePool::connect_lazy_with(SqliteConnectOptions::new().filename(file).create_if_missing(true))
}

/// A pool over an in-memory database: the store holds one connection, so the
/// database lives as long as the store.
pub fn memory_pool() -> SqlitePool {
    SqlitePool::connect_lazy_with(SqliteConnectOptions::from_str("sqlite::memory:").expect("options"))
}

/// A store over a SQLite file with the prefix given.
pub fn store(file: &Path, prefix: &str) -> SqlStore {
    SqlStore::sqlite(pool(file)).prefix(prefix).expect("a prefix")
}

/// The repository's root, from this crate's directory.
pub fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

pub fn definition(text: &str) -> Definition {
    Definition::from_json(text).expect("a definition")
}

pub fn state(text: &str) -> JobState {
    JobState::from_json(text).expect("a state")
}

/// JSON with every object's keys sorted, to compare what Postgres's JSONB
/// gives back in an order of its own.
pub fn sorted(text: &str) -> String {
    fn walk(v: &Value) -> String {
        match v {
            Value::Object(o) => {
                let mut keys: Vec<&str> = o.keys().collect();
                keys.sort_unstable();
                let parts: Vec<String> =
                    keys.iter().map(|k| format!("{}:{}", Value::from(*k).to_json(), walk(o.get(k).unwrap()))).collect();
                format!("{{{}}}", parts.join(","))
            }
            Value::Array(a) => format!("[{}]", a.iter().map(walk).collect::<Vec<_>>().join(",")),
            other => other.to_json(),
        }
    }
    walk(&cronwatch::js::parse(text).expect("JSON"))
}
