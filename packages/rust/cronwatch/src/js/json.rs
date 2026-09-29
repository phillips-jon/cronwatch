use std::fmt;

use super::format_number;

/// A JSON value as JavaScript holds one: numbers are `f64`, and objects keep
/// JavaScript's key order.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum Value {
    #[default]
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Value>),
    Object(Object),
}

impl Value {
    /// The string, when this is one.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    /// The number, when this is one.
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Value::Number(n) => Some(*n),
            _ => None,
        }
    }

    /// The boolean, when this is one.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// The array, when this is one.
    pub fn as_array(&self) -> Option<&Vec<Value>> {
        match self {
            Value::Array(a) => Some(a),
            _ => None,
        }
    }

    /// The object, when this is one.
    pub fn as_object(&self) -> Option<&Object> {
        match self {
            Value::Object(o) => Some(o),
            _ => None,
        }
    }

    /// Whether this is `null`.
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    /// The value's type as JavaScript's `typeof` names it, for messages.
    pub(crate) fn kind(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Bool(_) => "boolean",
            Value::Number(_) => "number",
            Value::String(_) => "string",
            _ => "object",
        }
    }

    /// `JSON.stringify` of the value.
    pub fn to_json(&self) -> String {
        stringify(self)
    }
}

impl From<bool> for Value {
    fn from(b: bool) -> Self {
        Value::Bool(b)
    }
}
impl From<f64> for Value {
    fn from(n: f64) -> Self {
        Value::Number(n)
    }
}
impl From<i64> for Value {
    fn from(n: i64) -> Self {
        Value::Number(n as f64)
    }
}
impl From<i32> for Value {
    fn from(n: i32) -> Self {
        Value::Number(n as f64)
    }
}
impl From<u32> for Value {
    fn from(n: u32) -> Self {
        Value::Number(n as f64)
    }
}
impl From<usize> for Value {
    fn from(n: usize) -> Self {
        Value::Number(n as f64)
    }
}
impl From<&str> for Value {
    fn from(s: &str) -> Self {
        Value::String(s.to_string())
    }
}
impl From<String> for Value {
    fn from(s: String) -> Self {
        Value::String(s)
    }
}
impl From<Object> for Value {
    fn from(o: Object) -> Self {
        Value::Object(o)
    }
}
impl From<Vec<Value>> for Value {
    fn from(a: Vec<Value>) -> Self {
        Value::Array(a)
    }
}
impl<T: Into<Value>> From<Option<T>> for Value {
    fn from(v: Option<T>) -> Self {
        v.map_or(Value::Null, Into::into)
    }
}

/// A JavaScript object: keys in JavaScript's order, which is every key that
/// is an array index (a canonical whole number below 2^32 - 1) in ascending
/// order, then every other key in the order it was first set.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Object {
    entries: Vec<(String, Value)>,
}

/// Whether a key is an array index, which JavaScript orders before every
/// other key.
pub(crate) fn array_index(key: &str) -> Option<u32> {
    let b = key.as_bytes();
    if b.is_empty() || b.len() > 10 || (b.len() > 1 && b[0] == b'0') || !b.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let n: u64 = key.parse().ok()?;
    if n >= (1 << 32) - 1 { None } else { Some(n as u32) }
}

impl Object {
    /// An empty object.
    pub fn new() -> Self {
        Self::default()
    }

    /// Gives `key` the value: a new key takes its place in JavaScript's
    /// order, a key already there keeps its place.
    pub fn set(&mut self, key: impl Into<String>, value: impl Into<Value>) {
        let key = key.into();
        let value = value.into();
        if let Some(e) = self.entries.iter_mut().find(|e| e.0 == key) {
            e.1 = value;
            return;
        }
        if let Some(n) = array_index(&key) {
            // Before the first key that is not an index or is a larger index.
            let at = self
                .entries
                .iter()
                .position(|(k, _)| array_index(k).is_none_or(|m| m > n))
                .unwrap_or(self.entries.len());
            self.entries.insert(at, (key, value));
            return;
        }
        self.entries.push((key, value));
    }

    /// `set`, returning the object, for building one in a line.
    pub fn with(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.set(key, value);
        self
    }

    /// The value at `key`.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries.iter().find(|e| e.0 == key).map(|e| &e.1)
    }

    /// Whether the key is there.
    pub fn has(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    /// Removes `key`, giving back its value.
    pub fn remove(&mut self, key: &str) -> Option<Value> {
        let at = self.entries.iter().position(|e| e.0 == key)?;
        Some(self.entries.remove(at).1)
    }

    /// `Object.keys`: the keys in JavaScript's order.
    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().map(|e| e.0.as_str())
    }

    /// The keys and values, in order.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &Value)> {
        self.entries.iter().map(|e| (e.0.as_str(), &e.1))
    }

    /// How many keys there are.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether there are none.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// `JSON.stringify` of the object.
    pub fn to_json(&self) -> String {
        let mut b = String::new();
        write_object(&mut b, self);
        b
    }
}

/// `JSON.stringify`: the same bytes for the same value. A number that is not
/// finite is `null`, as JavaScript writes it.
pub fn stringify(v: &Value) -> String {
    let mut b = String::new();
    write(&mut b, v);
    b
}

fn write(b: &mut String, v: &Value) {
    match v {
        Value::Null => b.push_str("null"),
        Value::Bool(true) => b.push_str("true"),
        Value::Bool(false) => b.push_str("false"),
        Value::Number(n) if !n.is_finite() => b.push_str("null"),
        Value::Number(n) => b.push_str(&format_number(*n)),
        Value::String(s) => quote_into(b, s),
        Value::Array(a) => {
            b.push('[');
            for (i, e) in a.iter().enumerate() {
                if i > 0 {
                    b.push(',');
                }
                write(b, e);
            }
            b.push(']');
        }
        Value::Object(o) => write_object(b, o),
    }
}

fn write_object(b: &mut String, o: &Object) {
    b.push('{');
    for (i, (k, v)) in o.entries.iter().enumerate() {
        if i > 0 {
            b.push(',');
        }
        quote_into(b, k);
        b.push(':');
        write(b, v);
    }
    b.push('}');
}

/// `JSON.stringify` of a string.
pub(crate) fn quote(s: &str) -> String {
    let mut b = String::with_capacity(s.len() + 2);
    quote_into(&mut b, s);
    b
}

const HEX: &[u8; 16] = b"0123456789abcdef";

fn quote_into(b: &mut String, s: &str) {
    b.push('"');
    let mut start = 0;
    for (i, c) in s.bytes().enumerate() {
        if c >= 0x20 && c != b'"' && c != b'\\' {
            continue;
        }
        b.push_str(&s[start..i]);
        match c {
            b'"' => b.push_str("\\\""),
            b'\\' => b.push_str("\\\\"),
            0x08 => b.push_str("\\b"),
            0x0c => b.push_str("\\f"),
            b'\n' => b.push_str("\\n"),
            b'\r' => b.push_str("\\r"),
            b'\t' => b.push_str("\\t"),
            _ => {
                b.push_str("\\u00");
                b.push(HEX[(c >> 4) as usize] as char);
                b.push(HEX[(c & 0xf) as usize] as char);
            }
        }
        start = i + 1;
    }
    b.push_str(&s[start..]);
    b.push('"');
}

/// Why text is not JSON, with `JSON.parse`'s wording and the byte position.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError(String);

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ParseError {}

/// `JSON.parse`: objects in JavaScript's key order (a key given twice keeps
/// its first place and its last value). A lone surrogate escape (`\ud800`)
/// becomes U+FFFD.
pub fn parse(text: &str) -> Result<Value, ParseError> {
    let mut p = Parser { s: text.as_bytes(), text, i: 0 };
    p.space();
    let v = p.value(0)?;
    p.space();
    if p.i < p.s.len() {
        return Err(p.fail("Unexpected non-whitespace character after JSON"));
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    text: &'a str,
    i: usize,
}

impl Parser<'_> {
    fn fail(&self, what: &str) -> ParseError {
        ParseError(format!("{what} at position {}", self.i))
    }

    fn space(&mut self) {
        while self.i < self.s.len() && matches!(self.s[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn at(&self, c: u8) -> bool {
        self.i < self.s.len() && self.s[self.i] == c
    }

    fn value(&mut self, depth: usize) -> Result<Value, ParseError> {
        if depth > 10_000 {
            return Err(ParseError("JSON nested too deeply".into()));
        }
        if self.i >= self.s.len() {
            return Err(self.fail("Unexpected end of JSON input"));
        }
        let rest = &self.s[self.i..];
        match self.s[self.i] {
            b'{' => {
                self.i += 1;
                let mut o = Object::new();
                self.space();
                if self.at(b'}') {
                    self.i += 1;
                    return Ok(Value::Object(o));
                }
                loop {
                    self.space();
                    if !self.at(b'"') {
                        return Err(self.fail("Expected property name"));
                    }
                    let k = self.string()?;
                    self.space();
                    if !self.at(b':') {
                        return Err(self.fail("Expected ':' after property name"));
                    }
                    self.i += 1;
                    self.space();
                    let v = self.value(depth + 1)?;
                    o.set(k, v);
                    self.space();
                    if self.at(b',') {
                        self.i += 1;
                        continue;
                    }
                    if self.at(b'}') {
                        self.i += 1;
                        return Ok(Value::Object(o));
                    }
                    return Err(self.fail("Expected ',' or '}' after property value"));
                }
            }
            b'[' => {
                self.i += 1;
                let mut out = Vec::new();
                self.space();
                if self.at(b']') {
                    self.i += 1;
                    return Ok(Value::Array(out));
                }
                loop {
                    self.space();
                    out.push(self.value(depth + 1)?);
                    self.space();
                    if self.at(b',') {
                        self.i += 1;
                        continue;
                    }
                    if self.at(b']') {
                        self.i += 1;
                        return Ok(Value::Array(out));
                    }
                    return Err(self.fail("Expected ',' or ']' after array element"));
                }
            }
            b'"' => Ok(Value::String(self.string()?)),
            b't' if rest.starts_with(b"true") => {
                self.i += 4;
                Ok(Value::Bool(true))
            }
            b'f' if rest.starts_with(b"false") => {
                self.i += 5;
                Ok(Value::Bool(false))
            }
            b'n' if rest.starts_with(b"null") => {
                self.i += 4;
                Ok(Value::Null)
            }
            b'-' | b'0'..=b'9' => self.number(),
            _ => Err(self.fail("Unexpected token")),
        }
    }

    fn digits(&mut self) -> usize {
        let from = self.i;
        while self.i < self.s.len() && self.s[self.i].is_ascii_digit() {
            self.i += 1;
        }
        self.i - from
    }

    fn number(&mut self) -> Result<Value, ParseError> {
        let start = self.i;
        if self.at(b'-') {
            self.i += 1;
        }
        if self.at(b'0') {
            self.i += 1;
        } else if self.digits() == 0 {
            return Err(self.fail("No number after minus sign"));
        }
        if self.at(b'.') {
            self.i += 1;
            if self.digits() == 0 {
                return Err(self.fail("Unterminated fractional number"));
            }
        }
        if self.at(b'e') || self.at(b'E') {
            self.i += 1;
            if self.at(b'+') || self.at(b'-') {
                self.i += 1;
            }
            if self.digits() == 0 {
                return Err(self.fail("Exponent part is missing a number"));
            }
        }
        // Out of range reads as JavaScript reads it: Infinity or 0.
        self.text[start..self.i].parse::<f64>().map(Value::Number).map_err(|_| self.fail("Unexpected number"))
    }

    fn hex4(&mut self) -> Option<u16> {
        let digits = self.text.get(self.i..self.i + 4)?;
        if !digits.bytes().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        let n = u16::from_str_radix(digits, 16).ok()?;
        self.i += 4;
        Some(n)
    }

    fn string(&mut self) -> Result<String, ParseError> {
        self.i += 1; // the opening quote
        let mut b = String::new();
        let mut start = self.i;
        while self.i < self.s.len() {
            let c = self.s[self.i];
            match c {
                b'"' => {
                    b.push_str(&self.text[start..self.i]);
                    self.i += 1;
                    return Ok(b);
                }
                0..0x20 => return Err(self.fail("Bad control character in string literal")),
                b'\\' => {
                    b.push_str(&self.text[start..self.i]);
                    self.i += 1;
                    if self.i >= self.s.len() {
                        return Err(self.fail("Unterminated string"));
                    }
                    let e = self.s[self.i];
                    self.i += 1;
                    match e {
                        b'"' | b'\\' | b'/' => b.push(e as char),
                        b'b' => b.push('\u{08}'),
                        b'f' => b.push('\u{0c}'),
                        b'n' => b.push('\n'),
                        b'r' => b.push('\r'),
                        b't' => b.push('\t'),
                        b'u' => {
                            let Some(u) = self.hex4() else {
                                return Err(self.fail("Bad Unicode escape"));
                            };
                            if (0xd800..0xe000).contains(&u) {
                                let mut pair = None;
                                if u < 0xdc00 && self.s[self.i..].starts_with(b"\\u") {
                                    let save = self.i;
                                    self.i += 2;
                                    match self.hex4() {
                                        Some(lo) if (0xdc00..0xe000).contains(&lo) => pair = Some(lo),
                                        _ => self.i = save,
                                    }
                                }
                                match pair {
                                    Some(lo) => {
                                        let cp = 0x10000 + ((u as u32 - 0xd800) << 10) + (lo as u32 - 0xdc00);
                                        b.push(char::from_u32(cp).unwrap_or(char::REPLACEMENT_CHARACTER));
                                    }
                                    None => b.push(char::REPLACEMENT_CHARACTER),
                                }
                            } else {
                                b.push(char::from_u32(u as u32).unwrap_or(char::REPLACEMENT_CHARACTER));
                            }
                        }
                        _ => return Err(self.fail("Bad escaped character")),
                    }
                    start = self.i;
                }
                _ => self.i += 1,
            }
        }
        Err(self.fail("Unterminated string"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_keep_javascripts_order() {
        let o = Object::new().with("b", 1).with("10", 2).with("a", 3).with("2", 4).with("b", 5);
        assert_eq!(o.to_json(), r#"{"2":4,"10":2,"b":5,"a":3}"#);
        let parsed = parse(r#"{"z":1,"1":2,"z":3,"4294967295":4}"#).unwrap();
        assert_eq!(parsed.to_json(), r#"{"1":2,"z":3,"4294967295":4}"#);
    }

    #[test]
    fn strings_escape_as_json_stringify_does() {
        assert_eq!(quote("a\"b\\c\n\u{1}<>&\u{2028}"), "\"a\\\"b\\\\c\\n\\u0001<>&\u{2028}\"");
        let v = parse(r#""😀 \ud83d x é""#).unwrap();
        assert_eq!(v.as_str(), Some("😀 \u{fffd} x é"));
    }

    #[test]
    fn numbers_and_errors() {
        assert_eq!(parse("[1e400,-0,2.50]").unwrap().to_json(), "[null,0,2.5]");
        assert_eq!(parse("{").unwrap_err().to_string(), "Expected property name at position 1");
        assert_eq!(parse("1 2").unwrap_err().to_string(), "Unexpected non-whitespace character after JSON at position 2");
        assert!(parse("-").is_err());
        assert!(parse("\"\u{1}\"").is_err());
    }
}
