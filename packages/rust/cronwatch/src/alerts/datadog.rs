//! Datadog events (`alerts/datadog.ts`). API reference:
//! <https://docs.datadoghq.com/api/latest/events/#post-an-event>. POST
//! `https://api.<site>/api/v1/events` with `dd-api-key`. Answers 202.

use std::sync::Arc;

use super::post::{Transport, cut};
use super::shared::{LinkFn, invalid, link_for, plain_text, send, sha256_hex, trimmed};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{self, Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::{Alert, AlertType};

/// Configures [`datadog`].
#[derive(Clone, Default)]
#[non_exhaustive]
pub struct DatadogOptions {
    /// An API key (not an application key).
    pub api_key: String,
    /// The Datadog site: `datadoghq.com` (for `""`), `datadoghq.eu`,
    /// `us3.datadoghq.com`, `us5.datadoghq.com`, `ap1.datadoghq.com`,
    /// `ddog-gov.com`.
    pub site: String,
    /// Tags added to every event, `env:prod` say.
    pub tags: Vec<String>,
    /// The host the event is about.
    pub host: String,
    /// A link back to the job in your dashboard, put in the event's text.
    pub link: Option<LinkFn>,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

super::setters!(DatadogOptions {
    text api_key,
    text site,
    texts tags,
    text host,
    link link,
    some transport: Arc<dyn Transport>,
});

struct Datadog {
    o: DatadogOptions,
    api_key: String,
    url: String,
}

fn alert_type(t: &AlertType) -> &'static str {
    match t {
        AlertType::Slow | AlertType::OverBudget => "warning",
        AlertType::Recovered => "success",
        _ => "error",
    }
}

/// The site as the SDK reads it: no scheme, no `api.` or `app.` in front, no
/// slashes after.
fn clean_site(site: &str) -> String {
    let site = site.strip_prefix("https://").or_else(|| site.strip_prefix("http://")).unwrap_or(site);
    let site = site.strip_prefix("api.").or_else(|| site.strip_prefix("app.")).unwrap_or(site);
    site.trim_end_matches('/').to_string()
}

/// Sends alerts to Datadog as events, one aggregation per job and alert
/// type.
pub fn datadog(options: DatadogOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let api_key = trimmed(&options.api_key);
    if api_key.is_empty() {
        return Err(invalid("alerts::datadog needs an api_key"));
    }
    let site = clean_site(if options.site.is_empty() { "datadoghq.com" } else { &options.site });
    if site.is_empty() || !site.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'-') {
        return Err(invalid("alerts::datadog needs a site like datadoghq.com"));
    }
    let url = format!("https://api.{site}/api/v1/events");
    Ok(Arc::new(Datadog { o: options, api_key, url }))
}

/// Datadog's aggregation key is at most 100 characters: a long job name is
/// hashed.
fn aggregation_key(a: &Alert) -> String {
    let key = format!("cronwatch:{}:{}", a.job, a.alert_type);
    if js::len16(&key) <= 100 {
        return key;
    }
    format!("cronwatch:{}", &sha256_hex(&key)[..40])
}

impl Channel for Datadog {
    fn name(&self) -> &str {
        "datadog"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.o;
            let link = link_for(&o.link, alert);
            let mut tags = vec![
                Value::from("cronwatch"),
                Value::from(format!("job:{}", alert.job)),
                Value::from(format!("alert:{}", alert.alert_type)),
            ];
            tags.extend(o.tags.iter().map(|t| Value::from(t.as_str())));
            let mut event = Object::new()
                .with("title", cut(&alert.title, 500))
                .with("text", cut(&plain_text(alert, &link), 4000))
                .with("alert_type", alert_type(&alert.alert_type))
                .with("aggregation_key", aggregation_key(alert))
                .with("date_happened", js::floor_div(alert.at, 1000))
                .with("priority", "normal")
                .with("tags", tags);
            if !o.host.is_empty() {
                event.set("host", o.host.as_str());
            }
            let headers = [
                ("content-type", "application/json".to_string()),
                ("accept", "application/json".to_string()),
                ("dd-api-key", self.api_key.clone()),
            ];
            send(&o.transport, "Datadog", &self.url, &headers, event.to_json(), &[&self.api_key]).await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sites_are_read_as_the_sdk_reads_them() {
        assert_eq!(clean_site("https://app.datadoghq.eu/"), "datadoghq.eu");
        assert_eq!(clean_site("api.us5.datadoghq.com"), "us5.datadoghq.com");
        assert_eq!(clean_site("HTTPS://datadoghq.com"), "HTTPS://datadoghq.com");
        let refused =
            datadog(DatadogOptions { api_key: "k".into(), site: "evil.example/x?".into(), ..Default::default() });
        assert_eq!(refused.err().unwrap().to_string(), "alerts::datadog needs a site like datadoghq.com");
    }
}
