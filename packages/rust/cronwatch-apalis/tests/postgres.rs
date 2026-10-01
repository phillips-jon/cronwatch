//! apalis's Postgres storage, when `CRONWATCH_TEST_PG` names a server
//! (`postgres://...`): a queued job opted in by name through
//! `Options::jobs` that fails twice and then succeeds (three runs, one
//! alert and its recovery), and a panic. apalis keeps its tasks in a schema
//! of its own (`apalis`); each run of this test uses queues of its own and
//! deletes their tasks at the end.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use apalis::prelude::*;
use apalis_postgres::{Config, PgPool, PostgresStorage};
use cronwatch::{Client, JobOptions, MemoryStore, RunStatus, Store};
use cronwatch_apalis::{Options, Watcher};

async fn finished(cw: &Client, name: &str) -> Vec<cronwatch::Run> {
    let mut runs = cw.runs(name, 100).await.unwrap();
    runs.retain(|r| r.status != RunStatus::Running);
    runs.reverse();
    runs
}

async fn until<F, Fut>(what: &str, mut cond: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    for _ in 0..600 {
        if cond().await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

#[derive(Debug)]
struct Down(usize);

impl std::fmt::Display for Down {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "attempt {} failed", self.0)
    }
}

impl std::error::Error for Down {}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queued_job_on_postgres() {
    let Ok(url) = std::env::var("CRONWATCH_TEST_PG") else {
        eprintln!("apalis on Postgres: skipped, CRONWATCH_TEST_PG is not set");
        return;
    };
    let pool = PgPool::connect(&url).await.unwrap();
    PostgresStorage::setup(&pool).await.unwrap();
    let suffix = std::process::id();
    let (retried, panicking) = (format!("cronwatch-retried-{suffix}"), format!("cronwatch-panicking-{suffix}"));

    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let alerts = Arc::new(Mutex::new(Vec::new()));
    let sink = alerts.clone();
    let cw = Client::builder()
        .store_arc(store.clone())
        .alerts([cronwatch::channel_fn("capture", move |alert: cronwatch::Alert| {
            sink.lock().unwrap().push(format!("{} {}", alert.alert_type, alert.job));
            async { Ok(()) }
        })])
        .build()
        .unwrap();
    let options = Options::new().app("billing").job("invoices", JobOptions::new().description("Queued invoices"));
    let watcher = Watcher::new(&cw, options);

    let mut invoices = PostgresStorage::new(&pool).with_config(Config::default().queue(&retried));
    invoices.push(41u32).await.unwrap();
    let mut crashes = PostgresStorage::new(&pool).with_config(Config::default().queue(&panicking));
    crashes.push(1u32).await.unwrap();

    async fn flaky(_: u32, attempt: Attempt) -> Result<(), BoxDynError> {
        if attempt.current() < 3 {
            return Err(Box::new(Down(attempt.current())));
        }
        Ok(())
    }
    async fn crash(_: u32) -> Result<(), BoxDynError> {
        panic!("the task crashed")
    }
    let first = WorkerBuilder::new(format!("invoices-{suffix}"))
        .backend(invoices)
        .retry(RetryPolicy::retries(2))
        .layer(watcher.layer_for("invoices"))
        .build(flaky);
    let second = WorkerBuilder::new(format!("crashes-{suffix}"))
        .backend(crashes)
        .catch_panic()
        .layer(watcher.layer_for("crashes"))
        .build(crash);
    let (a, b) = (cw.clone(), cw.clone());
    let one = tokio::spawn(first.run_with_ctx(move |ctx| {
        let cw = a.clone();
        async move {
            until("three runs", || async { finished(&cw, "invoices").await.len() >= 3 }).await;
            ctx.stop()
        }
    }));
    let two = tokio::spawn(second.run_with_ctx(move |ctx| {
        let cw = b.clone();
        async move {
            until("a run", || async { !finished(&cw, "crashes").await.is_empty() }).await;
            ctx.stop()
        }
    }));
    let _ = one.await.unwrap();
    let _ = two.await.unwrap();

    let statuses: Vec<RunStatus> = finished(&cw, "invoices").await.iter().map(|r| r.status.clone()).collect();
    assert_eq!(statuses, [RunStatus::Failed, RunStatus::Failed, RunStatus::Ok]);
    let crashed = finished(&cw, "crashes").await;
    assert_eq!(crashed[0].error.as_deref(), Some("panic: the task crashed"));
    let mut seen = alerts.lock().unwrap().clone();
    seen.sort();
    assert_eq!(seen, ["failed crashes", "failed invoices", "recovered invoices"]);
    assert_eq!(
        store.get_job("invoices").await.unwrap().unwrap().definition.to_json(),
        r#"{"description":"Queued invoices","tags":["apalis","apalis:billing"],"name":"invoices"}"#
    );

    for queue in [&retried, &panicking] {
        sqlx::query("DELETE FROM apalis.jobs WHERE job_type = $1").bind(queue).execute(&pool).await.unwrap();
    }
    for worker in [format!("invoices-{suffix}"), format!("crashes-{suffix}")] {
        sqlx::query("DELETE FROM apalis.workers WHERE id = $1").bind(worker).execute(&pool).await.unwrap();
    }
}
