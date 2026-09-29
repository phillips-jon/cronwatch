//! The dashboard's pages (routes/html.ts), byte for byte, carried over
//! from the Go port's `routes_html.go`: set like cronwatch.dev, a printed
//! sheet on grey paper, a serif for what a person reads, a mono for what a
//! machine printed, neutral greys, and colour only for the states CronWatch
//! reports. The page loads nothing but its own app shell, and works without
//! its one script.

use std::collections::HashMap;

use crate::evaluate::{js_number, truthy};
use crate::format::js_text;
use crate::js::{self, Value};
use crate::schedule::{format_duration, format_relative};
use crate::types::{Condition, Definition, JobHealth, JobSummary, Run, RunStatus};

use super::pwa::{STYLE_CSS, THEME_COLOR, THEME_COLOR_DARK};
use super::text::{count, encode_uri_component, escape_html as h, escape_name, escape_value, js_round, num, to_fixed};
use super::timeline::{
    BOARD_AHEAD_MS, BOARD_BEHIND_MS, LaneInput, Span, clock_utc, day_timeline, lane_note, lane_schedule, missed_at,
    week_timeline, when_utc,
};

/// The clock face from cronwatch.dev, in the text colour.
const MARK: &str = r#"<svg viewBox="0 0 40 40" aria-hidden="true" focusable="false"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="none" stroke="currentColor" stroke-opacity=".22" stroke-width="1.5"/><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>"#;

/// A page. `base` is where the dashboard is mounted (`""` at the root);
/// `refresh`, when above 0, is the page's refresh in seconds.
fn layout(title: &str, body: &str, base: &str, refresh: u32) -> String {
    let b = h(base);
    let meta = if refresh > 0 { format!(r#"<meta http-equiv="refresh" content="{refresh}">"#) } else { String::new() };
    [
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n",
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">\n",
        "<meta name=\"robots\" content=\"noindex,nofollow\">\n",
        "<meta name=\"color-scheme\" content=\"light dark\">\n",
        &meta,
        "\n<title>",
        &h(title),
        "</title>\n<meta name=\"theme-color\" content=\"",
        THEME_COLOR,
        "\" media=\"(prefers-color-scheme: light)\">\n<meta name=\"theme-color\" content=\"",
        THEME_COLOR_DARK,
        "\" media=\"(prefers-color-scheme: dark)\">\n",
        "<meta name=\"mobile-web-app-capable\" content=\"yes\">\n",
        "<meta name=\"apple-mobile-web-app-capable\" content=\"yes\">\n",
        "<meta name=\"apple-mobile-web-app-title\" content=\"CronWatch\">\n",
        "<meta name=\"apple-mobile-web-app-status-bar-style\" content=\"default\">\n",
        "<link rel=\"manifest\" href=\"",
        &b,
        "/manifest.webmanifest\">\n<link rel=\"icon\" href=\"",
        &b,
        "/icons/icon.svg\" type=\"image/svg+xml\">\n<link rel=\"apple-touch-icon\" href=\"",
        &b,
        "/icons/apple-touch-icon.png\">\n<script src=\"",
        &b,
        "/app.js\" defer></script>\n<style>",
        STYLE_CSS,
        "</style>\n</head>\n<body><div class=\"sheet\">",
        body,
        "</div></body>\n</html>",
    ]
    .concat()
}

/// The header's mark and name, and a crumb after it when one is given.
fn brand(base: &str, crumb: Option<&str>) -> String {
    let home = format!(r#"<a href="{}/">{MARK}<span>CronWatch</span></a>"#, h(base));
    match crumb {
        None => format!(r#"<p class="brand">{home}</p>"#),
        Some(c) => format!(
            r#"<p class="brand">{home}<span class="slash" aria-hidden="true">/</span><span class="crumb">{}</span></p>"#,
            escape_name(c)
        ),
    }
}

/// The healths in the SDK's order, with their class and label.
const HEALTH_ORDER: [(JobHealth, &str, &str); 6] = [
    (JobHealth::Failing, "bad", "failing"),
    (JobHealth::Stuck, "bad", "stuck"),
    (JobHealth::Late, "warn", "late"),
    (JobHealth::Healthy, "ok", "healthy"),
    (JobHealth::Silenced, "muted", "silenced"),
    (JobHealth::NeverRan, "muted", "never ran"),
];

fn health_label(health: &JobHealth) -> (&'static str, &'static str) {
    // A health this version does not know, as the SDK's lookup would leave it.
    HEALTH_ORDER.iter().find(|e| &e.0 == health).map_or(("undefined", "undefined"), |e| (e.1, e.2))
}

/// `c.replace("_", " ")`: the first underscore only.
pub(crate) fn condition_text(c: &Condition) -> String {
    c.as_str().replacen('_', " ", 1)
}

/// The job's health, with any open condition it does not already say (over
/// budget, slow) after it.
fn health_state(job: &JobSummary) -> String {
    let (cls, label) = health_label(&job.health);
    let mut extras = String::new();
    for c in &job.open {
        if !matches!(c, Condition::Missed | Condition::Failed | Condition::Stuck) {
            extras.push_str(&format!(r#"<span class="state warn">{}</span>"#, h(&condition_text(c))));
        }
    }
    format!(r#"<span class="state {cls}"><i class="sq {cls}" aria-hidden="true"></i>{label}</span>{extras}"#)
}

fn run_state(run: &Run) -> String {
    let cls = match run.status {
        RunStatus::Ok => "ok",
        RunStatus::Running => "info",
        _ => "bad",
    };
    format!(r#"<span class="state {cls}">{}</span>"#, h(run.status.as_str()))
}

/// The last twenty runs, oldest first, as bars as tall as they took; grey
/// unless something went wrong.
fn sparkline(runs: &[Run]) -> String {
    let points = &runs[..runs.len().min(20)];
    if points.len() < 2 {
        return String::new();
    }
    const BAR: f64 = 4.0;
    const GAP: f64 = 1.5;
    const HGT: f64 = 22.0;
    let took = |r: &Run| r.duration_ms.map_or(0.0, |d| d as f64);
    let most = points.iter().map(took).fold(1.0, f64::max);
    let mut bars = String::new();
    for (i, r) in points.iter().rev().enumerate() {
        let x = to_fixed(i as f64 * (BAR + GAP), 1);
        if r.status == RunStatus::Running {
            bars.push_str(&format!(r#"<rect class="running" x="{x}" y="15.5" width="3" height="6"/>"#));
            continue;
        }
        let (floor, cls) = if r.status == RunStatus::Ok { (2.0, "") } else { (6.0, r#" class="bad""#) };
        let tall = f64::max(floor, (took(r) / most) * HGT);
        bars.push_str(&format!(
            r#"<rect{cls} x="{x}" y="{}" width="4" height="{}" rx=".5"/>"#,
            to_fixed(HGT - tall, 1),
            to_fixed(tall, 1)
        ));
    }
    let w = to_fixed(points.len() as f64 * (BAR + GAP) - GAP, 1);
    format!(
        r#"<svg class="spark" width="{w}" height="22" viewBox="0 0 {w} 22" aria-hidden="true" focusable="false">{bars}</svg>"#
    )
}

/// A time as "5m ago", with the full UTC time as its title.
fn stamp(at: Option<i64>, now: i64) -> String {
    let Some(at) = at else {
        return r#"<span class="muted">never</span>"#.into();
    };
    let iso = js::iso_string(at);
    let title = iso.replacen('T', " ", 1);
    format!(
        r#"<time class="nowrap" datetime="{iso}" title="{} UTC">{}</time>"#,
        &title[..19],
        h(&format_relative(at, now))
    )
}

/// The counts by health, the ones needing attention first; a zero is set
/// faint rather than left out, so the row keeps its shape.
fn health_figures(jobs: &[JobSummary]) -> String {
    let mut b = String::from(r#"<dl class="figures">"#);
    for (health, cls, label) in &HEALTH_ORDER {
        let n = jobs.iter().filter(|j| &j.health == health).count();
        let shown = if n == 0 { "zero" } else { cls };
        b.push_str(&format!(
            r#"<div class="{shown}"><dt><i class="sq {cls}" aria-hidden="true"></i>{label}</dt><dd>{}</dd></div>"#,
            count(n)
        ));
    }
    b.push_str("</dl>");
    b
}

/// A definition's field when it is truthy, as a template's `d.x ? ... : ...`
/// reads it.
fn truthy_field<'a>(d: &'a Definition, key: &str) -> Option<&'a Value> {
    d.get(key).filter(|v| truthy(v))
}

/// The board's schedule column.
fn schedule_cell(d: &Definition) -> String {
    let Some(sched) = truthy_field(d, "schedule") else {
        return r#"<span class="muted">no schedule</span>"#.into();
    };
    let mut out = escape_value(Some(sched));
    if let Some(tz) = truthy_field(d, "timezone") {
        out.push_str(&format!(r#"<span class="tz">{}</span>"#, escape_value(Some(tz))));
    }
    out
}

pub(crate) fn dashboard_page(
    jobs: &[JobSummary],
    runs_by_job: &HashMap<String, Vec<Run>>,
    now: i64,
    base: &str,
    checked_at: Option<i64>,
    lanes: &[LaneInput],
) -> String {
    let attention = jobs.iter().filter(|j| j.health != JobHealth::Healthy).count();
    let headline = if jobs.is_empty() {
        "No jobs yet.".to_string()
    } else if attention == 0 && jobs.len() == 1 {
        "The one job is healthy.".to_string()
    } else if attention == 0 {
        format!("All {} jobs are healthy.", count(jobs.len()))
    } else {
        let s = if jobs.len() == 1 { "" } else { "s" };
        format!("{} job{s}, <b>{} needing attention</b>.", count(jobs.len()), count(attention))
    };

    let rows: Vec<String> = jobs
        .iter()
        .map(|job| {
            let d = &job.definition;
            let desc = truthy_field(d, "description")
                .map(|v| format!(r#"<span class="desc">{}</span>"#, escape_value(Some(v))))
                .unwrap_or_default();
            let last = match &job.last_run {
                None => r#"<span class="muted">never</span>"#.to_string(),
                Some(r) => {
                    let mut s = format!("{} {}", run_state(r), stamp(Some(r.started_at), now));
                    if let Some(d) = r.duration_ms {
                        s.push_str(&format!(r#"<span class="sub">took {}</span>"#, h(&format_duration(d as f64))));
                    }
                    s
                }
            };
            let next = match job.next_expected_at {
                None => r#"<span class="muted">not scheduled</span>"#.to_string(),
                Some(n) => {
                    let overdue = if n < now { r#"<span class="state warn">overdue</span> "# } else { "" };
                    format!(r#"{overdue}{}<span class="sub">{} UTC</span>"#, stamp(Some(n), now), h(&when_utc(n, now)))
                }
            };
            let empty = Vec::new();
            [
                "<tr>\n<td class=\"job\"><a class=\"name\" href=\"",
                &h(base),
                "/jobs/",
                &encode_uri_component(&job.name),
                "\">",
                &escape_name(&job.name),
                "</a>",
                &desc,
                "</td>\n<td class=\"health\">",
                &health_state(job),
                "</td>\n<td class=\"nowrap hide-sm\">",
                &schedule_cell(d),
                "</td>\n<td class=\"nowrap last\">",
                &last,
                "</td>\n<td class=\"nowrap hide-sm\">",
                &next,
                "</td>\n<td class=\"hide-sm\">",
                &sparkline(runs_by_job.get(&job.name).unwrap_or(&empty)),
                "</td>\n</tr>",
            ]
            .concat()
        })
        .collect();

    let checked = match checked_at {
        Some(at) if at != 0 => format!(", checked {}", h(&format_relative(at, now))),
        _ => String::new(),
    };
    let mut health = r#"<p class="empty">Declare one with <code>cw.job("name", { schedule: "0 2 * * *" })</code> and run it once, and it shows up here.</p>"#.to_string();
    let mut sections = String::new();
    if !jobs.is_empty() {
        health = health_figures(jobs);
        let sp = Span { from: now - BOARD_BEHIND_MS, to: now + BOARD_AHEAD_MS, now };
        sections = [
            "<section class=\"sec\" aria-label=\"Last 24 hours\">\n  <h2>Last 24 hours</h2>\n",
            "  <p class=\"lede\">One lane per job. Faint ticks mark when it was due, bars the runs it recorded, as long as they took. A dashed box is a slot nothing ran in. Times are UTC.</p>\n",
            "  <div class=\"wide\">",
            &day_timeline(lanes, sp, base, jobs.len()),
            "</div>\n</section>\n<section class=\"sec\" aria-label=\"Jobs\">\n  <h2>Jobs</h2>\n",
            "  <p class=\"lede\">Every job in the store. Open one for its week, its runs and their output.</p>\n",
            "  <div class=\"wide\"><table class=\"board\">\n",
            "<thead><tr><th>Job</th><th>Health</th><th class=\"hide-sm\">Schedule</th><th>Last run</th><th class=\"hide-sm\">Next due</th><th class=\"hide-sm\">Recent runs</th></tr></thead>\n",
            "<tbody>",
            &rows.join("\n"),
            "</tbody></table></div>\n</section>",
        ]
        .concat();
    }
    let body = [
        "\n<header class=\"top\">\n  ",
        &brand(base, None),
        "\n  <div class=\"actions\">\n    <span class=\"meta\">",
        &h(&clock_utc(now)),
        " UTC",
        &checked,
        "</span>\n    <form class=\"inline\" method=\"post\" action=\"",
        &h(base),
        "/check\"><button class=\"primary\" type=\"submit\">Run check now</button></form>\n  </div>\n</header>\n<main>\n",
        "<section class=\"sec\" aria-label=\"Health\">\n  <h2>Health</h2>\n  <div>\n    <p class=\"headline\">",
        &headline,
        "</p>\n    ",
        &health,
        "\n  </div>\n</section>\n",
        &sections,
        "\n</main>\n<footer><span>Refreshes every minute. Times are UTC.</span><a href=\"",
        &h(base),
        "/api/jobs\">JSON</a></footer>",
    ]
    .concat();
    layout("CronWatch", &body, base, 60)
}

/// A metric's value as the run list shows it: whole numbers as they are,
/// others to four places.
fn metric_text(v: f64) -> String {
    if js::is_integer(v) { num(v) } else { to_fixed(v, 4) }
}

/// One job: its state and figures, its last seven days, its runs with their
/// output, and its definition. `complete` is false when `runs` does not
/// reach back over the whole week (the run list shows the newest fifty).
pub(crate) fn job_page(job: &JobSummary, runs: &[Run], now: i64, base: &str, complete: bool) -> String {
    let d = &job.definition;
    let ok_rate = format!("{}%", num(js_round(job.stats.ok_rate * 100.0)));
    let listed = &runs[..runs.len().min(50)];
    let run_rows: Vec<String> = listed
        .iter()
        .map(|run| {
            let mut detail = String::new();
            if let Some(e) = run.error.as_deref().filter(|e| !e.is_empty()) {
                detail.push_str(&format!(
                    r#"<details class="out error" open><summary>error</summary><pre>{}</pre></details>"#,
                    h(e)
                ));
            }
            if let Some(o) = run.output.as_deref().filter(|o| !o.is_empty()) {
                let open = if run.status == RunStatus::Ok { "" } else { " open" };
                detail.push_str(&format!(
                    r#"<details class="out"{open}><summary>output</summary><pre>{}</pre></details>"#,
                    h(o)
                ));
            }
            let mut metrics = String::new();
            for (name, value) in run.metrics.iter() {
                metrics.push_str(&format!(
                    r#"<span><span class="k">{}</span> {}</span>"#,
                    h(name),
                    h(&metric_text(value))
                ));
            }
            let took = run
                .duration_ms
                .map_or(r#"<span class="muted">running</span>"#.to_string(), |d| h(&format_duration(d as f64)));
            let metric_cell =
                if metrics.is_empty() { String::new() } else { format!(r#"<span class="metrics">{metrics}</span>"#) };
            let (has_detail, detail_row) = if detail.is_empty() {
                (String::new(), String::new())
            } else {
                (
                    r#" class="has-detail""#.to_string(),
                    format!(r#"<tr class="detail"><td colspan="5">{detail}</td></tr>"#),
                )
            };
            [
                "<tr",
                &has_detail,
                ">\n<td class=\"nowrap\">",
                &run_state(run),
                "</td>\n<td class=\"nowrap\">",
                &h(&when_utc(run.started_at, now)),
                " <span class=\"muted\">UTC</span><span class=\"sub\">",
                &stamp(Some(run.started_at), now),
                "</span></td>\n<td class=\"nowrap\">",
                &took,
                "</td>\n<td class=\"hide-sm\">",
                &metric_cell,
                "</td>\n<td class=\"hide-sm muted\">",
                &h(&run.trigger),
                "</td>\n</tr>",
                &detail_row,
            ]
            .concat()
        })
        .collect();

    let silenced = job.silenced_until.is_some_and(|s| s > now);
    let path = format!("{}/jobs/{}", h(base), encode_uri_component(&job.name));
    let why = lane_note(job, missed_at(job, lane_schedule(job).as_deref(), &[], now), now);
    let why_html = if why.is_empty() { String::new() } else { format!(r#"<span class="why">{}</span>"#, h(&why)) };
    let desc = truthy_field(d, "description")
        .map(|v| format!(r#"<p class="desc">{}</p>"#, escape_value(Some(v))))
        .unwrap_or_default();
    let silence = match job.silenced_until {
        Some(until) if silenced => format!(
            r#"<form class="inline" method="post" action="{path}/unsilence"><button type="submit">Unsilence (until {})</button></form>"#,
            h(&format_relative(until, now))
        ),
        _ => format!(
            r#"<form class="inline" method="post" action="{path}/silence"><select name="for" aria-label="Silence for"><option value="1h">1 hour</option><option value="4h">4 hours</option><option value="1d">1 day</option><option value="7d">1 week</option></select><button type="submit">Silence</button></form>"#
        ),
    };
    let last_run = job.last_run.as_ref().map_or("never".to_string(), |r| h(&format_relative(r.started_at, now)));
    let next_due =
        job.next_expected_at.map_or("<small>no schedule</small>".to_string(), |n| h(&format_relative(n, now)));
    let percentile = |p: Option<i64>| p.map_or("?".to_string(), |p| h(&format_duration(p as f64)));
    let runs_section = if listed.is_empty() {
        r#"<p class="lede">No runs yet.</p>"#.to_string()
    } else {
        let newest = if listed.len() == 1 { "run".to_string() } else { format!("{} runs", count(listed.len())) };
        [
            "<p class=\"lede\">The newest ",
            &newest,
            ", with any error and output.</p>\n  <div class=\"wide\"><table class=\"runs\">\n",
            "<thead><tr><th>Status</th><th>Started</th><th>Took</th><th class=\"hide-sm\">Metrics</th><th class=\"hide-sm\">Trigger</th></tr></thead>\n",
            "<tbody>",
            &run_rows.join("\n"),
            "</tbody></table></div>",
        ]
        .concat()
    };

    let body = [
        "\n<header class=\"top\">\n  ",
        &brand(base, Some(&job.name)),
        "\n  <div class=\"actions\"><span class=\"meta\">",
        &h(&clock_utc(now)),
        " UTC</span></div>\n</header>\n<main>\n<section class=\"sec intro\" aria-label=\"Job\">\n  <h2>Job</h2>\n  <div>\n",
        "    <h1 class=\"jobname\">",
        &escape_name(&job.name),
        "</h1>\n    ",
        &desc,
        "\n    <p class=\"stateline\">",
        &health_state(job),
        &why_html,
        "</p>\n    <div class=\"actions\">\n      ",
        &silence,
        "\n      <details class=\"confirm\"><summary>Forget</summary><form class=\"inline\" method=\"post\" action=\"",
        &path,
        "/forget\"><span>Remove this job and its runs from the store?</span> <button type=\"submit\">Forget</button></form></details>\n",
        "    </div>\n    <dl class=\"figures\">\n      <div><dt>Last run</dt><dd>",
        &last_run,
        "</dd></div>\n      <div><dt>Next due</dt><dd>",
        &next_due,
        "</dd></div>\n      <div><dt>Success, last ",
        &h(&num(job.stats.runs as f64)),
        "</dt><dd>",
        &h(&ok_rate),
        "</dd></div>\n      <div><dt>p50 / p95</dt><dd>",
        &percentile(job.stats.p50_ms),
        " <small>/ ",
        &percentile(job.stats.p95_ms),
        "</small></dd></div>\n    </dl>\n  </div>\n</section>\n",
        "<section class=\"sec\" aria-label=\"Last 7 days\">\n  <h2>Last 7 days</h2>\n",
        "  <p class=\"lede\">A lane per UTC day, today first. Faint ticks mark when the job was due, bars its runs, as long as they took.</p>\n",
        "  <div class=\"wide\">",
        &week_timeline(job, runs, complete, now),
        "</div>\n</section>\n<section class=\"sec\" aria-label=\"Runs\">\n  <h2>Runs</h2>\n  ",
        &runs_section,
        "\n</section>\n<section class=\"sec\" aria-label=\"Definition\">\n  <h2>Definition</h2>\n  <dl class=\"def\">\n",
        "  <dt>Schedule</dt><dd>",
        &definition_schedule(d),
        "</dd>\n  <dt>Grace</dt><dd>",
        &or_default(d, "grace", "10m"),
        "</dd>\n  <dt>Timeout</dt><dd>",
        &or_default(d, "timeout", "1h"),
        "</dd>\n  ",
        &definition_row(d, "maxDuration", "Max duration"),
        "\n  ",
        &budget_row(d),
        "\n  ",
        &definition_row(d, "expect", "Expect"),
        "\n  ",
        &alert_after_row(d),
        "\n  ",
        &tags_row(d),
        "\n  ",
        &open_row(job),
        "\n  ",
        &failures_row(job),
        "\n  </dl>\n</section>\n</main>\n<footer><span>Refreshes every minute. Times are UTC.</span><a href=\"",
        &h(base),
        "/api/jobs/",
        &encode_uri_component(&job.name),
        "\">JSON</a></footer>",
    ]
    .concat();
    layout(&format!("{}: CronWatch", job.name), &body, base, 60)
}

fn definition_schedule(d: &Definition) -> String {
    let Some(sched) = truthy_field(d, "schedule") else {
        return r#"<span class="muted">none</span>"#.into();
    };
    let mut out = escape_value(Some(sched));
    if let Some(tz) = truthy_field(d, "timezone") {
        out.push_str(&format!(r#" <span class="muted">{}</span>"#, escape_value(Some(tz))));
    }
    out
}

/// `h(d[key] ?? fallback)`.
fn or_default(d: &Definition, key: &str, fallback: &str) -> String {
    match d.get(key) {
        Some(v) if !v.is_null() => escape_value(Some(v)),
        _ => h(fallback),
    }
}

fn definition_row(d: &Definition, key: &str, label: &str) -> String {
    truthy_field(d, key).map_or(String::new(), |v| format!("<dt>{label}</dt><dd>{}</dd>", escape_value(Some(v))))
}

fn budget_row(d: &Definition) -> String {
    let Some(v) = truthy_field(d, "budget") else {
        return String::new();
    };
    let parts: Vec<String> = match v {
        Value::Object(o) => o.iter().map(|(k, limit)| format!("{k} ≤ {}", js_text(Some(limit)))).collect(),
        _ => Vec::new(),
    };
    format!("<dt>Budget</dt><dd>{}</dd>", h(&parts.join(", ")))
}

fn alert_after_row(d: &Definition) -> String {
    match truthy_field(d, "failuresBeforeAlert") {
        Some(v) if js_number(v) > 1.0 => {
            format!("<dt>Alert after</dt><dd>{} consecutive failures</dd>", escape_value(Some(v)))
        }
        _ => String::new(),
    }
}

fn tags_row(d: &Definition) -> String {
    let tags: Vec<String> = match d.get("tags") {
        Some(Value::Array(list)) => list.iter().map(|e| escape_value(Some(e))).collect(),
        // A string's length and map are not an array's, so the SDK's page
        // would fail on one; show it as it is.
        Some(Value::String(t)) if !t.is_empty() => vec![h(t)],
        _ => Vec::new(),
    };
    if tags.is_empty() {
        return String::new();
    }
    format!("<dt>Tags</dt><dd>{}</dd>", tags.join(", "))
}

fn open_row(job: &JobSummary) -> String {
    if job.open.is_empty() {
        return String::new();
    }
    let mut spans = String::new();
    for c in &job.open {
        let cls = if matches!(c, Condition::Failed | Condition::Stuck) { "bad" } else { "warn" };
        spans.push_str(&format!(r#"<span class="state {cls}">{}</span>"#, h(&condition_text(c))));
    }
    format!("<dt>Open</dt><dd>{spans}</dd>")
}

fn failures_row(job: &JobSummary) -> String {
    if job.consecutive_failures <= 0 {
        return String::new();
    }
    format!("<dt>Failures in a row</dt><dd>{}</dd>", num(job.consecutive_failures as f64))
}

/// A page with one message. With `sign_in`, a form under it takes the token
/// and sends it as `?token=`, which the routes move into the cookie: the
/// way in where there is no address bar to open a link with, such as an app
/// on an iPhone's home screen.
pub(crate) fn message_page(title: &str, message: &str, base: &str, sign_in: bool) -> String {
    let form = if sign_in {
        format!(
            r#"<form class="signin" method="get" action="{}/"><label for="token">Token</label><input id="token" name="token" type="password" autocomplete="current-password" autocapitalize="off" spellcheck="false" required><button class="primary" type="submit">Sign in</button></form>"#,
            h(base)
        )
    } else {
        String::new()
    };
    let body = format!(
        r#"<header class="top">{}</header><main class="message"><h1>{}</h1><p>{}</p>{form}</main>"#,
        brand(base, None),
        h(title),
        h(message)
    );
    layout(title, &body, base, 0)
}
