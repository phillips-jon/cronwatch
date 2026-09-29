//! `conformance/format.json`: alert titles and messages, numbers as
//! `toLocaleString` writes them, the output cap, stored definitions and
//! expect rules.

use super::{Failures, field, fixture, int, js_rule, objects};
use crate::evaluate::AlertDraft;
use crate::format::{compose_alert, format_number};
use crate::js::{self, Object, Value};
use crate::output::cap_output;
use crate::output::tests::sha256_hex;
use crate::serialize::{check_expectation, to_stored};
use crate::types::{AlertDetails, AlertType, Definition, Run};

/// An alert draft from a fixture, `{ type, run, details }`.
pub(crate) fn draft_from(v: &Value) -> AlertDraft {
    let o = v.as_object().expect("a draft");
    let alert_type = AlertType::parse(field(o, "type").as_str().unwrap_or(""));
    let run = match field(o, "run") {
        Value::Null => None,
        r => Some(Run::from_value(r).expect("a run")),
    };
    let empty = Object::new();
    let details = AlertDetails::from_value(&alert_type, field(o, "details").as_object().unwrap_or(&empty));
    AlertDraft { alert_type, run, details }
}

/// A draft as the SDK writes one.
pub(crate) fn draft_value(d: &AlertDraft) -> Value {
    Object::new()
        .with("type", d.alert_type.as_str())
        .with("run", d.run.as_ref().map_or(Value::Null, Run::to_value))
        .with("details", d.details.to_value())
        .into()
}

pub(crate) fn definition(v: &Value) -> Definition {
    Definition::from_object(v.as_object().cloned().unwrap_or_default())
}

#[test]
fn conformance_format() {
    let f = fixture("format");
    let mut fails = Failures::default();
    let alerts = objects(&f, "alerts");
    for (i, c) in alerts.iter().enumerate() {
        let got = compose_alert(draft_from(field(c, "draft")), &definition(field(c, "definition")), int(c, "now"));
        fails.same(&format!("alert {i}"), &got.to_value(), field(c, "alert"));
    }
    let numbers = objects(&f, "numbers");
    for c in &numbers {
        let n = field(c, "n").as_f64().expect("a number");
        let got = Value::from(format_number(n));
        fails.same(&format!("formatNumber({})", js::format_number(n)), &got, field(c, "text"));
    }
    let caps = objects(&f, "capOutput");
    for c in &caps {
        let piece = field(c, "piece").as_str().unwrap_or("");
        let text = format!("{}{}", field(c, "prefix").as_str().unwrap_or(""), piece.repeat(int(c, "times") as usize));
        let out = cap_output(&text);
        let got = Object::new().with("length", js::len16(&out)).with("sha256", sha256_hex(out.as_bytes()));
        let want = Object::new().with("length", field(c, "length").clone()).with("sha256", field(c, "sha256").clone());
        fails.same(&format!("capOutput({piece:?} x {})", int(c, "times")), &got.into(), &want.into());
    }
    let stored = objects(&f, "toStored");
    for c in &stored {
        let input = field(c, "definition").as_object().expect("a definition");
        let rule = input.get("expect").map(js_rule);
        fails.same("toStored", &Value::Object(to_stored(input, rule.as_ref()).0), field(c, "stored"));
    }
    let checks = objects(&f, "checkExpectation");
    for c in &checks {
        let rule = js_rule(field(c, "expect"));
        let got = check_expectation(Some(&rule), field(c, "output").as_str());
        fails.same(&format!("checkExpectation({})", field(c, "expect").to_json()), &got.into(), field(c, "result"));
    }
    assert!(
        !alerts.is_empty() && !numbers.is_empty() && !caps.is_empty() && !stored.is_empty() && !checks.is_empty(),
        "format.json has an empty section"
    );
    fails.check("format");
}
