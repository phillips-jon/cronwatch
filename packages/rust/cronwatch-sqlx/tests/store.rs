//! The SQL store on SQLite: the store contract, the store.json replay, the
//! finish-once scenarios over several stores on one file, the SDK's schema,
//! rows of other shapes, and a client end to end.

mod common;

use std::sync::Arc;

use common::{TempDir, memory_pool, pool, repo, store};
use cronwatch::storetest::{self, Clock, Process, Shared, T0};
use cronwatch::{AlertType, JobOptions, Store};
use cronwatch_sqlx::SqlStore;

#[tokio::test]
async fn the_sqlite_store_passes_the_contract() {
    storetest::run(|| SqlStore::sqlite(memory_pool())).await;
}

#[tokio::test]
async fn the_sqlite_store_passes_the_contract_on_a_file_with_a_prefix() {
    let dir = TempDir::new();
    storetest::run(|| store(&dir.file("contract.db"), "cw_")).await;
}

#[tokio::test]
async fn the_sqlite_store_replays_store_json() {
    let fixture = std::fs::read_to_string(repo().join("conformance/store.json")).expect("conformance/store.json");
    let cases = storetest::replay_fixture(&fixture, || SqlStore::sqlite(memory_pool())).await;
    assert!(cases >= 20, "{cases} cases");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_is_finished_once_across_stores_on_one_file() {
    let dir = Arc::new(TempDir::new());
    let mut n = 0;
    storetest::finish_once(move || {
        n += 1;
        let file = dir.file(&format!("finish-{n}.db"));
        Shared { open: Box::new(move || Arc::new(store(&file, "cronwatch_")) as Arc<dyn Store>), done: Box::new(|| {}) }
    })
    .await;
}

#[tokio::test]
async fn a_bad_prefix_is_refused_with_the_sdks_message() {
    let err = SqlStore::sqlite(memory_pool()).prefix("Bad-").unwrap_err();
    assert_eq!(
        err.to_string(),
        "cronwatch: invalid table prefix \"Bad-\". Use lowercase letters, digits and underscores, not starting with a digit, at most 47 characters."
    );
    let s = SqlStore::sqlite(memory_pool());
    assert_eq!(s.table_prefix(), "cronwatch_");
}

#[tokio::test]
async fn the_tables_are_the_sdks() {
    let dir = TempDir::new();
    let file = dir.file("schema.db");
    let s = store(&file, "cw_");
    s.init().await.unwrap();
    s.init().await.expect("init twice");
    s.close().await.unwrap();
    let rows: Vec<(String,)> =
        sqlx::query_as("SELECT sql FROM sqlite_master WHERE name LIKE 'cw_%' AND sql IS NOT NULL ORDER BY name")
            .fetch_all(&pool(&file))
            .await
            .unwrap();
    let sql: Vec<&str> = rows.iter().map(|r| r.0.as_str()).collect();
    assert_eq!(sql.len(), 5, "{sql:?}");
    assert!(sql.contains(&"CREATE INDEX cw_runs_running ON cw_runs (status) WHERE status = 'running'"), "{sql:?}");
    let mode: (String,) = sqlx::query_as("PRAGMA journal_mode").fetch_one(&pool(&file)).await.unwrap();
    assert_eq!(mode.0, "wal");
}

#[tokio::test]
async fn rows_of_another_shape_are_read_as_the_sdk_reads_them() {
    let dir = TempDir::new();
    let file = dir.file("foreign.db");
    let s = store(&file, "cronwatch_");
    s.init().await.unwrap();
    let p = pool(&file);
    sqlx::query("INSERT INTO cronwatch_jobs (name, definition, created_at, updated_at) VALUES ('odd', '[1]', 1, 2)")
        .execute(&p)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO cronwatch_runs (id, job, status, started_at, metrics) VALUES ('x', 'odd', 'running', 5.0, '{\"a\":\"text\",\"b\":2}')",
    )
    .execute(&p)
    .await
    .unwrap();
    let job = s.get_job("odd").await.unwrap().expect("the job");
    assert_eq!(job.definition.to_json(), "{}", "a definition that is not an object is an empty one");
    assert_eq!(job.updated_at, 2);
    let running = s.running_runs().await.unwrap();
    assert_eq!(running.len(), 1);
    assert_eq!(running[0].metrics.to_json(), r#"{"b":2}"#, "metrics keep the numbers");
    assert_eq!(running[0].started_at, 5);
    assert_eq!(running[0].trigger, "run");

    // Text that is not UTF-8 reads with U+FFFD rather than failing every
    // read of the job's runs (the audit).
    sqlx::query(
        "INSERT INTO cronwatch_runs (id, job, status, started_at, output, trigger) VALUES ('y', 'odd', 'ok', 6, CAST(x'61ff62' AS TEXT), 'run')",
    )
    .execute(&p)
    .await
    .unwrap();
    let runs = s.list_runs("odd", 10).await.expect("the runs read");
    assert_eq!(runs[0].output.as_deref(), Some("a\u{fffd}b"));
}

#[tokio::test]
async fn a_client_records_and_checks_on_sqlite_and_another_reads_it() {
    let dir = TempDir::new();
    let file = dir.file("client.db");
    let clock = Clock::new(T0);
    let one = Process::new(Arc::new(store(&file, "cronwatch_")), &clock);
    let job = one
        .client
        .job("nightly", JobOptions::new().schedule("every 5m").expect("done").failures_before_alert(1))
        .unwrap();
    job.run(|j| async move {
        j.log("done");
        j.metric("rows", 3.0).unwrap();
        Ok::<_, std::io::Error>(())
    })
    .await
    .unwrap();
    clock.advance(60_000);
    let err = job.run(|_| async { Err::<(), _>(std::io::Error::other("disk full")) }).await.unwrap_err();
    assert_eq!(err.to_string(), "disk full");
    assert_eq!(one.alerts.types(), vec![AlertType::Failed.to_string()]);
    clock.advance(20 * 60_000);
    let result = one.client.check().await.unwrap();
    assert_eq!(result.jobs.len(), 1);
    assert_eq!(one.alerts.types(), vec!["failed".to_string(), "missed".into()]);

    let two = Process::new(Arc::new(store(&file, "cronwatch_")), &clock);
    let runs = two.client.runs("nightly", 10).await.unwrap();
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[0].error.as_deref(), Some("Error: disk full"));
    assert_eq!(runs[1].output.as_deref(), Some("done"));
    assert_eq!(runs[1].metrics.to_json(), r#"{"rows":3}"#);
    let summary = two.client.job_summary("nightly").await.unwrap().expect("a summary");
    assert_eq!(summary.consecutive_failures, 1);
    assert!(one.errors.list().is_empty() && two.errors.list().is_empty(), "{:?}", one.errors.list());
}
