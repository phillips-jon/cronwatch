//! Mailgun (`alerts/mailgun.ts`). API reference:
//! <https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages/post-v3--domain-name--messages>.
//! POST `https://api.mailgun.net/v3/<domain>/messages` (`api.eu.mailgun.net`
//! for the EU region), form encoded, with basic auth `api:<key>`.

use std::sync::Arc;

use super::email::{EmailOptions, compose_email, recipients};
use super::post::Transport;
use super::shared::{basic_auth, encode_uri_component, form, invalid, send, trimmed};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::store::{BoxError, BoxFuture};
use crate::types::Alert;

/// Configures [`mailgun`].
#[derive(Clone, Default)]
pub struct MailgunOptions {
    /// A sending or account API key.
    pub api_key: String,
    /// The sending domain, `mg.example.com`.
    pub domain: String,
    /// `eu` for a domain in the EU region. `""` for the US.
    pub region: String,
    pub email: EmailOptions,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

struct Mailgun {
    o: MailgunOptions,
    api_key: String,
    url: String,
    to: Vec<String>,
}

/// Sends alerts as email through Mailgun.
pub fn mailgun(options: MailgunOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let api_key = trimmed(&options.api_key);
    if api_key.is_empty() {
        return Err(invalid("alerts::mailgun needs an api_key"));
    }
    if options.domain.is_empty() {
        return Err(invalid("alerts::mailgun needs a domain"));
    }
    let to = recipients("mailgun", &options.email)?;
    let host = if options.region == "eu" { "https://api.eu.mailgun.net" } else { "https://api.mailgun.net" };
    let url = format!("{host}/v3/{}/messages", encode_uri_component(&options.domain));
    Ok(Arc::new(Mailgun { o: options, api_key, url, to }))
}

impl Channel for Mailgun {
    fn name(&self) -> &str {
        "mailgun"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let m = compose_email(alert, &self.o.email, &self.to);
            let mut pairs = vec![("from", m.from.as_str())];
            pairs.extend(m.to.iter().map(|t| ("to", t.as_str())));
            pairs.extend([
                ("subject", m.subject.as_str()),
                ("text", m.text.as_str()),
                ("html", m.html.as_str()),
                ("o:tag", "cronwatch"),
            ]);
            let headers = [
                ("content-type", "application/x-www-form-urlencoded".to_string()),
                ("authorization", basic_auth("api", &self.api_key)),
            ];
            send(&self.o.transport, "Mailgun", &self.url, &headers, form(&pairs), &[&self.api_key]).await
        })
    }
}
