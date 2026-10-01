//! The alert channels and triage through the public API: a client whose
//! failed run is triaged by Claude and sent to Slack, both over a transport
//! of the test's own, as an app's proxy or recorder would be.

use std::sync::{Arc, Mutex};

use cronwatch::alerts::{self, Request, Response, SlackOptions, Transport};
use cronwatch::triage::{self, AnthropicOptions};
use cronwatch::{BoxError, BoxFuture, Client, JobOptions};

#[derive(Default)]
struct Recorder {
    taken: Mutex<Vec<Request>>,
}

impl Transport for Recorder {
    fn post(&self, request: Request) -> BoxFuture<'_, Result<Response, BoxError>> {
        let answer = if request.url.starts_with("https://api.anthropic.com/") {
            Response::new(200, r#"{"stop_reason":"end_turn","content":[{"type":"text","text":"The disk is full."}]}"#)
        } else {
            Response::new(200, "ok")
        };
        self.taken.lock().unwrap().push(request);
        Box::pin(std::future::ready(Ok(answer)))
    }
}

#[tokio::test]
async fn a_failure_is_triaged_and_sent_to_slack() {
    let rec = Arc::new(Recorder::default());
    let transport: Arc<dyn Transport> = rec.clone();
    let slack = alerts::slack(
        SlackOptions::new()
            .webhook_url("https://hooks.slack.example/T/B/x")
            .link(|a| format!("https://app.example/cronwatch/jobs/{}", a.job))
            .transport(transport.clone()),
    )
    .unwrap();
    let diagnose = triage::anthropic(
        AnthropicOptions::new().api_key("test-key").base_url("https://api.anthropic.com").transport(transport),
    )
    .unwrap();
    let errors = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = errors.clone();
    let cw = Client::builder()
        .alert(slack)
        .triage(diagnose)
        .no_cron_secret()
        .on_error(move |e, w| sink.lock().unwrap().push(format!("{w}: {e}")))
        .build()
        .unwrap();
    let job = cw.job("nightly", JobOptions::new()).unwrap();
    let result = job.run(|_| async { Err::<(), _>(std::io::Error::other("no space left on device")) }).await;
    assert!(result.is_err());
    assert!(errors.lock().unwrap().is_empty(), "{:?}", errors.lock().unwrap());

    let taken = rec.taken.lock().unwrap().clone();
    assert_eq!(taken.len(), 2, "one triage, then one alert");
    assert_eq!(taken[0].url, "https://api.anthropic.com/v1/messages?beta=true");
    let prompt = String::from_utf8(taken[0].body.clone()).unwrap();
    assert!(prompt.contains("no space left on device"), "{prompt}");
    assert_eq!(taken[1].url, "https://hooks.slack.example/T/B/x");
    let body = String::from_utf8(taken[1].body.clone()).unwrap();
    assert!(body.contains("_Triage:_ The disk is full."), "{body}");
    assert!(body.contains("(<https://app.example/cronwatch/jobs/nightly|open>)"), "{body}");
}
