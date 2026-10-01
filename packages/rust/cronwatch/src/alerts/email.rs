//! What every email channel sends (`alerts/email.ts`): one subject, a plain
//! text body and a small HTML body, so an alert reads the same whichever
//! provider carries it.

use super::post::cut;
use super::shared::{LinkFn, invalid, link_for, plain_text, triage};
use crate::error::Error;
use crate::js::{self, Object, Value};
use crate::types::Alert;

/// The options every email channel takes.
#[derive(Clone, Default)]
#[non_exhaustive]
pub struct EmailOptions {
    /// The sender, `alerts@example.com` or `CronWatch <alerts@example.com>`.
    /// The provider must allow it.
    pub from: String,
    /// One address or several.
    pub to: Vec<String>,
    /// Goes in front of the title in the subject, `[prod]` say.
    pub subject_prefix: String,
    /// A link back to the job in your dashboard. Only an http or https link
    /// is put in a mail.
    pub link: Option<LinkFn>,
}

super::setters!(EmailOptions {
    text from,
    texts to,
    text subject_prefix,
    link link,
});

/// One alert as a mail.
pub(crate) struct Email {
    pub(crate) from: String,
    pub(crate) to: Vec<String>,
    pub(crate) subject: String,
    pub(crate) text: String,
    pub(crate) html: String,
}

/// Checks the shared options once, when the channel is made: the to
/// addresses, blanks dropped, each trimmed.
pub(crate) fn recipients(name: &str, o: &EmailOptions) -> Result<Vec<String>, Error> {
    if o.from.is_empty() {
        return Err(invalid(format!("alerts::{name} needs a from address")));
    }
    let to: Vec<String> = o.to.iter().map(|a| js::trim(a)).filter(|a| !a.is_empty()).map(str::to_string).collect();
    if to.is_empty() {
        return Err(invalid(format!("alerts::{name} needs at least one to address")));
    }
    Ok(to)
}

/// `.replace(/[\r\n]+/g, " ")`.
fn one_line(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut breaking = false;
    for c in text.chars() {
        if c == '\r' || c == '\n' {
            if !breaking {
                out.push(' ');
            }
            breaking = true;
        } else {
            out.push(c);
            breaking = false;
        }
    }
    out
}

/// The mail for an alert.
pub(crate) fn compose_email(a: &Alert, o: &EmailOptions, to: &[String]) -> Email {
    let link = safe_link(link_for(&o.link, a));
    let prefix = if o.subject_prefix.is_empty() { String::new() } else { format!("{} ", o.subject_prefix) };
    // One line: a newline in a subject is a header injection or a rejected send.
    let subject = cut(&one_line(&format!("{prefix}{}", a.title)), 250);
    Email { from: o.from.clone(), to: to.to_vec(), subject, text: plain_text(a, &link), html: html(a, &link) }
}

/// Escapes text for HTML content and double quoted attributes.
pub(crate) fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

/// Keeps only an http or https link.
fn safe_link(link: String) -> String {
    let lower = link.get(..8).unwrap_or(&link).to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") { link } else { String::new() }
}

fn html(a: &Alert, link: &str) -> String {
    let mut parts = vec![
        "<!doctype html>".to_string(),
        r#"<html><body style="margin:0;padding:16px;font-family:Georgia,serif;color:#1d1b16;background:#ffffff">"#
            .to_string(),
        format!(r#"<p style="margin:0 0 12px;font-size:18px"><strong>{}</strong></p>"#, escape_html(&a.title)),
        format!(
            r#"<pre style="margin:0 0 12px;padding:12px;background:#f6f3ec;white-space:pre-wrap;word-break:break-word;font:13px/1.45 Menlo,Consolas,monospace">{}</pre>"#,
            escape_html(&a.message)
        ),
    ];
    if !triage(a).is_empty() {
        parts.push(format!(r#"<p style="margin:0 0 12px"><em>Triage:</em> {}</p>"#, escape_html(triage(a))));
    }
    if !link.is_empty() {
        parts.push(format!(
            r#"<p style="margin:0"><a href="{}">Open {}</a></p>"#,
            escape_html(link),
            escape_html(&a.job)
        ));
    }
    parts.push("</body></html>".to_string());
    parts.join("\n")
}

/// `Name <a@b.c>` split into its parts; a bare address has no name
/// (email.ts's `parseAddress`: `/^\s*(.*?)\s*<([^<>]+)>\s*$/`, then the name
/// without the double quotes around it).
pub(crate) fn parse_address(text: &str) -> Value {
    let bare = || Value::Object(Object::new().with("email", js::trim(text)));
    let s = js::trim_end(text);
    let Some(inner) = s.strip_suffix('>') else {
        return bare();
    };
    let Some(at) = inner.rfind('<') else {
        return bare();
    };
    let address = &inner[at + 1..];
    if address.is_empty() || address.contains('>') {
        return bare();
    }
    let mut name = js::trim(&inner[..at]);
    // JavaScript's . matches no line terminator.
    if name.contains(['\n', '\r', '\u{2028}', '\u{2029}']) {
        return bare();
    }
    if name.len() >= 2 && name.starts_with('"') && name.ends_with('"') {
        name = &name[1..name.len() - 1];
    }
    let mut o = Object::new().with("email", js::trim(address));
    if !name.is_empty() {
        o.set("name", name);
    }
    Value::Object(o)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses_split_as_the_sdk_splits_them() {
        let json = |s: &str| parse_address(s).to_json();
        assert_eq!(json("ops@example.com"), r#"{"email":"ops@example.com"}"#);
        assert_eq!(json(" Ops <ops@example.com> "), r#"{"email":"ops@example.com","name":"Ops"}"#);
        assert_eq!(json(r#""Ops, Team" <ops@example.com>"#), r#"{"email":"ops@example.com","name":"Ops, Team"}"#);
        assert_eq!(json("<ops@example.com>"), r#"{"email":"ops@example.com"}"#);
        assert_eq!(json("a <b> <c@d>"), r#"{"email":"c@d","name":"a <b>"}"#);
        assert_eq!(json("x\ny <c@d>"), r#"{"email":"x\ny <c@d>"}"#);
        assert_eq!(one_line("a\r\n\nb\rc"), "a b c");
        assert_eq!(safe_link("HTTPS://x".into()), "HTTPS://x");
        assert_eq!(safe_link("javascript:alert(1)".into()), "");
    }
}
