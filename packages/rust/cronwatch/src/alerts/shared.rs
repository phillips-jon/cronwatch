//! What the channels share (`alerts/shared.ts`): severity, the stable alert
//! id, the run summary trackers attach, the plain text every channel reads,
//! and the encodings the requests use.

use std::sync::Arc;

use hmac::{Hmac, KeyInit, Mac};
use sha2::{Digest, Sha256};

use super::post::{self, Transport};
use crate::error::Error;
use crate::js::{self, Object, Value};
use crate::store::BoxError;
use crate::types::{Alert, AlertType};

/// A link back to the job in the app's dashboard, for an alert:
/// `Arc::new(|a| format!("https://app.example.com/cronwatch/jobs/{}", a.job))`.
pub type LinkFn = Arc<dyn Fn(&Alert) -> String + Send + Sync>;

/// A refusal of a channel's options, as `cronwatch::Error::Invalid`.
pub(crate) fn invalid(message: impl Into<String>) -> Error {
    Error::Invalid(message.into())
}

/// The level for trackers that have levels. Recovered is informational.
pub(crate) fn severity(t: &AlertType) -> &'static str {
    match t {
        AlertType::Recovered => "info",
        AlertType::Slow | AlertType::OverBudget | AlertType::UnderFloor => "warning",
        _ => "error",
    }
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(DIGITS[(b >> 4) as usize] as char);
        s.push(DIGITS[(b & 0xf) as usize] as char);
    }
    s
}

pub(crate) fn sha256_hex(text: &str) -> String {
    hex(&Sha256::digest(text.as_bytes()))
}

pub(crate) fn hmac_sha256(key: &[u8], data: &str) -> Vec<u8> {
    let mut m = <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("HMAC takes a key of any length");
    m.update(data.as_bytes());
    m.finalize().into_bytes().to_vec()
}

/// A stable 32 hex character id for one alert: the same job, type and time
/// always give the same id, so a provider that deduplicates on it drops a
/// resend of an alert it already took.
pub(crate) fn alert_id(a: &Alert) -> String {
    let mut id = sha256_hex(&format!("{}\n{}\n{}", a.job, a.alert_type, js::format_number(a.at as f64)));
    id.truncate(32);
    id
}

/// The same id laid out as a UUID, for APIs that ask for one.
pub(crate) fn as_uuid(id: &str) -> String {
    format!("{}-{}-{}-{}-{}", &id[0..8], &id[8..12], &id[12..16], &id[16..20], &id[20..32])
}

/// The run fields worth attaching to a tracker event, or `null`. A start
/// before the year 1 or after 9999 is `null`.
pub(crate) fn run_summary(a: &Alert) -> Value {
    let Some(r) = &a.run else {
        return Value::Null;
    };
    Value::Object(
        Object::new()
            .with("id", r.id.as_str())
            .with("status", r.status.as_str())
            .with("startedAt", js::iso_time(r.started_at).map_or(Value::Null, Value::from))
            .with("durationMs", r.duration_ms)
            .with("trigger", r.trigger.as_str()),
    )
}

/// The alert's details as the SDK writes them.
pub(crate) fn details(a: &Alert) -> Value {
    a.details.to_value()
}

/// The alert's diagnosis, `""` for none (JavaScript reads null and `""`
/// alike as absent).
pub(crate) fn triage(a: &Alert) -> &str {
    a.triage.as_deref().unwrap_or("")
}

/// The link option's answer for this alert, `""` for none.
pub(crate) fn link_for(link: &Option<LinkFn>, a: &Alert) -> String {
    link.as_ref().map(|f| f(a)).unwrap_or_default()
}

/// The title, message, triage and link as one plain text block, the way
/// every channel reads.
pub(crate) fn plain_text(a: &Alert, link: &str) -> String {
    let mut lines = vec![a.title.as_str(), "", a.message.as_str()];
    let t = format!("Triage: {}", triage(a));
    if !triage(a).is_empty() {
        lines.extend(["", t.as_str()]);
    }
    let l = format!("Open: {link}");
    if !link.is_empty() {
        lines.extend(["", l.as_str()]);
    }
    lines.join("\n")
}

/// A credential with the spaces and newlines a paste leaves around it taken
/// off.
pub(crate) fn trimmed(value: &str) -> String {
    js::trim(value).to_string()
}

/// Base64 of UTF-8.
pub(crate) fn base64(text: &str) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let b = text.as_bytes();
    let mut out = String::with_capacity(b.len().div_ceil(3) * 4);
    for chunk in b.chunks(3) {
        let n = ((chunk[0] as u32) << 16)
            | ((*chunk.get(1).unwrap_or(&0) as u32) << 8)
            | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

pub(crate) fn basic_auth(user: &str, password: &str) -> String {
    format!("Basic {}", base64(&format!("{user}:{password}")))
}

/// JavaScript's `encodeURIComponent`.
pub(crate) fn encode_uri_component(text: &str) -> String {
    percent(text, b"-_.!~*'()", false)
}

/// `URLSearchParams#toString` for these pairs:
/// application/x-www-form-urlencoded, a space as `+`.
pub(crate) fn form(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", percent(k, b"*-._", true), percent(v, b"*-._", true)))
        .collect::<Vec<_>>()
        .join("&")
}

pub(crate) fn percent(text: &str, safe: &[u8], plus: bool) -> String {
    const DIGITS: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(text.len());
    for &c in text.as_bytes() {
        if c.is_ascii_alphanumeric() || safe.contains(&c) {
            out.push(c as char);
        } else if c == b' ' && plus {
            out.push('+');
        } else {
            out.push('%');
            out.push(DIGITS[(c >> 4) as usize] as char);
            out.push(DIGITS[(c & 0xf) as usize] as char);
        }
    }
    out
}

/// Posts a JSON or form body and fails on an answer outside 2xx.
pub(crate) async fn send(
    transport: &Option<Arc<dyn Transport>>,
    provider: &str,
    url: &str,
    headers: &[(&str, String)],
    body: String,
    secrets: &[&str],
) -> Result<(), BoxError> {
    let t = post::transport(transport)?;
    post::post(&*t, provider, url, headers, body.into_bytes(), secrets).await.map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodings_are_the_sdks() {
        assert_eq!(base64(""), "");
        assert_eq!(base64("f"), "Zg==");
        assert_eq!(base64("fo"), "Zm8=");
        assert_eq!(base64("foo"), "Zm9v");
        assert_eq!(base64("api:é"), "YXBpOsOp");
        assert_eq!(encode_uri_component("a b/c?d=é!'()*~"), "a%20b%2Fc%3Fd%3D%C3%A9!'()*~");
        assert_eq!(form(&[("To", "+1 555"), ("Body", "a&b=c*~")]), "To=%2B1+555&Body=a%26b%3Dc*%7E");
        assert_eq!(as_uuid("0123456789abcdef0123456789abcdef"), "01234567-89ab-cdef-0123-456789abcdef");
        assert_eq!(
            hex(&hmac_sha256(b"key", "The quick brown fox jumps over the lazy dog")),
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
        );
    }
}
