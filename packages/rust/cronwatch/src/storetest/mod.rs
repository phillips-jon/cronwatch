//! The test every CronWatch store passes: the memory store, and
//! `cronwatch-sqlx` on SQLite. It is the SDK's store-conformance.ts, a
//! replay of the store cases in the repository's `conformance/store.json`,
//! and the SDK's finish-once tests over several stores on one database. Run
//! it against a store of your own, from a test on a tokio runtime
//! (`#[tokio::test]`):
//!
//! ```no_run
//! # use cronwatch::MemoryStore as MyStore;
//! # async fn my_store_passes_the_contract() {
//! cronwatch::storetest::run(|| MyStore::new()).await;
//! # }
//! ```
//!
//! Each function panics, as a test's assertion does, at the first thing the
//! store gets wrong.

mod finish_once;

use std::fmt::Debug;
use std::sync::{Arc, Mutex};

use crate::deliver::{Channel, ChannelContext};
use crate::js::{self, Object, Value};
use crate::store::{BoxError, BoxFuture, Store};
use crate::types::{Alert, Definition, JobState, Metrics, Run, RunStatus};
use crate::{Client, Error};

pub use finish_once::{Shared, finish_once};

/// Monday 2026-01-05 09:30:00Z, the SDK tests' clock start.
pub const T0: i64 = 1_767_605_400_000;

/// A run as the contract test writes them: finished ten milliseconds after
/// it started unless it is running, with one metric.
pub fn new_run(id: &str, job: &str, status: RunStatus, started_at: i64) -> Run {
    let finished = status != RunStatus::Running;
    Run {
        id: id.into(),
        job: job.into(),
        status,
        started_at,
        finished_at: finished.then_some(started_at + 10),
        duration_ms: finished.then_some(10),
        error: None,
        output: None,
        metrics: [("n", 1.0)].into_iter().collect(),
        trigger: "run".into(),
    }
}

/// The fixture script's run: as [`new_run`], with no metrics.
pub fn new_run_plain(id: &str, job: &str, status: RunStatus, started_at: i64) -> Run {
    Run { metrics: Metrics::new(), ..new_run(id, job, status, started_at) }
}

/// A stored definition from its JSON.
pub fn definition(text: &str) -> Definition {
    Definition::from_json(text).unwrap_or_else(|e| panic!("definition {text}: {e}"))
}

/// A job state from its JSON.
pub fn state(text: &str) -> JobState {
    JobState::from_json(text).unwrap_or_else(|e| panic!("state {text}: {e}"))
}

/// JSON with every object's keys sorted, so two values compare whatever order
/// a JSON column (Postgres's JSONB) gave an object's keys back in.
pub fn canonical(text: &str) -> String {
    fn write(v: &Value) -> String {
        match v {
            Value::Object(o) => {
                let mut pairs: Vec<(&str, &Value)> = o.iter().collect();
                pairs.sort_by(|a, b| a.0.cmp(b.0));
                let body: Vec<String> = pairs.iter().map(|(k, v)| format!("{}:{}", js::quote(k), write(v))).collect();
                format!("{{{}}}", body.join(","))
            }
            Value::Array(a) => format!("[{}]", a.iter().map(write).collect::<Vec<_>>().join(",")),
            other => other.to_json(),
        }
    }
    js::parse(text).map_or_else(|_| text.to_string(), |v| write(&v))
}

/// Asserts two JSON texts are the same value, keys in any order.
#[track_caller]
pub fn same_json(what: &str, got: &str, want: &str) {
    assert_eq!(canonical(got), canonical(want), "{what}:\n got {got}\nwant {want}");
}

fn json_of<T>(v: &Option<T>, to_json: impl Fn(&T) -> String) -> String {
    v.as_ref().map_or("null".into(), to_json)
}

fn ids(runs: &[Run]) -> Vec<String> {
    runs.iter().map(|r| r.id.clone()).collect()
}

#[track_caller]
fn must<T, E: Debug>(r: Result<T, E>) -> T {
    match r {
        Ok(v) => v,
        Err(e) => panic!("{e:?}"),
    }
}

#[track_caller]
fn eq<T: PartialEq + Debug>(what: &str, got: T, want: T) {
    assert_eq!(got, want, "{what}");
}

fn with(mut r: Run, change: impl FnOnce(&mut Run)) -> Run {
    change(&mut r);
    r
}

/// The contract test: store-conformance.ts, step for step. `make` is called
/// once and must return an empty store.
pub async fn run<S: Store>(make: impl FnOnce() -> S) {
    let store = make();
    must(store.init().await);
    eq("no job yet", must(store.get_job("a").await).is_none(), true);
    must(store.upsert_job(&definition(r#"{"name":"a","schedule":"every 5m"}"#), 100).await);
    must(store.upsert_job(&definition(r#"{"name":"a","schedule":"every 10m","tags":["x"]}"#), 200).await);
    for name in ["b", "B", "_c"] {
        must(store.upsert_job(&definition(&format!(r#"{{"name":"{name}"}}"#)), 300).await);
    }
    let a = must(store.get_job("a").await).expect("job a");
    eq("createdAt survives upsert", a.created_at, 100);
    eq("updatedAt", a.updated_at, 200);
    same_json("definition", &a.definition.to_json(), r#"{"name":"a","schedule":"every 10m","tags":["x"]}"#);
    let names: Vec<String> = must(store.list_jobs().await).into_iter().map(|j| j.name).collect();
    eq("byte order, not locale", names, vec!["B".to_string(), "_c".into(), "a".into(), "b".into()]);

    for r in [
        new_run("r1", "a", RunStatus::Ok, 1000),
        new_run("r2", "a", RunStatus::Failed, 2000),
        new_run("r3", "a", RunStatus::Running, 3000),
        new_run("r4", "b", RunStatus::Ok, 1500),
        new_run("rb", "B", RunStatus::Running, 2000),
        new_run("rc", "_c", RunStatus::Running, 2000),
    ] {
        must(store.insert_run(&r).await);
    }
    eq("newest first", ids(&must(store.list_runs("a", 10).await)), vec!["r3".to_string(), "r2".into(), "r1".into()]);
    eq("limit", ids(&must(store.list_runs("a", 2).await)), vec!["r3".to_string(), "r2".into()]);
    eq("last run", must(store.last_run("a").await).map(|r| r.id), Some("r3".into()));
    eq("no last run", must(store.last_run("none").await).is_none(), true);
    eq(
        "oldest first, then insertion order",
        ids(&must(store.running_runs().await)),
        vec!["rb".to_string(), "rc".into(), "r3".into()],
    );
    let r1 = must(store.get_run("r1").await).expect("r1");
    same_json("metrics", &r1.metrics.to_json(), r#"{"n":1}"#);
    eq("durationMs", r1.duration_ms, Some(10));

    let updated = with(new_run("r3", "a", RunStatus::Ok, 3000), |r| {
        r.output = Some("line1\nline2".into());
        r.metrics = [("cost", 0.25)].into_iter().collect();
    });
    must(store.update_run(&updated).await);
    let r3 = must(store.get_run("r3").await).expect("r3");
    eq("status", r3.status, RunStatus::Ok);
    eq("output", r3.output.as_deref(), Some("line1\nline2"));
    same_json("updated metrics", &r3.metrics.to_json(), r#"{"cost":0.25}"#);
    eq("running after update", ids(&must(store.running_runs().await)), vec!["rb".to_string(), "rc".into()]);

    // update_run_if writes only over a row whose status is one of those
    // given, and says whether it did.
    assert!(
        store.insert_run(&new_run("r3", "a", RunStatus::Running, 3000)).await.is_err(),
        "an id already recorded is refused"
    );
    must(store.upsert_job(&definition(r#"{"name":"q"}"#), 300).await);
    must(store.insert_run(&new_run("rx", "q", RunStatus::Running, 2500)).await);
    let running1 = [RunStatus::Running];
    let both = [RunStatus::Running, RunStatus::Timeout];
    let first = with(new_run("rx", "q", RunStatus::Failed, 2500), |r| r.error = Some("first".into()));
    eq("first finish", must(store.update_run_if(&first, &running1).await), true);
    let second = with(new_run("rx", "q", RunStatus::Ok, 2500), |r| r.output = Some("second".into()));
    eq("a second finish over the first is refused", must(store.update_run_if(&second, &running1).await), false);
    eq("first error kept", must(store.get_run("rx").await).and_then(|r| r.error), Some("first".into()));
    let late = with(new_run("rx", "q", RunStatus::Ok, 2500), |r| r.output = Some("late".into()));
    eq("not over failed", must(store.update_run_if(&late, &both).await), false);
    must(
        store.update_run(&with(new_run("rx", "q", RunStatus::Timeout, 2500), |r| r.error = Some("stuck".into()))).await,
    );
    let late = with(new_run("rx", "q", RunStatus::Ok, 2500), |r| {
        r.output = Some("late".into());
        r.metrics = [("m", 2.0)].into_iter().collect();
    });
    eq("any of the statuses given", must(store.update_run_if(&late, &both).await), true);
    same_json(
        "late finish",
        &json_of(&must(store.get_run("rx").await), Run::to_json),
        r#"{"id":"rx","job":"q","status":"ok","startedAt":2500,"finishedAt":2510,"durationMs":10,"error":null,"output":"late","metrics":{"m":2},"trigger":"run"}"#,
    );
    let missing = new_run("missing", "q", RunStatus::Ok, 1);
    eq("a run that is not there is not written", must(store.update_run_if(&missing, &running1).await), false);
    eq("still missing", must(store.get_run("missing").await).is_none(), true);
    let failed = new_run("rx", "q", RunStatus::Failed, 2500);
    eq("no statuses, no write", must(store.update_run_if(&failed, &[]).await), false);
    eq("still ok", must(store.get_run("rx").await).map(|r| r.status), Some(RunStatus::Ok));

    // delete_run_if, for a store that has it, takes back only a run still of
    // the job and in the status given.
    must(store.insert_run(&new_run("rd", "q", RunStatus::Running, 2600)).await);
    match store.delete_run_if("rd", "a", &RunStatus::Running).await {
        Err(err) if crate::store::is_unsupported(&err) => {}
        deleted => {
            eq("not another job's", must(deleted), false);
            eq("not in another status", must(store.delete_run_if("rd", "q", &RunStatus::Ok).await), false);
            eq("not a finished run", must(store.delete_run_if("rx", "q", &RunStatus::Running).await), false);
            eq("taken back", must(store.delete_run_if("rd", "q", &RunStatus::Running).await), true);
            eq("gone", must(store.get_run("rd").await).is_none(), true);
            eq("only once", must(store.delete_run_if("rd", "q", &RunStatus::Running).await), false);
            eq("the finished run kept", must(store.get_run("rx").await).is_some(), true);
        }
    }
    must(store.delete_job("q").await);

    // Forgetting a job while one of its runs is in flight: the run finishing
    // later changes nothing.
    must(store.delete_job("B").await);
    must(store.update_run(&with(new_run("rb", "B", RunStatus::Ok, 2000), |r| r.output = Some("late".into()))).await);
    eq("forgotten run stays gone", must(store.get_run("rb").await).is_none(), true);
    eq("no runs of a forgotten job", ids(&must(store.list_runs("B", 10).await)), Vec::<String>::new());
    eq("running after forgetting", ids(&must(store.running_runs().await)), vec!["rc".to_string()]);
    must(store.delete_job("_c").await);

    eq("no state yet", must(store.get_state("a").await).is_none(), true);
    must(
        store
            .set_state(&state(
                r#"{"job":"a","open":{"failed":5},"consecutiveFailures":2,"silencedUntil":null,"lastAlertAt":6}"#,
            ))
            .await,
    );
    let plain = r#"{"job":"a","open":{},"consecutiveFailures":0,"silencedUntil":99,"lastAlertAt":6}"#;
    must(store.set_state(&state(plain)).await);
    same_json("state", &json_of(&must(store.get_state("a").await), JobState::to_json), plain);
    let full = concat!(
        r#"{"job":"a","open":{"stuck":7},"consecutiveFailures":1,"silencedUntil":null,"lastAlertAt":6,"pendingRecovery":["missed"],"undelivered":["#,
        r#"{"type":"failed","run":null,"details":{"consecutiveFailures":1,"threshold":1},"job":"a","definition":{"name":"a"},"title":"a failed","message":"boom","at":7,"triage":null}]}"#
    );
    must(store.set_state(&state(full)).await);
    same_json(
        "pendingRecovery and undelivered round-trip",
        &json_of(&must(store.get_state("a").await), JobState::to_json),
        full,
    );
    must(store.set_state(&state(plain)).await);

    // compare_and_set_state writes only over the version it was told to expect.
    let v = |version: i64, failures: &str| {
        state(&format!(
            r#"{{"job":"v","open":{{}},"consecutiveFailures":{failures},"silencedUntil":null,"lastAlertAt":null,"version":{version}}}"#
        ))
    };
    let cas_is = |what: &'static str, st: JobState, expected: i64, want: bool| {
        let store = &store;
        async move {
            eq(what, must(store.compare_and_set_state(&st, expected).await), want);
        }
    };
    cas_is("no row matches only version 0", v(2, "0"), 1, false).await;
    eq("nothing written", must(store.get_state("v").await).is_none(), true);
    cas_is("no row counts as version 0", v(1, "0"), 0, true).await;
    cas_is("a write from a stale read is refused", v(1, "9"), 0, false).await;
    cas_is("the version read", v(2, "1"), 1, true).await;
    cas_is("an older version", v(3, "0"), 1, false).await;
    same_json(
        "state after writes",
        &json_of(&must(store.get_state("v").await), JobState::to_json),
        &v(2, "1").to_json(),
    );
    must(
        store
            .set_state(&state(
                r#"{"job":"w","open":{},"consecutiveFailures":3,"silencedUntil":null,"lastAlertAt":null}"#,
            ))
            .await,
    );
    let w1 =
        state(r#"{"job":"w","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"version":1}"#);
    cas_is("state written before versions counts as 0", w1.clone(), 1, false).await;
    cas_is("from 0", w1, 0, true).await;
    eq("version", must(store.get_state("w").await).and_then(|s| s.version), Some(1));
    must(store.delete_job("v").await);
    cas_is("a forgotten job's state is not written back", v(3, "0"), 2, false).await;
    eq("gone", must(store.get_state("v").await).is_none(), true);
    must(store.delete_job("w").await);

    must(store.insert_run(&new_run("r5", "a", RunStatus::Running, 500)).await);
    eq("r1 and r2 pruned; running r5 kept, and b's r4 kept as b's newest run", must(store.prune(2500).await), 2);
    eq("a after prune", ids(&must(store.list_runs("a", 10).await)), vec!["r3".to_string(), "r5".into()]);
    eq("b after prune", ids(&must(store.list_runs("b", 10).await)), vec!["r4".to_string()]);
    eq("however old, each job keeps its newest run, and running runs stay", must(store.prune(1_000_000).await), 0);

    must(store.delete_job("a").await);
    eq("job deleted", must(store.get_job("a").await).is_none(), true);
    eq("runs deleted", ids(&must(store.list_runs("a", 10).await)), Vec::<String>::new());
    eq("state deleted", must(store.get_state("a").await).is_none(), true);
    eq("b kept", must(store.get_job("b").await).map(|j| j.name), Some("b".into()));
    must(store.close().await);
}

fn field<'a>(o: &'a Object, key: &str) -> &'a Value {
    o.get(key).unwrap_or_else(|| panic!("the fixture has no {key:?}"))
}

fn objects(v: &Value) -> Vec<&Object> {
    v.as_array().map(|a| a.iter().filter_map(Value::as_object).collect()).unwrap_or_default()
}

fn fixture_run(v: &Value) -> Run {
    must(Run::from_value(v))
}

/// Replays the store cases of `conformance/store.json` (its text, which the
/// caller reads, since a published crate cannot reach the repository)
/// against stores from `make`, which must each be empty: prune scripts,
/// `compare_and_set_state` steps and `update_run_if` steps, each read back and
/// compared with what the SDK's memory store answered. Returns how many
/// cases were replayed.
pub async fn replay_fixture<S: Store>(fixture: &str, mut make: impl FnMut() -> S) -> usize {
    let root = must(js::parse(fixture));
    let fix = root.as_object().expect("the fixture is an object");
    let mut cases = 0;
    for script in objects(field(fix, "prune")) {
        let name = field(script, "name").as_str().unwrap_or("").to_string();
        let store = make();
        must(store.init().await);
        for event in objects(field(script, "events")) {
            if let Some(inserts) = event.get("insert") {
                for v in inserts.as_array().into_iter().flatten() {
                    must(store.insert_run(&fixture_run(v)).await);
                }
                continue;
            }
            let before = field(event, "prune").as_f64().unwrap_or(0.0) as i64;
            let pruned = must(store.prune(before).await);
            eq(&format!("{name}: pruned"), pruned, field(event, "pruned").as_f64().unwrap_or(-1.0) as u64);
            let remaining = field(event, "remaining").as_object().expect("remaining");
            for (job, want) in remaining.iter() {
                let want: Vec<String> =
                    want.as_array().into_iter().flatten().filter_map(|v| v.as_str().map(String::from)).collect();
                eq(&format!("{name}: {job} kept"), ids(&must(store.list_runs(job, 100).await)), want);
            }
            cases += 1;
        }
        must(store.close().await);
    }

    let store = make();
    must(store.init().await);
    for (i, step) in objects(field(fix, "compareAndSetState")).into_iter().enumerate() {
        if let Some(st) = step.get("cas") {
            let st = must(JobState::from_value(st));
            let expected = field(step, "expected").as_f64().unwrap_or(0.0) as i64;
            let wrote = must(store.compare_and_set_state(&st, expected).await);
            eq(&format!("compareAndSetState step {i}: wrote"), Some(wrote), field(step, "written").as_bool());
        } else if let Some(st) = step.get("set") {
            must(store.set_state(&must(JobState::from_value(st))).await);
        } else {
            must(store.delete_job(field(step, "forget").as_str().unwrap_or("")).await);
        }
        for (job, want) in field(step, "states").as_object().expect("states").iter() {
            let got = json_of(&must(store.get_state(job).await), JobState::to_json);
            same_json(&format!("compareAndSetState step {i}, state of {job}"), &got, &want.to_json());
        }
        cases += 1;
    }
    must(store.close().await);

    let store = make();
    must(store.init().await);
    must(store.insert_run(&new_run_plain("u1", "a", RunStatus::Running, 1000)).await);
    for (i, step) in objects(field(fix, "updateRunIf")).into_iter().enumerate() {
        if let Some(r) = step.get("set") {
            must(store.update_run(&fixture_run(r)).await);
        } else if let Some(r) = step.get("insert") {
            let outcome = if store.insert_run(&fixture_run(r)).await.is_ok() { "inserted" } else { "refused" };
            eq(&format!("updateRunIf step {i}"), Some(outcome), field(step, "outcome").as_str());
        } else {
            let from: Vec<RunStatus> = field(step, "from")
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|s| s.as_str().map(RunStatus::parse))
                .collect();
            let wrote = must(store.update_run_if(&fixture_run(field(step, "run")), &from).await);
            eq(&format!("updateRunIf step {i}: wrote"), Some(wrote), field(step, "outcome").as_bool());
        }
        let got = json_of(&must(store.get_run("u1").await), Run::to_json);
        same_json(&format!("updateRunIf step {i}"), &got, &field(step, "stored").to_json());
        cases += 1;
    }
    must(store.close().await);
    assert!(cases > 0, "no cases replayed");
    cases
}

/// A settable clock for a client, in epoch milliseconds.
#[derive(Clone, Debug)]
pub struct Clock(Arc<std::sync::atomic::AtomicI64>);

impl Clock {
    /// A clock at `start`.
    pub fn new(start: i64) -> Clock {
        Clock(Arc::new(std::sync::atomic::AtomicI64::new(start)))
    }

    /// The time.
    pub fn now(&self) -> i64 {
        self.0.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Moves the clock on by `ms` and answers the new time.
    pub fn advance(&self, ms: i64) -> i64 {
        self.0.fetch_add(ms, std::sync::atomic::Ordering::SeqCst) + ms
    }

    /// Moves the clock to `t`.
    pub fn set(&self, t: i64) {
        self.0.store(t, std::sync::atomic::Ordering::SeqCst);
    }
}

/// A channel that keeps the alerts it is sent.
#[derive(Clone, Debug, Default)]
pub struct Capture(Arc<Mutex<Vec<Alert>>>);

impl Capture {
    /// A copy of the kept alerts, in order.
    pub fn list(&self) -> Vec<Alert> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The kept alerts' types, in order.
    pub fn types(&self) -> Vec<String> {
        self.list().iter().map(|a| a.alert_type.to_string()).collect()
    }
}

impl Channel for Capture {
    fn name(&self) -> &str {
        "capture"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).push(alert.clone());
        Box::pin(std::future::ready(Ok(())))
    }
}

/// Keeps what a client reports, as `where: message`.
#[derive(Clone, Debug, Default)]
pub struct Errors(Arc<Mutex<Vec<String>>>);

impl Errors {
    /// Keeps an error.
    pub fn add(&self, err: &Error, where_: &str) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).push(format!("{where_}: {err}"));
    }

    /// What was kept.
    pub fn list(&self) -> Vec<String> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

/// One client over a shared store, as one process would have.
#[derive(Clone, Debug)]
pub struct Process {
    pub client: Client,
    pub alerts: Capture,
    pub errors: Errors,
}

impl Process {
    /// A client over `store`, with a capture channel and an error list. Call
    /// it on a tokio runtime.
    pub fn new(store: Arc<dyn Store>, clock: &Clock) -> Process {
        let alerts = Capture::default();
        let errors = Errors::default();
        let (clock, errs) = (clock.clone(), errors.clone());
        let client = Client::builder()
            .store_arc(store)
            .clock(move || clock.now())
            .alerts([Arc::new(alerts.clone()) as Arc<dyn Channel>])
            .no_cron_secret()
            .on_error(move |err, where_| errs.add(err, where_))
            .build()
            .expect("a client");
        Process { client, alerts, errors }
    }
}
