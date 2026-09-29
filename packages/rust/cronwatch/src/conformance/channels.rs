//! Replays `conformance/channels.json`, the requests the SDK's channels make
//! (`scripts/conformance.mjs` drives them with a stub fetch): every request's
//! URL, headers (name, value and position) and body, byte for byte, for
//! thirteen sample alerts and each channel's option sets; the error each
//! gives for a refused request; Twilio's partial delivery; and the text
//! cuts.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use super::{digest, field, fixture, objects};
use crate::alerts::post::error_body;
use crate::alerts::testing::{compose_email, sms_body, sms_segments};
use crate::alerts::*;
use crate::deliver::{Channel, ChannelContext};
use crate::js::{self, Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::Alert;

type Answer = Arc<dyn Fn(&str) -> (u16, String) + Send + Sync>;

/// A transport that keeps each request and answers each with the status and
/// body `answer` gives for its body.
struct Recorder {
    requests: Mutex<Vec<Request>>,
    answer: Mutex<Answer>,
}

impl Recorder {
    fn new() -> Arc<Recorder> {
        Arc::new(Recorder { requests: Mutex::new(Vec::new()), answer: Mutex::new(Arc::new(|_| (200, String::new()))) })
    }

    fn reset(&self, answer: Answer) {
        self.requests.lock().unwrap().clear();
        *self.answer.lock().unwrap() = answer;
    }

    fn answer_with(&self, status: u16, body: &str) {
        let body = body.to_string();
        self.reset(Arc::new(move |_| (status, body.clone())));
    }

    fn taken(&self) -> Vec<Request> {
        self.requests.lock().unwrap().clone()
    }
}

impl Transport for Recorder {
    fn post(&self, request: Request) -> BoxFuture<'_, Result<Response, BoxError>> {
        let answer = self.answer.lock().unwrap().clone();
        let (status, body) = answer(&String::from_utf8_lossy(&request.body));
        self.requests.lock().unwrap().push(request);
        Box::pin(std::future::ready(Ok(Response::new(status, body))))
    }
}

fn text<'a>(o: &'a Object, key: &str) -> &'a str {
    field(o, key).as_str().unwrap_or("")
}

/// A string or a list of strings.
fn strs(v: &Value) -> Vec<String> {
    match v {
        Value::String(s) => vec![s.clone()],
        Value::Array(list) => list.iter().map(|e| e.as_str().unwrap_or("").to_string()).collect(),
        _ => Vec::new(),
    }
}

/// A channel from a fixture's options, as the script's `materialize()`
/// makes it: `link: true` is the usual link, `now` a fixed clock.
fn build(name: &str, o: &Object, transport: Arc<dyn Transport>) -> Arc<dyn Channel> {
    let link: Option<LinkFn> = (field(o, "link") == &Value::Bool(true))
        .then(|| Arc::new(|a: &Alert| format!("https://app.example/cronwatch/jobs/{}", a.job)) as LinkFn);
    let now = field(o, "now").as_f64().map(|n| Arc::new(move || n as i64) as Arc<dyn Fn() -> i64 + Send + Sync>);
    let email = EmailOptions {
        from: text(o, "from").into(),
        to: strs(field(o, "to")),
        subject_prefix: text(o, "subjectPrefix").into(),
        link: link.clone(),
    };
    let recovered = field(o, "recovered").as_bool();
    let t = Some(transport);
    let s = |key: &str| text(o, key).to_string();
    let made = match name {
        "slack" => slack(SlackOptions { webhook_url: s("webhookUrl"), link, transport: t }),
        "discord" => discord(DiscordOptions { webhook_url: s("webhookUrl"), link, transport: t }),
        "webhook" => {
            let headers = field(o, "headers")
                .as_object()
                .map(|h| h.iter().map(|(k, v)| (k.to_string(), v.as_str().unwrap_or("").to_string())).collect())
                .unwrap_or_default();
            webhook(WebhookOptions { url: s("url"), secret: s("secret"), headers, transport: t })
        }
        "resend" => resend(ResendOptions { api_key: s("apiKey"), email, transport: t }),
        "postmark" => postmark(PostmarkOptions {
            server_token: s("serverToken"),
            message_stream: s("messageStream"),
            email,
            transport: t,
        }),
        "sendgrid" => sendgrid(SendgridOptions { api_key: s("apiKey"), region: s("region"), email, transport: t }),
        "mailgun" => mailgun(MailgunOptions {
            api_key: s("apiKey"),
            domain: s("domain"),
            region: s("region"),
            email,
            transport: t,
        }),
        "ses" => ses(SesOptions {
            region: s("region"),
            access_key_id: s("accessKeyId"),
            secret_access_key: s("secretAccessKey"),
            session_token: s("sessionToken"),
            configuration_set_name: s("configurationSetName"),
            email,
            now,
            transport: t,
        }),
        "twilio" => twilio(TwilioOptions {
            account_sid: s("accountSid"),
            auth_token: s("authToken"),
            api_key_sid: s("apiKeySid"),
            api_key_secret: s("apiKeySecret"),
            from: s("from"),
            messaging_service_sid: s("messagingServiceSid"),
            to: strs(field(o, "to")),
            recovered: recovered == Some(true),
            segments: field(o, "segments").as_f64().map(|n| n as u32),
            link,
            transport: t,
        }),
        "sentry" => sentry(SentryOptions {
            dsn: s("dsn"),
            environment: s("environment"),
            release: s("release"),
            skip_recovered: recovered == Some(false),
            link,
            transport: t,
        }),
        "honeybadger" => honeybadger(HoneybadgerOptions {
            api_key: s("apiKey"),
            environment: s("environment"),
            endpoint: s("endpoint"),
            recovered: recovered == Some(true),
            link,
            transport: t,
        }),
        "datadog" => datadog(DatadogOptions {
            api_key: s("apiKey"),
            site: s("site"),
            tags: strs(field(o, "tags")),
            host: s("host"),
            link,
            transport: t,
        }),
        "rollbar" => rollbar(RollbarOptions {
            access_token: s("accessToken"),
            environment: s("environment"),
            skip_recovered: recovered == Some(false),
            link,
            transport: t,
        }),
        "bugsnag" => bugsnag(BugsnagOptions {
            api_key: s("apiKey"),
            release_stage: s("releaseStage"),
            endpoint: s("endpoint"),
            recovered: recovered == Some(true),
            now,
            link,
            transport: t,
        }),
        "newrelic" => {
            let account = match field(o, "accountId") {
                Value::Number(n) => js::format_number(*n),
                v => v.as_str().unwrap_or("").to_string(),
            };
            newrelic(NewRelicOptions {
                account_id: account,
                api_key: s("apiKey"),
                region: s("region"),
                event_type: s("eventType"),
                link,
                transport: t,
            })
        }
        other => panic!("no channel {other}"),
    };
    let ch = made.unwrap_or_else(|e| panic!("{name}: {e}"));
    assert_eq!(ch.name(), name);
    ch
}

/// A captured request against the fixture's, or why not.
fn same_request(got: &Request, want: &Object) -> Result<(), String> {
    if got.url != text(want, "url") {
        return Err(format!("url {}, want {}", got.url, text(want, "url")));
    }
    let headers: Vec<(String, String)> = field(want, "headers")
        .as_object()
        .map(|h| h.iter().map(|(k, v)| (k.to_string(), v.as_str().unwrap_or("").to_string())).collect())
        .unwrap_or_default();
    if got.headers != headers {
        return Err(format!("headers {:?}, want {headers:?}", got.headers));
    }
    let body = String::from_utf8(got.body.clone()).map_err(|_| "the body is not UTF-8".to_string())?;
    let (g, w) = (digest(&body).to_json(), field(want, "body").to_json());
    if g != w {
        return Err(format!("body {g}, want {w}\n{body}"));
    }
    Ok(())
}

/// The `To` of a Twilio request's form.
fn form_to(r: &Request) -> String {
    url::form_urlencoded::parse(&r.body).find(|(k, _)| k == "To").map(|(_, v)| v.into_owned()).unwrap_or_default()
}

/// A Twilio send's requests in the order of its numbers, since they are made
/// at once.
fn number_order(requests: &mut [Request], numbers: &[String]) {
    let index = |r: &Request| {
        let to = form_to(r);
        numbers.iter().position(|n| js::trim(n) == to).unwrap_or(usize::MAX)
    };
    requests.sort_by_key(index);
}

#[tokio::test]
async fn conformance_channels() {
    let f = fixture("channels");
    let mut alerts: HashMap<String, Alert> = HashMap::new();
    let mut first: Option<Alert> = None;
    for c in objects(&f, "alerts") {
        let a = Alert::from_value(field(c, "alert")).unwrap();
        first.get_or_insert_with(|| a.clone());
        alerts.insert(text(c, "name").to_string(), a);
    }
    let first = first.expect("no alerts");
    let rec = Recorder::new();
    let transport: Arc<dyn Transport> = rec.clone();
    let cx = ChannelContext::new(|e| panic!("reported: {e}"));
    let mut failures: Vec<String> = Vec::new();
    let mut count = 0;

    for key in ["sends", "providerSends"] {
        for c in objects(&f, key) {
            let o = field(c, "options").as_object().unwrap();
            let ch = build(text(c, "channel"), o, transport.clone());
            rec.answer_with(200, "");
            let what = format!("{} {} {}", text(c, "channel"), o.to_json(), text(c, "alert"));
            if let Err(e) = ch.send(&alerts[text(c, "alert")], &cx).await {
                failures.push(format!("{what}: {e}"));
                continue;
            }
            let mut got = rec.taken();
            let want: Vec<&Object> = if key == "sends" { vec![c] } else { objects(c, "requests") };
            number_order(&mut got, &strs(field(o, "to")));
            if got.len() != want.len() {
                failures.push(format!("{what}: {} requests, want {}", got.len(), want.len()));
                continue;
            }
            for (g, w) in got.iter().zip(want) {
                if let Err(e) = same_request(g, w) {
                    failures.push(format!("{what}: {e}"));
                }
            }
            count += 1;
        }
    }

    for key in ["failures", "providerFailures"] {
        for c in objects(&f, key) {
            let o = field(c, "options").as_object().unwrap();
            let ch = build(text(c, "channel"), o, transport.clone());
            let status = field(c, "status").as_f64().unwrap() as u16;
            rec.answer_with(status, text(c, "body"));
            let got = ch.send(&first, &cx).await.err().map(|e| e.to_string());
            let want = field(c, "error").as_str().map(str::to_string);
            if got != want {
                failures.push(format!(
                    "{} {} answered {status}:\n  got  {got:?}\n  want {want:?}",
                    text(c, "channel"),
                    o.to_json()
                ));
            }
            count += 1;
        }
    }

    let partial = field(&f, "twilioPartial").as_object().unwrap();
    let o = field(partial, "options").as_object().unwrap();
    let numbers = strs(field(o, "to"));
    for c in objects(partial, "cases") {
        let statuses: Vec<u16> =
            field(c, "statuses").as_array().unwrap().iter().map(|s| s.as_f64().unwrap() as u16).collect();
        let (n, s) = (numbers.clone(), statuses.clone());
        rec.reset(Arc::new(move |body: &str| {
            let to = url::form_urlencoded::parse(body.as_bytes())
                .find(|(k, _)| k == "To")
                .map(|(_, v)| v.into_owned())
                .unwrap_or_default();
            match n.iter().position(|x| *x == to) {
                Some(i) if s[i] < 400 => (s[i], "{}".to_string()),
                Some(i) => (s[i], format!(r#"{{"message":"refused {to} with tw-secret"}}"#)),
                None => (500, String::new()),
            }
        }));
        let reported = Arc::new(Mutex::new(Vec::<Value>::new()));
        let sink = reported.clone();
        let ch = build("twilio", o, transport.clone());
        let got = ch.send(&first, &ChannelContext::new(move |e| sink.lock().unwrap().push(Value::from(e)))).await;
        let got_error = got.err().map_or(Value::Null, |e| Value::from(e.to_string()));
        if got_error.to_json() != field(c, "error").to_json() {
            failures.push(format!(
                "twilio {statuses:?}: error {}, want {}",
                got_error.to_json(),
                field(c, "error").to_json()
            ));
        }
        let reported = Value::Array(reported.lock().unwrap().clone());
        if reported.to_json() != field(c, "reported").to_json() {
            failures.push(format!(
                "twilio {statuses:?}: reported {}, want {}",
                reported.to_json(),
                field(c, "reported").to_json()
            ));
        }
        let mut got = rec.taken();
        number_order(&mut got, &numbers);
        for (i, want) in objects(c, "requests").into_iter().enumerate() {
            if got.get(i).map(|r| (r.url.as_str(), form_to(r)))
                != Some((text(want, "url"), text(want, "to").to_string()))
            {
                failures.push(format!("twilio {statuses:?}: request {i}"));
            }
        }
        count += 1;
    }

    let cuts = field(&f, "textCuts").as_object().unwrap();
    for c in objects(cuts, "errorBodies") {
        let secrets: Vec<&str> = field(c, "secrets").as_array().unwrap().iter().filter_map(Value::as_str).collect();
        let got = error_body(text(c, "text"), &secrets);
        if got != text(c, "body") {
            failures.push(format!("errorBody({:?}):\n  got  {got:?}\n  want {:?}", text(c, "text"), text(c, "body")));
        }
        count += 1;
    }
    for c in objects(cuts, "subjects") {
        let mut a = first.clone();
        a.title = text(c, "title").to_string();
        let options = EmailOptions {
            from: "a@example.com".into(),
            to: vec!["b@example.com".into()],
            subject_prefix: text(c, "subjectPrefix").into(),
            link: None,
        };
        let got = compose_email(&a, &options, &["b@example.com".to_string()]).subject;
        if got != text(c, "subject") {
            failures.push(format!("subject of {:?}: {got:?}, want {:?}", a.title, text(c, "subject")));
        }
        count += 1;
    }
    for c in objects(cuts, "smsSegments") {
        let (got, want) = (sms_segments(text(c, "text")), field(c, "segments").as_f64().unwrap() as usize);
        if got != want {
            failures.push(format!("smsSegments({:?}) = {got}, want {want}", text(c, "text")));
        }
        count += 1;
    }
    let mut long = first.clone();
    long.title = "nightly failed".into();
    long.message = format!("{}{{\n", "a".repeat(152)).repeat(12);
    long.triage = None;
    for c in objects(cuts, "smsBodies") {
        let segments = field(c, "segments").as_f64().unwrap_or(f64::NAN);
        let link = if text(c, "link") == "long" {
            format!("https://app.example/{}", "p".repeat(2000))
        } else {
            "https://app.example/j".to_string()
        };
        let got = digest(&sms_body(&long, &link, segments));
        if got.to_json() != field(c, "body").to_json() {
            failures.push(format!(
                "smsBody with {segments} segments: {}, want {}",
                got.to_json(),
                field(c, "body").to_json()
            ));
        }
        count += 1;
    }

    assert!(failures.is_empty(), "channels.json: {} cases differ:\n{}", failures.len(), failures.join("\n"));
    // Every case of the fixture, so a case added there is not skipped here.
    let total = ["sends", "providerSends", "failures", "providerFailures"]
        .iter()
        .map(|k| objects(&f, k).len())
        .sum::<usize>()
        + objects(partial, "cases").len()
        + ["errorBodies", "subjects", "smsSegments", "smsBodies"].iter().map(|k| objects(cuts, k).len()).sum::<usize>();
    assert_eq!(count, total);
    eprintln!("channels.json: {count} cases replayed");
}
