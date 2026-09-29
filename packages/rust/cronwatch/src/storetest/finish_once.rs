//! finish-once.test.ts's tests over several stores sharing one database:
//! however many processes finish a run, it is recorded and judged once.

use std::sync::Arc;

use tokio::task::JoinSet;

use super::{Clock, Process, T0};
use crate::options::JobOptions;
use crate::run::{RecordOptions, StartOptions};
use crate::store::Store;
use crate::types::{Metrics, Run, RunStatus};

const MIN: i64 = 60_000;

/// Stores over one database, as several processes would have them: each
/// call to `open` is another store on the same data, and `done` closes them
/// and drops the data at the end.
pub struct Shared {
    pub open: Box<dyn FnMut() -> Arc<dyn Store> + Send>,
    pub done: Box<dyn FnOnce() + Send>,
}

fn failed(id: &str, job: &str, started_at: i64) -> Run {
    Run {
        id: id.into(),
        job: job.into(),
        status: RunStatus::Failed,
        started_at,
        finished_at: Some(started_at + 1000),
        duration_ms: Some(1000),
        error: Some("ERROR: deadlock detected".into()),
        output: None,
        metrics: Metrics::new(),
        trigger: "pg_cron".into(),
    }
}

fn count(runs: &[Option<Run>]) -> usize {
    runs.iter().filter(|r| r.is_some()).count()
}

/// The three scenarios, each over a fresh database from `shared`. Call it
/// on a multi-threaded tokio runtime, so the processes race for real.
pub async fn finish_once(mut shared: impl FnMut() -> Shared) {
    two_processes_finishing_one_run(shared()).await;
    two_processes_recording_one_finished_run(shared()).await;
    many_processes_starting_and_finishing_one_id(shared()).await;
}

/// Two processes finishing one run: one records and judges it, the other
/// reports it already finished.
async fn two_processes_finishing_one_run(mut s: Shared) {
    let clock = Clock::new(T0);
    let one = Process::new((s.open)(), &clock);
    let two = Process::new((s.open)(), &clock);
    let options = || JobOptions::new().failures_before_alert(2);
    let job = one.client.job("webhook-ingest", options()).expect("a job");
    two.client.job("webhook-ingest", options()).expect("a job");
    job.start(StartOptions::new().id("delivery-1")).await.expect("a start");
    let h1 = one.client.resume_run("webhook-ingest", "delivery-1").await.expect("a handle");
    let h2 = two.client.resume_run("webhook-ingest", "delivery-1").await.expect("a handle");
    clock.advance(MIN);
    let mut set = JoinSet::new();
    for h in [h1, h2] {
        set.spawn(async move { h.fail("upstream 502").await });
    }
    let results: Vec<Option<Run>> = set.join_all().await;
    assert_eq!(count(&results), 1, "finishes recorded");
    let errors = [one.errors.list(), two.errors.list()].concat();
    assert!(
        errors.iter().any(|e| e.contains("already finished as failed; ignored")),
        "no process reported the run already finished: {errors:?}"
    );
    assert_eq!(one.client.runs("webhook-ingest", 50).await.expect("runs").len(), 1, "one run");
    let state = one.client.store().get_state("webhook-ingest").await.expect("a state").expect("a state");
    assert_eq!(state.consecutive_failures, 1, "the failure counted once");
    let types = [one.alerts.types(), two.alerts.types()].concat();
    assert!(types.is_empty(), "one failure is below failuresBeforeAlert 2: {types:?}");
    (s.done)();
}

/// Two processes recording one finished run from a source: it is judged once.
async fn two_processes_recording_one_finished_run(mut s: Shared) {
    let clock = Clock::new(T0);
    let one = Process::new((s.open)(), &clock);
    let two = Process::new((s.open)(), &clock);
    for p in [&one, &two] {
        p.client.job("db:rollup", JobOptions::new().failures_before_alert(2)).expect("a job");
    }
    let at = T0 - MIN;
    let running = Run {
        status: RunStatus::Running,
        finished_at: None,
        duration_ms: None,
        error: None,
        ..failed("pgcron:9", "db:rollup", at)
    };
    one.client.record_run(running, RecordOptions::new()).await.expect("recorded");
    two.client.jobs().await.expect("jobs");
    let mut set = JoinSet::new();
    for p in [one.clone(), two.clone()] {
        set.spawn(async move { p.client.record_run(failed("pgcron:9", "db:rollup", at), RecordOptions::new()).await });
    }
    for result in set.join_all().await {
        result.expect("recorded");
    }
    let state = one.client.store().get_state("db:rollup").await.expect("a state").expect("a state");
    assert_eq!(state.consecutive_failures, 1, "judged once");
    let types = [one.alerts.types(), two.alerts.types()].concat();
    assert!(types.is_empty(), "alerts {types:?}");
    // The SDK's two promises both read the run as running before either
    // writes, so one always reports the other's finish. Tasks may instead
    // read it after the first finish landed, and a run already finished is
    // left alone without a word; either way the only thing either process
    // may report is that finish.
    for e in [one.errors.list(), two.errors.list()].concat() {
        assert!(e.contains("pgcron:9 of db:rollup was already finished as failed; ignored"), "unexpected error: {e}");
    }
    (s.done)();
}

/// Many processes starting and finishing one id: exactly one finish is
/// recorded.
async fn many_processes_starting_and_finishing_one_id(mut s: Shared) {
    let clock = Clock::new(T0);
    let procs: Vec<Process> = (0..6).map(|_| Process::new((s.open)(), &clock)).collect();
    let jobs: Vec<_> = procs.iter().map(|p| p.client.job("ingest", JobOptions::new()).expect("a job")).collect();
    procs[0].client.check().await.expect("a check");
    for k in 0..5 {
        let id = format!("evt_{k}");
        let mut set = JoinSet::new();
        for job in &jobs {
            let (job, id) = (job.clone(), id.clone());
            set.spawn(async move { job.start(StartOptions::new().id(id)).await.expect("a start") });
        }
        let handles = set.join_all().await;
        let mut set = JoinSet::new();
        for (i, h) in handles.into_iter().enumerate() {
            set.spawn(async move { h.finish_with(format!("worker {i}")).await });
        }
        let finished = set.join_all().await;
        assert_eq!(count(&finished), 1, "{id}: finishes recorded");
    }
    let runs = procs[0].client.runs("ingest", 500).await.expect("runs");
    assert_eq!(runs.len(), 5, "runs");
    for r in &runs {
        assert_eq!(r.status, RunStatus::Ok, "run {}", r.id);
    }
    let unexpected: Vec<String> =
        procs.iter().flat_map(|p| p.errors.list()).filter(|e| !e.contains("already finished")).collect();
    assert!(unexpected.is_empty(), "unexpected errors: {unexpected:?}");
    (s.done)();
}
