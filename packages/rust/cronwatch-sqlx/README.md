# cronwatch-sqlx

The SQL store for [`cronwatch`](https://crates.io/crates/cronwatch), the Rust port of the library behind [cronwatch.dev](https://cronwatch.dev) (not the hosted cronwatch.io). It keeps CronWatch's jobs, runs and state in the app's own database through sqlx and the app's own pool, in the same tables and bytes as the Node SDK and the Ruby, Python, PHP and Go ports, so processes in any of them can share one database. It also has the pg_cron source, which watches the jobs pg_cron runs inside Postgres.

Each database is a feature (sqlx 0.9, Rust 1.94 or newer):

- `sqlite`: SQLite, built from source (a C compiler is needed, as for every SQLite crate).
- `postgres`: Postgres, with the SDK's statements text for text.
- `mysql`: MySQL 8.0.13 or newer, or MariaDB 10.6 or newer, in the PHP and Go ports' dialect.
- `pgcron`: the pg_cron source (turns on `postgres`).

```toml
[dependencies]
cronwatch = "0.6"
cronwatch-sqlx = { version = "0.6", features = ["postgres"] }
sqlx = { version = "0.9", default-features = false, features = ["runtime-tokio", "postgres"] }
```

```rust
use cronwatch_sqlx::SqlStore;

let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
let cw = cronwatch::Client::builder().store(SqlStore::postgres(pool).prefix("cronwatch_")?).build()?;
```

`SqlStore::sqlite(pool)` and `SqlStore::mysql(pool)` are the same for the other two. The tables are made at the client's first use: on Postgres under an advisory lock, so many processes can start at once.

- On SQLite the store holds one connection of the pool for its statements, in WAL mode with `busy_timeout` 5000 and `synchronous` NORMAL, so give the pool room for the app too.
- On Postgres and MySQL each statement runs on the pool on its own, so the store's writes never join a transaction the app has open.
- On MySQL the JSON columns are `LONGTEXT` holding the SDK's bytes (never MySQL's `JSON` type, which rewrites them), names compare by byte (`utf8mb4_bin`), and a trigger longer than 255 characters is cut to fit. MySQL 8's default sign-in over a connection without TLS needs sqlx's `mysql-rsa` feature, or TLS.

## pg_cron

```rust
use std::sync::Arc;
use cronwatch_sqlx::{PgCron, PgCronOptions, SqlStore};

let source = PgCron::new(pool.clone(), PgCronOptions { prefix: "db:".into(), ..Default::default() });
let cw = cronwatch::Client::builder().store(SqlStore::postgres(pool)).source(Arc::new(source)).build()?;
cw.start(std::time::Duration::from_secs(60));
```

On every check the source reads `cron.job`, declares each job with its schedule (in `cron.timezone`, read from `pg_settings`, else UTC), and copies new rows of `cron.job_run_details` in as runs, so missed, failed, stuck and slow runs alert as any other job's do. The first time it sees a job it copies the twenty newest runs without alerting. A job renamed, unscheduled or no longer picked keeps its history under its old name, declared again without a schedule. `PgCronOptions` picks jobs (`jobs`, `job_ids` or `pick`), names them (`prefix`, `job_name`) and gives them options (`options`, `options_for`). The pool must be on the database pg_cron runs in (its `cron.database_name`); pg_cron's row level security shows a role only its own jobs.

## Tests

`cargo test -p cronwatch-sqlx --all-features` runs the SQLite tests always, and the Postgres, MySQL, MariaDB and pg_cron tests when these are set:

```text
CRONWATCH_TEST_PG=postgres://postgres:pw@127.0.0.1:5432/cw
CRONWATCH_TEST_MYSQL=mysql://root:pw@127.0.0.1:3306/cw
CRONWATCH_TEST_MARIADB=mysql://root:pw@127.0.0.1:3307/cw
CRONWATCH_TEST_PGCRON=postgres://postgres:pw@127.0.0.1:5433/cw
```

Each test names its tables by a prefix of its own and drops them when it is done.

MIT licensed.
