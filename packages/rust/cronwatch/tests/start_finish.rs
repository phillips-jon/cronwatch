//! start-finish.test.ts, and the tests of finish-once.test.ts after its
//! backend loops (those are `storetest::kit::finish_once`), as the Go port has
//! them.

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;

use common::{Boom, HOUR, Held, Kit, MIN, Mortal, T0, TestStore};
use cronwatch::{JobHealth, JobOptions, Matcher, MemoryStore, RecordOptions, Run, RunHandle, RunStatus, StartOptions};

/// A test pattern: `wrote <digits> files`.
struct WroteFiles;

impl Matcher for WroteFiles {
    fn is_match(&self, text: &str) -> bool {
        text.split("wrote ").skip(1).any(|rest| {
            let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
            digits > 0 && rest[digits..].starts_with(" files")
        })
    }

    fn source(&self) -> String {
        r"/wrote \d+ files/".into()
    }
}

#[tokio::test]
async fn start_records_a_running_run_and_finish_records_it_ok() {
    let k = Kit::new();
    let job = k.cw.job("sync", JobOptions::new().schedule("@hourly")).unwrap();
    let run = job.start(StartOptions::new().trigger("queue")).await.unwrap();
    assert_eq!(run.job(), "sync");
    assert!(run.is_active());
    let stored = k.cw.get_run(run.id()).await.unwrap().unwrap();
    assert_eq!(stored.status, RunStatus::Running);
    assert_eq!(stored.trigger, "queue");
    run.log(format!("imported {} rows", 12));
    run.metric("rows", 12.0).unwrap();
    k.advance(90_000);
    let finished = run.finish().await.unwrap();
    assert_eq!(finished.status, RunStatus::Ok);
    assert_eq!(finished.duration_ms, Some(90_000));
    assert!(!run.is_active());
    let recorded = &k.runs("sync").await[0];
    assert_eq!(recorded.status, RunStatus::Ok);
    assert_eq!(recorded.output.as_deref(), Some("imported 12 rows"));
    assert_eq!(recorded.metrics.to_json(), r#"{"rows":12}"#);
    assert!(k.types().is_empty());
    assert_eq!(k.summary("sync").await.unwrap().health, JobHealth::Healthy);
}

#[tokio::test]
async fn fail_records_a_failure_and_alerts_once() {
    let k = Kit::new();
    let job = k.cw.job("import", JobOptions::new().failures_before_alert(2)).unwrap();
    let first = job.start(StartOptions::new()).await.unwrap();
    first.fail(&Boom("api down")).await;
    let second = job.start(StartOptions::new()).await.unwrap();
    let run = second.fail(&Boom("still down")).await.unwrap();
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.error.as_deref(), Some("Boom: still down"));
    assert_eq!(k.types(), ["failed"]);
    let third = job.start(StartOptions::new().trigger("retry")).await.unwrap();
    third.finish().await;
    assert_eq!(k.types(), ["failed", "recovered"]);
}

#[tokio::test]
async fn a_second_finish_is_ignored_and_reported() {
    let k = Kit::new();
    let job = k.cw.job("once", JobOptions::new()).unwrap();
    let run = job.start(StartOptions::new()).await.unwrap();
    let a = run.fail("boom").await.unwrap();
    assert_eq!(a.status, RunStatus::Failed);
    assert!(run.finish().await.is_none());
    assert!(run.finish().await.is_none());
    assert_eq!(k.types(), ["failed"]);
    assert_eq!(k.runs("once").await[0].status, RunStatus::Failed);
    let msgs = k.messages();
    assert_eq!(msgs.len(), 2);
    assert!(msgs[0].contains("was already finished by this handle; ignored"), "{msgs:?}");
    assert_eq!(k.wheres()[0], "finishing once");
}

#[tokio::test]
async fn concurrent_finishes_of_one_handle_record_one() {
    let k = Kit::new();
    let run = k.cw.job("once", JobOptions::new()).unwrap().start(StartOptions::new()).await.unwrap();
    let tasks: Vec<_> = (0..8)
        .map(|_| {
            let run = run.clone();
            tokio::spawn(async move { run.finish_with("done").await })
        })
        .collect();
    let mut recorded = 0;
    for t in tasks {
        if t.await.unwrap().is_some() {
            recorded += 1;
        }
    }
    assert_eq!(recorded, 1);
    assert_eq!(k.messages().len(), 7);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn start_with_an_id_twice_records_one_run() {
    let k = Kit::new();
    let job = k.cw.job("inngest-fn", JobOptions::new()).unwrap();
    let starts: Vec<_> = (0..2)
        .map(|_| {
            let job = job.clone();
            tokio::spawn(async move { job.start(StartOptions::new().id("01HX-run")).await.unwrap() })
        })
        .collect();
    let mut handles: Vec<RunHandle> = Vec::new();
    for s in starts {
        handles.push(s.await.unwrap());
    }
    assert_eq!(handles[0].id(), "01HX-run");
    assert_eq!(handles[1].id(), "01HX-run");
    let again = job.start(StartOptions::new().id("01HX-run").trigger("ignored")).await.unwrap();
    assert!(again.is_active());
    assert_eq!(k.runs("inngest-fn").await.len(), 1);
    assert_eq!(k.cw.get_run("01HX-run").await.unwrap().unwrap().trigger, "start");
    again.finish_with("done").await;
    // Finished elsewhere: this handle's finish is a reported no-op.
    assert!(handles[0].finish().await.is_none());
    let msgs = k.messages();
    assert!(msgs.last().unwrap().contains("already finished as ok; ignored"), "{msgs:?}");
    let late = job.start(StartOptions::new().id("01HX-run")).await.unwrap();
    assert!(!late.is_active());
    assert!(late.finish().await.is_none());
    assert_eq!(k.runs("inngest-fn").await.len(), 1);
    let other = k.cw.job("other", JobOptions::new()).unwrap();
    let err = other.start(StartOptions::new().id("01HX-run")).await.unwrap_err();
    assert!(err.to_string().contains(r#"belongs to job "inngest-fn""#), "{err}");
    let err = job.start(StartOptions::new().id("")).await.unwrap_err();
    assert_eq!(
        err.to_string(),
        r#"job "inngest-fn": start() needs a run id of 1 to 200 characters (got 0 characters)"#
    );
}

#[tokio::test]
async fn resume_in_a_second_client_appends_and_finishes() {
    let store = Arc::new(cronwatch::MemoryStore::new());
    let first = Kit::with(|b| b.store_arc(store.clone()));
    let second = Kit::with(|b| b.store_arc(store.clone()));
    let options = JobOptions::new().expect("sent").budget("emails", 100.0);
    let started =
        first.cw.job("digest", options.clone()).unwrap().start(StartOptions::new().id("evt-1")).await.unwrap();
    started.log("loaded 40 recipients");
    started.log("token=abc123");
    started.metric("recipients", 40.0).unwrap();
    started.flush().await;
    let midway = first.cw.get_run("evt-1").await.unwrap().unwrap();
    assert_eq!(midway.status, RunStatus::Running);
    assert_eq!(midway.output.as_deref(), Some("loaded 40 recipients\ntoken=[redacted]"));

    second.set(first.now() + 5 * MIN);
    second.cw.job("digest", options).unwrap();
    let resumed = second.cw.resume_run("digest", "evt-1").await.unwrap();
    assert!(resumed.is_active());
    assert_eq!(resumed.started_at(), Some(midway.started_at));
    resumed.log("sent 40 emails");
    resumed.metric("emails", 40.0).unwrap();
    let run = resumed.finish().await.unwrap();
    assert_eq!(run.status, RunStatus::Ok);
    assert_eq!(run.duration_ms, Some(5 * MIN));
    let stored = first.cw.get_run("evt-1").await.unwrap().unwrap();
    assert_eq!(stored.status, RunStatus::Ok);
    assert_eq!(stored.output.as_deref(), Some("loaded 40 recipients\ntoken=[redacted]\nsent 40 emails"));
    assert_eq!(stored.metrics.to_json(), r#"{"recipients":40,"emails":40}"#);
    assert!(first.types().is_empty() && second.types().is_empty());
    assert!(first.messages().is_empty() && second.messages().is_empty());
}

#[tokio::test]
async fn resume_of_an_unknown_or_finished_run() {
    let k = Kit::new();
    let job = k.cw.job("webhook", JobOptions::new()).unwrap();
    let missing = job.resume("nope").await.unwrap();
    assert!(!missing.is_active());
    assert_eq!(missing.started_at(), None);
    missing.log("dropped");
    missing.flush().await;
    assert!(missing.finish().await.is_none());
    assert!(k.messages()[0].contains("run nope of webhook was not found; ignored"), "{:?}", k.messages());
    job.run(|_| async { Ok::<_, Boom>(()) }).await.unwrap();
    let done = k.runs("webhook").await[0].clone();
    let finished = job.resume(&done.id).await.unwrap();
    assert!(!finished.is_active());
    assert!(finished.fail("late").await.is_none());
    assert!(k.messages()[1].contains("already finished as ok; ignored"), "{:?}", k.messages());
    assert_eq!(k.runs("webhook").await[0].status, RunStatus::Ok);
    let err = k.cw.resume_run("undeclared", "x").await.unwrap_err();
    assert!(err.to_string().contains("not declared"), "{err}");
}

#[tokio::test]
async fn a_run_never_finished_is_marked_stuck() {
    let k = Kit::new();
    let job = k.cw.job("callback", JobOptions::new().timeout("30m")).unwrap();
    let run = job.start(StartOptions::new()).await.unwrap();
    k.advance(29 * MIN);
    k.check().await;
    assert_eq!(k.cw.get_run(run.id()).await.unwrap().unwrap().status, RunStatus::Running);
    k.advance(2 * MIN);
    k.check().await;
    let stored = k.cw.get_run(run.id()).await.unwrap().unwrap();
    assert_eq!(stored.status, RunStatus::Timeout);
    assert!(stored.error.unwrap().contains("Still running after 30m"));
    assert_eq!(k.types(), ["stuck"]);
}

#[tokio::test]
async fn a_late_success_after_a_timeout_mark_recovers() {
    let k = Kit::new();
    let job = k.cw.job("slowpoke", JobOptions::new().timeout("10m").failures_before_alert(2)).unwrap();
    let first = job.start(StartOptions::new()).await.unwrap();
    k.advance(11 * MIN);
    k.check().await;
    assert!(k.types().is_empty(), "under the threshold");
    let failed = first.fail("gave up").await.unwrap();
    assert_eq!(failed.status, RunStatus::Failed);
    let error = k.cw.get_run(first.id()).await.unwrap().unwrap().error.unwrap();
    assert_eq!(error.lines().next(), Some("Error: gave up"), "the run keeps its real error");
    assert!(k.types().is_empty(), "the late failure did not count as a second one");

    let second = job.start(StartOptions::new()).await.unwrap();
    k.advance(11 * MIN);
    k.check().await;
    assert_eq!(k.types(), ["stuck"]);
    let resumed = k.cw.resume_run("slowpoke", second.id()).await.unwrap();
    assert!(resumed.is_active(), "a run marked timeout can still be finished late");
    assert_eq!(resumed.finish().await.unwrap().status, RunStatus::Ok);
    assert_eq!(k.types(), ["stuck", "recovered"]);
    assert!(second.finish().await.is_none(), "the handle that started it sees it finished elsewhere");
}

#[tokio::test]
async fn expect_is_applied_at_finish() {
    let k = Kit::new();
    let job = k.cw.job("export", JobOptions::new().expect_match(WroteFiles)).unwrap();
    assert_eq!(job.definition().expect(), r"matches /wrote \d+ files/");
    let quiet = job.start(StartOptions::new()).await.unwrap();
    let run = quiet.finish_with("nothing to do").await.unwrap();
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.output.as_deref(), Some("nothing to do"));
    assert_eq!(run.error.as_deref(), Some(r"Output did not match /wrote \d+ files/"));
    assert_eq!(k.types(), ["failed"]);

    let busy = job.start(StartOptions::new()).await.unwrap();
    busy.log("wrote 3 files");
    busy.flush().await;
    let resumed = job.resume(busy.id()).await.unwrap();
    let run = resumed.finish_with("uploaded").await.unwrap();
    assert_eq!(run.status, RunStatus::Ok, "lines flushed earlier count toward expect");
    assert_eq!(k.types(), ["failed", "recovered"]);
}

#[tokio::test]
async fn a_store_failing_during_start_does_not_fail_it() {
    let store = Arc::new(TestStore::default());
    store.breaks(&["insert_run"]);
    let k = Kit::with(|b| b.store_arc(store.clone()));
    let job = k.cw.job("backup", JobOptions::new().schedule("@hourly")).unwrap();
    let run = job.start(StartOptions::new()).await.unwrap();
    assert!(run.is_active());
    assert_eq!(k.wheres()[0], "recording backup");
    assert!(k.cw.get_run(run.id()).await.unwrap().is_none(), "not stored");
    run.log("copied");
    run.flush().await; // nothing stored to append to; kept for finish
    store.mends(&[]);
    k.advance(HOUR / 2);
    assert_eq!(run.finish().await.unwrap().status, RunStatus::Ok);
    let stored = k.cw.get_run(run.id()).await.unwrap().unwrap();
    assert_eq!(stored.status, RunStatus::Ok);
    assert_eq!(stored.output.as_deref(), Some("copied"));
    assert_eq!(stored.duration_ms, Some(HOUR / 2));
    assert!(k.types().is_empty());
}

#[tokio::test]
async fn a_store_failing_at_finish_leaves_the_handle_to_finish_again() {
    let store = Arc::new(TestStore::default());
    let k = Kit::with(|b| b.store_arc(store.clone()));
    let job = k.cw.job("flaky", JobOptions::new()).unwrap();
    let run = job.start(StartOptions::new()).await.unwrap();
    run.log("working");
    store.breaks(&["get_run", "update_run", "update_run_if"]);
    run.flush().await;
    let wheres = k.wheres();
    assert_eq!(wheres.last().unwrap(), "flushing flaky");
    assert!(run.finish().await.is_none(), "nothing recorded");
    assert_eq!(k.wheres()[wheres.len()..], ["finishing flaky"]);
    assert!(run.is_active(), "still active, to finish again");
    // The read works but the write fails: still retryable.
    store.mends(&["get_run"]);
    assert!(run.finish().await.is_none());
    assert!(run.is_active());
    store.mends(&[]);
    assert_eq!(k.cw.get_run(run.id()).await.unwrap().unwrap().status, RunStatus::Running, "nothing written yet");
    let finished = run.finish().await.unwrap();
    assert_eq!(finished.status, RunStatus::Ok);
    assert_eq!(finished.output.as_deref(), Some("working"), "the lines logged before the failures are kept");
    assert!(!run.is_active());
    assert!(run.finish().await.is_none(), "finished once only");
}

#[tokio::test]
async fn a_store_without_update_run_if_falls_back_to_a_read_and_a_write() {
    let store = Arc::new(TestStore { no_run_if: true, no_cas: true, ..Default::default() });
    let k = Kit::with(|b| b.store_arc(store));
    let job = k.cw.job("plain", JobOptions::new()).unwrap();
    let h = job.start(StartOptions::new().id("p1")).await.unwrap();
    assert_eq!(h.finish_with("done").await.unwrap().status, RunStatus::Ok);
    assert!(job.resume("p1").await.unwrap().finish_with("again").await.is_none());
    assert!(k.messages().iter().any(|m| m.contains("already finished")));
}

fn pg_run(id: &str, at: i64, status: RunStatus) -> Run {
    Run {
        id: id.into(),
        job: "db:vacuum".into(),
        status,
        started_at: at,
        finished_at: None,
        duration_ms: None,
        error: None,
        output: None,
        metrics: Default::default(),
        trigger: "pg_cron".into(),
    }
}

#[tokio::test]
async fn record_run_takes_the_late_finish_of_a_run_marked_timeout() {
    let k = Kit::new();
    k.set(1_767_236_400_000); // 2026-01-01 03:00Z
    k.cw.job("db:vacuum", JobOptions::new().schedule("0 3 * * *").timeout("30m")).unwrap();
    let start = k.now();
    k.cw.record_run(pg_run("pgcron:77", start, RunStatus::Running), RecordOptions::new()).await.unwrap();
    k.advance(45 * MIN);
    k.check().await;
    assert_eq!(k.cw.get_run("pgcron:77").await.unwrap().unwrap().status, RunStatus::Timeout);
    k.advance(15 * MIN);
    let mut done = pg_run("pgcron:77", start, RunStatus::Ok);
    done.finished_at = Some(k.now() - 5 * MIN);
    done.duration_ms = Some(55 * MIN);
    done.output = Some("VACUUM".into());
    k.cw.record_run(done, RecordOptions::new()).await.unwrap();
    k.check().await;
    let run = k.cw.get_run("pgcron:77").await.unwrap().unwrap();
    assert_eq!(run.status, RunStatus::Ok);
    assert_eq!(run.output.as_deref(), Some("VACUUM"));
    assert_eq!(k.summary("db:vacuum").await.unwrap().health, JobHealth::Healthy);
    assert_eq!(k.types(), ["stuck", "recovered"]);

    // A late failure is written but not counted twice.
    let mut other = pg_run("pgcron:78", k.now(), RunStatus::Running);
    k.cw.record_run(other.clone(), RecordOptions::new()).await.unwrap();
    k.advance(45 * MIN);
    k.check().await;
    other.status = RunStatus::Failed;
    other.finished_at = Some(k.now());
    other.duration_ms = Some(45 * MIN);
    other.error = Some("ERROR: canceled".into());
    k.cw.record_run(other, RecordOptions::new()).await.unwrap();
    assert_eq!(k.cw.get_run("pgcron:78").await.unwrap().unwrap().status, RunStatus::Failed);
    assert_eq!(k.state("db:vacuum").await.unwrap().consecutive_failures, 1);
    assert_eq!(k.types(), ["stuck", "recovered", "stuck"]);
}

#[tokio::test]
async fn record_run_leaves_a_stored_run_of_another_job_alone() {
    let k = Kit::new();
    let a = k.cw.job("webhook-job", JobOptions::new()).unwrap();
    k.cw.job("db:nightly", JobOptions::new()).unwrap();
    let h = a.start(StartOptions::new().id("run-43")).await.unwrap();
    let mut foreign = pg_run("run-43", T0 - 1000, RunStatus::Ok);
    foreign.job = "db:nightly".into();
    foreign.finished_at = Some(T0);
    foreign.duration_ms = Some(1000);
    let sent = k.cw.record_run(foreign, RecordOptions::new()).await.unwrap();
    assert!(sent.is_empty());
    let stored = k.cw.get_run("run-43").await.unwrap().unwrap();
    assert_eq!(stored.job, "webhook-job");
    assert_eq!(stored.status, RunStatus::Running);
    assert!(k.messages().iter().any(|m| m.contains(r#"run-43 of db:nightly belongs to job "webhook-job"; ignored"#)));
    assert_eq!(h.finish().await.unwrap().status, RunStatus::Ok);
    assert!(k.types().is_empty());
    let mut undeclared = pg_run("x", T0, RunStatus::Ok);
    undeclared.job = "undeclared".into();
    let err = k.cw.record_run(undeclared, RecordOptions::new()).await.unwrap_err();
    assert!(err.to_string().contains("not declared"), "{err}");
}

#[tokio::test]
async fn start_and_resume_refuse_the_pg_cron_namespace() {
    let k = Kit::new();
    let job = k.cw.job("webhook-job", JobOptions::new()).unwrap();
    let want = r#"cannot take a run id starting with "pgcron:""#;
    assert!(job.start(StartOptions::new().id("pgcron:42")).await.unwrap_err().to_string().contains(want));
    assert!(job.resume("pgcron:42").await.unwrap_err().to_string().contains(want));
    assert!(k.cw.resume_run("webhook-job", "pgcron:db:42").await.unwrap_err().to_string().contains("pgcron:"));
    let h = job.start(StartOptions::new().id("pgcron-42")).await.unwrap();
    assert!(h.is_active(), "only the prefix with its colon is reserved");
}

// No store could hold a NUL (Postgres refuses it), so such an id is refused
// wherever one is taken.
#[tokio::test]
async fn a_run_id_with_a_nul_is_refused() {
    let k = Kit::new();
    let job = k.cw.job("nul-id", JobOptions::new()).unwrap();
    let err = job.start(StartOptions::new().id("01HX\0run")).await.unwrap_err().to_string();
    assert_eq!(err, r#"job "nul-id": start() cannot take a run id containing a NUL character"#);
    let err = job.resume("01HX\0run").await.unwrap_err().to_string();
    assert_eq!(err, r#"job "nul-id": resume() cannot take a run id containing a NUL character"#);
    let mut run = pg_run("x\0y", k.now(), RunStatus::Ok);
    run.job = "nul-id".into();
    let err = k.cw.record_run(run, RecordOptions::new()).await.unwrap_err().to_string();
    assert_eq!(err, r#"recordRun: run ids cannot contain a NUL character (job "nul-id")"#);
    assert!(k.cw.runs("nul-id", 10).await.unwrap().is_empty());
}

#[tokio::test]
async fn close_waits_for_a_check_under_way_before_it_closes_the_store() {
    let store = Mortal::new(&Arc::new(MemoryStore::new()));
    let held = Held::new();
    let channel = held.channel();
    let k = Kit::with(|b| b.store_arc(store.clone()).alerts([channel]));
    k.cw.job("callback", JobOptions::new().timeout("30m")).unwrap().start(StartOptions::new()).await.unwrap();
    k.advance(31 * MIN);
    let cw = k.cw.clone();
    let check = tokio::spawn(async move { cw.check().await.unwrap() });
    held.sending.notified().await;
    let cw = k.cw.clone();
    let closing = tokio::spawn(async move { cw.close().await.unwrap() });
    settle().await;
    assert!(!closing.is_finished(), "still waiting on the check");
    assert_eq!(store.closes.load(Ordering::SeqCst), 0);
    held.open();
    closing.await.unwrap();
    assert_eq!(held.types(), ["stuck"], "sent before the store closed");
    assert_eq!(store.closes.load(Ordering::SeqCst), 1);
    assert_eq!(common::alert_types(&check.await.unwrap().alerts), ["stuck"]);
    // With no check under way it closes straight away.
    k.cw.close().await.unwrap();
    assert_eq!(store.closes.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn lines_flushed_while_a_check_marks_earlier_runs_stuck_are_kept_on_the_run_it_marks_next() {
    let held = Held::new();
    let channel = held.channel();
    let k = Kit::with(|b| b.alerts([channel]));
    let first = k.cw.job("first", JobOptions::new().timeout("30m")).unwrap().start(StartOptions::new()).await.unwrap();
    k.advance(1000);
    let second =
        k.cw.job("second", JobOptions::new().timeout("30m")).unwrap().start(StartOptions::new()).await.unwrap();
    second.log("early line");
    second.metric("rows", 1.0).unwrap();
    second.flush().await;
    k.advance(31 * MIN);
    let cw = k.cw.clone();
    let check = tokio::spawn(async move { cw.check().await.unwrap() });
    // The first stuck run's alert is being sent; the second is still
    // running, and flushes.
    held.sending.notified().await;
    second.log("important progress line");
    second.metric("rows", 2.0).unwrap();
    second.flush().await;
    held.open();
    check.await.unwrap();
    let stored = k.cw.get_run(second.id()).await.unwrap().unwrap();
    assert_eq!(stored.status, RunStatus::Timeout);
    assert_eq!(stored.output.as_deref(), Some("early line\nimportant progress line"));
    assert_eq!(stored.metrics.to_json(), r#"{"rows":2}"#);
    assert_eq!(k.cw.get_run(first.id()).await.unwrap().unwrap().status, RunStatus::Timeout);
}

#[tokio::test]
async fn a_metric_that_is_not_a_finite_number_is_refused_by_record_run() {
    let k = Kit::new();
    k.cw.job("imported", JobOptions::new()).unwrap();
    for bad in [f64::NAN, f64::INFINITY] {
        let mut run = pg_run("nan", k.now(), RunStatus::Ok);
        run.job = "imported".into();
        run.metrics.set("rows", bad);
        let err = k.cw.record_run(run, RecordOptions::new()).await.unwrap_err().to_string();
        assert_eq!(err, r#"recordRun: metric "rows" must be a finite number (job "imported", run "nan")"#);
    }
    assert!(k.cw.get_run("nan").await.unwrap().is_none(), "nothing is written");
}

/// Lets every task that can run get as far as it can, on the test's one
/// thread.
async fn settle() {
    for _ in 0..50 {
        tokio::task::yield_now().await;
    }
}
