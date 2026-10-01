//! The blocking client, from plain threads with no runtime of their own.
#![cfg(feature = "blocking")]

use std::sync::{Arc, Mutex};

use cronwatch::blocking::Client;
use cronwatch::{Alert, JobHealth, JobOptions, RunStatus, StartOptions, channel_fn};

fn client() -> (Client, Arc<Mutex<Vec<Alert>>>) {
    let alerts = Arc::new(Mutex::new(Vec::new()));
    let sink = alerts.clone();
    let cw = Client::new(cronwatch::Client::builder().alerts([channel_fn("capture", move |a: Alert| {
        sink.lock().unwrap().push(a);
        async { Ok(()) }
    })]))
    .expect("a blocking client");
    (cw, alerts)
}

#[derive(Debug)]
struct DiskFull;

impl std::fmt::Display for DiskFull {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("no space left")
    }
}

#[test]
fn a_plain_closure_runs_on_the_calling_thread_and_is_recorded() {
    let (cw, alerts) = client();
    let job = cw.job("backup", JobOptions::new().schedule("0 3 * * *").timezone("UTC")).unwrap();
    let caller = std::thread::current().id();
    let copied = job
        .run(|run| {
            assert_eq!(std::thread::current().id(), caller, "on the calling thread");
            run.log("copied 3 files");
            cronwatch::current().expect("the run's context").metric("files", 3.0).unwrap();
            Ok::<_, DiskFull>(3)
        })
        .unwrap();
    assert_eq!(copied, 3);
    let run = &cw.runs("backup", 10).unwrap()[0];
    assert_eq!(run.status, RunStatus::Ok);
    assert_eq!(run.output.as_deref(), Some("copied 3 files"));
    assert_eq!(run.metrics.to_json(), r#"{"files":3}"#);

    assert!(job.run(|_| Err::<(), _>(DiskFull)).is_err());
    let run = &cw.runs("backup", 10).unwrap()[0];
    assert_eq!(run.error.as_deref(), Some("DiskFull: no space left"));
    let types: Vec<String> = alerts.lock().unwrap().iter().map(|a| a.alert_type.to_string()).collect();
    assert_eq!(types, ["failed"]);
    assert_eq!(cw.job_summary("backup").unwrap().unwrap().health, JobHealth::Failing);
    let checked = cw.check().unwrap();
    assert_eq!(checked.jobs.len(), 1);
    cw.close().unwrap();
}

#[test]
fn start_and_finish_across_calls() {
    let (cw, _) = client();
    let job = cw.job("import", JobOptions::new()).unwrap();
    let handle = job.start(StartOptions::new().id("batch-7")).unwrap();
    handle.log("read 10 rows");
    handle.flush();
    assert_eq!(cw.get_run("batch-7").unwrap().unwrap().output.as_deref(), Some("read 10 rows"));
    let resumed = cw.resume_run("import", "batch-7").unwrap();
    let run = resumed.fail(&DiskFull).unwrap();
    assert_eq!(run.error.as_deref(), Some("DiskFull: no space left"));
    assert!(handle.finish().is_none(), "finished elsewhere");
}

#[test]
fn a_panic_is_recorded_then_resumed() {
    let (cw, _) = client();
    let job = cw.job("panics", JobOptions::new()).unwrap();
    let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = job.run(|_| -> Result<(), DiskFull> { panic!("out of cheese") });
    }));
    assert!(caught.is_err());
    assert_eq!(cw.runs("panics", 1).unwrap()[0].error.as_deref(), Some("panic: out of cheese"));
}

#[tokio::test(flavor = "multi_thread")]
async fn it_works_inside_another_runtime_too() {
    let (cw, _) = client();
    let job = cw.job("nested", JobOptions::new()).unwrap();
    job.run(|_| Ok::<_, DiskFull>(())).unwrap();
    assert_eq!(cw.runs("nested", 1).unwrap()[0].status, RunStatus::Ok);
}

#[test]
fn start_checking_and_its_old_name_check_on_an_interval_until_stopped() {
    let (cw, _) = client();
    cw.start_checking(std::time::Duration::from_secs(60));
    #[allow(deprecated)]
    cw.start(std::time::Duration::from_secs(60)); // a second call does nothing
    cw.stop();
    cw.close().unwrap();
}
