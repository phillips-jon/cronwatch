//! A signed webhook to any URL (`alerts/webhook.ts`).

use std::sync::Arc;

use super::post::{self, Transport};
use super::shared::{hex, hmac_sha256, invalid};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js;
use crate::store::{BoxError, BoxFuture};
use crate::types::Alert;

/// Configures [`webhook`].
#[derive(Clone, Default)]
pub struct WebhookOptions {
    /// Where the alert is posted. Errors name only its origin, since a
    /// webhook URL's path or query is often the credential.
    pub url: String,
    /// Extra request headers, in order, an `authorization` header say.
    /// Values are trimmed of the spaces and newlines a paste leaves.
    pub headers: Vec<(String, String)>,
    /// When set, each request carries `x-cronwatch-signature:
    /// sha256=<hex>`, the HMAC-SHA256 of the raw body with this secret, so
    /// the receiver can verify it (see [`signature`]).
    pub secret: String,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

struct Webhook(WebhookOptions);

/// Posts each alert as JSON to any URL. The body is the [`Alert`] as the SDK
/// writes it (`Alert::to_json`). A redirect is an error: point the URL at
/// where the receiver really is.
pub fn webhook(options: WebhookOptions) -> Result<Arc<dyn Channel>, Error> {
    if options.url.is_empty() {
        return Err(invalid("alerts::webhook needs a url"));
    }
    Ok(Arc::new(Webhook(options)))
}

/// The webhook's signature of a body: the HMAC-SHA256 of the body with the
/// secret, as lowercase hex. The request carries it as
/// `x-cronwatch-signature: sha256=<signature>`.
pub fn signature(secret: &str, body: &str) -> String {
    hex(&hmac_sha256(secret.as_bytes(), body))
}

/// Sets a header as a JavaScript object's key is set: an exact name already
/// there takes the new value in its place, a new one goes last.
pub(crate) fn assign(headers: &mut Vec<(String, String)>, name: &str, value: String) {
    match headers.iter_mut().find(|(n, _)| n == name) {
        Some(h) => h.1 = value,
        None => headers.push((name.to_string(), value)),
    }
}

impl Channel for Webhook {
    fn name(&self) -> &str {
        "webhook"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.0;
            let body = alert.to_json();
            let mut headers = vec![
                ("content-type".to_string(), "application/json".to_string()),
                ("user-agent".into(), "cronwatch".into()),
            ];
            for (name, value) in &o.headers {
                // A pasted Authorization value often carries a stray space or newline, which fetch would refuse.
                assign(&mut headers, name, js::trim(value).to_string());
            }
            if !o.secret.is_empty() {
                assign(&mut headers, "x-cronwatch-signature", format!("sha256={}", signature(&o.secret, &body)));
            }
            let list: Vec<(&str, String)> = headers.iter().map(|(n, v)| (n.as_str(), v.clone())).collect();
            let t = post::transport(&o.transport)?;
            // A redirect is refused, not followed: the headers (and the signature) would go with it.
            let answer = post::fetch(&*t, post::TIMEOUT, &o.url, &list, body.into_bytes()).await?;
            if !answer.ok() {
                // Only the origin: a webhook URL's path or query often is the credential.
                return Err(post::fail(format!("Webhook {} answered {}", post::origin(&o.url), answer.status)));
            }
            Ok(())
        })
    }
}
