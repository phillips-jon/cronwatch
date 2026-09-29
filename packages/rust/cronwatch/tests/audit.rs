//! What the audit before the first release found in the client, each with
//! the case that shows it fixed (DESIGN.md, Phases, 5).

mod common;

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::{Boom, Kit, TestStore, wait_for};
use cronwatch::web::Request;
use cronwatch::{Alert, Client, HandlerOptions, JobOptions, Matcher, Run, RunOptions, RunStatus, channel_fn};

fn alive() -> usize {
    tokio::runtime::Handle::current().metrics().num_alive_tasks()
}

#[tokio::test]
async fn a_dropped_run_leaves_no_task_behind() {
    let k = Kit::new();
    let job = k.cw.job("dropped", JobOptions::new()).unwrap();
    let before = alive();
    let outcome = tokio::time::timeout(
        Duration::from_millis(20),
        job.run(|_| async {
            std::future::pending::<()>().await;
            Ok::<(), Boom>(())
        }),
    )
    .await;
    assert!(outcome.is_err(), "the timeout dropped the run");
    wait_for("the dropped run to be recorded", || async {
        k.runs("dropped").await.first().is_some_and(|r| r.status == RunStatus::Failed)
    })
    .await;
    // The job's timeout timer (an hour by default) went with the run.
    wait_for("the run's tasks to end", || async { alive() <= before }).await;
}

#[tokio::test]
async fn a_run_dropped_while_it_is_given_back_is_still_recorded() {
    let store =
        Arc::new(TestStore { no_delete: true, delete_delay: Some(Duration::from_millis(100)), ..Default::default() });
    let k = Kit::with(|b| b.store_arc(store.clone()));
    let job = k.cw.job("q", JobOptions::new()).unwrap();
    let outcome = tokio::time::timeout(
        Duration::from_millis(30),
        job.run_or_discard(RunOptions::new(), |_: &Boom| true, |_| async { Err::<(), _>(Boom("snoozed")) }),
    )
    .await;
    assert!(outcome.is_err(), "dropped while the store was asked to take the run back");
    // The store could not take it back, so it is recorded as it ended
    // rather than left running.
    wait_for("the run to be recorded", || async {
        k.runs("q").await.first().is_some_and(|r| r.status == RunStatus::Failed)
    })
    .await;
    assert_eq!(k.runs("q").await[0].error.as_deref(), Some("Boom: snoozed"));
}

struct Grumpy;

impl std::fmt::Display for Grumpy {
    fn fmt(&self, _: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        panic!("no words")
    }
}

#[tokio::test]
async fn an_error_whose_display_panics_fails_its_run() {
    let k = Kit::new();
    let job = k.cw.job("grumpy", JobOptions::new()).unwrap();
    let result = job.run(|_| async { Err::<(), _>(Grumpy) }).await;
    assert!(result.is_err(), "the error is still returned");
    let run = &k.runs("grumpy").await[0];
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.error.as_deref(), Some("Grumpy: its Display panicked: no words"));
}

#[tokio::test]
async fn a_function_that_panics_before_its_future_is_a_panicked_run() {
    let k = Kit::new();
    let job = k.cw.job("eager", JobOptions::new()).unwrap();
    let j = job.clone();
    let joined = tokio::spawn(async move {
        j.run(|_| -> std::future::Ready<Result<(), Boom>> { panic!("before its future") }).await
    })
    .await;
    assert!(joined.expect_err("the panic is resumed").is_panic());
    let run = &k.runs("eager").await[0];
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.error.as_deref(), Some("panic: before its future"));
    assert_eq!(k.types(), ["failed"]);

    // A handler answers it 500, as it answers any panic.
    let h = k.cw.job("eager-handler", JobOptions::new()).unwrap().handler(
        |_, _| -> std::future::Ready<Result<(), std::io::Error>> { panic!("before its future") },
        HandlerOptions::new().no_secret(),
    );
    let res = h.handle(Request::new("GET", "/")).await;
    assert_eq!(res.status, 500);
    assert_eq!(k.runs("eager-handler").await[0].error.as_deref(), Some("panic: before its future"));
}

#[tokio::test]
async fn the_context_is_current_before_the_functions_future() {
    let k = Kit::new();
    let job = k.cw.job("sync-part", JobOptions::new()).unwrap();
    job.run(|_| {
        cronwatch::current().expect("inside the run").log("from the sync part");
        async { Ok::<_, Boom>(()) }
    })
    .await
    .unwrap();
    assert_eq!(k.runs("sync-part").await[0].output.as_deref(), Some("from the sync part"));
}

struct Picky;

impl Matcher for Picky {
    fn is_match(&self, _: &str) -> bool {
        panic!("cannot read it")
    }
    fn source(&self) -> String {
        "/picky/".into()
    }
}

#[tokio::test]
async fn a_matcher_that_panics_fails_the_run() {
    let k = Kit::new();
    let job = k.cw.job("picky", JobOptions::new().expect_match(Picky)).unwrap();
    job.run(|_| async { Ok::<_, Boom>("output") }).await.unwrap();
    let run = &k.runs("picky").await[0];
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.error.as_deref(), Some("Output check threw: cannot read it"));
}

#[tokio::test]
async fn a_store_that_panics_while_recording_is_reported() {
    let store = Arc::new(TestStore::default());
    let k = Kit::with(|b| b.store_arc(store.clone()));
    let job = k.cw.job("x", JobOptions::new()).unwrap();
    store.panicking.lock().unwrap().insert("update_run_if");
    job.run(|_| async { Ok::<_, Boom>(()) }).await.unwrap();
    assert!(
        k.errors.lock().unwrap().contains(&("recording x".to_string(), "panicked: update_run_if panicked".to_string())),
        "{:?}",
        k.errors.lock().unwrap()
    );
}

#[tokio::test]
async fn a_handles_finish_dropped_part_way_still_finishes() {
    let store = Arc::new(TestStore { state_delay: Some(Duration::from_millis(50)), ..Default::default() });
    let k = Kit::with(|b| b.store_arc(store.clone()));
    let job = k.cw.job("h", JobOptions::new()).unwrap();
    let handle = job.start(cronwatch::StartOptions::new()).await.unwrap();
    handle.log("a line");
    let dropped = tokio::time::timeout(Duration::from_millis(10), handle.finish()).await;
    assert!(dropped.is_err(), "the finish was dropped while the store read the state");
    wait_for("the finish to land", || async { k.runs("h").await.first().is_some_and(|r| r.status == RunStatus::Ok) })
        .await;
    assert_eq!(k.runs("h").await[0].output.as_deref(), Some("a line"));
}

#[tokio::test(start_paused = true)]
async fn start_holds_its_interval_at_the_sdks_longest() {
    let store = Arc::new(TestStore::default());
    let k = Kit::with(|b| b.store_arc(store.clone()));
    k.cw.start(Duration::MAX);
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(store.running_runs_calls.load(Ordering::SeqCst), 1, "the first check ran");
    k.cw.stop();
}

#[tokio::test(start_paused = true)]
async fn a_long_check_is_not_followed_by_the_ticks_it_missed() {
    let store = Arc::new(TestStore::default());
    let k = Kit::with(|b| b.store_arc(store.clone()));
    let gate = store.running_runs_gate.lock().await;
    k.cw.start(Duration::from_secs(5));
    // The first check, a second in, waits on the store for half a minute.
    tokio::time::sleep(Duration::from_secs(31)).await;
    assert_eq!(store.running_runs_calls.load(Ordering::SeqCst), 1);
    drop(gate);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(store.running_runs_calls.load(Ordering::SeqCst), 1, "no burst of the ticks it missed");
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert_eq!(store.running_runs_calls.load(Ordering::SeqCst), 2, "the next tick on the interval");
    k.cw.stop();
}

#[tokio::test]
async fn a_foreign_rows_far_times_do_not_fail_the_check() {
    let k = Kit::new();
    k.cw.job("far", JobOptions::new().schedule("every 5m"))
        .unwrap()
        .run(|_| async { Ok::<_, Boom>(()) })
        .await
        .unwrap();
    k.cw.job("old", JobOptions::new()).unwrap().run(|_| async { Ok::<_, Boom>(()) }).await.unwrap();
    let mut far = k.runs("far").await[0].clone();
    far.id = "far-future".into();
    far.started_at = i64::MAX - 1;
    k.cw.store().insert_run(&far).await.unwrap();
    let mut old =
        Run::from_json(r#"{"id":"long-ago","job":"old","status":"running","startedAt":0,"trigger":"run"}"#).unwrap();
    old.started_at = i64::MIN + 1;
    k.cw.store().insert_run(&old).await.unwrap();
    k.cw.check().await.expect("the check goes through");
    assert!(k.cw.jobs().await.is_ok());
    let routes = k.cw.routes(cronwatch::web::RoutesOptions::new().no_token()).unwrap();
    for target in ["/cronwatch", "/cronwatch/jobs/far", "/cronwatch/jobs/old", "/cronwatch/api/jobs"] {
        let res = routes.handle(Request::new("GET", target).with_header("host", "localhost")).await;
        assert_eq!(res.status, 200, "{target}");
    }
}

#[tokio::test]
async fn alert_keeps_every_channel_given() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let channel = |name: &'static str| {
        let seen = seen.clone();
        channel_fn(name, move |_: Alert| {
            seen.lock().unwrap().push(name);
            async { Ok(()) }
        })
    };
    let cw = Client::builder().alert(channel("console")).alert(channel("second")).build().unwrap();
    cw.job("two", JobOptions::new()).unwrap().run(|_| async { Err::<(), _>(Boom("down")) }).await.unwrap_err();
    wait_for("both channels", || async { seen.lock().unwrap().len() == 2 }).await;
    let mut names = seen.lock().unwrap().clone();
    names.sort_unstable();
    assert_eq!(names, ["console", "second"]);
}

#[tokio::test]
async fn defaults_refuse_a_field_set_by_name() {
    let err = Client::builder().defaults(JobOptions::new().field("schedule", "@hourly")).build().unwrap_err();
    assert_eq!(err.to_string(), "defaults takes grace, timeout, timezone and failuresBeforeAlert, not schedule");
    assert!(Client::builder().defaults(JobOptions::new().field("grace", "5m")).build().is_ok());
}
