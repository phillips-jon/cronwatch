//! Honeybadger (`alerts/honeybadger.ts`). API reference:
//! <https://docs.honeybadger.io/api/reporting-exceptions/>. POST
//! `https://api.honeybadger.io/v1/notices` with `x-api-key`.

use std::sync::Arc;

use super::post::{Transport, cut};
use super::shared::{LinkFn, details, invalid, link_for, run_summary, send, triage, trimmed};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::{Alert, AlertType};

/// Configures [`honeybadger`].
#[derive(Clone, Default)]
#[non_exhaustive]
pub struct HoneybadgerOptions {
    /// A project API key.
    pub api_key: String,
    /// `""` for `production`.
    pub environment: String,
    /// The API's origin, `https://eu-api.honeybadger.io` for the EU. `""` for
    /// `https://api.honeybadger.io`.
    pub endpoint: String,
    /// Also reports recoveries. Off by default: a notice is for what broke.
    pub recovered: bool,
    /// A link back to the job in your dashboard, sent as the notice's URL.
    pub link: Option<LinkFn>,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

super::setters!(HoneybadgerOptions {
    text api_key,
    text environment,
    text endpoint,
    flag recovered,
    link link,
    some transport: Arc<dyn Transport>,
});

struct Honeybadger {
    o: HoneybadgerOptions,
    api_key: String,
    url: String,
    environment: String,
}

fn class(t: &AlertType) -> String {
    match t {
        AlertType::Missed => "CronWatch::Missed".into(),
        AlertType::Failed => "CronWatch::Failed".into(),
        AlertType::Stuck => "CronWatch::Stuck".into(),
        AlertType::Slow => "CronWatch::Slow".into(),
        AlertType::OverBudget => "CronWatch::OverBudget".into(),
        AlertType::Recovered => "CronWatch::Recovered".into(),
        AlertType::Other(s) => format!("CronWatch::{s}"),
    }
}

/// Reports alerts to Honeybadger as notices, one fault per job and alert
/// type.
pub fn honeybadger(options: HoneybadgerOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let api_key = trimmed(&options.api_key);
    if api_key.is_empty() {
        return Err(invalid("alerts::honeybadger needs an api_key"));
    }
    let endpoint = if options.endpoint.is_empty() { "https://api.honeybadger.io" } else { options.endpoint.as_str() };
    let url = format!("{}/v1/notices", endpoint.trim_end_matches('/'));
    let environment = if options.environment.is_empty() { "production".into() } else { options.environment.clone() };
    Ok(Arc::new(Honeybadger { o: options, api_key, url, environment }))
}

impl Channel for Honeybadger {
    fn name(&self) -> &str {
        "honeybadger"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.o;
            if alert.alert_type == AlertType::Recovered && !o.recovered {
                return Ok(());
            }
            let link = link_for(&o.link, alert);
            let kind = alert.alert_type.as_str();
            let mut request = Object::new().with("component", "cronwatch").with("action", alert.job.as_str());
            if !link.is_empty() {
                request.set("url", link);
            }
            let mut about = Object::new().with("job", alert.job.as_str()).with("type", kind);
            if !triage(alert).is_empty() {
                about.set("triage", triage(alert));
            }
            about.set("details", details(alert));
            about.set("run", run_summary(alert));
            request.set("context", about);
            let notice = Object::new()
                .with("notifier", Object::new().with("name", "cronwatch").with("url", "https://cronwatch.dev"))
                .with(
                    "error",
                    Object::new()
                        .with("class", class(&alert.alert_type))
                        .with("message", cut(&format!("{}\n{}", alert.title, alert.message), 8000))
                        .with(
                            "backtrace",
                            vec![Value::Object(
                                Object::new()
                                    .with("number", "0")
                                    .with("file", format!("cronwatch/{}", alert.job))
                                    .with("method", kind),
                            )],
                        )
                        .with("fingerprint", format!("cronwatch:{}:{kind}", alert.job))
                        .with("tags", vec![Value::from("cronwatch"), Value::from(kind)]),
                )
                .with("request", request)
                .with("server", Object::new().with("environment_name", self.environment.as_str()));
            let headers = [
                ("content-type", "application/json".to_string()),
                ("accept", "application/json".to_string()),
                ("x-api-key", self.api_key.clone()),
            ];
            send(&o.transport, "Honeybadger", &self.url, &headers, notice.to_json(), &[&self.api_key]).await
        })
    }
}
