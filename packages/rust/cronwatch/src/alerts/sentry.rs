//! Sentry, through the envelope endpoint (`alerts/sentry.ts`).
//! Envelopes: <https://develop.sentry.dev/sdk/data-model/envelopes/>.
//! Event payload: <https://develop.sentry.dev/sdk/data-model/event-payloads/>.
//! DSN and X-Sentry-Auth:
//! <https://develop.sentry.dev/sdk/foundations/transport/authentication/>.

use std::sync::Arc;

use super::post::{Transport, cut, percent_decode};
use super::shared::{LinkFn, alert_id, details, invalid, link_for, run_summary, send, severity, triage, trimmed};
use super::sigv4::host;
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::{Alert, AlertType};

/// Configures [`sentry`].
#[derive(Clone, Default)]
#[non_exhaustive]
pub struct SentryOptions {
    /// The project's DSN, `https://<key>@o0.ingest.sentry.io/<project>`.
    pub dsn: String,
    /// `""` for `production`.
    pub environment: String,
    pub release: String,
    /// Leaves recoveries out. They are sent by default, as info events.
    pub skip_recovered: bool,
    /// A link back to the job in your dashboard, sent as extra data.
    pub link: Option<LinkFn>,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

super::setters!(SentryOptions {
    text dsn,
    text environment,
    text release,
    flag skip_recovered,
    link link,
    some transport: Arc<dyn Transport>,
});

struct Sentry {
    o: SentryOptions,
    endpoint: String,
    public_key: String,
    environment: String,
}

/// The envelope endpoint and the public key of a DSN.
fn parse_dsn(dsn: &str) -> Result<(String, String), Error> {
    let url = super::post::parse(dsn).map_err(|_| invalid("alerts::sentry needs a valid dsn"))?;
    let mut segments: Vec<&str> = url.path().split('/').filter(|s| !s.is_empty()).collect();
    let project = segments.pop().unwrap_or("");
    if url.username().is_empty() || project.is_empty() || !project.bytes().all(|c| c.is_ascii_digit()) {
        return Err(invalid("alerts::sentry needs a dsn like https://<key>@<host>/<project>"));
    }
    let prefix = if segments.is_empty() { String::new() } else { format!("/{}", segments.join("/")) };
    let endpoint = format!("{}://{}{prefix}/api/{project}/envelope/", url.scheme(), host(&url));
    Ok((endpoint, percent_decode(url.username())))
}

/// Sends alerts to Sentry as events, one issue per job and alert type.
pub fn sentry(options: SentryOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let dsn = trimmed(&options.dsn);
    if dsn.is_empty() {
        return Err(invalid("alerts::sentry needs a dsn"));
    }
    let (endpoint, public_key) = parse_dsn(&dsn)?;
    let environment = if options.environment.is_empty() { "production".into() } else { options.environment.clone() };
    Ok(Arc::new(Sentry { o: options, endpoint, public_key, environment }))
}

impl Channel for Sentry {
    fn name(&self) -> &str {
        "sentry"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.o;
            if alert.alert_type == AlertType::Recovered && o.skip_recovered {
                return Ok(());
            }
            let event_id = alert_id(alert);
            let link = link_for(&o.link, alert);
            let mut event = Object::new()
                .with("event_id", event_id.as_str())
                .with("timestamp", alert.at as f64 / 1000.0)
                .with("platform", "other")
                .with("level", severity(&alert.alert_type))
                .with("logger", "cronwatch")
                .with("transaction", alert.job.as_str())
                .with("environment", self.environment.as_str());
            if !o.release.is_empty() {
                event.set("release", o.release.as_str());
            }
            // The first line is the issue title.
            event.set(
                "logentry",
                Object::new().with("formatted", cut(&format!("{}\n\n{}", alert.title, alert.message), 8192)),
            );
            event.set(
                "fingerprint",
                vec![Value::from("cronwatch"), Value::from(alert.job.as_str()), Value::from(alert.alert_type.as_str())],
            );
            event.set("tags", Object::new().with("job", cut(&alert.job, 199)).with("type", alert.alert_type.as_str()));
            let mut extra = Object::new();
            if !triage(alert).is_empty() {
                extra.set("triage", triage(alert));
            }
            if !link.is_empty() {
                extra.set("link", link);
            }
            extra.set("details", details(alert));
            extra.set("run", run_summary(alert));
            event.set("extra", extra);
            let payload = event.to_json();
            let envelope = format!(
                "{}\n{}\n{payload}\n",
                Object::new().with("event_id", event_id.as_str()).to_json(),
                Object::new()
                    .with("type", "event")
                    .with("content_type", "application/json")
                    .with("length", payload.len())
                    .to_json(),
            );
            let headers = [
                ("content-type", "application/x-sentry-envelope".to_string()),
                (
                    "x-sentry-auth",
                    format!("Sentry sentry_version=7, sentry_key={}, sentry_client=cronwatch", self.public_key),
                ),
            ];
            send(&o.transport, "Sentry", &self.endpoint, &headers, envelope, &[&self.public_key]).await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dsns_are_read_as_the_sdk_reads_them() {
        assert_eq!(
            parse_dsn("https://pub%20key@sentry.example.com:9000/a/b/7").unwrap(),
            ("https://sentry.example.com:9000/a/b/api/7/envelope/".to_string(), "pub key".to_string())
        );
        assert_eq!(
            parse_dsn("https://k@o1.ingest.sentry.io:443/42").unwrap().0,
            "https://o1.ingest.sentry.io/api/42/envelope/"
        );
        assert_eq!(parse_dsn("not a url").unwrap_err().to_string(), "alerts::sentry needs a valid dsn");
        assert_eq!(
            parse_dsn("https://o1.ingest.sentry.io/42").unwrap_err().to_string(),
            "alerts::sentry needs a dsn like https://<key>@<host>/<project>"
        );
        assert!(parse_dsn("https://k@o1.ingest.sentry.io/x").is_err());
    }
}
