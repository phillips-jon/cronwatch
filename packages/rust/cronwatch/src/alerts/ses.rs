//! Amazon SES, API v2 SendEmail (`alerts/ses.ts`). API reference:
//! <https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html>.
//! POST `https://email.<region>.amazonaws.com/v2/email/outbound-emails`,
//! signed with AWS Signature Version 4, so no AWS SDK is needed.

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use super::email::{EmailOptions, compose_email, recipients};
use super::post::{self, Transport};
use super::shared::{invalid, send, trimmed};
use super::sigv4::{Credentials, SigningRequest, sign};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::Alert;

/// Configures [`ses`].
#[derive(Clone, Default)]
pub struct SesOptions {
    /// The SES region, `us-east-1` say. The from identity must be verified
    /// there.
    pub region: String,
    pub access_key_id: String,
    pub secret_access_key: String,
    /// For temporary credentials, an assumed role say.
    pub session_token: String,
    /// A configuration set for event publishing, if you use one.
    pub configuration_set_name: String,
    pub email: EmailOptions,
    /// The clock requests are signed with, in epoch milliseconds. For tests;
    /// `None` for the time now.
    pub now: Option<Arc<dyn Fn() -> i64 + Send + Sync>>,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

struct Ses {
    o: SesOptions,
    creds: Credentials,
    url: String,
    to: Vec<String>,
}

/// Sends alerts as email through Amazon SES.
pub fn ses(options: SesOptions) -> Result<Arc<dyn Channel>, Error> {
    if options.region.is_empty() {
        return Err(invalid("alerts::ses needs a region"));
    }
    if !options.region.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-') {
        return Err(invalid("alerts::ses needs a region like us-east-1"));
    }
    // A pasted credential often carries a stray space or newline, which would spoil the signature.
    let creds = Credentials {
        access_key_id: trimmed(&options.access_key_id),
        secret_access_key: trimmed(&options.secret_access_key),
        session_token: trimmed(&options.session_token),
    };
    if creds.access_key_id.is_empty() || creds.secret_access_key.is_empty() {
        return Err(invalid("alerts::ses needs an access_key_id and secret_access_key"));
    }
    let to = recipients("ses", &options.email)?;
    let url = format!("https://email.{}.amazonaws.com/v2/email/outbound-emails", options.region);
    Ok(Arc::new(Ses { o: options, creds, url, to }))
}

pub(crate) fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64)
}

impl Channel for Ses {
    fn name(&self) -> &str {
        "ses"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.o;
            let m = compose_email(alert, &o.email, &self.to);
            let utf8 = |data: String| Object::new().with("Data", data).with("Charset", "UTF-8");
            let mut message = Object::new()
                .with("FromEmailAddress", m.from)
                .with(
                    "Destination",
                    Object::new().with("ToAddresses", m.to.into_iter().map(Value::from).collect::<Vec<_>>()),
                )
                .with(
                    "Content",
                    Object::new().with(
                        "Simple",
                        Object::new()
                            .with("Subject", utf8(m.subject))
                            .with("Body", Object::new().with("Text", utf8(m.text)).with("Html", utf8(m.html))),
                    ),
                );
            if !o.configuration_set_name.is_empty() {
                message.set("ConfigurationSetName", o.configuration_set_name.as_str());
            }
            message
                .set("EmailTags", vec![Value::Object(Object::new().with("Name", "source").with("Value", "cronwatch"))]);
            let body = message.to_json();
            let now = o.now.as_ref().map_or_else(now_ms, |f| f());
            let given = [("content-type", "application/json".to_string())];
            let request = SigningRequest {
                method: "POST",
                url: &self.url,
                headers: &given,
                body: &body,
                region: &o.region,
                service: "ses",
                now,
            };
            let headers = sign(&request, &self.creds).map_err(post::fail)?;
            let list: Vec<(&str, String)> = headers.iter().map(|(n, v)| (n.as_str(), v.clone())).collect();
            let secrets = [self.creds.secret_access_key.as_str(), self.creds.session_token.as_str()];
            send(&o.transport, "SES", &self.url, &list, body, &secrets).await
        })
    }
}
