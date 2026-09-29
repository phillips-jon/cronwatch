//! The SDK's `output.ts` and the recorder of `job.ts`: the output cap, error
//! text, secret redaction, and the lines and metrics a run collects.
//! Lengths and cuts are in UTF-16 code units, as JavaScript counts them, so
//! the same output is capped at the same character here and in every other
//! port.

mod recorder;

use std::sync::OnceLock;

pub(crate) use recorder::Recorder;

use crate::js;
use crate::jsre::{Match, Regexp};

/// How much output a run keeps: 16 KB of UTF-16 code units, the tail. A
/// chatty job cannot fill the store.
pub(crate) const OUTPUT_CAP: usize = 16 * 1024;

/// Removes every U+0000. Postgres refuses NUL in TEXT and JSONB, and the
/// whole run row would be lost with it.
pub(crate) fn strip_nul(s: &str) -> String {
    if s.contains('\0') { s.replace('\0', "") } else { s.to_string() }
}

/// Removes NULs, then keeps the last `OUTPUT_CAP` code units behind a line
/// saying the rest was trimmed. A cut through a surrogate pair leaves
/// U+FFFD, the character JavaScript's lone half becomes once written out as
/// UTF-8, so the stored bytes are the same.
pub(crate) fn cap_output(s: &str) -> String {
    let clean = strip_nul(s);
    // Each byte is at most one code unit, so a short text needs no count.
    if clean.len() <= OUTPUT_CAP || js::len16(&clean) <= OUTPUT_CAP {
        return clean;
    }
    format!("[earlier output trimmed]\n{}", js::tail16(&clean, OUTPUT_CAP))
}

/// An error as a JavaScript stack reads: `Name: message`, then up to five
/// frames, each `    at <frame>`.
pub(crate) fn describe(name: &str, message: &str, frames: &[String]) -> String {
    let mut b = format!("{name}: {message}");
    for f in frames.iter().take(5) {
        b.push_str("\n    at ");
        b.push_str(f);
    }
    b
}

/// The SDK's `errorMessage` for an error: described, then capped like
/// output.
pub(crate) fn error_message(name: &str, message: &str, frames: &[String]) -> String {
    cap_output(&describe(name, message, frames))
}

/// The SDK's `errorMessage` for a thrown value that is not an `Error`: a
/// string as it is, anything else as its JSON, capped like output. Rust
/// throws nothing but panics, so only the conformance replay needs it.
#[cfg(test)]
pub(crate) fn value_message(value: &js::Value) -> String {
    match value {
        js::Value::String(s) => cap_output(s),
        v => cap_output(&v.to_json()),
    }
}

/// The name an error goes by in `Name: message`, from its type's name
/// (`std::any::type_name`): the last path segment without generics, so
/// `std::io::error::Error` is `Error` and `my_app::ReportError` is
/// `ReportError`. A boxed trait object, `anyhow::Error`, `String` and `&str`
/// are `Error`, as a plain JavaScript `Error` is, since their type names say
/// nothing to a reader.
pub(crate) fn error_name(type_name: &str) -> &str {
    let t = type_name.trim_start_matches('&').trim_start_matches("mut ");
    if t.starts_with("dyn ") || t == "str" || t == "alloc::string::String" || t.starts_with("alloc::boxed::Box<dyn ") {
        return "Error";
    }
    let t = t.split('<').next().unwrap_or(t);
    let name = t.rsplit("::").next().unwrap_or(t);
    if name.is_empty() || !name.starts_with(|c: char| c.is_ascii_uppercase()) {
        return "Error";
    }
    name
}

/// What replaces a secret.
pub(crate) const REDACTED: &str = "[redacted]";

/// What a pattern's match is replaced by.
enum Replacement {
    /// A replacement string in which `$1` stands for group 1 (the only
    /// group the SDK's replacements name), split around each `$1` and held
    /// as code units, so a surrogate pair is never split and put back
    /// together.
    Template(Vec<Vec<u16>>),
    /// The name, the value's quote (double or single, if any), the marker
    /// and the quote again: the key=value pattern's function.
    Assignment,
}

/// One of the SDK's secret patterns and what replaces a match.
struct Pattern {
    re: Regexp,
    replace: Replacement,
}

impl Pattern {
    fn template(source: &str, flags: &str, text: &str) -> Pattern {
        let pieces = text.split("$1").map(js::units).collect();
        Pattern { re: Regexp::must(source, flags), replace: Replacement::Template(pieces) }
    }

    fn apply(&self, m: &Match<'_>) -> Vec<u16> {
        match &self.replace {
            Replacement::Template(pieces) => {
                let group = m.group(1).unwrap_or(&[]);
                let mut out = pieces[0].clone();
                for p in &pieces[1..] {
                    out.extend_from_slice(group);
                    out.extend_from_slice(p);
                }
                out
            }
            Replacement::Assignment => {
                let quote = m.group(2).or_else(|| m.group(3)).unwrap_or(&[]);
                let mut out = m.group(1).unwrap_or(&[]).to_vec();
                out.extend_from_slice(quote);
                out.extend(js::units(REDACTED));
                out.extend_from_slice(quote);
                out
            }
        }
    }
}

/// The SDK's patterns (`packages/sdk/src/output.ts`, `SECRET_PATTERNS`), as
/// JavaScript source, character for character, compiled by `jsre` so they
/// match what they match in JavaScript. Bounded quantifiers throughout, so
/// a long line cannot make these backtrack. They apply in this order, each
/// to the text the ones before it left.
fn patterns() -> &'static [Pattern] {
    static PATTERNS: OnceLock<Vec<Pattern>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        let redacted_after = format!("$1{REDACTED}");
        vec![
            // A PEM private key, header to footer. Without a footer (the
            // output was trimmed) it runs to the end of the base64 body. A
            // "-" that starts five dashes ends the body, so the footer is
            // never swallowed into it.
            Pattern::template(
                r"-----BEGIN (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----(?:[A-Za-z0-9+/=\s,:]|-(?!----)){0,16384}(?:-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----)?",
                "g",
                REDACTED,
            ),
            // password=..., API_KEY: ..., "client_secret": "...",
            // TOKEN='...', token=..., :password=>"..." (but not max_tokens:
            // 800). A quoted value is blanked to its closing quote, spaces
            // and all, and keeps its quotes.
            Pattern {
                re: Regexp::must(
                    r#"\b([A-Za-z0-9_-]{0,40}(?:secret|token|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])"?\s{0,3}(?:=>|[=:])\s{0,3})(?:(")[^"\n]{1,4096}"|(')[^'\n]{1,4096}'|["']?[^\s"',;&]{1,4096})"#,
                    "gi",
                ),
                replace: Replacement::Assignment,
            },
            // Authorization: Basic <base64> and Authorization: Token
            // <token>, also as a JSON or hash entry.
            Pattern::template(
                r#"\b((?:proxy-)?authorization["']?\s{0,3}(?:=>|[=:])\s{0,3}["']?\s{0,3}(?:basic|token)\s{1,3})[A-Za-z0-9._~+/=:-]{1,4096}"#,
                "gi",
                &redacted_after,
            ),
            // Credentials inside a URL: postgres://user:password@host. The
            // password runs to the last "@" before a "/" or a space, so one
            // that contains "@" is blanked whole.
            Pattern::template(
                r"(\b[a-z][a-z0-9+.-]{0,30}:\/\/[^\s/:@]{0,256}:)[^\s/]{1,256}@",
                "gi",
                &format!("$1{REDACTED}@"),
            ),
            // Authorization: Bearer <token>
            Pattern::template(r"\b(Bearer\s{1,3})[A-Za-z0-9._~+/=-]{8,4096}", "g", &redacted_after),
            // A bare JWT: three base64url segments, the first starting eyJ.
            Pattern::template(
                r"\beyJ[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{0,4096}",
                "g",
                REDACTED,
            ),
            // Incoming webhook URLs carry their secret in the path.
            Pattern::template(
                r"(\bhooks\.slack\.com\/(?:services|workflows|triggers)\/)[A-Za-z0-9/_-]{1,255}",
                "gi",
                &redacted_after,
            ),
            Pattern::template(
                r"(\bdiscord(?:app)?\.com\/api\/(?:v\d{1,2}\/)?webhooks\/)[A-Za-z0-9/_-]{1,255}",
                "gi",
                &redacted_after,
            ),
            // Well-known token shapes: AWS, GitHub, Slack, Stripe,
            // Anthropic, OpenAI and Google style keys.
            Pattern::template(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b", "g", REDACTED),
            Pattern::template(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\b", "g", REDACTED),
            Pattern::template(r"\bxox[abposr]-[A-Za-z0-9-]{10,255}", "g", REDACTED),
            Pattern::template(r"\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\b", "g", REDACTED),
            Pattern::template(r"\bwhsec_[A-Za-z0-9+/=]{16,255}", "g", REDACTED),
            Pattern::template(r"\bsk-[A-Za-z0-9_-]{20,255}", "g", REDACTED),
            Pattern::template(r"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])", "g", REDACTED),
        ]
    })
}

/// The default redact: blanks values that look like secrets (key=value
/// pairs with secret-ish names, Authorization headers, URL credentials,
/// bearer tokens, JWTs, PEM private keys, webhook URLs and well-known token
/// formats) before output or an error is stored, shown or sent anywhere.
/// The text is matched as UTF-16 code units, as JavaScript holds it, and
/// turned back into UTF-8 once at the end, so a match that cut a character
/// outside the BMP in two leaves U+FFFD where JavaScript leaves the lone
/// surrogate that becomes U+FFFD when it is written out.
pub(crate) fn redact_secrets(text: &str) -> String {
    let mut units = js::units(text);
    for p in patterns() {
        units = p.re.replace_units(&units, |m| p.apply(m));
    }
    js::from_units(&units)
}

#[cfg(test)]
mod tests;
