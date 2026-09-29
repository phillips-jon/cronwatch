//! Replays `conformance/*.json`, the cases `scripts/conformance.mjs` writes
//! by running the TypeScript SDK. `evaluate`, `format` and `health` are
//! replayed here, `channels` with the `alerts` feature and `triage` with the
//! `triage` feature, `duration` and `schedule` by the schedule module,
//! `output` by the output module, `store.json` against every store (the
//! `storetest` feature's replay, run over the memory store here and over
//! every SQL store in `cronwatch-sqlx`), and `pgcron.json` by
//! `cronwatch-sqlx`'s pg_cron source. This module holds what those tests
//! share, and fails when the SDK writes a fixture this port does not know.

#[cfg(feature = "alerts")]
mod channels;
mod evaluate;
mod format;
mod health;
#[cfg(feature = "triage")]
mod triage;

use std::path::PathBuf;

use crate::js::{self, Object, Value};
use crate::jsre::Regexp;
use crate::serialize::{ExpectRule, Matcher};

/// The fixtures the workspace replays: every one the SDK writes. A new
/// fixture fails the test below until it is placed.
const REPLAYED: [&str; 10] =
    ["channels", "duration", "evaluate", "format", "health", "output", "pgcron", "schedule", "store", "triage"];

/// SHA-256 as lowercase hex, for the fixtures' digests of long texts.
#[cfg(any(feature = "alerts", feature = "triage"))]
pub(crate) fn sha256_hex(data: &[u8]) -> String {
    use sha2::Digest;
    use std::fmt::Write;
    sha2::Sha256::digest(data).iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

/// The fixtures' form of a request body: itself up to 400 UTF-16 code
/// units, else its length and the SHA-256 of its UTF-8.
#[cfg(any(feature = "alerts", feature = "triage"))]
pub(crate) fn digest(s: &str) -> Value {
    if js::len16(s) <= 400 {
        return Value::Object(Object::new().with("text", s));
    }
    Value::Object(Object::new().with("length", js::len16(s)).with("sha256", sha256_hex(s.as_bytes())))
}

/// The repository's `conformance/` directory.
pub(crate) fn conformance_dir() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../conformance"))
}

/// `conformance/<name>.json`, in JavaScript's key order.
pub(crate) fn fixture(name: &str) -> Object {
    let path = conformance_dir().join(format!("{name}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    match js::parse(&text) {
        Ok(Value::Object(o)) => o,
        other => panic!("{name}.json is not an object: {other:?}"),
    }
}

/// `o[key]`, or `null` when it is absent.
pub(crate) fn field<'a>(o: &'a Object, key: &str) -> &'a Value {
    const NULL: Value = Value::Null;
    o.get(key).unwrap_or(&NULL)
}

/// `o[key]` as a list of objects.
pub(crate) fn objects<'a>(o: &'a Object, key: &str) -> Vec<&'a Object> {
    field(o, key).as_array().map(|list| list.iter().filter_map(Value::as_object).collect()).unwrap_or_default()
}

/// `o[key]` as a whole number of milliseconds.
pub(crate) fn int(o: &Object, key: &str) -> i64 {
    js::to_i64(field(o, key).as_f64().unwrap_or(f64::NAN))
}

/// A number or null as an `Option<i64>`.
pub(crate) fn opt_int(v: &Value) -> Option<i64> {
    v.as_f64().map(js::to_i64)
}

/// Collects every case that is not the SDK's JSON, byte for byte, so a
/// replay reports them all at once.
#[derive(Default)]
pub(crate) struct Failures(Vec<String>);

impl Failures {
    pub(crate) fn same(&mut self, what: &str, got: &Value, want: &Value) {
        let (g, w) = (got.to_json(), want.to_json());
        if g != w {
            self.0.push(format!("{what}:\n  got  {g}\n  want {w}"));
        }
    }

    pub(crate) fn fail(&mut self, what: String) {
        self.0.push(what);
    }

    pub(crate) fn check(self, fixture: &str) {
        assert!(self.0.is_empty(), "{fixture}.json: {} cases differ:\n{}", self.0.len(), self.0.join("\n"));
    }
}

/// A JavaScript RegExp from a fixture, matched with the port's own engine.
struct JsRegExp(Regexp);

impl Matcher for JsRegExp {
    fn is_match(&self, text: &str) -> bool {
        self.0.is_match(text)
    }

    fn source(&self) -> String {
        self.0.to_string()
    }
}

/// An expect rule from a fixture: a string, a JavaScript RegExp as `{ regex:
/// { source, flags } }`, or a function as `{ callable: true }`, which the
/// script makes as `(o) => o.length > 3`.
pub(crate) fn js_rule(v: &Value) -> ExpectRule {
    match v {
        Value::String(s) => ExpectRule::Contains(s.clone()),
        Value::Object(o) => match field(o, "regex").as_object() {
            Some(re) => {
                let source = field(re, "source").as_str().unwrap_or("");
                let flags = field(re, "flags").as_str().unwrap_or("");
                let re = Regexp::new(source, flags).unwrap_or_else(|e| panic!("/{source}/{flags}: {e}"));
                ExpectRule::Matches(std::sync::Arc::new(JsRegExp(re)))
            }
            None => ExpectRule::Func(std::sync::Arc::new(|o: &str| js::len16(o) > 3)),
        },
        other => panic!("not an expect rule: {}", other.to_json()),
    }
}

#[test]
fn conformance_fixtures_are_replayed() {
    let mut unknown: Vec<String> = std::fs::read_dir(conformance_dir())
        .expect("conformance/")
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter_map(|name| name.strip_suffix(".json").map(str::to_string))
        .filter(|name| !REPLAYED.contains(&name.as_str()))
        .collect();
    unknown.sort();
    assert!(unknown.is_empty(), "conformance/ has fixtures this port does not replay: {unknown:?}");
}

/// The fixtures are made with `TZ=UTC`, and a schedule without a zone is read
/// in the process's own, so the workspace's `.cargo/config.toml` sets it for
/// every test run; this fails when something runs the tests without it.
#[test]
fn the_tests_run_in_utc() {
    assert_eq!(
        std::env::var("TZ").as_deref(),
        Ok("UTC"),
        "run the tests with TZ=UTC (packages/rust/.cargo/config.toml)"
    );
    assert_eq!(jiff::tz::TimeZone::system().to_offset(jiff::Timestamp::UNIX_EPOCH).seconds(), 0);
}
