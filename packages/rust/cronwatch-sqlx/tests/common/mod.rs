//! What the SQL store's tests share: SQLite files in a directory of their own
//! and stores over them.

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};

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
