//! The dashboard's timelines (routes/timeline.ts), markup for markup,
//! carried over from the Go port's `routes_timeline.go`: one lane per job
//! (or per day, on a job's page), drawn on the server as inline SVG so the
//! page needs no script.
//!
//! Every time a job was due is a faint tick, worked out from its schedule
//! with the same functions the checks use, so the lane shows the cadence
//! the job is meant to keep. Every run it recorded is a solid mark on top,
//! as wide as it took and coloured by how it ended. A slot the check has
//! reported missed is a dashed box. The empty part of a lane carries a
//! short note about anything open, and a visually hidden list says the same
//! things in words. Every time is UTC: without script the page cannot know
//! the viewer's zone.

use std::collections::BTreeSet;
use std::sync::Arc;

use crate::evaluate::{grace_ms, is_stuck, js_number, parsed_schedule, timeout_ms, truthy};
use crate::format::js_text;
use crate::js::{self, Value};
use crate::schedule::{self, Parsed, format_duration};
use crate::types::{Condition, JobHealth, JobSummary, Run, RunStatus};

use super::text::{count, encode_uri_component, escape_html as h, escape_name, js_round, num, to_fixed};

const HOUR_MS: i64 = 3_600_000;
const DAY_MS: i64 = 24 * HOUR_MS;
/// The board's span: the last day, plus a few hours ahead so what is due
/// soon shows.
pub(crate) const BOARD_BEHIND_MS: i64 = DAY_MS;
pub(crate) const BOARD_AHEAD_MS: i64 = 3 * HOUR_MS;
/// How many jobs the board's timeline draws. The table below it lists
/// every job.
pub(crate) const BOARD_LANES: usize = 30;
/// Runs read for a lane when the twenty the table reads start inside the
/// span, so a frequent job's lane is not cut short. Older runs than this are
/// shown as not loaded rather than as absent.
pub(crate) const BOARD_RUNS: usize = 200;
/// How many days a job's page draws.
const WEEK_DAYS: i64 = 7;
/// Width of a lane in SVG units. Lanes stretch to fit, so strokes do not
/// scale.
const LANE_WIDTH: f64 = 1000.0;
/// A lane with more due times than this shows its cadence as a dotted line
/// instead.
const MAX_TICKS: usize = 330;
/// More missed slots than this are drawn as one dashed band.
const MAX_BOXES: usize = 8;
/// The narrowest a missed box is drawn, in SVG units.
const MIN_BOX: f64 = 10.0;

const MONTH_NAMES: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAY_NAMES: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/// "22:42", in UTC.
pub(crate) fn clock_utc(t: i64) -> String {
    js::iso_string(t)[11..16].to_string()
}

/// The UTC month (1 to 12), day and weekday (0 for Sunday) of `t`.
fn civil(t: i64) -> (usize, i64, usize) {
    let days = js::floor_div(t, DAY_MS);
    let (_, m, d) = js::civil_from_days(days);
    (m as usize, d, js::modulo(days + 4, 7) as usize)
}

/// "Sat 26 Sep", in UTC.
fn day_label(t: i64) -> String {
    let (m, d, wd) = civil(t);
    format!("{} {} {}", WEEKDAY_NAMES[wd], d, MONTH_NAMES[m - 1])
}

/// "22:42" on the same UTC day as `now`, otherwise "25 Sep 22:42".
pub(crate) fn when_utc(t: i64, now: i64) -> String {
    if js::floor_div(t, DAY_MS) == js::floor_div(now, DAY_MS) {
        return clock_utc(t);
    }
    let (m, d, _) = civil(t);
    format!("{d} {} {}", MONTH_NAMES[m - 1], clock_utc(t))
}

/// The stretch of time a timeline draws, and the moment it was drawn.
#[derive(Clone, Copy)]
pub(crate) struct Span {
    pub from: i64,
    pub to: i64,
    pub now: i64,
}

/// The job's schedule, parsed, or `None` when it has none or it no longer
/// parses.
pub(crate) fn lane_schedule(job: &JobSummary) -> Option<Arc<Parsed>> {
    if !job.definition.get("schedule").is_some_and(truthy) {
        return None;
    }
    parsed_schedule(&job.definition).ok()
}

/// When the job was due within `from` to `to`, ascending, and whether they
/// are too many to draw one by one. A cron's fires come from its schedule.
/// An interval is due one period after each run started, and after the
/// last run once a period for as long as nothing runs; with no run yet,
/// from its next expected time.
fn due_times(job: &JobSummary, parsed: Option<&Parsed>, runs: &[Run], from: i64, to: i64) -> (Vec<i64>, bool) {
    let Some(parsed) = parsed else {
        return (Vec::new(), false);
    };
    if parsed.is_interval() {
        let every = parsed.every_ms;
        if every <= 0 {
            return (Vec::new(), false);
        }
        if (to - from) as f64 / every as f64 > MAX_TICKS as f64 {
            return (Vec::new(), true);
        }
        let mut starts: Vec<i64> = runs.iter().map(|r| r.started_at).collect();
        starts.sort_unstable();
        let mut set = BTreeSet::new();
        for start in &starts {
            let t = start.saturating_add(every);
            if t >= from && t <= to {
                set.insert(t);
            }
        }
        let next = starts.last().map(|s| s.saturating_add(every)).or(job.next_expected_at);
        if let Some(mut t) = next {
            if t < from {
                t += ((from - t) as f64 / every as f64).ceil() as i64 * every;
            }
            while t <= to {
                set.insert(t);
                t += every;
            }
        }
        return (set.into_iter().collect(), false);
    }
    match schedule::fires_between(parsed, from - 1, to, MAX_TICKS) {
        Some(fires) => (fires, false),
        None => (Vec::new(), true),
    }
}

/// The slot a missed job was due at, the one the check reported: the first
/// fire its last run does not cover. A job that never ran has no run to
/// count from, so the latest due time whose grace has passed stands in.
/// `None` when missed is not open.
pub(crate) fn missed_at(job: &JobSummary, parsed: Option<&Parsed>, times: &[i64], now: i64) -> Option<i64> {
    let parsed = parsed?;
    if !job.open.contains(&Condition::Missed) {
        return None;
    }
    let grace = grace_ms(&job.definition).unwrap_or(0.0);
    if let Some(last) = &job.last_run {
        let last = last.started_at;
        return schedule::expect(parsed, Some(last), last, grace).map(|e| e.due_at);
    }
    times.iter().copied().rfind(|&t| (t as f64) + grace < now as f64)
}

fn stuck(job: &JobSummary, run: &Run, now: i64) -> bool {
    is_stuck(&job.definition, run, now).unwrap_or(false)
}

fn tone_of(run: &Run, job: &JobSummary, now: i64) -> &'static str {
    match run.status {
        RunStatus::Running => return if stuck(job, run, now) { "stuck" } else { "running" },
        RunStatus::Failed => return "bad",
        RunStatus::Timeout => return "timeout",
        _ => {}
    }
    let latest = job.last_run.as_ref().is_some_and(|l| l.id == run.id);
    if latest && (job.open.contains(&Condition::OverBudget) || job.open.contains(&Condition::Slow)) {
        return "warn";
    }
    "ok"
}

fn timeout_text(job: &JobSummary) -> String {
    timeout_ms(&job.definition).map_or_else(|_| "configured".into(), format_duration)
}

/// One run, as its tooltip says it.
fn describe_run(run: &Run, tone: &str, job: &JobSummary, now: i64) -> String {
    let at = format!("{} UTC", when_utc(run.started_at, now));
    match tone {
        "running" => {
            return format!("running since {at}, {} so far", format_duration((now - run.started_at) as f64));
        }
        "stuck" => return format!("running since {at}, past its {} timeout", timeout_text(job)),
        _ => {}
    }
    let took = run.duration_ms.map_or(String::new(), |d| format!(", took {}", format_duration(d as f64)));
    let extra = if tone == "warn" {
        if job.open.contains(&Condition::OverBudget) { ", over budget" } else { ", slow" }
    } else {
        ""
    };
    format!("{} at {at}{took}{extra}", run.status.as_str())
}

/// The metrics of the job's last run that went over their ceilings.
fn over_ceilings(job: &JobSummary) -> Vec<String> {
    let Some(Value::Object(budget)) = job.definition.get("budget") else {
        return Vec::new();
    };
    budget
        .iter()
        .filter(|(k, limit)| {
            let value = job.last_run.as_ref().and_then(|r| r.metrics.get(k)).unwrap_or(f64::NEG_INFINITY);
            value > js_number(limit)
        })
        .map(|(k, _)| k.to_string())
        .collect()
}

/// What is worth saying about the job in a few words, or `""` when all is
/// well.
pub(crate) fn lane_note(job: &JobSummary, missed: Option<i64>, now: i64) -> String {
    let last = job.last_run.as_ref();
    let open = |c: Condition| job.open.contains(&c);
    if let Some(until) = job.silenced_until.filter(|&u| u > now) {
        return format!("silenced until {}", when_utc(until, now));
    }
    if open(Condition::Missed) {
        return match missed {
            Some(m) => format!("due {}, nothing ran", when_utc(m, now)),
            None => "overdue, nothing ran".into(),
        };
    }
    if let Some(last) = last {
        match last.status {
            RunStatus::Running => {
                if stuck(job, last, now) {
                    return format!(
                        "running since {}, past its {} timeout",
                        when_utc(last.started_at, now),
                        timeout_text(job)
                    );
                }
                return format!("running since {}", when_utc(last.started_at, now));
            }
            RunStatus::Failed => {
                let mut text = format!("failed at {}", when_utc(last.started_at, now));
                if job.consecutive_failures > 1 {
                    text.push_str(&format!(", {} in a row", num(job.consecutive_failures as f64)));
                }
                return text;
            }
            RunStatus::Timeout => return format!("timed out at {}", when_utc(last.started_at, now)),
            _ => {}
        }
    }
    if open(Condition::Stuck) {
        return "stuck".into();
    }
    if let (true, Some(last)) = (open(Condition::OverBudget), last) {
        let mut text = "went over budget".to_string();
        let over = over_ceilings(job);
        if !over.is_empty() {
            text.push_str(&format!(" on {}", over.join(" and ")));
        }
        return format!("{text} at {}", when_utc(last.started_at, now));
    }
    if let (true, Some(d)) = (open(Condition::Slow), last.and_then(|l| l.duration_ms)) {
        return format!("slow: took {}", format_duration(d as f64));
    }
    if open(Condition::Failed) {
        return "failing".into();
    }
    if let (None, Some(next)) = (last, job.next_expected_at) {
        return format!("no runs yet, first due {}", when_utc(next, now));
    }
    String::new()
}

/// Everything one lane of the board shows.
pub(crate) struct LaneInput {
    pub job: JobSummary,
    /// The job's runs, any order. Only those overlapping the span are drawn.
    pub runs: Vec<Run>,
    /// False when older runs exist that were not read; the lane says so
    /// before its oldest run.
    pub complete: bool,
}

struct LaneParts {
    svg: String,
    note: String,
    words: String,
}

/// `toFixed(1)`, the precision every coordinate is written with.
fn fx(n: f64) -> String {
    to_fixed(n, 1)
}

/// The animation delay for a mark at `x`, so marks arrive in time order,
/// left to right.
fn delay(x: f64, base: f64, per_unit: f64) -> String {
    format!("--d:{}ms", num(js_round(base + x.max(0.0) * per_unit)))
}

fn finished_or(r: &Run, now: i64) -> i64 {
    r.finished_at.unwrap_or(now)
}

/// A lane's x for a time that need not be whole (a slot plus its grace).
fn xf(t: f64, sp: Span) -> f64 {
    (((t - sp.from as f64) / (sp.to - sp.from) as f64) * LANE_WIDTH).clamp(0.0, LANE_WIDTH)
}

fn lane(job: &JobSummary, runs: &[Run], complete: bool, sp: Span, now_in_lane: bool, name: &str) -> LaneParts {
    let Span { from, to, now } = sp;
    let x = |t: i64| ((((t - from) as f64) / (to - from) as f64) * LANE_WIDTH).clamp(0.0, LANE_WIDTH);
    let parsed = lane_schedule(job);
    let (times, dense) = due_times(job, parsed.as_deref(), runs, from, to);
    let missed = missed_at(job, parsed.as_deref(), &times, now);
    let grace = grace_ms(&job.definition).unwrap_or(0.0);
    let mut busy: Vec<(f64, f64)> = Vec::new();

    let mut s = String::from(
        r#"<svg class="marks" viewBox="0 0 1000 24" preserveAspectRatio="none" aria-hidden="true" focusable="false">"#,
    );
    if now_in_lane && now > from && now < to {
        s.push_str(&format!(
            r#"<rect class="ahead" x="{}" y="0" width="{}" height="24"/>"#,
            fx(x(now)),
            fx(LANE_WIDTH - x(now))
        ));
    }
    s.push_str(r#"<line class="base" x1="0" y1="12" x2="1000" y2="12"/>"#);

    let mut in_span: Vec<&Run> = runs.iter().filter(|r| r.started_at <= to && finished_or(r, now) >= from).collect();
    in_span.sort_by_key(|r| r.started_at);
    if !complete && !runs.is_empty() {
        let oldest = runs.iter().map(|r| r.started_at).min().unwrap_or(0);
        if oldest > from {
            s.push_str(&format!(
                r#"<rect class="unloaded" x="0" y="4" width="{}" height="16"><title>{}</title></rect>"#,
                fx(x(oldest)),
                h(&format!("{name}: runs before {} UTC are not loaded here", when_utc(oldest, now)))
            ));
        }
    }

    if dense {
        s.push_str(&format!(
            r#"<line class="cadence" x1="0" y1="12" x2="1000" y2="12"><title>{}</title></line>"#,
            h(&format!("{name}: due {}, too often to mark each time", schedule_text(job, "")))
        ));
    }
    for &t in &times {
        let tx = x(t);
        let ahead = if t > now { " ahead" } else { "" };
        s.push_str(&format!(
            r#"<line class="tick{ahead}" x1="{0}" y1="6" x2="{0}" y2="18" style="{1}"/>"#,
            fx(tx),
            delay(tx, 0.0, 0.45)
        ));
    }

    // Missed slots: the reported one and every later one whose grace has run out.
    if let Some(m) = missed.filter(|&m| m <= to) {
        let mut slots: Vec<i64> = if dense {
            Vec::new()
        } else {
            times.iter().copied().filter(|&t| t >= m && (t as f64) + grace < now as f64).collect()
        };
        if !slots.contains(&m) && m >= from {
            slots.insert(0, m);
        }
        let mut title = format!("{name}: due {} UTC, nothing started", when_utc(m, now));
        if slots.len() > 1 {
            title.push_str(&format!(" ({} slots in this span)", count(slots.len())));
        }
        let title = h(&title);
        if dense || slots.len() > MAX_BOXES {
            let x1 = x(m.max(from));
            let x2 = x(now).max(x1 + MIN_BOX);
            s.push_str(&format!(
                r#"<rect class="missed" x="{}" y="5" width="{}" height="14" style="{}"><title>{title}</title></rect>"#,
                fx(x1),
                fx(x2 - x1),
                delay(x1, 80.0, 0.75)
            ));
            busy.push((x1, x2));
        } else {
            for &t in &slots {
                if t < from {
                    continue;
                }
                let x1 = x(t);
                let width = (xf(t as f64 + grace, sp) - x1).max(MIN_BOX);
                s.push_str(&format!(
                    r#"<rect class="missed" x="{}" y="5" width="{}" height="14" style="{}"><title>{title}</title></rect>"#,
                    fx(x1),
                    fx(width),
                    delay(x1, 80.0, 0.75)
                ));
                busy.push((x1, x1 + width));
            }
        }
    }

    for run in &in_span {
        let tone = tone_of(run, job, now);
        // A zero-width rect is not drawn at all; its stroke gives short runs their width.
        let x1 = x(run.started_at);
        let x2 = x(finished_or(run, now)).max(x1 + 0.5);
        s.push_str(&format!(
            r#"<rect class="run {tone}" x="{}" y="5" width="{}" height="14" style="{}"><title>{}</title></rect>"#,
            fx(x1),
            fx(x2 - x1),
            delay(x1, 80.0, 0.75),
            h(&format!("{name}: {}", describe_run(run, tone, job, now)))
        ));
        busy.push((x1, x2));
    }

    if now_in_lane && now > from && now < to {
        s.push_str(&format!(r#"<line class="nowline" x1="{0}" y1="0" x2="{0}" y2="24"/>"#, fx(x(now))));
    }
    s.push_str("</svg>");

    // The note goes wherever the lane is actually empty, so it never sits on
    // the marks it describes; it is cut short with an ellipsis when narrow.
    let text = lane_note(job, missed, now);
    let mut note = String::new();
    if !text.is_empty() {
        let now_x = x(now);
        let (mut lo, mut hi) = (now_x, now_x);
        if !busy.is_empty() {
            (lo, hi) = (f64::INFINITY, f64::NEG_INFINITY);
            for &(b_lo, b_hi) in &busy {
                lo = lo.min(b_lo);
                hi = hi.max(b_hi);
            }
        }
        let right = LANE_WIDTH - hi >= lo;
        let room = if right { LANE_WIDTH - hi } else { lo };
        if room > 90.0 {
            let (place, cls) = if right {
                (format!("left:{}%", fx((hi + 14.0) / 10.0)), "")
            } else {
                (format!("right:{}%", fx(100.0 - (lo - 14.0) / 10.0)), " before")
            };
            note = format!(
                r#"<span class="note{cls}" style="{place};max-width:{}%">{}</span>"#,
                fx((room - 18.0) / 10.0),
                h(&text)
            );
        }
    }
    let words = lane_words(job, &in_span, &times, dense, missed, sp, &text);
    LaneParts { svg: s, note, words }
}

/// `${definition.schedule ?? fallback}`.
fn schedule_text(job: &JobSummary, fallback: &str) -> String {
    match job.definition.get("schedule") {
        None | Some(Value::Null) => fallback.to_string(),
        v => js_text(v),
    }
}

/// The lane in words, for anyone who cannot see it.
fn lane_words(
    job: &JobSummary,
    runs: &[&Run],
    times: &[i64],
    dense: bool,
    missed: Option<i64>,
    sp: Span,
    note: &str,
) -> String {
    let mut parts: Vec<String> = Vec::new();
    let sched = job.definition.get("schedule");
    if dense {
        parts.push(format!("due {}", js_text(sched)));
    } else if sched.is_some_and(truthy) {
        parts.push(match times.iter().filter(|&&t| t <= sp.now).count() {
            0 => "due no times so far".into(),
            1 => "due once so far".into(),
            n => format!("due {} times so far", count(n)),
        });
    }
    let ok = runs.iter().filter(|r| r.status == RunStatus::Ok).count();
    let mut recorded =
        if runs.len() == 1 { "1 run recorded".to_string() } else { format!("{} runs recorded", count(runs.len())) };
    if !runs.is_empty() {
        if ok == runs.len() && ok == 1 {
            recorded.push_str(", ok");
        } else if ok == runs.len() {
            recorded.push_str(", all ok");
        } else if ok > 0 {
            recorded.push_str(&format!(", {} ok", count(ok)));
        }
    }
    parts.push(recorded);
    let bad: Vec<&&Run> = runs.iter().filter(|r| matches!(r.status, RunStatus::Failed | RunStatus::Timeout)).collect();
    for r in &bad[bad.len().saturating_sub(5)..] {
        parts.push(format!(
            "{} at {} UTC after {}",
            r.status.as_str(),
            when_utc(r.started_at, sp.now),
            format_duration(r.duration_ms.map_or(0.0, |d| d as f64))
        ));
    }
    if let Some(m) = missed {
        parts.push(format!("due at {} UTC and nothing started", when_utc(m, sp.now)));
    }
    if !note.is_empty() && !note.starts_with("due ") && !note.starts_with("failed at") && !note.starts_with("timed out")
    {
        parts.push(note.to_string());
    }
    parts.join("; ")
}

/// The grid lines and hour labels every `step`, on UTC boundaries.
fn hour_grid(sp: Span, step: i64, now_label: bool) -> (String, String) {
    let x = |t: i64| ((t - sp.from) as f64 / (sp.to - sp.from) as f64) * LANE_WIDTH;
    let now_x = x(sp.now);
    let (mut lines, mut labels) = (String::new(), String::new());
    let mut t = -js::floor_div(-sp.from, step) * step;
    while t <= sp.to {
        let gx = x(t);
        lines.push_str(&format!(r#"<i class="gl" style="left:{}%"></i>"#, fx(gx / 10.0)));
        let near_now = now_label && (gx - now_x).abs() < 70.0;
        if (25.0..=LANE_WIDTH - 25.0).contains(&gx) && !near_now {
            let mut cls: Vec<&str> = Vec::new();
            if js_round(t as f64 / HOUR_MS as f64) % 6.0 != 0.0 {
                cls.push("minor");
            }
            // On a phone the track is too narrow for a label this close to "now"; CSS hides it there.
            if now_label && (gx - now_x).abs() < 170.0 {
                cls.push("near");
            }
            labels.push_str(&format!(
                r#"<span class="{}" style="left:{}%">{}</span>"#,
                cls.join(" "),
                fx(gx / 10.0),
                clock_utc(t)
            ));
        }
        t += step;
    }
    if now_label && sp.now >= sp.from && sp.now <= sp.to {
        labels.push_str(&format!(
            r#"<span class="nowlabel" style="left:{}%">now {}</span>"#,
            fx(now_x / 10.0),
            clock_utc(sp.now)
        ));
    }
    (lines, labels)
}

/// The key under a timeline: a small sample of each mark and what it means.
fn timeline_legend() -> String {
    let key = |inner: &str| {
        format!(r#"<svg class="key" viewBox="0 0 16 12" aria-hidden="true" focusable="false">{inner}</svg>"#)
    };
    let boxed = |cls: &str| key(&format!(r#"<rect class="{cls}" x="2" y="1" width="12" height="10"/>"#));
    let items = [
        (key(r#"<line class="tick" x1="8" y1="1" x2="8" y2="11"/>"#), "due"),
        (boxed("run ok"), "ran"),
        (boxed("run bad"), "failed"),
        (boxed("run timeout"), "timed out"),
        (boxed("run warn"), "over budget or slow"),
        (boxed("run running"), "running"),
        (boxed("missed"), "missed"),
    ];
    let mut b = String::from(r#"<p class="legend" aria-hidden="true">"#);
    for (sample, label) in items {
        b.push_str(&format!("<span>{sample}{label}</span>"));
    }
    b.push_str("</p>");
    b
}

fn state_class(job: &JobSummary) -> &'static str {
    match job.health {
        JobHealth::Healthy => "ok",
        JobHealth::Late => "warn",
        JobHealth::Failing | JobHealth::Stuck => "bad",
        _ => "muted",
    }
}

/// The board's timeline: one lane per job across `sp`, with a shared now
/// line and the first `BOARD_LANES` jobs only. `total` is how many jobs
/// there are in all, for the note when some are left out.
pub(crate) fn day_timeline(lanes: &[LaneInput], sp: Span, base: &str, total: usize) -> String {
    let (lines, labels) = hour_grid(sp, 3 * HOUR_MS, true);
    let now_x = ((sp.now - sp.from) as f64 / (sp.to - sp.from) as f64) * 100.0;
    let (mut rows, mut words) = (String::new(), String::new());
    for input in lanes {
        let job = &input.job;
        let parts = lane(job, &input.runs, input.complete, sp, false, &job.name);
        let sched = schedule_text(job, "no schedule");
        rows.push_str(
            &[
                r#"<li class="lane"><div class="who"><i class="sq "#,
                state_class(job),
                r#"" aria-hidden="true"></i><a class="name" href=""#,
                &h(base),
                "/jobs/",
                &encode_uri_component(&job.name),
                r#"">"#,
                &escape_name(&job.name),
                r#"</a><span class="sched">"#,
                &h(&sched),
                r#"</span></div><div class="track">"#,
                &parts.svg,
                &parts.note,
                "</div></li>",
            ]
            .concat(),
        );
        words.push_str(&format!("<li>{}</li>", h(&format!("{} ({sched}): {}.", job.name, parts.words))));
    }
    let more = if total > lanes.len() {
        format!(
            r#"<p class="more">Showing the first {} of {} jobs here; the table below lists them all.</p>"#,
            count(lanes.len()),
            count(total)
        )
    } else {
        String::new()
    };
    [
        "<figure class=\"timeline day\">\n<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">",
        &labels,
        "</div></div>\n<div class=\"field\">\n<div class=\"under\" aria-hidden=\"true\"><span></span><div>",
        &lines,
        "<i class=\"future\" style=\"left:",
        &fx(now_x),
        "%\"></i></div></div>\n<ol class=\"lanes\">",
        &rows,
        "</ol>\n<div class=\"over\" aria-hidden=\"true\"><span></span><div><i class=\"now\" style=\"left:",
        &fx(now_x),
        "%\"></i></div></div>\n</div>\n",
        &timeline_legend(),
        &more,
        "\n<ul class=\"vh\">",
        &words,
        "</ul>\n</figure>",
    ]
    .concat()
}

/// A job's page: its last `WEEK_DAYS` UTC days, today first, one lane each.
/// `complete` is false when the runs read do not reach back over the week.
pub(crate) fn week_timeline(job: &JobSummary, runs: &[Run], complete: bool, now: i64) -> String {
    let today = js::floor_div(now, DAY_MS) * DAY_MS;
    let oldest = runs.iter().map(|r| r.started_at).min();
    let (lines, labels) = hour_grid(Span { from: today, to: today + DAY_MS, now }, 3 * HOUR_MS, false);
    let (mut rows, mut words) = (String::new(), String::new());
    for i in 0..WEEK_DAYS {
        let from = today - i * DAY_MS;
        let sp = Span { from, to: from + DAY_MS, now };
        let n = runs.iter().filter(|r| r.started_at < sp.to && finished_or(r, now) >= from).count();
        let known = complete || oldest.is_some_and(|o| o <= from);
        let label = if i == 0 { "today".to_string() } else { day_label(from) };
        let parts = lane(job, runs, known, sp, i == 0, &format!("{}, {label}", job.name));
        let count_text = if n == 1 { "1 run".to_string() } else { format!("{} runs", count(n)) };
        let (cls, name, note, said) = if i == 0 {
            (" today", format!("Today, {}", &day_label(from)[4..]), parts.note.as_str(), "Today".to_string())
        } else {
            ("", day_label(from), "", day_label(from))
        };
        rows.push_str(&format!(
            r#"<li class="lane{cls}"><div class="who"><span class="name">{}</span><span class="sched">{}</span></div><div class="track">{}{note}</div></li>"#,
            h(&name),
            h(&count_text),
            parts.svg
        ));
        words.push_str(&format!("<li>{}</li>", h(&format!("{said}: {}.", parts.words))));
    }
    [
        "<figure class=\"timeline week\">\n<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">",
        &labels,
        "</div></div>\n<div class=\"field\">\n<div class=\"under\" aria-hidden=\"true\"><span></span><div>",
        &lines,
        "</div></div>\n<ol class=\"lanes\">",
        &rows,
        "</ol>\n</div>\n",
        &timeline_legend(),
        "\n<ul class=\"vh\">",
        &words,
        "</ul>\n</figure>",
    ]
    .concat()
}

/// How many runs a job's page reads so its week is drawn in full: roughly
/// how often the schedule was due over the week, with room to spare, from
/// 50 (what the run list shows) to 500 (the most `runs` returns).
pub(crate) fn week_runs_limit(job: &JobSummary, now: i64) -> usize {
    let Some(parsed) = lane_schedule(job) else {
        return 50;
    };
    let from = js::floor_div(now, DAY_MS) * DAY_MS - (WEEK_DAYS - 1) * DAY_MS;
    let width = (now + DAY_MS - from) as f64;
    let expected = if parsed.is_interval() {
        width / parsed.every_ms as f64
    } else {
        // A cron's fires over one day, times the week: close enough, and cheap.
        let (times, dense) = due_times(job, Some(&parsed), &[], now - DAY_MS, now);
        if dense { f64::INFINITY } else { times.len() as f64 * width / DAY_MS as f64 }
    };
    ((expected * 1.2).ceil() + 10.0).clamp(50.0, 500.0) as usize
}
