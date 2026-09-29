# cronwatch-sqlx

The SQL store for [`cronwatch`](https://crates.io/crates/cronwatch), the Rust port of the library behind [cronwatch.dev](https://cronwatch.dev) (not the hosted cronwatch.io). It keeps CronWatch's jobs, runs and state in the app's own database through sqlx and the app's own pool, in the same tables and bytes as the Node SDK and the Ruby, Python, PHP and Go ports, so processes in any of them can share one database.

SQLite is the first database, behind the `sqlite` feature (sqlx 0.9, Rust 1.94 or newer):

```toml
[dependencies]
cronwatch = "0.6"
cronwatch-sqlx = { version = "0.6", features = ["sqlite"] }
sqlx = { version = "0.9", default-features = false, features = ["runtime-tokio", "sqlite"] }
```

```rust
use cronwatch_sqlx::SqlStore;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool};

let pool = SqlitePool::connect_with(SqliteConnectOptions::new().filename("data/app.db").create_if_missing(true)).await?;
let cw = cronwatch::Client::builder().store(SqlStore::sqlite(pool).prefix("cronwatch_")?).build()?;
```

The store holds one connection of the pool for its statements, in WAL mode with `busy_timeout` 5000 and `synchronous` NORMAL, so give the pool room for the app too.

MIT licensed.
