//! What the public API promises at compile time: every handle and store is
//! `Send + Sync`, and every future the client returns is `Send`, so it can
//! be spawned. A change that breaks one fails to build here rather than in
//! an app.

use std::future::Future;

use cronwatch::{
    Alert, Client, Definition, Error, Handler, HandlerOptions, Job, JobContext, JobOptions, JobState, JobSummary,
    MemoryStore, RecordOptions, Run, RunHandle, RunOptions, StartOptions, Store,
};

fn send_sync<T: Send + Sync>() {}
fn send<F: Future + Send>(_: &F) {}

#[test]
fn the_handles_and_values_are_send_and_sync() {
    send_sync::<Client>();
    send_sync::<Job>();
    send_sync::<JobContext>();
    send_sync::<RunHandle>();
    send_sync::<Handler>();
    send_sync::<HandlerOptions>();
    send_sync::<cronwatch::web::Routes>();
    send_sync::<cronwatch::web::RoutesOptions>();
    send_sync::<cronwatch::web::Request>();
    send_sync::<cronwatch::web::Response>();
    send_sync::<MemoryStore>();
    send_sync::<std::sync::Arc<dyn Store>>();
    send_sync::<JobOptions>();
    send_sync::<Error>();
    send_sync::<Run>();
    send_sync::<JobState>();
    send_sync::<JobSummary>();
    send_sync::<Definition>();
    send_sync::<Alert>();
    send_sync::<cronwatch::bridge::Watch>();
    #[cfg(feature = "blocking")]
    {
        send_sync::<cronwatch::blocking::Client>();
        send_sync::<cronwatch::blocking::Job>();
        send_sync::<cronwatch::blocking::RunHandle>();
    }
}

#[test]
fn debug_never_prints_a_token_or_secret() {
    let token = "not-a-real-token-0123";
    let routes = format!("{:?}", cronwatch::web::RoutesOptions::new().token(token).base_path("/cw"));
    assert!(!routes.contains(token), "{routes}");
    assert!(routes.contains("\"set\"") && routes.contains("/cw"), "{routes}");
    let handler = format!("{:?}", HandlerOptions::new().secret(token));
    assert!(!handler.contains(token), "{handler}");
    let request = cronwatch::web::Request::new("GET", format!("/cronwatch?token={token}"))
        .with_header("authorization", format!("Bearer {token}"))
        .with_header("cookie", format!("cronwatch_token={token}"));
    let request = format!("{request:?}");
    assert!(!request.contains(token), "{request}");
    assert!(request.contains("/cronwatch?..."), "{request}");
}

#[cfg(feature = "alerts")]
#[test]
fn a_channels_request_and_options_never_debug_a_credential() {
    let key = "not-a-real-key-0123";
    let request = cronwatch::alerts::Request {
        url: format!("https://hooks.example.com/services/{key}"),
        headers: vec![("authorization".into(), format!("Bearer {key}"))],
        body: key.as_bytes().to_vec(),
    };
    let text = format!("{request:?}");
    assert!(!text.contains(key), "{text}");
    assert!(text.contains("https://hooks.example.com") && text.contains("authorization"), "{text}");
    let slack = cronwatch::alerts::SlackOptions {
        webhook_url: format!("https://hooks.example.com/{key}"),
        ..Default::default()
    };
    let resend = cronwatch::alerts::ResendOptions { api_key: key.into(), ..Default::default() };
    for text in [format!("{slack:?}"), format!("{resend:?}")] {
        assert!(!text.contains(key), "{text}");
    }
}

#[tokio::test]
async fn the_futures_are_send() {
    let cw = Client::builder().build().unwrap();
    let job = cw.job("api", JobOptions::new()).unwrap();
    send(&job.run(|_| async { Ok::<_, std::io::Error>(()) }));
    send(&job.run_with(RunOptions::new(), |_| async { Ok::<_, std::io::Error>(()) }));
    send(&job.run_or_discard(RunOptions::new(), |_: &std::io::Error| false, |_| async { Ok::<_, std::io::Error>(()) }));
    send(&cw.run("api", None, |_| async { Ok::<_, std::io::Error>(()) }));
    send(&job.start(StartOptions::new()));
    send(&job.resume("r"));
    send(&cw.resume_run("api", "r"));
    send(&cw.check());
    send(&cw.jobs());
    send(&cw.jobs_with_runs(5));
    send(&cw.job_summary("api"));
    send(&cw.runs("api", 5));
    send(&cw.get_run("r"));
    send(&cw.silence("api", "1h"));
    send(&cw.unsilence("api"));
    send(&cw.forget("api"));
    send(&cw.sync_job("api"));
    send(&cw.close());
    let run = Run::from_json(r#"{"id":"r","job":"api","status":"ok","startedAt":0,"trigger":"run"}"#).unwrap();
    send(&cw.record_run(run, RecordOptions::new()));
    let handle = job.start(StartOptions::new()).await.unwrap();
    send(&handle.flush());
    send(&handle.finish());
    send(&handle.finish_with("done"));
    send(&handle.fail("boom"));
    let routes = cw.routes(cronwatch::web::RoutesOptions::new().no_token()).unwrap();
    send(&routes.handle(cronwatch::web::Request::new("GET", "/cronwatch/api/jobs")));
    let handler = job.handler(|_, _| async { Ok::<_, std::io::Error>(()) }, HandlerOptions::new().no_secret());
    send(&handler.handle(cronwatch::web::Request::new("POST", "/")));
}
