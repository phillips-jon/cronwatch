//! Postmark (`alerts/postmark.ts`). API reference:
//! <https://postmarkapp.com/developer/api/email-api>. POST
//! `https://api.postmarkapp.com/email` with `x-postmark-server-token`.

use std::sync::Arc;

use super::email::{EmailOptions, compose_email, recipients};
use super::post::Transport;
use super::shared::{invalid, send, trimmed};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::Object;
use crate::store::{BoxError, BoxFuture};
use crate::types::Alert;

/// Configures [`postmark`].
#[derive(Clone, Default)]
pub struct PostmarkOptions {
    /// A server API token, from the server's API Tokens tab.
    pub server_token: String,
    /// The message stream. `""` for `outbound`, the transactional stream.
    pub message_stream: String,
    pub email: EmailOptions,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

struct Postmark {
    o: PostmarkOptions,
    token: String,
    stream: String,
    to: Vec<String>,
}

const ENDPOINT: &str = "https://api.postmarkapp.com/email";

/// Sends alerts as email through Postmark.
pub fn postmark(options: PostmarkOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let token = trimmed(&options.server_token);
    if token.is_empty() {
        return Err(invalid("alerts::postmark needs a server_token"));
    }
    let to = recipients("postmark", &options.email)?;
    let stream =
        if options.message_stream.is_empty() { "outbound".to_string() } else { options.message_stream.clone() };
    Ok(Arc::new(Postmark { o: options, token, stream, to }))
}

impl Channel for Postmark {
    fn name(&self) -> &str {
        "postmark"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let m = compose_email(alert, &self.o.email, &self.to);
            let body = Object::new()
                .with("From", m.from)
                .with("To", m.to.join(", "))
                .with("Subject", m.subject)
                .with("TextBody", m.text)
                .with("HtmlBody", m.html)
                .with("MessageStream", self.stream.as_str())
                .with("Tag", "cronwatch")
                .to_json();
            let headers = [
                ("content-type", "application/json".to_string()),
                ("accept", "application/json".to_string()),
                ("x-postmark-server-token", self.token.clone()),
            ];
            send(&self.o.transport, "Postmark", ENDPOINT, &headers, body, &[&self.token]).await
        })
    }
}
