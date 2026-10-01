//! New Relic custom events, through the Event API (`alerts/newrelic.ts`).
//! API reference: <https://docs.newrelic.com/docs/data-apis/ingest-apis/event-api/introduction-event-api/>.
//! POST `https://insights-collector.newrelic.com/v1/accounts/<id>/events`
//! (`insights-collector.eu01.nr-data.net` for EU accounts) with `api-key`.

use std::sync::Arc;

use super::post::{Transport, cut};
use super::shared::{LinkFn, invalid, link_for, send, severity, triage, trimmed};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::Alert;

/// Configures [`newrelic`].
#[derive(Clone, Default)]
#[non_exhaustive]
pub struct NewRelicOptions {
    /// The account id, the number in your New Relic URLs.
    pub account_id: String,
    /// A license key (an ingest key).
    pub api_key: String,
    /// `eu` for an account in the EU data center. `""` for the US.
    pub region: String,
    /// The event type queried with NRQL. `""` for `CronWatchAlert`.
    pub event_type: String,
    /// A link back to the job in your dashboard, sent as an attribute.
    pub link: Option<LinkFn>,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

super::setters!(NewRelicOptions {
    text account_id,
    text api_key,
    text region,
    text event_type,
    link link,
    some transport: Arc<dyn Transport>,
});

struct NewRelic {
    o: NewRelicOptions,
    api_key: String,
    url: String,
    event_type: String,
}

/// Sends alerts to New Relic as custom events.
pub fn newrelic(options: NewRelicOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let api_key = trimmed(&options.api_key);
    if api_key.is_empty() {
        return Err(invalid("alerts::newrelic needs an api_key"));
    }
    if options.account_id.is_empty() || !options.account_id.bytes().all(|c| c.is_ascii_digit()) {
        return Err(invalid("alerts::newrelic needs a numeric account_id"));
    }
    let host = if options.region == "eu" {
        "https://insights-collector.eu01.nr-data.net"
    } else {
        "https://insights-collector.newrelic.com"
    };
    let url = format!("{host}/v1/accounts/{}/events", options.account_id);
    let event_type = if options.event_type.is_empty() { "CronWatchAlert".into() } else { options.event_type.clone() };
    Ok(Arc::new(NewRelic { o: options, api_key, url, event_type }))
}

impl Channel for NewRelic {
    fn name(&self) -> &str {
        "newrelic"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.o;
            let link = link_for(&o.link, alert);
            let mut event = Object::new()
                .with("eventType", self.event_type.as_str())
                .with("timestamp", alert.at)
                .with("job", cut(&alert.job, 4095))
                .with("alertType", alert.alert_type.as_str())
                .with("severity", severity(&alert.alert_type))
                .with("title", cut(&alert.title, 4095))
                .with("message", cut(&alert.message, 4095));
            if !triage(alert).is_empty() {
                event.set("triage", cut(triage(alert), 4095));
            }
            if !link.is_empty() {
                event.set("link", cut(&link, 4095));
            }
            if let Some(r) = &alert.run {
                event.set("runId", r.id.as_str());
                event.set("runStatus", r.status.as_str());
                if let Some(d) = r.duration_ms {
                    event.set("durationMs", d);
                }
            }
            let headers = [("content-type", "application/json".to_string()), ("api-key", self.api_key.clone())];
            let body = Value::Array(vec![Value::Object(event)]).to_json();
            send(&o.transport, "New Relic", &self.url, &headers, body, &[&self.api_key]).await
        })
    }
}
