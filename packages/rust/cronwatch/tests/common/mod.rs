//! What the client tests share: a client with a settable clock, a capture
//! channel and an error list (the SDK tests' `make()`), and a store whose
//! methods can be made to fail (helpers.ts `flaky()`).
#![allow(dead_code)]

use std::collections::HashSet;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use cronwatch::{
    Alert, BoxError, BoxFuture, Client, ClientBuilder, Definition, JobState, JobSummary, MemoryStore, Run, RunStatus,
    Store, StoredJob, channel_fn,
};

/// 2026-01-05 09:30:00 UTC, a Monday.
pub const T0: i64 = 1_767_605_400_000;
pub const MIN: i64 = 60_000;
pub const HOUR: i64 = 3_600_000;

/// A client and what a test watches it through.
pub struct Kit {
    pub cw: Client,
    pub clock: Arc<AtomicI64>,
    pub alerts: Arc<Mutex<Vec<Alert>>>,
    pub errors: Arc<Mutex<Vec<(String, String)>>>,
}

impl Kit {
    /// A client on a clock at T0 that sends to a capture channel and keeps
    /// its errors.
    pub fn new() -> Kit {
        Kit::with(|b| b)
    }

    /// `new` with more options applied after those.
    pub fn with(more: impl FnOnce(ClientBuilder) -> ClientBuilder) -> Kit {
        let clock = Arc::new(AtomicI64::new(T0));
        let alerts = Arc::new(Mutex::new(Vec::new()));
        let errors = Arc::new(Mutex::new(Vec::new()));
        let now = clock.clone();
        let sink = alerts.clone();
        let kept = errors.clone();
        let builder = Client::builder()
            .clock(move || now.load(Ordering::SeqCst))
            .alerts([channel_fn("capture", move |alert: Alert| {
                sink.lock().unwrap().push(alert);
                async { Ok(()) }
            })])
            .no_cron_secret()
            .on_error(move |err, where_| kept.lock().unwrap().push((where_.to_string(), err.to_string())));
        let cw = more(builder).build().expect("a client");
        Kit { cw, clock, alerts, errors }
    }

    pub fn now(&self) -> i64 {
        self.clock.load(Ordering::SeqCst)
    }

    pub fn advance(&self, ms: i64) {
        self.clock.fetch_add(ms, Ordering::SeqCst);
    }

    pub fn set(&self, ms: i64) {
        self.clock.store(ms, Ordering::SeqCst);
    }

    /// The type of each alert sent, in order.
    pub fn types(&self) -> Vec<String> {
        self.alerts.lock().unwrap().iter().map(|a| a.alert_type.to_string()).collect()
    }

    pub fn alert_list(&self) -> Vec<Alert> {
        self.alerts.lock().unwrap().clone()
    }

    /// The "where" of each error reported, in order.
    pub fn wheres(&self) -> Vec<String> {
        self.errors.lock().unwrap().iter().map(|e| e.0.clone()).collect()
    }

    /// The message of each error reported, in order.
    pub fn messages(&self) -> Vec<String> {
        self.errors.lock().unwrap().iter().map(|e| e.1.clone()).collect()
    }

    pub async fn runs(&self, name: &str) -> Vec<Run> {
        self.cw.runs(name, 100).await.expect("runs")
    }

    pub async fn summary(&self, name: &str) -> Option<JobSummary> {
        self.cw.job_summary(name).await.expect("a summary")
    }

    pub async fn state(&self, name: &str) -> Option<JobState> {
        self.cw.store().get_state(name).await.expect("a state")
    }

    pub async fn check(&self) -> cronwatch::CheckResult {
        self.cw.check().await.expect("a check")
    }
}

pub fn alert_types(alerts: &[Alert]) -> Vec<String> {
    alerts.iter().map(|a| a.alert_type.to_string()).collect()
}

/// An error a job returns.
#[derive(Debug)]
pub struct Boom(pub &'static str);

impl std::fmt::Display for Boom {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for Boom {}

/// Polls until `cond` holds, for work running in another task.
pub async fn wait_for<F, Fut>(what: &str, mut cond: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !cond().await {
        assert!(std::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    }
}

/// A memory store whose named methods can be made to fail.
#[derive(Default)]
pub struct TestStore {
    pub inner: MemoryStore,
    pub broken: Mutex<HashSet<&'static str>>,
    /// Whether the conditional writes are offered.
    pub no_run_if: bool,
    pub no_cas: bool,
    /// Whether `delete_run_if` is offered.
    pub no_delete: bool,
    /// Whether every compare-and-set is refused, as if another process
    /// wrote between every read and write.
    pub cas_refuses: bool,
    /// How long a state read waits after reading, as over a network.
    pub state_delay: Option<std::time::Duration>,
    /// How many times `running_runs` was called, and a gate it waits on.
    pub running_runs_calls: std::sync::atomic::AtomicUsize,
    pub running_runs_gate: tokio::sync::Mutex<()>,
}

impl TestStore {
    pub fn breaks(&self, names: &[&'static str]) {
        self.broken.lock().unwrap().extend(names);
    }

    /// Mends the named methods, or every one when none are named.
    pub fn mends(&self, names: &[&'static str]) {
        let mut broken = self.broken.lock().unwrap();
        if names.is_empty() {
            broken.clear();
        }
        for n in names {
            broken.remove(n);
        }
    }

    fn enter(&self, name: &'static str) -> Result<(), BoxError> {
        if self.broken.lock().unwrap().contains(name) {
            return Err(format!("{name} failed").into());
        }
        Ok(())
    }
}

macro_rules! guarded {
    ($self:ident, $name:literal, $call:expr) => {{
        let entered = $self.enter($name);
        Box::pin(async move {
            entered?;
            $call.await
        })
    }};
}

impl Store for TestStore {
    fn init(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        guarded!(self, "init", self.inner.init())
    }
    fn upsert_job<'a>(&'a self, d: &'a Definition, now: i64) -> BoxFuture<'a, Result<(), BoxError>> {
        guarded!(self, "upsert_job", self.inner.upsert_job(d, now))
    }
    fn get_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<Option<StoredJob>, BoxError>> {
        guarded!(self, "get_job", self.inner.get_job(name))
    }
    fn list_jobs(&self) -> BoxFuture<'_, Result<Vec<StoredJob>, BoxError>> {
        guarded!(self, "list_jobs", self.inner.list_jobs())
    }
    fn delete_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<(), BoxError>> {
        guarded!(self, "delete_job", self.inner.delete_job(name))
    }
    fn insert_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        guarded!(self, "insert_run", self.inner.insert_run(run))
    }
    fn update_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        guarded!(self, "update_run", self.inner.update_run(run))
    }
    fn get_run<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
        guarded!(self, "get_run", self.inner.get_run(id))
    }
    fn list_runs<'a>(&'a self, job: &'a str, limit: usize) -> BoxFuture<'a, Result<Vec<Run>, BoxError>> {
        guarded!(self, "list_runs", self.inner.list_runs(job, limit))
    }
    fn last_run<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
        guarded!(self, "last_run", self.inner.last_run(job))
    }
    fn running_runs(&self) -> BoxFuture<'_, Result<Vec<Run>, BoxError>> {
        let entered = self.enter("running_runs");
        self.running_runs_calls.fetch_add(1, Ordering::SeqCst);
        Box::pin(async move {
            entered?;
            drop(self.running_runs_gate.lock().await);
            self.inner.running_runs().await
        })
    }
    fn get_state<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<JobState>, BoxError>> {
        let entered = self.enter("get_state");
        Box::pin(async move {
            entered?;
            let state = self.inner.get_state(job).await;
            if let Some(delay) = self.state_delay {
                tokio::time::sleep(delay).await;
            }
            state
        })
    }
    fn set_state<'a>(&'a self, state: &'a JobState) -> BoxFuture<'a, Result<(), BoxError>> {
        guarded!(self, "set_state", self.inner.set_state(state))
    }
    fn prune(&self, before: i64) -> BoxFuture<'_, Result<u64, BoxError>> {
        guarded!(self, "prune", self.inner.prune(before))
    }
    fn close(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        self.inner.close()
    }
    fn update_run_if<'a>(&'a self, run: &'a Run, from: &'a [RunStatus]) -> BoxFuture<'a, Result<bool, BoxError>> {
        if self.no_run_if {
            return Box::pin(async { Err(cronwatch::Unsupported.into()) });
        }
        guarded!(self, "update_run_if", self.inner.update_run_if(run, from))
    }
    fn compare_and_set_state<'a>(
        &'a self,
        state: &'a JobState,
        expected: i64,
    ) -> BoxFuture<'a, Result<bool, BoxError>> {
        if self.no_cas {
            return Box::pin(async { Err(cronwatch::Unsupported.into()) });
        }
        if self.cas_refuses {
            return Box::pin(async { Ok(false) });
        }
        guarded!(self, "compare_and_set_state", self.inner.compare_and_set_state(state, expected))
    }
    fn delete_run_if<'a>(
        &'a self,
        id: &'a str,
        job: &'a str,
        status: &'a RunStatus,
    ) -> BoxFuture<'a, Result<bool, BoxError>> {
        if self.no_delete {
            return Box::pin(async { Err(cronwatch::Unsupported.into()) });
        }
        guarded!(self, "delete_run_if", self.inner.delete_run_if(id, job, status))
    }
}
