//! `conformance/evaluate.json`: each scenario plays a job's life through the
//! pure functions the way the client does (a run's start and finish, a
//! check with stuck runs first and then missed, a silence, a changed
//! definition), and every event's alerts and state must be the SDK's, byte
//! for byte.

use super::format::definition;
use super::{Failures, field, fixture, int, objects};
use crate::evaluate::{
    BASELINE_WINDOW, Evaluation, apply_silence, empty_state, is_stuck, on_check, on_run_finish, on_run_start,
    summarize, timeout_ms,
};
use crate::format::compose_alert;
use crate::js::{Object, Value};
use crate::schedule::format_duration;
use crate::types::{Definition, JobState, Metrics, Run, RunStatus, StoredJob, run_duration};

/// `scripts/conformance.mjs`'s `Sim`: one job, its runs, and its state.
struct Sim {
    def: Definition,
    stored: StoredJob,
    state: JobState,
    /// Each run and the order it was started in, which breaks ties.
    runs: Vec<(Run, usize)>,
}

impl Sim {
    /// The runs newest first, ties broken by insertion.
    fn sorted(&self) -> Vec<Run> {
        let mut out = self.runs.clone();
        out.sort_by(|(a, sa), (b, sb)| b.started_at.cmp(&a.started_at).then(sb.cmp(sa)));
        out.into_iter().map(|(r, _)| r).collect()
    }

    /// Saves an evaluation as the client does (silence applied) and returns
    /// its alerts as the SDK writes them.
    fn settle(&mut self, previous: &JobState, e: Evaluation, now: i64) -> Vec<Value> {
        let e = apply_silence(previous, e, now);
        self.state = e.state;
        e.alerts.into_iter().map(|d| compose_alert(d, &self.def, now).to_value()).collect()
    }

    fn finish_run(&mut self, run: &Run, now: i64) -> Result<Vec<Value>, String> {
        let history: Vec<Run> = self.sorted().into_iter().filter(|r| r.id != run.id).collect();
        let previous = self.state.clone();
        let e = on_run_finish(&self.def, run, &previous, &history, now)?;
        Ok(self.settle(&previous, e, now))
    }

    fn index(&self, id: &str) -> Option<usize> {
        self.runs.iter().position(|(r, _)| r.id == id)
    }

    /// Plays one event, returning what the fixture expects of it, or `None`
    /// for an event that expects nothing.
    fn play(&mut self, ev: &Object) -> Result<Option<Value>, String> {
        let at = int(ev, "at");
        let op = field(ev, "op").as_str().unwrap_or("");
        let state_only = |s: &JobState| Some(Object::new().with("state", s.to_value()).into());
        match op {
            "start" => {
                let id = field(ev, "id").as_str().unwrap_or("").to_string();
                let order = self.runs.len();
                self.runs.push((
                    Run {
                        id,
                        job: self.def.name().to_string(),
                        status: RunStatus::Running,
                        started_at: at,
                        finished_at: None,
                        duration_ms: None,
                        error: None,
                        output: None,
                        metrics: Metrics::new(),
                        trigger: "run".into(),
                    },
                    order,
                ));
                self.state = on_run_start(&self.state);
                Ok(state_only(&self.state))
            }
            "finish" => {
                let id = field(ev, "id").as_str().unwrap_or("");
                let i = self.index(id).ok_or_else(|| format!("no run {id}"))?;
                let mut run = self.runs[i].0.clone();
                if matches!(run.status, RunStatus::Ok | RunStatus::Failed) {
                    return Ok(Some(
                        Object::new()
                            .with("alerts", Vec::<Value>::new())
                            .with("state", self.state.to_value())
                            .with("ignored", format!("was already finished as {}", run.status))
                            .into(),
                    ));
                }
                let marked = run.status == RunStatus::Timeout;
                run.finished_at = Some(at);
                run.duration_ms = Some(run_duration(run.started_at, at));
                run.status = RunStatus::parse(field(ev, "status").as_str().unwrap_or(""));
                run.metrics = match ev.get("metrics") {
                    Some(m) => Metrics::from_value(m).map_err(|e| e.to_string())?,
                    None => Metrics::new(),
                };
                run.output = ev.get("output").and_then(Value::as_str).map(str::to_string);
                run.error = ev.get("error").and_then(Value::as_str).map(str::to_string);
                self.runs[i].0 = run.clone();
                if marked && run.status != RunStatus::Ok {
                    return Ok(Some(
                        Object::new().with("alerts", Vec::<Value>::new()).with("state", self.state.to_value()).into(),
                    ));
                }
                let alerts = self.finish_run(&run, at)?;
                Ok(Some(Object::new().with("alerts", alerts).with("state", self.state.to_value()).into()))
            }
            "check" => {
                let now = at;
                let mut alerts = Vec::new();
                let mut running: Vec<usize> =
                    (0..self.runs.len()).filter(|&i| self.runs[i].0.status == RunStatus::Running).collect();
                running.sort_by(|&a, &b| {
                    let (ra, sa) = &self.runs[a];
                    let (rb, sb) = &self.runs[b];
                    ra.started_at.cmp(&rb.started_at).then(sa.cmp(sb))
                });
                for i in running {
                    let mut r = self.runs[i].0.clone();
                    if !is_stuck(&self.def, &r, now)? {
                        continue;
                    }
                    let timeout = timeout_ms(&self.def)?;
                    r.status = RunStatus::Timeout;
                    r.finished_at = Some(now);
                    r.duration_ms = Some(run_duration(r.started_at, now));
                    r.error = Some(format!("Still running after {}; marked as timed out", format_duration(timeout)));
                    self.runs[i].0 = r.clone();
                    alerts.extend(self.finish_run(&r, now)?);
                }
                let mut recent = self.sorted();
                recent.truncate(BASELINE_WINDOW);
                let previous = self.state.clone();
                let out = on_check(&self.def, &self.stored, recent.first(), &previous, now)?;
                let (next, due) = (out.next_expected_at, out.due_at);
                alerts.extend(self.settle(&previous, out.evaluation, now));
                let summary = summarize(&self.stored, &recent, &self.state, next, now)?;
                Ok(Some(
                    Object::new()
                        .with("alerts", alerts)
                        .with("state", self.state.to_value())
                        .with("nextExpectedAt", next)
                        .with("dueAt", due)
                        .with("summary", summary.to_value())
                        .into(),
                ))
            }
            "silence" => {
                self.state.silenced_until = Some(int(ev, "until"));
                Ok(state_only(&self.state))
            }
            "unsilence" => {
                self.state.silenced_until = None;
                Ok(state_only(&self.state))
            }
            "define" => {
                self.def = definition(field(ev, "definition"));
                self.stored.definition = self.def.clone();
                Ok(None)
            }
            other => Err(format!("unknown op {other:?}")),
        }
    }
}

#[test]
fn conformance_evaluate() {
    let f = fixture("evaluate");
    let mut fails = Failures::default();
    let scenarios = objects(&f, "scenarios");
    let mut events = 0;
    for sc in &scenarios {
        let name = field(sc, "name").as_str().unwrap_or("");
        let def = definition(field(sc, "definition"));
        let created_at = int(sc, "createdAt");
        let mut sim = Sim {
            stored: StoredJob {
                name: def.name().to_string(),
                definition: def.clone(),
                created_at,
                updated_at: created_at,
                unreadable: false,
            },
            state: empty_state(def.name()),
            def,
            runs: Vec::new(),
        };
        for (i, ev) in objects(sc, "events").into_iter().enumerate() {
            events += 1;
            let what = format!("{name}: event {i} ({})", field(ev, "op").as_str().unwrap_or(""));
            match sim.play(ev) {
                Ok(Some(got)) => fails.same(&what, &got, field(ev, "expect")),
                Ok(None) => {}
                Err(err) => {
                    fails.fail(format!("{what}: {err}"));
                    break;
                }
            }
        }
    }
    assert!(events > 0, "no events replayed");
    fails.check("evaluate");
}
