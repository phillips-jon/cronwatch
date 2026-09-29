//! Discord, through a channel webhook (`alerts/discord.ts`).

use std::sync::Arc;

use super::post::{self, Transport};
use super::shared::{LinkFn, invalid, link_for, triage};
use super::slack::code_block_safe;
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js::{self, LoneJson, Object, Value};
use crate::store::{BoxError, BoxFuture};
use crate::types::{Alert, AlertType};

/// Configures [`discord`].
#[derive(Clone, Default)]
pub struct DiscordOptions {
    /// A channel webhook URL from Server Settings, Integrations, Webhooks. It
    /// is its own credential: errors never quote it.
    pub webhook_url: String,
    /// A link back to the job in your dashboard.
    pub link: Option<LinkFn>,
    /// Sends the request; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

struct Discord(DiscordOptions);

fn color(t: &AlertType) -> i64 {
    match t {
        AlertType::Failed | AlertType::Stuck => 0xc62828,
        AlertType::Recovered => 0x1f8a4c,
        _ => 0xb7791f,
    }
}

/// Sends alerts to a Discord channel through a webhook.
pub fn discord(options: DiscordOptions) -> Result<Arc<dyn Channel>, Error> {
    if options.webhook_url.is_empty() {
        return Err(invalid("alerts::discord needs a webhook_url"));
    }
    Ok(Arc::new(Discord(options)))
}

impl Channel for Discord {
    fn name(&self) -> &str {
        "discord"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.0;
            let link = link_for(&o.link, alert);
            let mut lone = LoneJson::new();
            // codeBlockSafe after the cut, as the SDK does it: it works on
            // code units, so a lone half at the end passes through.
            let message = js::head16_units(&alert.message, 3800);
            let mut description: Vec<u16> = "```\n".encode_utf16().collect();
            description.extend(code_block_safe_units(&message));
            description.extend("\n```".encode_utf16());
            if !triage(alert).is_empty() {
                description.extend("\n**Triage:** ".encode_utf16());
                description.extend(escape_markdown_units(&js::head16_units(triage(alert), 1000)));
            }
            let mut embed = Object::new().with("title", alert.title.as_str());
            if !link.is_empty() {
                embed.set("url", link);
            }
            embed.set("description", lone.string(&description));
            embed.set("color", color(&alert.alert_type));
            embed.set("timestamp", js::iso_string(alert.at));
            let payload = Value::Object(
                Object::new()
                    .with("content", alert.title.as_str())
                    // Job output can hold anything, "@everyone" included; ping no one.
                    .with("allowed_mentions", Object::new().with("parse", Vec::<Value>::new()))
                    .with("embeds", vec![Value::Object(embed)]),
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
                    "Discord webhook answered {}: {}",
                    answer.status,
                    js::head16(&answer.body, 200)
                )));
            }
            Ok(())
        })
    }
}

/// [`code_block_safe`] over code units.
fn code_block_safe_units(units: &[u16]) -> Vec<u16> {
    let tick = u16::from(b'`');
    let mut out = Vec::with_capacity(units.len());
    let mut i = 0;
    while i < units.len() {
        if i + 3 <= units.len() && units[i..i + 3] == [tick, tick, tick] {
            out.extend(code_block_safe("```").encode_utf16());
            i += 3;
        } else {
            out.push(units[i]);
            i += 1;
        }
    }
    out
}

/// Escapes the characters Discord reads as markdown, links included.
fn escape_markdown_units(units: &[u16]) -> Vec<u16> {
    let mut out = Vec::with_capacity(units.len());
    for &u in units {
        if u < 0x80 && b"\\`*_~|[]()<>".contains(&(u as u8)) {
            out.push(u16::from(b'\\'));
        }
        out.push(u);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markup_is_broken_up_and_escaped() {
        let units = |s: &str| s.encode_utf16().collect::<Vec<_>>();
        assert_eq!(code_block_safe_units(&units("a````b")), units("a`\u{200b}`\u{200b}``b"));
        assert_eq!(escape_markdown_units(&units("*a* [b](c) <d>")), units("\\*a\\* \\[b\\]\\(c\\) \\<d\\>"));
    }
}
