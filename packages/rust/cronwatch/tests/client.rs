//! client.test.ts, as the Go port has it. The handler tests are in handler.rs and env.rs.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::{Boom, HOUR, Kit, MIN, T0, alert_types, wait_for};
use cronwatch::{Alert, JobHealth, JobOptions, Metrics, RunStatus, TriageContext, channel_fn, triage_fn};

fn ok_job(_: cronwatch::JobContext) -> std::future::Ready<Result<(), Boom>> {
    std::future::ready(Ok(()))
}

fn failing(msg: &'static str) -> impl FnOnce(cronwatch::JobContext) -> std::future::Ready<Result<(), Boom>> {
    move |_| std::future::ready(Err(Boom(msg)))
}

#[tokio::test]
async fn run_records_output_metrics_and_duration() {
    let k = Kit::new();
    let job = k.cw.job("report", JobOptions::new().schedule("0 2 * * *")).unwrap();
    let result = job
        .run(|j| {
            j.log(format!("hello {}", r#"{"n":1}"#));
            j.metric("rows", 42.0).unwrap();
            k.advance(1500);
            async { Ok::<_, Boom>("done") }
        })
        .await
        .unwrap();
    assert_eq!(result, "done");
    let run = &k.runs("report").await[0];
    assert_eq!(run.status, RunStatus::Ok);
    assert_eq!(run.duration_ms, Some(1500));
    assert_eq!(run.output.as_deref(), Some(r#"hello {"n":1}"#));
    assert_eq!(run.metrics.to_json(), r#"{"rows":42}"#);
    let s = k.summary("report").await.unwrap();
    assert_eq!(s.health, JobHealth::Healthy);
    assert_eq!(s.next_expected_at, Some(1_767_664_800_000)); // 2026-01-06 02:00Z
}

#[tokio::test]
async fn a_failing_job_is_recorded_alerts_and_returns_its_error() {
    let k = Kit::new();
    let job = k.cw.job("nightly", JobOptions::new()).unwrap();
    let err = job.run(failing("db down")).await.unwrap_err();
    assert_eq!(err.to_string(), "db down", "the job's own error comes back");
    let run = &k.runs("nightly").await[0];
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.error.as_deref(), Some("Boom: db down"));
    assert_eq!(k.types(), ["failed"]);
    assert!(k.alert_list()[0].message.contains("db down"));
    assert_eq!(k.summary("nightly").await.unwrap().health, JobHealth::Failing);
}

#[tokio::test]
async fn an_error_is_named_by_its_type() {
    let k = Kit::new();
    let job = k.cw.job("named", JobOptions::new()).unwrap();
    let _ = job.run(|_| async { Err::<(), _>(std::io::Error::other("disk full")) }).await;
    let _ = job.run(|_| async { Err::<(), Box<dyn std::error::Error + Send + Sync>>("boxed".into()) }).await;
    let _ = job.run(|_| async { Err::<(), _>("text".to_string()) }).await;
    let errors: Vec<_> = k.runs("named").await.into_iter().filter_map(|r| r.error).collect();
    assert_eq!(errors, ["Error: text", "Error: boxed", "Error: disk full"]);
}

#[tokio::test]
async fn expect_turns_a_quiet_success_into_a_failure() {
    let k = Kit::new();
    let job = k.cw.job("export", JobOptions::new().expect("wrote")).unwrap();
    job.run(|j| {
        j.log("wrote 12 files");
        async { Ok::<_, Boom>(()) }
    })
    .await
    .unwrap();
    assert!(k.types().is_empty());
    k.advance(HOUR);
    job.run(|j| {
        j.log("nothing to do");
        async { Ok::<_, Boom>(()) }
    })
    .await
    .unwrap();
    let run = &k.runs("export").await[0];
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.error.as_deref(), Some(r#"Output did not contain "wrote""#));
    assert_eq!(k.types(), ["failed"]);
    // A returned string counts as output too.
    job.run(|_| async { Ok::<_, Boom>(String::from("wrote 3 files")) }).await.unwrap();
    assert_eq!(k.types(), ["failed", "recovered"]);
}

#[tokio::test]
async fn run_declares_on_first_use_and_options_are_validated() {
    let k = Kit::new();
    k.cw.run("adhoc", Some(JobOptions::new().schedule("every 5m")), ok_job).await.unwrap().unwrap();
    assert_eq!(k.cw.jobs().await.unwrap().len(), 1);
    let cases: [(&str, JobOptions, &str); 4] = [
        (
            "bad name!",
            JobOptions::new(),
            r#"job name "bad name!" must be 1 to 120 characters of letters, digits, ".", "_", ":" or "-""#,
        ),
        (
            "x",
            JobOptions::new().schedule("nope"),
            r#"schedule "nope" is not a cron expression or "every <duration>": "#,
        ),
        ("x", JobOptions::new().grace("soon"), r#"grace "soon" is not a duration like "15m", "1h30m" or "90s""#),
        ("x", JobOptions::new().timezone("Mars/Base"), r#"job "x": timezone "Mars/Base" is not an IANA timezone"#),
    ];
    for (name, options, want) in cases {
        let err = k.cw.job(name, options).unwrap_err().to_string();
        assert!(err.starts_with(want), "{want}\n{err}");
    }
    let err = cronwatch::Client::builder().defaults(JobOptions::new().schedule("@hourly")).build().unwrap_err();
    assert_eq!(err.to_string(), "defaults takes grace, timeout, timezone and failuresBeforeAlert, not schedule");
}

#[tokio::test]
async fn a_check_finds_a_missed_run_once_and_a_run_recovers() {
    let k = Kit::new();
    let job = k.cw.job("sync", JobOptions::new().schedule("every 1h").grace("10m")).unwrap();
    k.check().await; // registers at T0
    k.advance(30 * MIN);
    assert!(k.check().await.alerts.is_empty(), "early");
    k.set(T0 + 70 * MIN + 1);
    let r = k.check().await;
    assert_eq!(alert_types(&r.alerts), ["missed"]);
    assert_eq!(r.jobs[0].health, JobHealth::Late);
    assert!(k.check().await.alerts.is_empty(), "no repeat");
    job.run(ok_job).await.unwrap();
    assert_eq!(k.types(), ["missed", "recovered"]);
    assert_eq!(k.summary("sync").await.unwrap().health, JobHealth::Healthy);
}

#[tokio::test]
async fn a_job_declared_again_without_its_schedule_closes_missed() {
    let k = Kit::new();
    k.cw.job("sync", JobOptions::new().schedule("every 1h").grace("10m")).unwrap();
    k.check().await;
    k.set(T0 + 70 * MIN + 1);
    assert_eq!(alert_types(&k.check().await.alerts), ["missed"]);
    let job = k.cw.job("sync", JobOptions::new()).unwrap();
    k.advance(MIN);
    let r = k.check().await;
    assert_eq!(alert_types(&r.alerts), ["recovered"]);
    let a = &r.alerts[0];
    assert_eq!(a.title, "sync is no longer scheduled");
    assert_eq!(
        a.message,
        "Missed since 2026-01-05 10:40:00 UTC (1m ago). It has no schedule now, so nothing is due; the missed alert is closed."
    );
    let json = a.to_json();
    assert!(
        json.contains(r#""details":{"after":["missed"],"reason":"unscheduled","since":1767609600001},"job""#),
        "{json}"
    );
    assert_eq!(r.jobs[0].health, JobHealth::NeverRan);
    assert!(k.check().await.alerts.is_empty(), "no repeat");
    job.run(ok_job).await.unwrap();
    assert_eq!(k.types(), ["missed", "recovered"], "the next run owes nothing");
}

#[tokio::test]
async fn a_schedule_removed_while_silenced_closes_missed_quietly() {
    let k = Kit::new();
    k.cw.job("sync", JobOptions::new().schedule("every 1h").grace("10m")).unwrap();
    k.check().await;
    k.set(T0 + 70 * MIN + 1);
    k.check().await;
    k.cw.silence("sync", Duration::from_secs(3600)).await.unwrap();
    k.cw.job("sync", JobOptions::new()).unwrap();
    k.advance(MIN);
    assert!(k.check().await.alerts.is_empty(), "quiet");
    assert!(k.summary("sync").await.unwrap().open.is_empty());
    k.advance(2 * HOUR);
    assert!(k.check().await.alerts.is_empty(), "still quiet");
    assert_eq!(k.types(), ["missed"]);
}

#[tokio::test]
async fn a_check_marks_a_run_that_never_finished_as_stuck() {
    let k = Kit::new();
    let job = k.cw.job("long", JobOptions::new().timeout("5m")).unwrap();
    let (release, released) = tokio::sync::oneshot::channel::<()>();
    let running = tokio::spawn(async move {
        job.run(|_| async move {
            let _ = released.await;
            Ok::<_, Boom>(())
        })
        .await
    });
    wait_for("the run to start", || async {
        k.runs("long").await.first().is_some_and(|r| r.status == RunStatus::Running)
    })
    .await;
    k.advance(4 * MIN);
    assert!(k.check().await.alerts.is_empty(), "not yet");
    k.advance(2 * MIN);
    let r = k.check().await;
    assert_eq!(alert_types(&r.alerts), ["stuck"]);
    assert_eq!(k.runs("long").await[0].status, RunStatus::Timeout);
    assert_eq!(r.jobs[0].health, JobHealth::Stuck);
    assert!(k.alert_list()[0].message.contains("never reported finishing"));
    let _ = release.send(());
    running.await.unwrap().unwrap();
}

#[tokio::test]
async fn slow_and_over_budget_from_the_jobs_baseline() {
    let k = Kit::new();
    let job = k.cw.job("agent", JobOptions::new().budget("cost", 1.0)).unwrap();
    let run = |ms: i64, tokens: f64, cost: f64| {
        let job = job.clone();
        let k = &k;
        async move {
            job.run(|j| {
                k.advance(ms);
                let metrics: Metrics = [("tokens", tokens), ("cost", cost)].into_iter().collect();
                std::future::ready(j.metrics(&metrics))
            })
            .await
            .unwrap();
        }
    };
    for _ in 0..5 {
        run(1000, 1000.0, 0.5).await;
        k.advance(HOUR);
    }
    assert!(k.types().is_empty(), "none yet");
    run(15_000, 1000.0, 0.5).await;
    assert_eq!(k.types(), ["slow"]);
    k.advance(HOUR);
    run(1000, 5000.0, 1.2).await;
    assert_eq!(k.types(), ["slow", "over_budget"]);
    let last = &k.alert_list()[1];
    assert!(last.message.contains("cost: 1.2, limit 1 (budget)"), "{}", last.message);
    assert!(last.message.contains("tokens: 5,000, limit 3,000 (three times the usual 1,000)"), "{}", last.message);
    k.advance(HOUR);
    run(1000, 1000.0, 0.5).await;
    assert_eq!(k.types(), ["slow", "over_budget", "recovered"]);
}

#[tokio::test]
async fn an_under_floor_alert_names_the_metric_and_what_it_was_judged_against() {
    let k = Kit::new();
    let job = k.cw.job("import", JobOptions::new().floor("files", 1.0)).unwrap();
    let run = |rows: f64, files: f64| {
        let job = job.clone();
        let k = &k;
        async move {
            job.run(|j| {
                k.advance(1000);
                let metrics: Metrics = [("rows", rows), ("files", files)].into_iter().collect();
                std::future::ready(j.metrics(&metrics))
            })
            .await
            .unwrap();
        }
    };
    for i in 0..5 {
        run(4812.0 + f64::from(i), 2.0).await;
        k.advance(HOUR);
    }
    run(0.0, 0.0).await;
    assert_eq!(k.types(), ["under_floor"]);
    let alert = &k.alert_list()[0];
    assert_eq!(alert.title, "import fell short");
    assert!(
        alert.message.contains("rows: 0 (the last 5 runs all reported more than 0, the lowest 4,812)"),
        "{}",
        alert.message
    );
    assert!(alert.message.contains("files: 0, below the floor of 1."), "{}", alert.message);
    k.advance(HOUR);
    run(0.0, 0.0).await;
    assert_eq!(k.types(), ["under_floor"]);
    k.advance(HOUR);
    run(10.0, 1.0).await;
    assert_eq!(k.types(), ["under_floor", "recovered"]);
}

#[tokio::test]
async fn a_floor_must_be_a_finite_number_and_no_higher_than_its_ceiling() {
    let k = Kit::new();
    let err = k.cw.job("a", JobOptions::new().floor("rows", f64::NAN)).unwrap_err().to_string();
    assert_eq!(err, r#"job "a": floor.rows must be a finite number (got NaN)"#);
    let err = k.cw.job("b", JobOptions::new().floor("cost", 3.0).budget("cost", 2.0)).unwrap_err().to_string();
    assert_eq!(err, r#"job "b": floor.cost (3) is above budget.cost (2), so every run would alert"#);
    let err = k.cw.job("c", JobOptions::new().field("floor", 1.0)).unwrap_err().to_string();
    assert_eq!(err, r#"job "c": floor must be an object of { metric: floor }"#);
    k.cw.job("d", JobOptions::new().floor("delta", -5.0).budget("delta", 5.0)).unwrap();
}

#[tokio::test]
async fn silence_swallows_alerts_and_unsilence_alerts_again() {
    let k = Kit::new();
    let job = k.cw.job("flaky", JobOptions::new()).unwrap();
    k.cw.silence("flaky", "1h").await.unwrap();
    assert!(job.run(failing("x")).await.is_err());
    assert!(k.types().is_empty(), "silenced");
    assert_eq!(k.summary("flaky").await.unwrap().health, JobHealth::Silenced);
    k.cw.unsilence("flaky").await.unwrap();
    assert!(job.run(failing("y")).await.is_err());
    assert_eq!(k.types(), ["failed"]);
}

#[tokio::test]
async fn triage_is_attached_and_never_blocks() {
    let k = Kit::with(|b| {
        b.triage(triage_fn(|cx: TriageContext| async move { Ok(format!("Probably {}'s database.", cx.alert.job)) }))
    });
    assert!(k.cw.run("t", None, failing("x")).await.unwrap().is_err());
    assert_eq!(k.alert_list()[0].triage.as_deref(), Some("Probably t's database."));

    let k2 = Kit::with(|b| b.triage(triage_fn(|_| async { Err::<String, _>("api down".into()) })));
    assert!(k2.cw.run("t", None, failing("x")).await.unwrap().is_err());
    assert_eq!(k2.types(), ["failed"]);
    let a = &k2.alert_list()[0];
    assert!(a.triage.is_none() && a.triage_tried, "tried, and gave nothing");
    assert!(a.to_json().contains(r#""triage":null"#), "written as null");
    assert_eq!(k2.wheres(), ["triage for t"]);
}

#[tokio::test]
async fn forget_removes_the_job_and_its_runs() {
    let k = Kit::new();
    k.cw.run("gone", None, ok_job).await.unwrap().unwrap();
    assert_eq!(k.cw.jobs().await.unwrap().len(), 1);
    k.cw.forget("gone").await.unwrap();
    assert!(k.cw.jobs().await.unwrap().is_empty());
    assert!(k.summary("gone").await.is_none(), "summary of a forgotten job");
}

#[tokio::test]
async fn a_failing_channel_does_not_break_the_run() {
    let k = Kit::with(|b| b.alerts([channel_fn("broken", |_: Alert| async { Err("no network".into()) })]));
    let err = k.cw.run("x", None, failing("job")).await.unwrap().unwrap_err();
    assert!(err.to_string().contains("job"));
    assert_eq!(k.wheres(), ["alert channel broken"]);
}

#[tokio::test]
async fn a_panic_is_recorded_as_a_failed_run_and_resumed() {
    let k = Kit::new();
    let job = k.cw.job("panics", JobOptions::new()).unwrap();
    let task = tokio::spawn({
        let job = job.clone();
        async move {
            job.run(|_| async {
                if true {
                    panic!("the disk is gone");
                }
                Ok::<(), Boom>(())
            })
            .await
        }
    });
    let err = task.await.unwrap_err();
    assert!(err.is_panic(), "the panic carries on");
    let run = &k.runs("panics").await[0];
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.error.as_deref(), Some("panic: the disk is gone"));
    assert_eq!(k.types(), ["failed"]);
}

#[tokio::test]
async fn a_run_whose_future_is_dropped_is_recorded_as_failed() {
    let k = Kit::new();
    let job = k.cw.job("dropped", JobOptions::new()).unwrap();
    let outcome = tokio::time::timeout(
        Duration::from_millis(50),
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
    let run = &k.runs("dropped").await[0];
    assert_eq!(run.error.as_deref(), Some("Cancelled: the run's future was dropped before it finished"));
    assert_eq!(k.types(), ["failed"]);
}

#[tokio::test]
async fn the_job_context_is_found_from_deep_in_a_call_chain() {
    async fn deep() {
        cronwatch::current().expect("inside a run").log("from deep inside");
    }
    let k = Kit::new();
    assert!(cronwatch::current().is_none(), "outside a run");
    k.cw.run("deep", None, |_| async {
        deep().await;
        Ok::<_, Boom>(())
    })
    .await
    .unwrap()
    .unwrap();
    assert_eq!(k.runs("deep").await[0].output.as_deref(), Some("from deep inside"));
}

#[tokio::test(start_paused = true)]
async fn cancelled_resolves_at_the_jobs_timeout() {
    let k = Kit::new();
    let job = k.cw.job("slow", JobOptions::new().timeout("2s")).unwrap();
    let result = job
        .run(|j| async move {
            assert!(!j.is_cancelled());
            j.cancelled().await;
            assert!(j.is_cancelled());
            Err::<(), _>(Boom("gave up at the timeout"))
        })
        .await;
    assert!(result.is_err());
    assert_eq!(k.runs("slow").await[0].error.as_deref(), Some("Boom: gave up at the timeout"));
}

#[tokio::test]
async fn deferred_delivery_queues_alerts_for_a_check_elsewhere() {
    let store = Arc::new(cronwatch::MemoryStore::new());
    let quiet = Kit::with(|b| b.store_arc(store.clone()).deliver(cronwatch::Deliver::AtCheck));
    let sender = Kit::with(|b| b.store_arc(store.clone()));
    quiet.cw.run("backup", None, failing("sandboxed")).await.unwrap().unwrap_err();
    assert!(quiet.types().is_empty(), "nothing sent from the sandbox");
    let queued = quiet.state("backup").await.unwrap().undelivered.unwrap();
    assert_eq!(alert_types(&queued), ["failed"]);
    let r = sender.check().await;
    assert_eq!(alert_types(&r.alerts), ["failed"]);
    assert_eq!(sender.types(), ["failed"]);
    assert!(sender.state("backup").await.unwrap().undelivered.unwrap().is_empty());
}

#[tokio::test]
async fn a_secret_split_by_the_16_kb_cut_is_redacted_whole() {
    const CAP: usize = 16 * 1024;
    const TRIMMED: &str = "[earlier output trimmed]\n";
    let body: Vec<String> = (0..25).map(|i| format!("{}{i:04}", "QUJD".repeat(15))).collect();
    let pem = format!("-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----", body.join("\n"));
    let bearer = "Authorization: Bearer opaqueTOKENvalue1234567890";
    let k = Kit::new();
    // The cut lands inside the key's body, and in a second run just after "Bear".
    let (head, rest) = pem.split_at(900);
    let (head, rest) = (head.to_string(), rest.to_string());
    k.cw.run("pem", None, move |j| {
        j.log("x".repeat(CAP));
        j.log(head);
        j.log(rest);
        j.log("done");
        std::future::ready(Ok::<_, Boom>(()))
    })
    .await
    .unwrap()
    .unwrap();
    let output = k.runs("pem").await[0].output.clone().unwrap();
    assert!(!output.contains("QUJD"));
    assert!(output.ends_with("[redacted]\ndone"));
    let tail = "y".repeat(CAP - 30);
    let returned = format!("{bearer}\n{tail}");
    k.cw.run("bearer", None, move |_| std::future::ready(Ok::<_, Boom>(returned))).await.unwrap().unwrap();
    let output = k.runs("bearer").await[0].output.clone().unwrap();
    assert!(!output.contains("opaqueTOKEN"));
    assert!(output.len() <= CAP + TRIMMED.len());

    // Errors, recorded runs and flushed lines the same way.
    let thrown = format!("{} {bearer} {}", "e".repeat(CAP), "z".repeat(CAP - 40));
    let _ = k.cw.run("thrown", None, move |_| std::future::ready(Err::<(), _>(thrown))).await.unwrap();
    assert!(!k.runs("thrown").await[0].error.clone().unwrap().contains("opaqueTOKEN"));
    k.cw.job("imported", JobOptions::new()).unwrap();
    let mut run = cronwatch::Run::new("i1", "imported", RunStatus::Ok, 1);
    run.finished_at = Some(2);
    run.duration_ms = Some(1);
    run.output = Some(format!("{bearer}\n{tail}"));
    run.trigger = "source".into();
    k.cw.record_run(run, cronwatch::RecordOptions::new()).await.unwrap();
    assert!(!k.cw.get_run("i1").await.unwrap().unwrap().output.unwrap().contains("opaqueTOKEN"));
    let handle = k.cw.job("flushed", JobOptions::new()).unwrap().start(cronwatch::StartOptions::new()).await.unwrap();
    handle.log(bearer);
    handle.log(&tail);
    handle.flush().await;
    assert!(!k.cw.get_run(handle.id()).await.unwrap().unwrap().output.unwrap().contains("opaqueTOKEN"));
    handle.finish().await.expect("finished");
    assert!(!k.cw.get_run(handle.id()).await.unwrap().unwrap().output.unwrap().contains("opaqueTOKEN"));
}
