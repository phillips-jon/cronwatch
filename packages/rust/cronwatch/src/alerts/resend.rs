//! Resend (`alerts/resend.ts`). API reference:
//! <https://resend.com/docs/api-reference/emails/send-email>. POST
//! `https://api.resend.com/emails` with a bearer API key.

use std::sync::Arc;

use super::email::{EmailOptions, compose_email, recipients};
use super::post::Transport;
use super::shared::{alert_id, invalid, send, trimmed};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::Alert;

/// Configures [`resend`].
#[derive(Clone, Default)]
#[non_exhaustive]
pub struct ResendOptions {
    /// An API key from resend.com/api-keys, `re_...`.
    pub api_key: String,
    pub email: EmailOptions,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

super::setters!(ResendOptions {
    text api_key,
    value email: EmailOptions,
    some transport: Arc<dyn Transport>,
});

struct Resend {
    o: ResendOptions,
    api_key: String,
    to: Vec<String>,
}

const ENDPOINT: &str = "https://api.resend.com/emails";

/// Sends alerts as email through Resend.
pub fn resend(options: ResendOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let api_key = trimmed(&options.api_key);
    if api_key.is_empty() {
        return Err(invalid("alerts::resend needs an api_key"));
    }
    let to = recipients("resend", &options.email)?;
    Ok(Arc::new(Resend { o: options, api_key, to }))
}

impl Channel for Resend {
    fn name(&self) -> &str {
        "resend"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let m = compose_email(alert, &self.o.email, &self.to);
            let body = Object::new()
                .with("from", m.from)
                .with("to", m.to.into_iter().map(Value::from).collect::<Vec<_>>())
                .with("subject", m.subject)
                .with("text", m.text)
                .with("html", m.html)
                .to_json();
            let headers = [
                ("content-type", "application/json".to_string()),
                ("authorization", format!("Bearer {}", self.api_key)),
                // The same alert sent twice within 24 hours is delivered once.
                ("idempotency-key", format!("cronwatch-{}", alert_id(alert))),
            ];
            send(&self.o.transport, "Resend", ENDPOINT, &headers, body, &[&self.api_key]).await
        })
    }
}
