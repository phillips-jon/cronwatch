//! Text that may hold a lone surrogate, for the places the SDK sends one.
//!
//! A cut in UTF-16 code units through a surrogate pair keeps the lone half
//! in JavaScript, and `JSON.stringify` writes it as `\ud83d`. A Rust `String`
//! cannot hold it, so the few requests the SDK sends such a cut in (Slack's
//! and Discord's bodies, triage's prompt) hold those strings as UTF-16 code
//! units, as JavaScript does, and write them into the JSON through
//! [`LoneJson`], so the bytes on the wire are the SDK's.

use super::json::{Value, stringify};

/// `s.slice(0, n)` as UTF-16 code units, the lone half kept.
pub(crate) fn head16_units(s: &str, n: usize) -> Vec<u16> {
    s.encode_utf16().take(n).collect()
}

/// `s.slice(-n)` as UTF-16 code units, the lone half kept (triage's output
/// tail).
#[cfg_attr(not(feature = "triage"), allow(dead_code))]
pub(crate) fn tail16_units(s: &str, n: usize) -> Vec<u16> {
    let units: Vec<u16> = s.encode_utf16().collect();
    units[units.len().saturating_sub(n)..].to_vec()
}

const HEX: &[u8; 16] = b"0123456789abcdef";

/// `JSON.stringify` of a string held as UTF-16 code units: the same escapes
/// as [`quote`](super::quote), and a lone surrogate as `\udXXX`, as a
/// well-formed `JSON.stringify` writes it.
pub(crate) fn quote_units(units: &[u16]) -> String {
    let mut b = String::with_capacity(units.len() + 2);
    b.push('"');
    for r in char::decode_utf16(units.iter().copied()) {
        match r {
            Ok('"') => b.push_str("\\\""),
            Ok('\\') => b.push_str("\\\\"),
            Ok('\u{08}') => b.push_str("\\b"),
            Ok('\u{0c}') => b.push_str("\\f"),
            Ok('\n') => b.push_str("\\n"),
            Ok('\r') => b.push_str("\\r"),
            Ok('\t') => b.push_str("\\t"),
            Ok(c) if (c as u32) < 0x20 => {
                b.push_str("\\u00");
                b.push(HEX[(c as usize) >> 4] as char);
                b.push(HEX[(c as usize) & 0xf] as char);
            }
            Ok(c) => b.push(c),
            Err(e) => {
                let u = e.unpaired_surrogate();
                b.push_str("\\u");
                for shift in [12, 8, 4, 0] {
                    b.push(HEX[((u >> shift) & 0xf) as usize] as char);
                }
            }
        }
    }
    b.push('"');
    b
}

/// Builds a JSON value some of whose strings are UTF-16 code units that may
/// hold a lone surrogate. Each such string is a placeholder in the value (a
/// random token no other text can quote), swapped for its own JSON once the
/// value is written.
#[derive(Default)]
pub(crate) struct LoneJson {
    swaps: Vec<(String, String)>,
}

impl LoneJson {
    pub(crate) fn new() -> Self {
        LoneJson::default()
    }

    /// The value for text held as code units: a plain string when it is
    /// well-formed, else a placeholder.
    pub(crate) fn string(&mut self, units: &[u16]) -> Value {
        if let Ok(s) = String::from_utf16(units) {
            return Value::String(s);
        }
        let token = format!("cronwatch-lone-{}", crate::client::new_id());
        self.swaps.push((super::quote(&token), quote_units(units)));
        Value::String(token)
    }

    /// `JSON.stringify(value)`, each placeholder written as its code units.
    pub(crate) fn stringify(&self, value: &Value) -> String {
        let mut out = stringify(value);
        for (token, json) in &self.swaps {
            out = out.replacen(token.as_str(), json, 1);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js::{Object, quote};

    #[test]
    fn a_lone_half_is_written_as_json_stringify_writes_it() {
        let s = "a\u{1F600}b";
        assert_eq!(quote_units(&head16_units(s, 2)), r#""a\ud83d""#);
        assert_eq!(quote_units(&tail16_units(s, 2)), r#""\ude00b""#);
        assert_eq!(quote_units(&head16_units(s, 4)), quote(s));
        let text = "q\"\\\u{1}\n\u{7f}é";
        assert_eq!(quote_units(&text.encode_utf16().collect::<Vec<_>>()), quote(text));
    }

    #[test]
    fn placeholders_are_swapped_for_their_units() {
        let mut lone = LoneJson::new();
        let cut = lone.string(&head16_units("x\u{1F600}", 2));
        let whole = lone.string(&head16_units("ok", 9));
        let v = Value::Object(Object::new().with("a", cut).with("b", whole).with("c", "\"cronwatch-lone-\""));
        assert_eq!(lone.stringify(&v), r#"{"a":"x\ud83d","b":"ok","c":"\"cronwatch-lone-\""}"#);
    }
}
