//! `conformance/health.json`: health, summaries, percentiles, state
//! normalization, silence and which queued alerts a retry drops.

use super::format::{definition, draft_from, draft_value};
use super::{Failures, field, fixture, int, objects, opt_int};
use crate::evaluate::{
    Evaluation, apply_silence, is_stuck, job_health, mute_opens, normalize_state, summarize, unevaluable_summary,
};
use crate::js::{Object, Value};
use crate::stats::{median, percentile};
use crate::types::{Alert, JobState, Run, StoredJob};

fn run(v: &Value) -> Option<Run> {
    (!v.is_null()).then(|| Run::from_value(v).expect("a run"))
}

fn runs(v: &Value) -> Vec<Run> {
    v.as_array().map(|list| list.iter().filter_map(run).collect()).unwrap_or_default()
}

fn state(v: &Value) -> JobState {
    JobState::from_value(v).expect("a state")
}

fn stored(v: &Value) -> StoredJob {
    let o = v.as_object().expect("a stored job");
    StoredJob {
        name: field(o, "name").as_str().unwrap_or("").to_string(),
        definition: definition(field(o, "definition")),
        created_at: int(o, "createdAt"),
        updated_at: int(o, "updatedAt"),
    }
}

fn numbers(v: &Value) -> Vec<f64> {
    v.as_array().map(|list| list.iter().filter_map(Value::as_f64).collect()).unwrap_or_default()
}

#[test]
fn conformance_health() {
    let f = fixture("health");
    let mut fails = Failures::default();
    let mut cases = 0;
    for (i, c) in objects(&f, "jobHealth").into_iter().enumerate() {
        cases += 1;
        let got = job_health(
            &definition(field(c, "definition")),
            run(field(c, "lastRun")).as_ref(),
            &state(field(c, "state")),
            int(c, "now"),
        )
        .map(|h| Value::from(h.as_str()))
        .unwrap_or_else(|e| Value::from(format!("error: {e}")));
        fails.same(&format!("jobHealth {i}"), &got, field(c, "health"));
    }
    for (i, c) in objects(&f, "summarize").into_iter().enumerate() {
        cases += 1;
        let got = summarize(
            &stored(field(c, "stored")),
            &runs(field(c, "recent")),
            &state(field(c, "state")),
            opt_int(field(c, "nextExpectedAt")),
            int(c, "now"),
        )
        .map_or_else(|e| Value::from(format!("error: {e}")), |s| s.to_value());
        fails.same(&format!("summarize {i}"), &got, field(c, "summary"));
    }
    for c in objects(&f, "percentile") {
        cases += 1;
        let p = field(c, "p").as_f64().expect("p");
        let got = percentile(&numbers(field(c, "values")), p).into();
        fails.same(&format!("percentile({}, {p})", field(c, "values").to_json()), &got, field(c, "percentile"));
    }
    for c in objects(&f, "median") {
        cases += 1;
        let got = median(&numbers(field(c, "values"))).into();
        fails.same(&format!("median({})", field(c, "values").to_json()), &got, field(c, "median"));
    }
    for (i, c) in objects(&f, "normalizeState").into_iter().enumerate() {
        cases += 1;
        let input = match field(c, "state") {
            Value::Null => None,
            v => Some(state(v)),
        };
        fails.same(
            &format!("normalizeState {i}"),
            &normalize_state(input.as_ref(), "j").to_value(),
            field(c, "normalized"),
        );
    }
    for (i, c) in objects(&f, "muteOpens").into_iter().enumerate() {
        cases += 1;
        let got = mute_opens(&state(field(c, "previous")), &state(field(c, "next")));
        fails.same(&format!("muteOpens {i}"), &got.to_value(), field(c, "muted"));
    }
    for (i, c) in objects(&f, "isStuck").into_iter().enumerate() {
        cases += 1;
        let r = run(field(c, "run")).expect("a run");
        let got = is_stuck(&definition(field(c, "definition")), &r, int(c, "now"))
            .map_or_else(|e| Value::from(format!("error: {e}")), Value::from);
        fails.same(&format!("isStuck {i}"), &got, field(c, "stuck"));
    }
    for (i, c) in objects(&f, "unevaluableSummary").into_iter().enumerate() {
        cases += 1;
        let got = unevaluable_summary(
            &stored(field(c, "stored")),
            &runs(field(c, "recent")),
            &state(field(c, "state")),
            int(c, "now"),
        );
        fails.same(&format!("unevaluableSummary {i}"), &got.to_value(), field(c, "summary"));
    }
    for (i, c) in objects(&f, "applySilence").into_iter().enumerate() {
        cases += 1;
        let e = field(c, "evaluation").as_object().expect("an evaluation");
        let alerts = field(e, "alerts").as_array().map(|l| l.iter().map(draft_from).collect()).unwrap_or_default();
        let input = Evaluation { state: state(field(e, "state")), alerts };
        let out = apply_silence(&state(field(c, "previous")), input, int(c, "now"));
        let got = Object::new()
            .with("state", out.state.to_value())
            .with("alerts", out.alerts.iter().map(draft_value).collect::<Vec<_>>());
        fails.same(&format!("applySilence {i}"), &got.into(), field(c, "result"));
    }
    for (i, c) in objects(&f, "staleAlert").into_iter().enumerate() {
        cases += 1;
        let alert = Alert::from_value(field(c, "alert")).expect("an alert");
        let got = crate::evaluate::stale_alert(&alert, &state(field(c, "state")));
        fails.same(&format!("staleAlert {i}"), &got.into(), field(c, "stale"));
    }
    assert!(cases > 0, "health.json has no cases");
    fails.check("health");
}
