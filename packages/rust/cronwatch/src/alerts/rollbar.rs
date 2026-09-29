//! Rollbar (`alerts/rollbar.ts`). API reference:
//! <https://docs.rollbar.com/reference/create-item>. POST
//! `https://api.rollbar.com/api/1/item/` with `x-rollbar-access-token`.

use std::sync::Arc;

use super::post::{Transport, cut};
use super::shared::{
    LinkFn, alert_id, as_uuid, details, invalid, link_for, run_summary, send, severity, triage, trimmed,
};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{self, Object};
use crate::store::{BoxError, BoxFuture};
use crate::types::{Alert, AlertType};

/// Configures [`rollbar`].
#[derive(Clone, Default)]
pub struct RollbarOptions {
    /// A project access token with the `post_server_item` scope.
    pub access_token: String,
    /// `""` for `production`.
    pub environment: String,
    /// Leaves recoveries out. They are sent by default, as info items.
    pub skip_recovered: bool,
    /// A link back to the job in your dashboard, sent as custom data.
    pub link: Option<LinkFn>,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

struct Rollbar {
    o: RollbarOptions,
    token: String,
    environment: String,
}

const ENDPOINT: &str = "https://api.rollbar.com/api/1/item/";

/// Sends alerts to Rollbar as items, one item per job and alert type.
pub fn rollbar(options: RollbarOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which a header would refuse or send.
    let token = trimmed(&options.access_token);
    if token.is_empty() {
        return Err(invalid("alerts::rollbar needs an access_token"));
    }
    let environment = if options.environment.is_empty() { "production".into() } else { options.environment.clone() };
    Ok(Arc::new(Rollbar { o: options, token, environment }))
}

impl Channel for Rollbar {
    fn name(&self) -> &str {
        "rollbar"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.o;
            if alert.alert_type == AlertType::Recovered && o.skip_recovered {
                return Ok(());
            }
            let link = link_for(&o.link, alert);
            let mut custom = Object::new().with("job", alert.job.as_str()).with("type", alert.alert_type.as_str());
            if !triage(alert).is_empty() {
                custom.set("triage", triage(alert));
            }
            if !link.is_empty() {
                custom.set("link", link);
            }
            custom.set("details", details(alert));
            custom.set("run", run_summary(alert));
            let item = Object::new().with(
                "data",
                Object::new()
                    .with("environment", cut(&self.environment, 255))
                    .with("level", severity(&alert.alert_type))
                    .with("timestamp", js::floor_div(alert.at, 1000))
                    .with("title", cut(&alert.title, 255))
                    .with("fingerprint", format!("cronwatch:{}:{}", alert.job, alert.alert_type))
                    .with("uuid", as_uuid(&alert_id(alert)))
                    .with("body", Object::new().with("message", Object::new().with("body", alert.message.as_str())))
                    .with("custom", custom)
                    .with("notifier", Object::new().with("name", "cronwatch")),
            );
            let headers =
                [("content-type", "application/json".to_string()), ("x-rollbar-access-token", self.token.clone())];
            send(&o.transport, "Rollbar", ENDPOINT, &headers, item.to_json(), &[&self.token]).await
        })
    }
}
