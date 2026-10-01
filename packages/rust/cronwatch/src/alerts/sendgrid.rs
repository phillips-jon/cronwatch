//! SendGrid (`alerts/sendgrid.ts`). API reference:
//! <https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send>.
//! POST `https://api.sendgrid.com/v3/mail/send` (`api.eu.sendgrid.com` for EU
//! subusers) with a bearer API key. Answers 202.

use std::sync::Arc;

use super::email::{EmailOptions, compose_email, parse_address, recipients};
use super::post::Transport;
use super::shared::{invalid, send, trimmed};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::Alert;

/// Configures [`sendgrid`].
#[derive(Clone, Default)]
#[non_exhaustive]
pub struct SendgridOptions {
    /// An API key with Mail Send access, `SG...`.
    pub api_key: String,
    /// `eu` for an EU regional subuser. `""` for the US.
    pub region: String,
    pub email: EmailOptions,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

super::setters!(SendgridOptions {
    text api_key,
    text region,
    value email: EmailOptions,
    some transport: Arc<dyn Transport>,
});

struct Sendgrid {
    o: SendgridOptions,
    api_key: String,
    url: &'static str,
    to: Vec<String>,
}

/// Sends alerts as email through SendGrid.
pub fn sendgrid(options: SendgridOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let api_key = trimmed(&options.api_key);
    if api_key.is_empty() {
        return Err(invalid("alerts::sendgrid needs an api_key"));
    }
    let to = recipients("sendgrid", &options.email)?;
    let url = if options.region == "eu" {
        "https://api.eu.sendgrid.com/v3/mail/send"
    } else {
        "https://api.sendgrid.com/v3/mail/send"
    };
    Ok(Arc::new(Sendgrid { o: options, api_key, url, to }))
}

impl Channel for Sendgrid {
    fn name(&self) -> &str {
        "sendgrid"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let m = compose_email(alert, &self.o.email, &self.to);
            let to: Vec<Value> = m.to.iter().map(|t| parse_address(t)).collect();
            let content =
                |kind: &str, value: String| Value::Object(Object::new().with("type", kind).with("value", value));
            let body = Object::new()
                .with("personalizations", vec![Value::Object(Object::new().with("to", to))])
                .with("from", parse_address(&m.from))
                .with("subject", m.subject)
                // text/plain must come before text/html.
                .with("content", vec![content("text/plain", m.text), content("text/html", m.html)])
                .with("categories", vec![Value::from("cronwatch")])
                .to_json();
            let headers = [
                ("content-type", "application/json".to_string()),
                ("authorization", format!("Bearer {}", self.api_key)),
            ];
            send(&self.o.transport, "SendGrid", self.url, &headers, body, &[&self.api_key]).await
        })
    }
}
