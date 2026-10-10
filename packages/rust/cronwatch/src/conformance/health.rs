//! `conformance/health.json`: health, summaries, percentiles, state
//! normalization, silence, and which queued alerts a retry drops.

use super::format::{definition, draft_from, draft_value};
use super::{Failures, field, fixture, int, objects, opt_int};
use crate::evaluate::{
    Evaluation, MAX_UNDELIVERED, SEND_LEASE_MS, alert_key, apply_silence, hold_alerts, is_stuck, job_health,
    mute_opens, normalize_state, queue_undelivered, record_sent, release_sending, silence_end, summarize,
    unevaluable_summary,
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
        unreadable: false,
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
        // A state that is not an object is none, as a store reads it.
        let input = match field(c, "state") {
            v @ Value::Object(_) => Some(state(v)),
            _ => None,
        };
        // A queued alert is written whole by this port (every field, as an
        // alert it composed), so each the fixture keeps is compared as the
        // port reads and writes it; which ones are kept is the SDK's.
        let mut want = field(c, "normalized").as_object().expect("a state").clone();
        if let Some(Value::Array(list)) = want.get("undelivered") {
            let read: Vec<Value> = list.iter().map(|a| Alert::from_value(a).expect("an alert").to_value()).collect();
            want.set("undelivered", read);
        }
        let want = Value::Object(want);
        fails.same(&format!("normalizeState {i}"), &normalize_state(input.as_ref(), "j").to_value(), &want);
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
    for (i, c) in objects(&f, "runDuration").into_iter().enumerate() {
        cases += 1;
        let got = crate::types::run_duration(int(c, "startedAt"), int(c, "finishedAt"));
        fails.same(&format!("runDuration {i}"), &got.into(), field(c, "durationMs"));
    }
    for (i, c) in objects(&f, "stateVersion").into_iter().enumerate() {
        cases += 1;
        let text = field(c, "state").as_str().expect("a state's text");
        let parsed = crate::js::parse(text).expect("JSON");
        let from_value = crate::types::state_version(parsed.as_object().and_then(|o| o.get("version")));
        let read = JobState::from_json(text).expect("a state").counted_version();
        fails.same(&format!("stateVersion {i}"), &from_value.into(), field(c, "version"));
        fails.same(&format!("stateVersion {i}, read as a state"), &read.into(), field(c, "version"));
    }
    let failed_def = definition(&crate::js::parse(r#"{"name":"j","failuresBeforeAlert":3}"#).expect("JSON"));
    let failed_run = Run::from_value(
        &crate::js::parse(
            r#"{"id":"f","job":"j","status":"failed","startedAt":1767605340000,"finishedAt":1767605341000,"durationMs":1000,"error":"Error: boom","output":null,"metrics":{},"trigger":"run"}"#,
        )
        .expect("JSON"),
    )
    .expect("a run");
    for (i, c) in objects(&f, "failureCount").into_iter().enumerate() {
        cases += 1;
        let text = field(c, "state").as_str().expect("a state's text");
        let read = normalize_state(Some(&JobState::from_json(text).expect("a state")), "j");
        fails.same(&format!("failureCount {i}"), &read.consecutive_failures.into(), field(c, "consecutiveFailures"));
        let e = crate::evaluate::on_run_finish(&failed_def, &failed_run, &read, &[], 1_767_605_400_000)
            .expect("an evaluation");
        let got = Object::new()
            .with("state", e.state.to_value())
            .with("alerts", e.alerts.iter().map(draft_value).collect::<Vec<_>>());
        fails.same(&format!("failureCount {i}, a failed run"), &got.into(), field(c, "failed"));
    }
    for (i, c) in objects(&f, "silenceEnd").into_iter().enumerate() {
        cases += 1;
        let ms = crate::schedule::parse_duration(field(c, "duration"), "silence duration").expect("a duration");
        let got = silence_end(int(c, "now"), ms);
        fails.same(&format!("silenceEnd {i}"), &got.into(), field(c, "silencedUntil"));
    }
    cases += delivery(field(&f, "delivery").as_object().expect("delivery"), &mut fails);
    assert!(cases > 0, "health.json has no cases");
    fails.check("health");
}

fn alerts(v: &Value) -> Vec<Alert> {
    v.as_array().expect("alerts").iter().map(|a| Alert::from_value(a).expect("an alert")).collect()
}

/// A result `{ state, dropped }`, as the SDK's delivery functions give it.
fn held((state, dropped): (JobState, usize)) -> Value {
    Object::new().with("state", state.to_value()).with("dropped", dropped).into()
}

/// JSON with every object's keys sorted: the fixture's alerts are written in
/// the order the script built them, a port's in its writer's own.
fn sorted(v: &Value) -> Value {
    match v {
        Value::Object(o) => {
            let mut keys: Vec<&str> = o.keys().collect();
            keys.sort_unstable();
            let mut out = Object::new();
            for k in keys {
                out.set(k, sorted(field(o, k)));
            }
            Value::Object(out)
        }
        Value::Array(list) => Value::Array(list.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

/// `health.json`'s `delivery`: the outbox and the undelivered queue.
fn delivery(d: &Object, fails: &mut Failures) -> usize {
    let mut cases = 0;
    fails.same("maxUndelivered", &MAX_UNDELIVERED.into(), field(d, "maxUndelivered"));
    fails.same("sendLeaseMs", &SEND_LEASE_MS.into(), field(d, "sendLeaseMs"));
    for (i, c) in objects(d, "alertKey").into_iter().enumerate() {
        cases += 1;
        let alert = Alert::from_value(field(c, "alert")).expect("an alert");
        let want = field(c, "key").as_str().expect("a key");
        // An alert's `at` is a whole millisecond here (see DESIGN.md, Where
        // it cannot match the SDK): a fraction is read as the whole part.
        let want = if want == "failed|1.5|" { "failed|1|" } else { want };
        fails.same(&format!("alertKey {i}"), &alert_key(&alert).into(), &want.into());
    }
    for (i, c) in objects(d, "normalizeState").into_iter().enumerate() {
        cases += 1;
        let got = normalize_state(Some(&state(field(c, "state"))), "j").to_value();
        fails.same(&format!("delivery normalizeState {i}"), &sorted(&got), &sorted(field(c, "normalized")));
    }
    for (i, c) in objects(d, "queueUndelivered").into_iter().enumerate() {
        cases += 1;
        let got = held(queue_undelivered(&state(field(c, "state")), &alerts(field(c, "alerts"))));
        fails.same(&format!("queueUndelivered {i}"), &sorted(&got), &sorted(field(c, "result")));
    }
    for (i, c) in objects(d, "holdAlerts").into_iter().enumerate() {
        cases += 1;
        let deferred = matches!(field(c, "deferred"), Value::Bool(true));
        let got = held(hold_alerts(&state(field(c, "state")), &alerts(field(c, "alerts")), int(c, "until"), deferred));
        fails.same(&format!("holdAlerts {i}"), &sorted(&got), &sorted(field(c, "result")));
    }
    for (i, c) in objects(d, "releaseSending").into_iter().enumerate() {
        cases += 1;
        let got = held(release_sending(&state(field(c, "state")), int(c, "now")));
        fails.same(&format!("releaseSending {i}"), &sorted(&got), &sorted(field(c, "result")));
    }
    for (i, c) in objects(d, "recordSent").into_iter().enumerate() {
        cases += 1;
        let got = held(record_sent(
            &state(field(c, "state")),
            &alerts(field(c, "delivered")),
            &alerts(field(c, "failed")),
            &alerts(field(c, "stale")),
            int(c, "now"),
        ));
        fails.same(&format!("recordSent {i}"), &sorted(&got), &sorted(field(c, "result")));
    }
    let listed = ["alertKey", "normalizeState", "queueUndelivered", "holdAlerts", "releaseSending", "recordSent"];
    let known = ["maxUndelivered", "sendLeaseMs"];
    for key in d.keys() {
        assert!(listed.contains(&key) || known.contains(&key), "health.json's delivery has {key}, not replayed");
    }
    cases
}
