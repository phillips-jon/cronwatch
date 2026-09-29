//! Real apalis workers: over its memory storage, a cron schedule on the wall
//! clock (apalis-cron reads `SystemTime`), and, when `CRONWATCH_TEST_PG`
//! names a Postgres, over apalis's Postgres storage.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use apalis::prelude::*;
use apalis_cron::Tick;
use cronwatch::{Client, JobOptions, MemoryStore, RunStatus, Store};
use cronwatch_apalis::{CHECK_WORKER, Options, TRIGGER, Watcher};

struct Kit {
    cw: Client,
    store: Arc<dyn Store>,
    alerts: Arc<Mutex<Vec<String>>>,
    errors: Arc<Mutex<Vec<String>>>,
}

fn kit(store: Arc<dyn Store>) -> Kit {
    let alerts = Arc::new(Mutex::new(Vec::new()));
    let errors = Arc::new(Mutex::new(Vec::new()));
    let (sink, kept) = (alerts.clone(), errors.clone());
    let cw = Client::builder()
        .store_arc(store.clone())
        .alerts([cronwatch::channel_fn("capture", move |alert: cronwatch::Alert| {
            sink.lock().unwrap().push(alert.alert_type.to_string());
            async { Ok(()) }
        })])
        .on_error(move |err, where_| kept.lock().unwrap().push(format!("{where_}: {err}")))
        .build()
        .unwrap();
    Kit { cw, store, alerts, errors }
}

fn options(app: &str) -> Options {
    Options { app: Some(app.into()), ..Options::default() }
}

async fn stored(store: &dyn Store, name: &str) -> String {
    store.get_job(name).await.unwrap().unwrap_or_else(|| panic!("{name} is not stored")).definition.to_json()
}

/// Waits (on the wall clock) until `cond` holds, for at most fifteen
/// seconds.
async fn until<F, Fut>(what: &str, mut cond: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    for _ in 0..300 {
        if cond().await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

async fn finished(cw: &Client, name: &str) -> Vec<cronwatch::Run> {
    let mut runs = cw.runs(name, 100).await.unwrap();
    runs.retain(|r| r.status != RunStatus::Running);
    runs.reverse();
    runs
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
async fn each_retry_is_a_run_and_the_last_closes_the_alert() {
    let k = kit(Arc::new(MemoryStore::new()));
    let watcher = Watcher::new(&k.cw, options("billing"));
    let mut storage = MemoryStorage::new();
    storage.push(7u32).await.unwrap();

    async fn flaky(n: u32, attempt: Attempt) -> Result<(), BoxDynError> {
        if let Some(job) = cronwatch::current() {
            job.log(format!("task {n}, attempt {}", attempt.current()));
        }
        if attempt.current() < 3 {
            return Err(Box::new(Down(attempt.current())));
        }
        Ok(())
    }
    let worker = WorkerBuilder::new("invoices")
        .backend(storage)
        .retry(RetryPolicy::retries(2))
        .layer(watcher.layer())
        .build(flaky);
    let cw = k.cw.clone();
    let handle = tokio::spawn(worker.run_with_ctx(move |ctx| {
        let cw = cw.clone();
        async move {
            until("three runs", || async { finished(&cw, "invoices").await.len() >= 3 }).await;
            ctx.stop()
        }
    }));
    let _ = handle.await.unwrap();

    let runs = finished(&k.cw, "invoices").await;
    let seen: Vec<(RunStatus, Option<String>, Option<String>)> =
        runs.iter().map(|r| (r.status.clone(), r.error.clone(), r.output.clone())).collect();
    assert_eq!(
        seen,
        [
            (RunStatus::Failed, Some("Error: attempt 1 failed".into()), Some("task 7, attempt 1".into())),
            (RunStatus::Failed, Some("Error: attempt 2 failed".into()), Some("task 7, attempt 2".into())),
            (RunStatus::Ok, None, Some("task 7, attempt 3".into())),
        ]
    );
    assert!(runs.iter().all(|r| r.trigger == TRIGGER));
    assert_eq!(k.alerts.lock().unwrap().clone(), ["failed", "recovered"], "one alert and its recovery");
    assert_eq!(
        stored(&*k.store, "invoices").await,
        r#"{"tags":["apalis","apalis:billing"],"name":"invoices"}"#,
        "a worker with no schedule here is declared with the defaults"
    );
    assert!(k.errors.lock().unwrap().is_empty(), "{:?}", k.errors.lock().unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_panic_is_a_failed_run_and_a_deferred_attempt_is_given_back() {
    let k = kit(Arc::new(MemoryStore::new()));
    let watcher = Watcher::new(&k.cw, options("billing"));
    let mut storage = MemoryStorage::new();
    for n in [1u32, 2, 3] {
        storage.push(n).await.unwrap();
    }
    async fn odd(n: u32) -> Result<(), BoxDynError> {
        match n {
            1 => panic!("task one panicked"),
            2 => Err(Box::new(DeferredError::new("not yet"))),
            _ => Ok(()),
        }
    }
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = calls.clone();
    let worker = WorkerBuilder::new("odd")
        .backend(storage)
        .catch_panic()
        .layer(watcher.layer_for("odd-jobs"))
        .layer(tower_layer_fn(counted))
        .build(odd);
    let cw = k.cw.clone();
    let handle = tokio::spawn(worker.run_with_ctx(move |ctx| {
        let (cw, calls) = (cw.clone(), calls.clone());
        async move {
            until("three calls and two runs", || async {
                calls.load(Ordering::SeqCst) >= 3 && finished(&cw, "odd-jobs").await.len() >= 2
            })
            .await;
            tokio::time::sleep(Duration::from_millis(200)).await;
            ctx.stop()
        }
    }));
    let _ = handle.await.unwrap();
    let runs = finished(&k.cw, "odd-jobs").await;
    // The tasks run at once, so in any order.
    let mut seen: Vec<(String, Option<String>)> =
        runs.iter().map(|r| (r.status.to_string(), r.error.clone())).collect();
    seen.sort();
    assert_eq!(
        seen,
        [("failed".to_string(), Some("panic: task one panicked".to_string())), ("ok".to_string(), None)],
        "the deferred attempt left no run"
    );
    assert!(k.errors.lock().unwrap().is_empty(), "{:?}", k.errors.lock().unwrap());
}

/// A layer that counts the calls through it, inside CronWatch's.
fn tower_layer_fn(calls: Arc<AtomicUsize>) -> Counting {
    Counting(calls)
}

#[derive(Clone)]
struct Counting(Arc<AtomicUsize>);

impl<S> tower_layer::Layer<S> for Counting {
    type Service = CountingService<S>;
    fn layer(&self, inner: S) -> CountingService<S> {
        CountingService(inner, self.0.clone())
    }
}

#[derive(Clone)]
struct CountingService<S>(S, Arc<AtomicUsize>);

impl<S: tower_service::Service<R>, R> tower_service::Service<R> for CountingService<S> {
    type Response = S::Response;
    type Error = S::Error;
    type Future = S::Future;
    fn poll_ready(&mut self, cx: &mut std::task::Context<'_>) -> std::task::Poll<Result<(), S::Error>> {
        self.0.poll_ready(cx)
    }
    fn call(&mut self, req: R) -> S::Future {
        self.1.fetch_add(1, Ordering::SeqCst);
        self.0.call(req)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cron_worker_runs_on_cronwatchs_schedule() {
    let k = kit(Arc::new(MemoryStore::new()));
    let watcher = Watcher::new(&k.cw, Options { defaults: JobOptions::new().grace("1m"), ..options("billing") });
    let backend = watcher.cron("every-second", "* * * * * *", "UTC", JobOptions::new().description("Ticks")).unwrap();
    async fn tick(t: Tick) -> Result<String, BoxDynError> {
        Ok(format!("tick {}", t.get_timestamp() > 0))
    }
    let worker = WorkerBuilder::new("every-second").backend(backend).layer(watcher.layer()).build(tick);
    let checker = watcher.check_worker(Duration::from_secs(1)).unwrap();
    let cw = k.cw.clone();
    let check = tokio::spawn(checker.run_with_ctx(move |ctx| async move {
        tokio::time::sleep(Duration::from_millis(2500)).await;
        ctx.stop()
    }));
    let handle = tokio::spawn(worker.run_with_ctx(move |ctx| {
        let cw = cw.clone();
        async move {
            until("two runs", || async { finished(&cw, "every-second").await.len() >= 2 }).await;
            ctx.stop()
        }
    }));
    let _ = handle.await.unwrap();
    let _ = check.await.unwrap();
    let runs = finished(&k.cw, "every-second").await;
    assert!(runs.iter().all(|r| r.status == RunStatus::Ok && r.output.as_deref() == Some("tick true")), "{runs:?}");
    // Each tick on a whole second, as croner fires.
    assert!(runs.iter().all(|r| r.started_at % 1000 < 900), "{runs:?}");
    assert_eq!(
        stored(&*k.store, "every-second").await,
        r#"{"grace":"1m","schedule":"* * * * * *","timezone":"UTC","description":"Ticks","tags":["apalis","apalis:billing"],"name":"every-second"}"#
    );
    let names: Vec<String> = k.store.list_jobs().await.unwrap().into_iter().map(|j| j.name).collect();
    assert!(!names.iter().any(|n| n == CHECK_WORKER), "the check is never a job: {names:?}");
    assert!(k.errors.lock().unwrap().is_empty(), "{:?}", k.errors.lock().unwrap());
}

#[tokio::test]
async fn what_cronwatch_refuses_is_an_error() {
    let k = kit(Arc::new(MemoryStore::new()));
    let watcher = Watcher::new(&k.cw, options("billing"));
    assert!(watcher.cron("no spaces", "0 2 * * *", "UTC", JobOptions::new()).is_err());
    assert!(watcher.cron("x", "not a cron", "UTC", JobOptions::new()).is_err());
    assert!(watcher.cron("x", "0 2 * * *", "Mars/Olympus", JobOptions::new()).is_err());
    assert!(watcher.cron("x", "0 2 * * *", "UTC", JobOptions::new().grace("soon")).is_err());
    assert!(k.cw.defined_jobs().is_empty());
    assert!(cronwatch_apalis::schedule("0 2 * * *", "Europe/London").is_ok());
}

// A worker in a process of its own (a second client on the same store)
// keeps the definition the scheduling process stored, and the check there
// unschedules this app's job that no worker has any more.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_worker_elsewhere_keeps_the_schedulers_definition() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let scheduler = kit(store.clone());
    let planner = Watcher::new(&scheduler.cw, options("billing"));
    let _ = planner.cron("report", "0 2 * * *", "UTC", JobOptions::new().expect("written")).unwrap();
    let _ = planner.cron("retired", "0 3 * * *", "UTC", JobOptions::new()).unwrap();
    planner.wait().await;
    let before = stored(&*store, "report").await;

    let worker_kit = kit(store.clone());
    let watcher = Watcher::new(&worker_kit.cw, options("billing"));
    let mut storage = MemoryStorage::new();
    storage.push(1u32).await.unwrap();
    async fn report(_: u32) -> Result<String, BoxDynError> {
        Ok("written".into())
    }
    let worker = WorkerBuilder::new("report").backend(storage).layer(watcher.layer()).build(report);
    let cw = worker_kit.cw.clone();
    let handle = tokio::spawn(worker.run_with_ctx(move |ctx| {
        let cw = cw.clone();
        async move {
            until("a run", || async { finished(&cw, "report").await.len() == 1 }).await;
            ctx.stop()
        }
    }));
    let _ = handle.await.unwrap();
    assert_eq!(finished(&worker_kit.cw, "report").await[0].status, RunStatus::Ok, "the expect rule held");
    assert_eq!(stored(&*store, "report").await, before, "the scheduler's definition is kept");

    // The scheduling process's next release no longer has "retired".
    let next = kit(store.clone());
    let released = Watcher::new(&next.cw, options("billing"));
    let _ = released.cron("report", "0 2 * * *", "UTC", JobOptions::new().expect("written")).unwrap();
    released.sync().await.unwrap();
    assert!(stored(&*store, "retired").await.contains("no longer scheduled"));
    assert_eq!(stored(&*store, "report").await, before);
}

#[cfg(feature = "cron")]
#[tokio::test]
async fn a_cron_crate_schedule_is_declared_once_checked() {
    use std::str::FromStr;
    let k = kit(Arc::new(MemoryStore::new()));
    let watcher = Watcher::new(&k.cw, options("billing"));
    let named = cron::Schedule::from_str("0 30 9 * * Mon-Fri").unwrap();
    let _ = watcher.cron_schedule("weekdays", named, chrono_tz::Europe::London, JobOptions::new()).unwrap();
    // The cron crate counts the days of the week from 1, Sunday; croner
    // from 0, so "2" is Monday to one and Tuesday to the other.
    let numbered = cron::Schedule::from_str("0 0 8 * * 2").unwrap();
    let _ = watcher.cron_schedule("numbered", numbered, chrono_tz::UTC, JobOptions::new()).unwrap();
    watcher.wait().await;
    assert_eq!(
        stored(&*k.store, "weekdays").await,
        r#"{"schedule":"0 30 9 * * Mon-Fri","timezone":"Europe/London","tags":["apalis","apalis:billing"],"name":"weekdays"}"#
    );
    assert_eq!(stored(&*k.store, "numbered").await, r#"{"tags":["apalis","apalis:billing"],"name":"numbered"}"#);
    let errors = k.errors.lock().unwrap().clone();
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(errors[0].contains(r#"is "0 0 8 * * 2" in UTC, but after a run at"#), "{errors:?}");
}
