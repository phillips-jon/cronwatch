//! Bugsnag, through the Error Reporting API (`alerts/bugsnag.ts`). API
//! reference: <https://bugsnagerrorreportingapi.docs.apiary.io/>. POST
//! `https://notify.bugsnag.com/` with `bugsnag-api-key`, payload version 5.

use std::sync::Arc;

use super::post::{Transport, cut};
use super::ses::now_ms;
use super::shared::{LinkFn, details, invalid, link_for, run_summary, send, severity, triage, trimmed};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{self, Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::{Alert, AlertType};

/// Configures [`bugsnag`].
#[derive(Clone, Default)]
#[non_exhaustive]
pub struct BugsnagOptions {
    /// A project's notifier API key.
    pub api_key: String,
    /// `""` for `production`.
    pub release_stage: String,
    /// The notify endpoint, for on-premise Bugsnag. `""` for
    /// `https://notify.bugsnag.com/`.
    pub endpoint: String,
    /// Also reports recoveries. Off by default: an event is for what broke.
    pub recovered: bool,
    /// The clock `bugsnag-sent-at` is read from, in epoch milliseconds. For
    /// tests; `None` for the time now.
    pub now: Option<Arc<dyn Fn() -> i64 + Send + Sync>>,
    /// A link back to the job in your dashboard, sent as metadata.
    pub link: Option<LinkFn>,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

super::setters!(BugsnagOptions {
    text api_key,
    text release_stage,
    text endpoint,
    flag recovered,
    clock now,
    link link,
    some transport: Arc<dyn Transport>,
});

struct Bugsnag {
    o: BugsnagOptions,
    api_key: String,
    url: String,
    stage: String,
}

/// Reports alerts to Bugsnag as handled events, grouped per job and alert
/// type.
pub fn bugsnag(options: BugsnagOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let api_key = trimmed(&options.api_key);
    if api_key.is_empty() {
        return Err(invalid("alerts::bugsnag needs an api_key"));
    }
    let url = if options.endpoint.is_empty() { "https://notify.bugsnag.com/".into() } else { options.endpoint.clone() };
    let stage = if options.release_stage.is_empty() { "production".into() } else { options.release_stage.clone() };
    Ok(Arc::new(Bugsnag { o: options, api_key, url, stage }))
}

impl Channel for Bugsnag {
    fn name(&self) -> &str {
        "bugsnag"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.o;
            if alert.alert_type == AlertType::Recovered && !o.recovered {
                return Ok(());
            }
            let link = link_for(&o.link, alert);
            let kind = alert.alert_type.as_str();
            let mut meta = Object::new().with("job", alert.job.as_str()).with("type", kind);
            if !triage(alert).is_empty() {
                meta.set("triage", triage(alert));
            }
            if !link.is_empty() {
                meta.set("link", link);
            }
            meta.set("details", details(alert));
            meta.set("run", run_summary(alert));
            let exception = Object::new()
                .with("errorClass", format!("CronWatch {kind}"))
                .with("message", cut(&format!("{}\n{}", alert.title, alert.message), 8000))
                .with("stacktrace", Vec::<Value>::new())
                .with("type", "nodejs");
            let event = Object::new()
                .with("exceptions", vec![Value::Object(exception)])
                .with("severity", severity(&alert.alert_type))
                .with("unhandled", false)
                .with("severityReason", Object::new().with("type", "handledException"))
                .with("context", alert.job.as_str())
                .with("groupingHash", format!("cronwatch:{}:{kind}", alert.job))
                .with("metaData", Object::new().with("cronwatch", meta))
                .with("app", Object::new().with("releaseStage", self.stage.as_str()))
                .with("device", Object::new().with("time", js::iso_string(alert.at)));
            let payload = Object::new()
                .with("apiKey", self.api_key.as_str())
                .with("payloadVersion", "5")
                .with(
                    "notifier",
                    Object::new()
                        .with("name", "cronwatch")
                        .with("version", "1.0.0")
                        .with("url", "https://cronwatch.dev"),
                )
                .with("events", vec![Value::Object(event)]);
            let now = o.now.as_ref().map_or_else(now_ms, |f| f());
            let headers = [
                ("content-type", "application/json".to_string()),
                ("bugsnag-api-key", self.api_key.clone()),
                ("bugsnag-payload-version", "5".to_string()),
                ("bugsnag-sent-at", js::iso_string(now)),
            ];
            send(&o.transport, "Bugsnag", &self.url, &headers, payload.to_json(), &[&self.api_key]).await
        })
    }
}
