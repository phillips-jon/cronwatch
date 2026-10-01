//! Replays `conformance/triage.json`: the parameters the SDK hands the
//! official client for each context and option set, the diagnosis read from
//! each answer, and (the `wire` cases) the HTTP request that client sends,
//! which the port makes itself.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use super::{digest, field, fixture, objects};
use crate::alerts::{Request, Response, Transport};
use crate::deliver::TriageContext;
use crate::js::{LoneJson, Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::triage::{AnthropicOptions, DEADLINE, anthropic, diagnosis, params};
use crate::types::{Alert, Run};

/// The fixture's triage contexts, by name.
pub(crate) fn contexts(f: &Object) -> HashMap<String, TriageContext> {
    objects(f, "contexts")
        .into_iter()
        .map(|c| {
            let alert = Alert::from_value(field(c, "alert")).unwrap();
            let recent_runs =
                field(c, "recentRuns").as_array().unwrap().iter().map(|r| Run::from_value(r).unwrap()).collect();
            (field(c, "name").as_str().unwrap().to_string(), TriageContext { alert, recent_runs })
        })
        .collect()
}

/// A fixture's option set.
fn options_of(o: &Object) -> AnthropicOptions {
    let s = |key: &str| field(o, key).as_str().unwrap_or("").to_string();
    AnthropicOptions {
        model: s("model"),
        effort: s("effort"),
        context: s("context"),
        max_tokens: field(o, "maxTokens").as_f64().map(|n| n as i64),
        no_fallbacks: field(o, "fallbacks").as_bool() == Some(false),
        ..Default::default()
    }
}

/// Answers every request with one Messages API answer and keeps the request.
#[derive(Default)]
pub(crate) struct Recorder {
    pub(crate) taken: Mutex<Vec<Request>>,
}

impl Transport for Recorder {
    fn post(&self, request: Request) -> BoxFuture<'_, Result<Response, BoxError>> {
        self.taken.lock().unwrap().push(request);
        let answer = r#"{"id":"msg_1","type":"message","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}],"usage":{}}"#;
        Box::pin(std::future::ready(Ok(Response::new(200, answer))))
    }
}

#[tokio::test]
async fn conformance_triage() {
    let f = fixture("triage");
    let by_name = contexts(&f);
    let mut failures = Vec::new();
    let mut count = 0;
    for c in objects(&f, "requests") {
        let o = field(c, "options").as_object().unwrap();
        let context = field(c, "context").as_str().unwrap();
        let mut lone = LoneJson::new();
        let p = params(&options_of(o), &by_name[context], &mut lone);
        let got = lone.stringify(&Value::Object(p));
        if got != field(c, "params").to_json() {
            failures.push(format!(
                "{} {context}: params\n  got  {got}\n  want {}",
                o.to_json(),
                field(c, "params").to_json()
            ));
        }
        let ro = field(c, "requestOptions").as_object().unwrap();
        assert_eq!(field(ro, "timeout").as_f64(), Some(DEADLINE.as_millis() as f64));
        assert_eq!(field(ro, "maxRetries").as_f64(), Some(0.0));
        count += 1;
    }
    for c in objects(&f, "responses") {
        let got = diagnosis(field(c, "response"));
        let want = field(c, "result").as_str().unwrap_or("");
        if got != want {
            failures.push(format!("{}: {got:?}, want {want:?}", field(c, "response").to_json()));
        }
        count += 1;
    }
    for c in objects(&f, "wire") {
        let o = field(c, "options").as_object().unwrap();
        let rec = Arc::new(Recorder::default());
        let triage = anthropic(AnthropicOptions {
            api_key: "test-key".into(),
            base_url: "https://api.anthropic.com".into(),
            transport: Some(rec.clone()),
            ..options_of(o)
        })
        .unwrap();
        let context = field(c, "context").as_str().unwrap();
        let answer = triage.triage(by_name[context].clone()).await.unwrap();
        assert_eq!(answer, "ok");
        let taken = rec.taken.lock().unwrap().clone();
        assert_eq!(taken.len(), 1);
        let want = field(c, "request").as_object().unwrap();
        assert_eq!(field(want, "method").as_str(), Some("POST"));
        if taken[0].url != field(want, "url").as_str().unwrap() {
            failures.push(format!("{}: url {}", o.to_json(), taken[0].url));
        }
        let kept = ["accept", "anthropic-beta", "anthropic-version", "content-type", "x-api-key"];
        let got: Vec<(String, String)> =
            taken[0].headers.iter().filter(|(n, _)| kept.contains(&n.as_str())).cloned().collect();
        let wanted: Vec<(String, String)> = field(want, "headers")
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.to_string(), v.as_str().unwrap().to_string()))
            .collect();
        if got != wanted {
            failures.push(format!("{}: headers {got:?}, want {wanted:?}", o.to_json()));
        }
        let ua = taken[0].headers.iter().find(|(n, _)| n == "user-agent").map(|(_, v)| v.clone());
        assert_eq!(ua, Some(format!("cronwatch-rust/{}", crate::VERSION)));
        let body = String::from_utf8(taken[0].body.clone()).unwrap();
        let digest = digest(&body);
        if digest.to_json() != field(want, "body").to_json() {
            failures.push(format!(
                "{}: body {}, want {}",
                o.to_json(),
                digest.to_json(),
                field(want, "body").to_json()
            ));
        }
        count += 1;
    }
    assert!(failures.is_empty(), "triage.json: {} cases differ:\n{}", failures.len(), failures.join("\n"));
    let total = ["requests", "responses", "wire"].iter().map(|k| objects(&f, k).len()).sum::<usize>();
    assert_eq!(count, total);
    eprintln!("triage.json: {count} cases replayed");
}
