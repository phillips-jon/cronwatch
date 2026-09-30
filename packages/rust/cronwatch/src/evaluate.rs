//! Pure decisions about a job's health (evaluate.ts). Each function takes the
//! current state and returns the new state plus the alerts that should go
//! out. Nothing here touches a store or a network, which is what makes it
//! testable, and what lets `conformance/evaluate.json` replay a job's life
//! through it event by event.

use crate::format::format_number;
use crate::js::{self, Value};
use crate::schedule::{self, Parsed};
use crate::stats::{median, percentile};
use crate::types::{
    Alert, AlertDetails, AlertType, BudgetBreach, Condition, Definition, JobHealth, JobState, JobSummary,
    MAX_DURATION_MS, OpenCondition, Run, RunStatus, SendingAlert, Stats, StoredJob,
};

/// A state worked out, and the alerts it owes.
#[derive(Clone, Debug)]
pub(crate) struct Evaluation {
    pub state: JobState,
    pub alerts: Vec<AlertDraft>,
}

/// An alert before it has a title and message (`composeAlert`).
#[derive(Clone, Debug)]
pub(crate) struct AlertDraft {
    pub alert_type: AlertType,
    pub run: Option<Run>,
    pub details: AlertDetails,
}

pub(crate) const DEFAULT_GRACE_MS: f64 = 10.0 * 60_000.0;
pub(crate) const DEFAULT_TIMEOUT_MS: f64 = 60.0 * 60_000.0;
/// Runs faster than this are never called slow, whatever the baseline says.
const SLOW_FLOOR_MS: f64 = 10_000.0;
/// How many earlier runs a baseline needs before it is trusted.
const BASELINE_MIN_RUNS: usize = 5;
/// How many successful runs a baseline looks at, and how many runs a summary
/// covers.
pub(crate) const BASELINE_WINDOW: usize = 20;

pub(crate) fn empty_state(job: &str) -> JobState {
    JobState { pending_recovery: Some(Vec::new()), undelivered: Some(Vec::new()), ..JobState::new(job) }
}

/// A stored state with every field present, or a fresh one. State written
/// by an older version lacks the newer fields. `sending` is the exception:
/// it is there only while it holds an alert (see `hold_alerts`).
pub(crate) fn normalize_state(state: Option<&JobState>, job: &str) -> JobState {
    let Some(state) = state else {
        return empty_state(job);
    };
    let mut s = state.clone();
    if s.job.is_empty() {
        s.job = job.to_string();
    }
    s.consecutive_failures = s.consecutive_failures.clamp(0, MAX_DURATION_MS);
    s.pending_recovery.get_or_insert_with(Vec::new);
    s.undelivered.get_or_insert_with(Vec::new);
    if s.sending.as_ref().is_some_and(Vec::is_empty) {
        s.sending = None;
    }
    s
}

/// When a silence of `ms` from `now` ends: a whole millisecond, never past
/// `MAX_DURATION_MS` (2^53 - 1), however long the silence asked for. Every
/// port sharing the store reads it back unchanged.
pub(crate) fn silence_end(now: i64, ms: f64) -> i64 {
    let ms = ms.min(MAX_DURATION_MS as f64).floor().max(0.0) as i64;
    now.saturating_add(ms).min(MAX_DURATION_MS)
}

// ---------------------------------------------------------------- delivery

/// Alerts kept per job for retry, and per job being sent; past it the
/// oldest go.
pub(crate) const MAX_UNDELIVERED: usize = 20;

/// How long an alert in `sending` is left to the process sending it, in
/// milliseconds. Longer than any send takes: at most three alerts go out
/// together, each with 25 seconds of triage and 15 of channels.
pub(crate) const SEND_LEASE_MS: i64 = 5 * 60_000;

/// Identifies an alert across retries, and in `sending`.
pub(crate) fn alert_key(a: &Alert) -> String {
    format!("{}|{}|{}", a.alert_type, a.at, a.run.as_ref().map_or("", |r| r.id.as_str()))
}

/// Keeps the newest `MAX_UNDELIVERED` of `list`, and says how many went.
fn newest<T>(mut list: Vec<T>) -> (Vec<T>, usize) {
    let dropped = list.len().saturating_sub(MAX_UNDELIVERED);
    (list.split_off(dropped), dropped)
}

/// `alerts` added to the undelivered queue: one with the same key as a
/// queued alert replaces it where it stands, the rest go at the end, and
/// only the newest `MAX_UNDELIVERED` stay. Also says how many were let go.
pub(crate) fn queue_undelivered(state: &JobState, alerts: &[Alert]) -> (JobState, usize) {
    let mut next = clone_state(state);
    // The last of `alerts` with a key wins, as a Map built from them keeps it.
    let mut queue: Vec<Alert> = next
        .undelivered
        .take()
        .unwrap_or_default()
        .into_iter()
        .map(|a| {
            let key = alert_key(&a);
            alerts.iter().rev().find(|b| alert_key(b) == key).cloned().unwrap_or(a)
        })
        .collect();
    let known: std::collections::HashSet<String> = queue.iter().map(alert_key).collect();
    queue.extend(alerts.iter().filter(|a| !known.contains(&alert_key(a))).cloned());
    let (kept, dropped) = newest(queue);
    next.undelivered = Some(kept);
    (next, dropped)
}

/// The outbox. Alerts just composed are written with the state that opens
/// their condition, before any is sent, so a process that stops part way
/// does not lose them: into `sending`, each with its lease ending at
/// `until`, when this process sends them, or (`deferred`, for
/// `Deliver::AtCheck`) straight into the undelivered queue for a check
/// elsewhere. Also says how many were let go past `MAX_UNDELIVERED`.
pub(crate) fn hold_alerts(state: &JobState, alerts: &[Alert], until: i64, deferred: bool) -> (JobState, usize) {
    if alerts.is_empty() {
        return (state.clone(), 0);
    }
    if deferred {
        return queue_undelivered(state, alerts);
    }
    let mut next = clone_state(state);
    let mut sending = next.sending.take().unwrap_or_default();
    sending.extend(alerts.iter().map(|a| SendingAlert { until: Some(until), alert: Some(a.clone()) }));
    let (kept, dropped) = newest(sending);
    next.sending = Some(kept);
    (next, dropped)
}

/// Alerts in `sending` whose lease ran out by `now`: the process sending
/// them stopped before it recorded how the send went. They go to the
/// undelivered queue, where the retry sends them (with triage, which is
/// never stored with them here) or drops them as stale. An entry without an
/// alert is dropped; one without a numeric `until` counts as run out.
pub(crate) fn release_sending(state: &JobState, now: i64) -> (JobState, usize) {
    let sending = state.sending.as_deref().unwrap_or_default();
    let lapsed = |e: &SendingAlert| !e.until.is_some_and(|until| until > now);
    if !sending.iter().any(lapsed) {
        return (state.clone(), 0);
    }
    let held: Vec<SendingAlert> = sending.iter().filter(|e| !lapsed(e)).cloned().collect();
    let released: Vec<Alert> = sending.iter().filter(|e| lapsed(e)).filter_map(|e| e.alert.clone()).collect();
    let mut next = state.clone();
    next.sending = (!held.is_empty()).then_some(held);
    queue_undelivered(&next, &released)
}

/// How a send went. Delivered and stale alerts leave the queue; failed ones
/// replace their queued copy, so a triage made on this attempt is kept, or
/// join the queue. Every one of them leaves `sending`. `last_alert_at` moves
/// only on a delivery. Also says how many were let go past
/// `MAX_UNDELIVERED`.
pub(crate) fn record_sent(
    state: &JobState,
    delivered: &[Alert],
    failed: &[Alert],
    stale: &[Alert],
    now: i64,
) -> (JobState, usize) {
    let mut next = clone_state(state);
    let done: std::collections::HashSet<String> = delivered.iter().chain(stale).map(alert_key).collect();
    if let Some(queue) = next.undelivered.as_mut() {
        queue.retain(|a| !done.contains(&alert_key(a)));
    }
    let sent: std::collections::HashSet<String> = delivered.iter().chain(failed).chain(stale).map(alert_key).collect();
    let held: Vec<SendingAlert> = next
        .sending
        .take()
        .unwrap_or_default()
        .into_iter()
        .filter(|e| !e.alert.as_ref().is_some_and(|a| sent.contains(&alert_key(a))))
        .collect();
    next.sending = (!held.is_empty()).then_some(held);
    if !delivered.is_empty() {
        next.last_alert_at = Some(now);
    }
    queue_undelivered(&next, failed)
}

fn clone_state(s: &JobState) -> JobState {
    normalize_state(Some(s), &s.job)
}

fn pending(s: &mut JobState) -> &mut Vec<Condition> {
    s.pending_recovery.get_or_insert_with(Vec::new)
}

fn open_condition(s: &mut JobState, c: Condition, now: i64) -> bool {
    if s.open_at(&c).is_some() {
        return false;
    }
    s.open.push(OpenCondition { condition: c, since: now });
    true
}

/// Closes `c`. Every open condition has alerted, so closing one owes a
/// recovered message; it is remembered until a successful run leaves
/// nothing open and sends it.
fn close_condition(s: &mut JobState, c: Condition) -> bool {
    if !delete_open(s, &c) {
        return false;
    }
    let list = pending(s);
    if !list.contains(&c) {
        list.push(c);
    }
    true
}

fn delete_open(s: &mut JobState, c: &Condition) -> bool {
    match s.open.iter().position(|o| &o.condition == c) {
        Some(i) => {
            s.open.remove(i);
            true
        }
        None => false,
    }
}

fn open_conditions(s: &JobState) -> Vec<Condition> {
    s.open.iter().map(|o| o.condition.clone()).collect()
}

/// A duration option of a definition, or the default when it is absent. A
/// present null is an error, as JavaScript's `parseDuration(null)` throws.
fn duration_field(def: &Definition, key: &str, fallback: f64) -> Result<f64, String> {
    match def.get(key) {
        None => Ok(fallback),
        Some(v) => schedule::parse_duration(v, key),
    }
}

pub(crate) fn grace_ms(def: &Definition) -> Result<f64, String> {
    duration_field(def, "grace", DEFAULT_GRACE_MS)
}

pub(crate) fn timeout_ms(def: &Definition) -> Result<f64, String> {
    duration_field(def, "timeout", DEFAULT_TIMEOUT_MS)
}

/// The slow threshold for a successful run and its basis, or `None` when
/// there is nothing to compare against yet.
pub(crate) fn slow_threshold(def: &Definition, history: &[Run]) -> Result<Option<(f64, String)>, String> {
    if let Some(v) = def.get("maxDuration") {
        return Ok(Some((schedule::parse_duration(v, "maxDuration")?, "maxDuration".into())));
    }
    let durations: Vec<f64> = history
        .iter()
        .filter(|r| r.status == RunStatus::Ok)
        .filter_map(|r| r.duration_ms.map(|d| d as f64))
        .take(BASELINE_WINDOW)
        .collect();
    if durations.len() < BASELINE_MIN_RUNS {
        return Ok(None);
    }
    let p95 = percentile(&durations, 95.0).unwrap_or(0.0);
    Ok(Some((
        (2.0 * p95).max(SLOW_FLOOR_MS),
        format!("twice the p95 of the last {} runs ({})", durations.len(), schedule::format_duration(p95)),
    )))
}

/// The run's metrics over their ceiling, or, without one, over three times
/// the job's usual value.
fn budget_breaches(def: &Definition, run: &Run, history: &[Run]) -> Vec<BudgetBreach> {
    let mut breaches = Vec::new();
    let budget = def.get("budget").and_then(Value::as_object);
    for (name, value) in run.metrics.iter() {
        if let Some(v) = budget.and_then(|b| b.get(name)) {
            if value > js_number(v) {
                breaches.push(BudgetBreach { metric: name.into(), value, limit: js_number(v), basis: "budget".into() });
            }
            continue;
        }
        let past: Vec<f64> = history
            .iter()
            .filter(|r| r.status == RunStatus::Ok)
            .filter_map(|r| r.metrics.get(name))
            .take(BASELINE_WINDOW)
            .collect();
        if past.len() < BASELINE_MIN_RUNS {
            continue;
        }
        let usual = median(&past).unwrap_or(0.0);
        if usual > 0.0 && value > 3.0 * usual {
            breaches.push(BudgetBreach {
                metric: name.into(),
                value,
                limit: 3.0 * usual,
                basis: format!("three times the usual {}", format_number(usual)),
            });
        }
    }
    breaches
}

/// JavaScript's `Number(v)` for a JSON value, as a comparison with `>`
/// coerces one.
pub(crate) fn js_number(v: &Value) -> f64 {
    match v {
        Value::Number(n) => *n,
        Value::Null => 0.0,
        Value::Bool(b) => f64::from(u8::from(*b)),
        Value::String(s) => {
            let text = js::trim(s);
            if text.is_empty() { 0.0 } else { string_to_number(text) }
        }
        _ => f64::NAN,
    }
}

/// `Number(text)` for trimmed, non-empty text: decimal, `Infinity`, and the
/// `0x`, `0o` and `0b` integer forms; anything else is NaN.
fn string_to_number(text: &str) -> f64 {
    let (sign, body) = match text.as_bytes()[0] {
        b'-' => (-1.0, &text[1..]),
        b'+' => (1.0, &text[1..]),
        _ => (1.0, text),
    };
    if body == "Infinity" {
        return sign * f64::INFINITY;
    }
    let radix = match body.get(..2) {
        Some("0x" | "0X") => 16,
        Some("0o" | "0O") => 8,
        Some("0b" | "0B") => 2,
        _ => 10,
    };
    if radix != 10 {
        // A sign is not allowed before a prefixed integer.
        if sign < 0.0 || text.starts_with('+') || body.len() == 2 {
            return f64::NAN;
        }
        return body[2..]
            .chars()
            .try_fold(0.0, |acc, c| c.to_digit(radix).map(|d| acc * radix as f64 + d as f64))
            .unwrap_or(f64::NAN);
    }
    let valid = !body.is_empty()
        && !body.starts_with(['+', '-'])
        && body.bytes().all(|c| c.is_ascii_digit() || matches!(c, b'.' | b'e' | b'E' | b'+' | b'-'))
        && body.bytes().any(|c| c.is_ascii_digit());
    if !valid {
        return f64::NAN;
    }
    body.parse::<f64>().map_or(f64::NAN, |n| sign * n)
}

/// Called when a run starts. Missed and stuck are about the absence of a
/// run, so a run starting closes them without an alert; the recovered
/// message waits for a successful finish.
pub(crate) fn on_run_start(state: &JobState) -> JobState {
    let mut next = clone_state(state);
    close_condition(&mut next, Condition::Missed);
    close_condition(&mut next, Condition::Stuck);
    next
}

/// `Math.max(1, def.failuresBeforeAlert ?? 1)`.
fn failures_before_alert(def: &Definition) -> f64 {
    match def.get("failuresBeforeAlert") {
        None | Some(Value::Null) => 1.0,
        Some(v) => {
            let n = js_number(v);
            if n.is_nan() { n } else { n.max(1.0) }
        }
    }
}

/// Called when a run finishes with status ok, failed or timeout. `history`
/// is the job's earlier runs, newest first, not including this one.
pub(crate) fn on_run_finish(
    def: &Definition,
    run: &Run,
    state: &JobState,
    history: &[Run],
    now: i64,
) -> Result<Evaluation, String> {
    let mut next = clone_state(state);
    let mut alerts = Vec::new();

    if run.status == RunStatus::Ok {
        next.consecutive_failures = 0;
        close_condition(&mut next, Condition::Missed);
        close_condition(&mut next, Condition::Stuck);
        close_condition(&mut next, Condition::Failed);

        match (slow_threshold(def, history)?, run.duration_ms) {
            (Some((threshold, basis)), Some(duration)) if duration as f64 > threshold => {
                if open_condition(&mut next, Condition::Slow, now) {
                    alerts.push(AlertDraft {
                        alert_type: AlertType::Slow,
                        run: Some(run.clone()),
                        details: AlertDetails::Slow { duration_ms: duration, threshold_ms: threshold, basis },
                    });
                }
            }
            _ => {
                close_condition(&mut next, Condition::Slow);
            }
        }

        let breaches = budget_breaches(def, run, history);
        if !breaches.is_empty() {
            if open_condition(&mut next, Condition::OverBudget, now) {
                alerts.push(AlertDraft {
                    alert_type: AlertType::OverBudget,
                    run: Some(run.clone()),
                    details: AlertDetails::OverBudget { breaches },
                });
            }
        } else {
            close_condition(&mut next, Condition::OverBudget);
        }

        if !pending(&mut next).is_empty() && next.open.is_empty() {
            let after = std::mem::take(pending(&mut next));
            alerts.push(AlertDraft {
                alert_type: AlertType::Recovered,
                run: Some(run.clone()),
                details: AlertDetails::Recovered { after, reason: None, since: None },
            });
        }
        return Ok(Evaluation { state: next, alerts });
    }

    // failed or timeout
    // Held at the top: a count at the limit must not wrap below a threshold.
    next.consecutive_failures = next.consecutive_failures.clamp(0, MAX_DURATION_MS - 1) + 1;
    close_condition(&mut next, Condition::Missed);
    let threshold = failures_before_alert(def);
    let (condition, alert_type) = if run.status == RunStatus::Timeout {
        (Condition::Stuck, AlertType::Stuck)
    } else {
        (Condition::Failed, AlertType::Failed)
    };
    if next.consecutive_failures as f64 >= threshold && open_condition(&mut next, condition, now) {
        alerts.push(AlertDraft {
            alert_type,
            run: Some(run.clone()),
            details: AlertDetails::Failure {
                consecutive_failures: next.consecutive_failures,
                threshold: js::to_i64(threshold),
            },
        });
    }
    Ok(Evaluation { state: next, alerts })
}

/// What `on_check` found besides the evaluation.
#[derive(Clone, Debug)]
pub(crate) struct CheckOutcome {
    pub evaluation: Evaluation,
    pub next_expected_at: Option<i64>,
    #[allow(dead_code)] // the SDK's shape; nothing reads it yet
    pub due_at: Option<i64>,
}

/// JavaScript's truthiness of a JSON value.
pub(crate) fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => *n != 0.0 && !n.is_nan(),
        Value::String(s) => !s.is_empty(),
        _ => true,
    }
}

/// `parseSchedule(def.schedule, def.timezone)` for a stored definition,
/// which may hold anything another writer put there.
pub(crate) fn parsed_schedule(def: &Definition) -> Result<std::sync::Arc<Parsed>, String> {
    let Some(Value::String(text)) = def.get("schedule") else {
        return Err("schedule.trim is not a function".into());
    };
    let tz = match def.get("timezone") {
        None | Some(Value::Null) => "",
        Some(Value::String(s)) => s.as_str(),
        Some(v) => return Err(format!("timezone {} is not an IANA timezone", v.to_json())),
    };
    schedule::parse(text, tz)
}

/// Called by a check. It decides whether the schedule has been missed: the
/// run the schedule wants next (see `schedule::expect`) has not started and
/// its grace has run out. `last_run` is the most recent run of any status. A
/// job with no schedule is never missed, and one whose schedule was removed
/// while missed was open gets a recovered alert (reason `unscheduled`) for
/// missed alone.
pub(crate) fn on_check(
    def: &Definition,
    stored: &StoredJob,
    last_run: Option<&Run>,
    state: &JobState,
    now: i64,
) -> Result<CheckOutcome, String> {
    let mut next = clone_state(state);
    let mut alerts = Vec::new();
    if !def.get("schedule").is_some_and(truthy) {
        if let Some(since) = next.open_at(&Condition::Missed) {
            // The schedule went away while missed was open (the job was
            // declared again without one, or a source retired it), so nothing
            // is due any more. Missed closes now with a recovery of its own;
            // other open conditions keep their own rules. Missed is taken out
            // of the pending recovery too, so the next successful run does
            // not name it again.
            delete_open(&mut next, &Condition::Missed);
            pending(&mut next).retain(|c| c != &Condition::Missed);
            alerts.push(AlertDraft {
                alert_type: AlertType::Recovered,
                run: last_run.cloned(),
                details: AlertDetails::Recovered {
                    after: vec![Condition::Missed],
                    reason: Some("unscheduled".into()),
                    since: Some(since),
                },
            });
        }
        return Ok(CheckOutcome {
            evaluation: Evaluation { state: next, alerts },
            next_expected_at: None,
            due_at: None,
        });
    }

    let parsed = parsed_schedule(def)?;
    let grace = grace_ms(def)?;
    let last_run_at = last_run.map(|r| r.started_at);
    let expectation = schedule::expect(&parsed, last_run_at, stored.created_at, grace);
    let next_expected_at = if parsed.is_interval() {
        schedule::next_fire(&parsed, stored.created_at, last_run_at)
    } else {
        schedule::next_fire(&parsed, now, None)
    };
    let Some(exp) = expectation else {
        return Ok(CheckOutcome { evaluation: Evaluation { state: next, alerts }, next_expected_at, due_at: None });
    };
    let due_at = Some(exp.due_at);

    // An interval's next run is due a period after the last one started. If
    // that run is still going, the job is busy, not late; stuck covers one
    // that never ends.
    if parsed.is_interval() && last_run.is_some_and(|r| r.status == RunStatus::Running) {
        return Ok(CheckOutcome { evaluation: Evaluation { state: next, alerts }, next_expected_at, due_at });
    }

    if now as f64 > exp.deadline {
        if open_condition(&mut next, Condition::Missed, now) {
            alerts.push(AlertDraft {
                alert_type: AlertType::Missed,
                run: last_run.cloned(),
                details: AlertDetails::Missed {
                    due_at: exp.due_at,
                    deadline: exp.deadline,
                    grace_ms: grace,
                    last_run_at,
                },
            });
        }
    } else {
        // A run has started since it opened, or the grace was widened.
        close_condition(&mut next, Condition::Missed);
    }
    Ok(CheckOutcome { evaluation: Evaluation { state: next, alerts }, next_expected_at, due_at })
}

/// Whether a running run has gone on longer than the job's timeout.
pub(crate) fn is_stuck(def: &Definition, run: &Run, now: i64) -> Result<bool, String> {
    if run.status != RunStatus::Running {
        return Ok(false);
    }
    Ok(now.saturating_sub(run.started_at) as f64 > timeout_ms(def)?)
}

/// `next` with nothing opened that was not open in `previous`. While a job
/// is silenced nothing new is recorded as an incident: conditions may close
/// (so a job that recovered during the silence shows as healthy) but none
/// may open, so the first problem after the silence ends alerts normally.
pub(crate) fn mute_opens(previous: &JobState, next: &JobState) -> JobState {
    let mut muted = clone_state(next);
    muted.open.retain(|o| previous.open_at(&o.condition).is_some());
    muted
}

pub(crate) fn is_silenced(state: &JobState, now: i64) -> bool {
    state.silenced_until.is_some_and(|until| until > now)
}

/// An evaluation as it is saved and sent: while the job was silenced when it
/// began, nothing opens and nothing is sent.
pub(crate) fn apply_silence(previous: &JobState, e: Evaluation, now: i64) -> Evaluation {
    if !is_silenced(previous, now) {
        return e;
    }
    Evaluation { state: mute_opens(previous, &e.state), alerts: Vec::new() }
}

/// Whether an alert waiting to be retried no longer describes the job, so it
/// is dropped rather than sent late. An alert for a condition is stale once
/// that condition has closed, or has closed and opened again (it opened at a
/// time other than the alert's). A recovery is stale when any condition it
/// names is open again; while they all stay closed it is kept.
pub(crate) fn stale_alert(alert: &Alert, state: &JobState) -> bool {
    if alert.alert_type == AlertType::Recovered {
        let AlertDetails::Recovered { after, .. } = &alert.details else {
            return false;
        };
        return after.iter().any(|c| state.open_at(c).is_some());
    }
    state.open_at(&Condition::parse(alert.alert_type.as_str())) != Some(alert.at)
}

/// How a job looks at a glance. Silence wins, then stuck, failing and late.
pub(crate) fn job_health(
    def: &Definition,
    last_run: Option<&Run>,
    state: &JobState,
    now: i64,
) -> Result<JobHealth, String> {
    let open = open_conditions(state);
    if is_silenced(state, now) {
        return Ok(JobHealth::Silenced);
    }
    if open.contains(&Condition::Stuck) {
        return Ok(JobHealth::Stuck);
    }
    if let Some(run) = last_run {
        if is_stuck(def, run, now)? {
            return Ok(JobHealth::Stuck);
        }
    }
    if open.contains(&Condition::Failed)
        || last_run.is_some_and(|r| r.status == RunStatus::Failed || r.status == RunStatus::Timeout)
    {
        return Ok(JobHealth::Failing);
    }
    if open.contains(&Condition::Missed) {
        return Ok(JobHealth::Late);
    }
    Ok(if last_run.is_none() { JobHealth::NeverRan } else { JobHealth::Healthy })
}

/// A job's summary from its most recent runs (newest first; the first
/// `BASELINE_WINDOW` are used) and its state. Stats cover runs of any
/// status; the percentiles are over the successful ones among them.
pub(crate) fn summarize(
    stored: &StoredJob,
    recent: &[Run],
    state: &JobState,
    next_expected_at: Option<i64>,
    now: i64,
) -> Result<JobSummary, String> {
    let window = &recent[..recent.len().min(BASELINE_WINDOW)];
    let health = job_health(&stored.definition, window.first(), state, now)?;
    Ok(summary(stored, recent, state, next_expected_at, health))
}

/// The summary of a job that could not be evaluated, say because its stored
/// schedule no longer parses. It reads nothing from the definition. The job
/// shows as failing (or silenced, while it is), since it needs a look, and
/// nothing is known about when it is next due.
pub(crate) fn unevaluable_summary(stored: &StoredJob, recent: &[Run], state: &JobState, now: i64) -> JobSummary {
    let health = if is_silenced(state, now) { JobHealth::Silenced } else { JobHealth::Failing };
    summary(stored, recent, state, None, health)
}

fn summary(
    stored: &StoredJob,
    recent: &[Run],
    state: &JobState,
    next_expected_at: Option<i64>,
    health: JobHealth,
) -> JobSummary {
    let window = &recent[..recent.len().min(BASELINE_WINDOW)];
    let finished = window.iter().filter(|r| r.status != RunStatus::Running).count();
    let ok = window.iter().filter(|r| r.status == RunStatus::Ok).count();
    let ok_durations: Vec<f64> =
        window.iter().filter(|r| r.status == RunStatus::Ok).filter_map(|r| r.duration_ms.map(|d| d as f64)).collect();
    let ok_rate = if finished > 0 { ok as f64 / finished as f64 } else { 1.0 };
    JobSummary {
        name: stored.name.clone(),
        definition: stored.definition.clone(),
        health,
        open: open_conditions(state),
        last_run: window.first().cloned(),
        next_expected_at,
        consecutive_failures: state.consecutive_failures,
        silenced_until: state.silenced_until,
        stats: Stats {
            runs: finished as i64,
            ok_rate,
            p50_ms: percentile(&ok_durations, 50.0).map(js::to_i64),
            p95_ms: percentile(&ok_durations, 95.0).map(js::to_i64),
        },
    }
}
