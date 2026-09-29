//! Replays conformance/duration.json and conformance/schedule.json, the
//! cases scripts/conformance.mjs writes by running the TypeScript SDK (in
//! UTC), comparing every answer as the JSON the SDK writes, byte for byte.

use super::*;
use crate::js::{Object, Value, parse as parse_json, stringify};

pub(super) fn fixture(name: &str) -> Object {
    let path = format!("{}/../../../conformance/{name}.json", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    match parse_json(&text).unwrap() {
        Value::Object(o) => o,
        _ => panic!("{path} is not an object"),
    }
}

fn field<'a>(o: &'a Object, key: &str) -> &'a Value {
    static NULL: Value = Value::Null;
    o.get(key).unwrap_or(&NULL)
}

fn cases<'a>(o: &'a Object, key: &str) -> Vec<&'a Object> {
    field(o, key).as_array().unwrap().iter().map(|v| v.as_object().unwrap()).collect()
}

fn text<'a>(o: &'a Object, key: &str) -> &'a str {
    field(o, key).as_str().unwrap_or("")
}

/// A number that may travel as `{ "special": "NaN" }`.
fn number(v: &Value) -> f64 {
    if let Value::Object(o) = v {
        return match field(o, "special").as_str() {
            Some("NaN") => f64::NAN,
            Some("Infinity") => f64::INFINITY,
            Some("-Infinity") => f64::NEG_INFINITY,
            _ => panic!("not a number: {}", stringify(v)),
        };
    }
    v.as_f64().unwrap()
}

fn integer(v: &Value) -> i64 {
    v.as_f64().unwrap() as i64
}

fn optional(v: &Value) -> Option<i64> {
    if v.is_null() { None } else { Some(integer(v)) }
}

fn same(what: &str, got: &Value, want: &Value) -> bool {
    let (g, w) = (stringify(got), stringify(want));
    if g != w {
        eprintln!("{what}:\n got {g}\nwant {w}");
    }
    g == w
}

#[test]
fn conformance_duration() {
    let f = fixture("duration");
    let (mut n, mut failed) = (0, 0);
    for c in cases(&f, "parse") {
        let input = field(c, "input");
        let value = if input.as_str().is_some() { input.clone() } else { Value::Number(number(input)) };
        let mut got = Object::new().with("input", input.clone());
        if c.has("label") {
            got.set("label", text(c, "label"));
        }
        match parse_duration(&value, text(c, "label")) {
            Ok(ms) => got.set("ms", ms),
            Err(e) => got.set("error", e),
        }
        failed += usize::from(!same("parse", &got.into(), &Value::Object(c.clone())));
        n += 1;
    }
    for c in cases(&f, "format") {
        let got =
            Object::new().with("ms", field(c, "ms").clone()).with("text", format_duration(number(field(c, "ms"))));
        failed += usize::from(!same("format", &got.into(), &Value::Object(c.clone())));
        n += 1;
    }
    for c in cases(&f, "relative") {
        let got = Object::new()
            .with("at", field(c, "at").clone())
            .with("now", field(c, "now").clone())
            .with("text", format_relative(integer(field(c, "at")), integer(field(c, "now"))));
        failed += usize::from(!same("relative", &got.into(), &Value::Object(c.clone())));
        n += 1;
    }
    assert_eq!(failed, 0, "{failed} of {n} duration cases differ");
    known(&f, &["parse", "format", "relative"]);
    eprintln!("{n} duration cases");
}

#[test]
fn conformance_schedule() {
    let f = fixture("schedule");
    let mut counts: Vec<(&str, usize)> = Vec::new();
    let mut failed = 0;
    let mut count = |section: &'static str| match counts.iter_mut().find(|e| e.0 == section) {
        Some(e) => e.1 += 1,
        None => counts.push((section, 1)),
    };

    for c in cases(&f, "parse") {
        let mut got = Object::new().with("schedule", text(c, "schedule"));
        if c.has("timezone") {
            got.set("timezone", text(c, "timezone"));
        }
        match parse(text(c, "schedule"), text(c, "timezone")) {
            Ok(p) => got.set("parsed", p.to_value()),
            Err(e) => got.set("error", e),
        }
        failed += usize::from(!same("parse", &got.into(), &Value::Object(c.clone())));
        count("parse");
    }

    for c in cases(&f, "fires") {
        let p = parse(text(c, "schedule"), text(c, "timezone")).unwrap();
        let want = field(c, "fires");
        let mut out = Vec::new();
        let mut at = integer(field(c, "from"));
        for _ in want.as_array().unwrap() {
            let next = next_fire(&p, at, None);
            out.push(Value::from(next));
            let Some(next) = next else { break };
            at = next;
        }
        let what = format!("fires of {} in {}", text(c, "schedule"), text(c, "timezone"));
        failed += usize::from(!same(&what, &Value::Array(out), want));
        count("fires");
    }

    for c in cases(&f, "nextFire") {
        let p = parse(text(c, "schedule"), "").unwrap();
        let got = next_fire(&p, integer(field(c, "from")), optional(field(c, "lastRunAt")));
        failed += usize::from(!same("nextFire", &Value::from(got), field(c, "expected")));
        count("nextFire");
    }

    for c in cases(&f, "expectation") {
        let p = parse(text(c, "schedule"), text(c, "timezone")).unwrap();
        let e =
            expect(&p, optional(field(c, "lastRunAt")), integer(field(c, "registeredAt")), number(field(c, "graceMs")));
        let got = match e {
            Some(e) => Value::Object(Object::new().with("dueAt", e.due_at).with("deadline", e.deadline)),
            None => Value::Null,
        };
        let what = format!(
            "expectation of {} in {} after {}",
            text(c, "schedule"),
            text(c, "timezone"),
            stringify(field(c, "lastRunAt"))
        );
        failed += usize::from(!same(&what, &got, field(c, "expected")));
        count("expectation");
    }

    for c in cases(&f, "runCovers") {
        let got =
            run_covers(integer(field(c, "startedAt")), integer(field(c, "dueAt")), optional(field(c, "followingAt")));
        failed += usize::from(!same("runCovers", &Value::Bool(got), field(c, "expected")));
        count("runCovers");
    }

    for c in cases(&f, "autumn") {
        let p = parse(text(c, "schedule"), text(c, "timezone")).unwrap();
        let (from, step) = (integer(field(c, "from")), integer(field(c, "stepMs")));
        let mut out = Vec::new();
        let mut at = from;
        while at < from + 8 * 3_600_000 {
            out.push(Value::from(next_fire(&p, at, None)));
            at += step;
        }
        let what = format!("autumn {} in {}", text(c, "schedule"), text(c, "timezone"));
        failed += usize::from(!same(&what, &Value::Array(out), field(c, "next")));
        count("autumn");
    }
    assert_eq!(failed, 0, "{failed} schedule cases differ");
    known(&f, &["parse", "fires", "nextFire", "expectation", "runCovers", "autumn"]);
    eprintln!("schedule cases: {counts:?}");
}

/// Fails when the SDK writes a section this replay does not know.
fn known(f: &Object, sections: &[&str]) {
    for key in f.keys() {
        assert!(
            key == "generatedBy" || key == "sdkVersion" || sections.contains(&key),
            "the fixture has a section this port does not replay: {key}"
        );
    }
}
