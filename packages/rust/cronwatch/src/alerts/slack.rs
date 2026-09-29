//! Slack, through an incoming webhook (`alerts/slack.ts`).

use std::sync::Arc;

use super::post::{self, Transport};
use super::shared::{LinkFn, invalid, link_for, triage};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{self, LoneJson, Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::{Alert, AlertType};

/// Configures [`slack`].
#[derive(Clone, Default)]
pub struct SlackOptions {
    /// An incoming webhook URL from api.slack.com/messaging/webhooks. It is
    /// its own credential: errors never quote it.
    pub webhook_url: String,
    /// A link back to the job in your dashboard.
    pub link: Option<LinkFn>,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

struct Slack(SlackOptions);

fn emoji(t: &AlertType) -> &'static str {
    match t {
        AlertType::Missed => ":hourglass_flowing_sand:",
        AlertType::Failed => ":x:",
        AlertType::Stuck => ":no_entry:",
        AlertType::Slow => ":turtle:",
        AlertType::OverBudget => ":moneybag:",
        AlertType::Recovered => ":white_check_mark:",
        AlertType::Other(_) => "",
    }
}

/// Sends alerts to a Slack channel through an incoming webhook.
pub fn slack(options: SlackOptions) -> Result<Arc<dyn Channel>, Error> {
    if options.webhook_url.is_empty() {
        return Err(invalid("alerts::slack needs a webhook_url"));
    }
    Ok(Arc::new(Slack(options)))
}

impl Channel for Slack {
    fn name(&self) -> &str {
        "slack"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.0;
            let link = link_for(&o.link, alert);
            let mut head = format!("{} *{}*", emoji(&alert.alert_type), escape(&alert.title));
            if !link.is_empty() {
                head.push_str(&format!(" (<{link}|open>)"));
            }
            let mut lone = LoneJson::new();
            let mut code: Vec<u16> = "```".encode_utf16().collect();
            code.extend(js::head16_units(&code_block_safe(&escape(&alert.message)), 2900));
            code.extend("```".encode_utf16());
            let section = |text: Value| {
                Value::Object(
                    Object::new()
                        .with("type", "section")
                        .with("text", Object::new().with("type", "mrkdwn").with("text", text)),
                )
            };
            let mut blocks = vec![section(Value::from(head)), section(lone.string(&code))];
            if !triage(alert).is_empty() {
                // Its own block, so a long diagnosis cannot push a block past Slack's 3000 character limit.
                let text = js::head16_units(&format!("_Triage:_ {}", escape(triage(alert))), 3000);
                blocks.push(section(lone.string(&text)));
            }
            let payload = Value::Object(
                Object::new()
                    // The notification fallback is parsed as mrkdwn too, so it is escaped like the blocks.
                    .with("text", escape(&format!("{}\n{}", alert.title, alert.message)))
                    .with("blocks", blocks),
            );
            let body = lone.stringify(&payload);
            let t = post::transport(&o.transport)?;
            // A redirect is refused, not followed: a webhook URL is its own credential.
            let answer = post::fetch(
                &*t,
                post::TIMEOUT,
                &o.webhook_url,
                &[("content-type", "application/json".into())],
                body.into_bytes(),
            )
            .await?;
            if !answer.ok() {
                return Err(post::fail(format!(
                    "Slack webhook answered {}: {}",
                    answer.status,
                    js::head16(&answer.body, 200)
                )));
            }
            Ok(())
        })
    }
}

/// Slack's three control characters. Escaping `<` and `>` also stops
/// `<!channel>` and `<url|links>`.
fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Breaks up ``` so text inside a code block cannot close it.
pub(crate) fn code_block_safe(text: &str) -> String {
    text.replace("```", "`\u{200b}`\u{200b}`")
}
