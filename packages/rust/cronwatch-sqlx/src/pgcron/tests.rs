//! The pg_cron source against fake tables, as the SDK's pgcron.test.ts and
//! the Go port's pgcron_test.go have them, and the replay of
//! conformance/pgcron.json. The tests against a real pg_cron are in
//! tests/pgcron.rs.

use std::sync::{Arc, Mutex};

use cronwatch::js::{self, Value};
use cronwatch::storetest::kit::{Capture, Clock, Errors, T0};
use cronwatch::{AlertType, CheckResult, Client, JobOptions, JobSummary, MemoryStore, Run, RunStatus, Store};

use super::*;
use crate::rows::Cell;

const MIN: i64 = 60_000;
const HOUR: i64 = 60 * MIN;
const DAY: i64 = 24 * HOUR;

/// Epoch milliseconds of a UTC time.
fn utc(y: i64, m: i64, d: i64, h: i64, min: i64, s: i64) -> i64 {
    crate::rows::parse_timestamp(&format!("{y:04}-{m:02}-{d:02} {h:02}:{min:02}:{s:02}Z")).unwrap()
}

#[derive(Clone, Debug)]
struct FakeJob {
    jobid: i64,
    jobname: Option<String>,
    schedule: String,
    active: bool,
}

#[derive(Clone, Debug)]
struct Detail {
    runid: i64,
    jobid: i64,
    status: String,
    message: Option<String>,
    start: Option<i64>,
    end: Option<i64>,
}

#[derive(Default)]
struct Tables {
    jobs: Vec<FakeJob>,
    details: Vec<Detail>,
    settings: HashMap<String, String>,
    runid: i64,
    queries: Vec<String>,
}

/// `cron.job`, `cron.job_run_details` and the settings a role can read, in
/// memory, answering the source's queries with ids as text, as the SDK's
/// fake gives them.
#[derive(Clone)]
struct FakeCron(Arc<Mutex<Tables>>);

fn name(s: &str) -> Option<String> {
    Some(s.to_string())
}

impl FakeCron {
    fn new() -> FakeCron {
        let mut t = Tables::default();
        t.settings.insert("cron.timezone".into(), "GMT".into());
        t.settings.insert("cron.log_run".into(), "on".into());
        FakeCron(Arc::new(Mutex::new(t)))
    }

    fn tables(&self) -> std::sync::MutexGuard<'_, Tables> {
        self.0.lock().unwrap()
    }

    fn job(&self, jobid: i64, jobname: Option<String>, schedule: &str, active: bool) {
        self.tables().jobs.push(FakeJob { jobid, jobname, schedule: schedule.into(), active });
    }

    /// A run detail; `start` and `end` are epoch milliseconds, or -1 for
    /// NULL. Answers its runid.
    fn add(&self, jobid: i64, status: &str, start: i64, end: i64, message: Option<&str>) -> i64 {
        let mut t = self.tables();
        t.runid += 1;
        let runid = t.runid;
        t.details.push(Detail {
            runid,
            jobid,
            status: status.into(),
            message: message.map(str::to_string),
            start: (start >= 0).then_some(start),
            end: (end >= 0).then_some(end),
        });
        runid
    }

    /// Changes a detail as pg_cron would.
    fn update(&self, runid: i64, change: impl FnOnce(&mut Detail)) {
        let mut t = self.tables();
        change(t.details.iter_mut().find(|d| d.runid == runid).expect("a detail"));
    }

    fn update_job(&self, jobid: i64, change: impl FnOnce(&mut FakeJob)) {
        let mut t = self.tables();
        change(t.jobs.iter_mut().find(|j| j.jobid == jobid).expect("a job"));
    }
}

fn text(s: &str) -> Cell {
    Cell::Text(s.into())
}

fn opt(s: &Option<String>) -> Cell {
    s.as_deref().map_or(Cell::Null, text)
}

fn time(t: Option<i64>) -> Cell {
    t.map_or(Cell::Null, Cell::Time)
}

fn detail_rows(list: &[&Detail]) -> Vec<Row> {
    list.iter()
        .map(|d| {
            Row(vec![
                ("runid".into(), text(&d.runid.to_string())),
                ("jobid".into(), text(&d.jobid.to_string())),
                ("status".into(), text(&d.status)),
                ("return_message".into(), opt(&d.message)),
                ("start_time".into(), time(d.start)),
                ("end_time".into(), time(d.end)),
            ])
        })
        .collect()
}

/// A Postgres array literal of integers.
fn array(p: &Param) -> Vec<i64> {
    let Param::Text(s) = p else { panic!("an array literal: {p:?}") };
    s.trim_matches(|c| c == '{' || c == '}').split(',').filter(|s| !s.is_empty()).map(|s| s.parse().unwrap()).collect()
}

impl Reader for FakeCron {
    fn query<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<Vec<Row>, BoxError>> {
        let mut t = self.tables();
        t.queries.push(sql.to_string());
        let rows = if sql.contains("pg_settings") {
            let Param::Text(key) = &params[0] else { panic!() };
            t.settings.get(key).map(|v| vec![Row(vec![("setting".into(), text(v))])]).unwrap_or_default()
        } else if sql.contains("FROM cron.job ORDER BY") {
            t.jobs
                .iter()
                .map(|j| {
                    Row(vec![
                        ("jobid".into(), text(&j.jobid.to_string())),
                        ("jobname".into(), opt(&j.jobname)),
                        ("schedule".into(), text(&j.schedule)),
                        ("database".into(), text("postgres")),
                        ("username".into(), text("postgres")),
                        ("active".into(), Cell::Bool(j.active)),
                    ])
                })
                .collect()
        } else if sql.contains("ORDER BY d.runid DESC") {
            let Param::Int(jobid) = params[0] else { panic!() };
            let mut list: Vec<&Detail> = t.details.iter().filter(|d| d.jobid == jobid).collect();
            list.sort_by_key(|d| std::cmp::Reverse(d.runid));
            list.truncate(20);
            detail_rows(&list)
        } else if sql.contains("unnest") {
            let (ids, afters, open) = (array(&params[0]), array(&params[1]), array(&params[2]));
            let after: HashMap<i64, i64> = ids.into_iter().zip(afters).collect();
            let mut list: Vec<&Detail> = t
                .details
                .iter()
                .filter(|d| after.get(&d.jobid).is_some_and(|c| d.runid > *c) || open.contains(&d.runid))
                .collect();
            list.sort_by_key(|d| d.runid);
            list.truncate(500);
            detail_rows(&list)
        } else {
            return Box::pin(std::future::ready(Err(format!("unexpected query {sql}").into())));
        };
        Box::pin(std::future::ready(Ok(rows)))
    }
}

/// A client watching a fake through the source.
struct Kit {
    cw: Client,
    alerts: Capture,
    errors: Errors,
}

impl Kit {
    fn new(cron: &FakeCron, clock: Option<&Clock>, store: Option<Arc<dyn Store>>, o: PgCronOptions) -> Kit {
        let (alerts, errors) = (Capture::default(), Errors::default());
        let errs = errors.clone();
        let mut b = Client::builder()
            .alerts([Arc::new(alerts.clone()) as Arc<dyn cronwatch::Channel>])
            .no_cron_secret()
            .on_error(move |e, w| errs.add(e, w))
            .source(Arc::new(PgCron::with_reader(cron.clone(), o)));
        if let Some(c) = clock {
            let c = c.clone();
            b = b.clock(move || c.now());
        }
        if let Some(s) = store {
            b = b.store_arc(s);
        }
        Kit { cw: b.build().unwrap(), alerts, errors }
    }

    async fn check(&self) -> CheckResult {
        self.cw.check().await.unwrap()
    }

    async fn runs(&self, name: &str, limit: usize) -> Vec<Run> {
        self.cw.runs(name, limit).await.unwrap()
    }

    async fn run(&self, id: &str) -> Option<Run> {
        self.cw.get_run(id).await.unwrap()
    }

    /// The errors that are not about settings or row level security.
    fn others(&self) -> Vec<String> {
        self.errors.list().into_iter().filter(|e| !e.contains("cron.") && !e.contains("row level")).collect()
    }
}

fn summary(r: &CheckResult, name: &str) -> JobSummary {
    r.jobs.iter().find(|j| j.name == name).cloned().unwrap_or_else(|| panic!("no job {name}"))
}

fn types_and_jobs(alerts: &[Alert]) -> Vec<String> {
    let mut out: Vec<String> = alerts.iter().map(|a| format!("{} {}", a.alert_type, a.job)).collect();
    out.sort();
    out
}

fn pid(runid: i64) -> String {
    format!("pgcron:{runid}")
}

#[test]
fn conformance_pgcron_json() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../conformance/pgcron.json");
    let root = js::parse(&std::fs::read_to_string(path).expect("conformance/pgcron.json")).unwrap();
    let f = root.as_object().unwrap();
    let get = |o: &js::Object, k: &str| o.get(k).cloned().unwrap_or(Value::Null);
    let mut count = 0;
    for c in get(f, "schedules").as_array().unwrap() {
        let o = c.as_object().unwrap();
        let input = get(o, "schedule");
        let got = schedule(input.as_str().unwrap()).map_or(Value::Null, Value::from);
        assert_eq!(got.to_json(), get(o, "result").to_json(), "schedule {}", input.to_json());
        count += 1;
    }
    for c in get(f, "names").as_array().unwrap() {
        let o = c.as_object().unwrap();
        let j = get(o, "job");
        let j = j.as_object().unwrap();
        let job = PgCronJob {
            job_id: get(j, "jobid").as_f64().unwrap() as i64,
            job_name: get(j, "jobname").as_str().map(str::to_string),
            ..Default::default()
        };
        assert_eq!(job_name(&job), get(o, "name").as_str().unwrap(), "name of {}", Value::Object(j.clone()).to_json());
        count += 1;
    }
    // A number, or the number a string holds, as the fixture has both.
    let num = |v: Value| match v {
        Value::String(s) => s.parse::<f64>().unwrap() as i64,
        other => other.as_f64().unwrap() as i64,
    };
    for c in get(f, "runs").as_array().unwrap() {
        let o = c.as_object().unwrap();
        let r = get(o, "row");
        let r = r.as_object().unwrap();
        let when = |k: &str| get(r, k).as_str().map(|s| crate::rows::parse_timestamp(s).expect("an ISO time"));
        let row = PgCronRow {
            run_id: num(get(r, "runid")),
            job_id: num(get(r, "jobid")),
            status: get(r, "status").as_str().unwrap_or("").to_string(),
            return_message: get(r, "return_message").as_str().map(str::to_string),
            start_time: when("start_time"),
            end_time: when("end_time"),
        };
        let fallback = get(o, "fallbackAt").as_f64().map_or(T0, |n| n as i64);
        let got = run_of(&row, "db:j", "pgcron:db:", fallback).map_or(Value::Null, |r| r.to_value());
        assert_eq!(got.to_json(), get(o, "run").to_json(), "run of {}", Value::Object(r.clone()).to_json());
        count += 1;
    }
    assert_eq!(HOLD.as_millis() as f64, get(f, "holdMs").as_f64().unwrap());
    assert_eq!(count + 1, 30, "every case replayed");
}

#[tokio::test]
async fn jobs_are_declared_history_is_copied_quietly_and_imports_are_idempotent() {
    let c = Clock::new(T0);
    let cron = FakeCron::new();
    cron.job(1, name("nightly vacuum"), "0 3 * * *", true);
    cron.job(2, None, "10 seconds", true);
    cron.job(3, name("paused"), "0 * * * *", false);
    cron.job(4, name("other"), "0 * * * *", true);
    let three = utc(2026, 1, 5, 3, 0, 0);
    for i in (1..=24).rev() {
        cron.add(1, "succeeded", three - i * DAY, three - i * DAY + 5000, Some("VACUUM"));
    }
    cron.add(1, "failed", three, three + 2000, Some("ERROR:  deadlock detected\n"));
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let options = PgCronOptions {
        pick: Some(Arc::new(|j: &PgCronJob| j.job_id != 4)),
        prefix: "db:".into(),
        ..Default::default()
    };
    let k = Kit::new(&cron, Some(&c), Some(store.clone()), options.clone());

    let first = k.check().await;
    let names: Vec<&str> = first.jobs.iter().map(|j| j.name.as_str()).collect();
    assert_eq!(names, ["db:nightly-vacuum", "db:paused", "db:pg_cron:2"]);
    let vacuum = summary(&first, "db:nightly-vacuum");
    assert_eq!(vacuum.definition.schedule(), "0 3 * * *");
    assert_eq!(vacuum.definition.timezone(), "UTC");
    assert_eq!(vacuum.definition.tags(), ["pg_cron"]);
    assert_eq!(summary(&first, "db:pg_cron:2").definition.schedule(), "every 10s");
    assert_eq!(summary(&first, "db:paused").definition.schedule(), "", "a paused job is not expected to run");
    let runs = k.runs("db:nightly-vacuum", 100).await;
    assert_eq!(runs.len(), 20, "twenty newest runs copied on first sight");
    assert_eq!(runs[0].id, "pgcron:db:25");
    assert_eq!(runs[0].status, RunStatus::Failed);
    assert_eq!(runs[0].error.as_deref(), Some("ERROR:  deadlock detected"));
    assert_eq!(runs[0].duration_ms, Some(2000));
    assert_eq!(runs[0].trigger, "pg_cron");
    assert_eq!(runs[1].output.as_deref(), Some("VACUUM"));
    assert_eq!(k.alerts.types(), ["failed"], "only the newest finished run is judged; history does not alert");

    k.check().await;
    // A new process over the same store.
    let k = Kit::new(&cron, Some(&c), Some(store.clone()), options);
    k.check().await;
    assert_eq!(k.runs("db:nightly-vacuum", 100).await.len(), 20, "a re-import, even after a restart, adds nothing");
    assert!(k.alerts.types().is_empty(), "no new alerts");

    // A run not yet started holds the cursor; the run after it is copied
    // now and it is copied once it starts.
    let starting = cron.add(2, "starting", -1, -1, None);
    cron.add(2, "succeeded", T0 - 5000, T0 - 4000, Some("1 row"));
    c.advance(1000);
    k.check().await;
    let ids: Vec<String> = k.runs("db:pg_cron:2", 20).await.into_iter().map(|r| r.id).collect();
    assert_eq!(ids, ["pgcron:db:27"]);
    cron.update(starting, |d| {
        d.status = "running".into();
        d.start = Some(T0 - 3000);
    });
    k.check().await;
    assert_eq!(k.run("pgcron:db:26").await.unwrap().status, RunStatus::Running);
    cron.update(starting, |d| {
        d.status = "failed".into();
        d.end = Some(T0 - 1000);
        d.message = name("ERROR:  boom");
    });
    c.advance(1000);
    k.check().await;
    let done = k.run("pgcron:db:26").await.unwrap();
    assert_eq!(done.status, RunStatus::Failed);
    assert_eq!(done.duration_ms, Some(2000));
    assert_eq!(k.alerts.types(), ["failed"], "a run that was running and then failed is judged when it finishes");

    // The nightly job stops running: missed, from its schedule, with no run
    // details at all.
    c.set(utc(2026, 1, 6, 3, 11, 0));
    cron.add(2, "succeeded", c.now() - 2000, c.now() - 1000, Some("1 row"));
    let later = k.check().await;
    assert_eq!(types_and_jobs(&later.alerts), ["missed db:nightly-vacuum", "recovered db:pg_cron:2"]);
    assert!(k.check().await.alerts.is_empty(), "each condition alerts once");

    // Unscheduled: its name keeps its history but loses its schedule, so it
    // is never missed again, and the missed alert it had open closes with a
    // recovery that says so.
    cron.tables().jobs.remove(0);
    c.set(utc(2026, 1, 8, 3, 11, 0));
    let gone = k.check().await;
    let now = summary(&gone, "db:nightly-vacuum");
    assert_eq!(now.definition.schedule(), "");
    assert!(now.definition.description().contains("no longer watched"), "{}", now.definition.description());
    assert_eq!(
        now.open.iter().map(|c| c.to_string()).collect::<Vec<_>>(),
        ["failed"],
        "its failure stays open until a successful run"
    );
    let closed: Vec<&Alert> = gone.alerts.iter().filter(|a| a.job == "db:nightly-vacuum").collect();
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0].alert_type, AlertType::Recovered);
    assert_eq!(closed[0].title, "db:nightly-vacuum is no longer scheduled");
    let details = closed[0].to_value().as_object().unwrap().get("details").unwrap().to_json();
    assert_eq!(
        details,
        format!(r#"{{"after":["missed"],"reason":"unscheduled","since":{}}}"#, utc(2026, 1, 6, 3, 11, 0))
    );
    assert!(k.check().await.alerts.iter().all(|a| a.job != "db:nightly-vacuum"), "once");
    assert_eq!(k.runs("db:nightly-vacuum", 100).await.len(), 20, "its history is kept");
}

// The review: the source declared a job again only when its settings
// changed, so after the dashboard's forget every later run was refused as
// not declared until the process restarted.
#[tokio::test]
async fn a_job_forgotten_from_the_dashboard_is_declared_again_and_its_runs_recorded() {
    let c = Clock::new(T0);
    let cron = FakeCron::new();
    cron.job(1, name("vacuum"), "0 3 * * *", true);
    cron.add(1, "succeeded", T0 - 5000, T0 - 4000, Some("VACUUM"));
    let k = Kit::new(&cron, Some(&c), Some(Arc::new(MemoryStore::new())), PgCronOptions::default());
    k.check().await;
    k.cw.forget("vacuum").await.unwrap();
    cron.add(1, "succeeded", T0 - 3000, T0 - 2000, Some("VACUUM"));
    cron.add(1, "failed", T0 - 1000, T0, Some("ERROR:  boom"));
    c.advance(1000);
    let result = k.check().await;
    assert_eq!(k.others(), Vec::<String>::new());
    assert_eq!(result.jobs.iter().map(|j| j.name.as_str()).collect::<Vec<_>>(), ["vacuum"]);
    assert_eq!(summary(&result, "vacuum").definition.schedule(), "0 3 * * *");
    let ids: Vec<String> = k.runs("vacuum", 50).await.into_iter().map(|r| r.id).collect();
    assert_eq!(ids, [pid(3), pid(2)], "the runs after the forget");
    assert_eq!(k.cw.defined_jobs().iter().map(|d| d.name().to_string()).collect::<Vec<_>>(), ["vacuum"]);
}

#[tokio::test]
async fn a_jobs_options_apply_and_a_schedule_it_cannot_read_is_reported() {
    struct Rows;
    impl cronwatch::Matcher for Rows {
        fn is_match(&self, text: &str) -> bool {
            text.contains("row")
        }
        fn source(&self) -> String {
            "/rows?/".into()
        }
    }
    let cron = FakeCron::new();
    cron.job(1, name("odd"), "not a schedule", true);
    let options = PgCronOptions { options: JobOptions::new().grace("1m").expect_match(Rows), ..Default::default() };
    let k = Kit::new(&cron, None, None, options);
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as i64;
    cron.add(1, "succeeded", now - 1000, now, Some("nothing"));
    let result = k.check().await;
    assert_eq!(result.jobs[0].definition.schedule(), "");
    assert_eq!(result.jobs[0].definition.get("grace"), Some(&Value::from("1m")));
    assert!(k.errors.list().join("\n").contains("watching it without a schedule"), "{:?}", k.errors.list());
    let run = &k.runs("odd", 20).await[0];
    assert_eq!(run.status, RunStatus::Failed, "expect applies to imported output");
    assert!(run.error.as_deref().unwrap().contains("did not match"), "{:?}", run.error);
}

#[tokio::test]
async fn a_pick_job_name_or_options_callback_that_panics_fails_only_its_job_reported_once() {
    let c = Clock::new(T0);
    let cron = FakeCron::new();
    for (id, n) in [(1, "one"), (2, "two"), (3, "three"), (4, "four")] {
        cron.job(id, name(n), "0 * * * *", true);
    }
    let broken: Arc<Mutex<HashSet<String>>> = Arc::default();
    let fault = {
        let broken = broken.clone();
        move |what: &str, id: i64| {
            if broken.lock().unwrap().contains(&format!("{what}:{id}")) {
                panic!("{what} broke");
            }
        }
    };
    let (f1, f2, f3) = (fault.clone(), fault.clone(), fault);
    let options = PgCronOptions {
        pick: Some(Arc::new(move |j: &PgCronJob| {
            f1("pick", j.job_id);
            true
        })),
        job_name: Some(Arc::new(move |j: &PgCronJob| {
            f2("name", j.job_id);
            format!("j-{}", j.job_name.as_deref().unwrap_or(""))
        })),
        options_for: Some(Arc::new(move |j: &PgCronJob| {
            f3("options", j.job_id);
            JobOptions::new()
        })),
        ..Default::default()
    };
    let k = Kit::new(&cron, Some(&c), None, options);
    let set = |keys: &[&str]| {
        let mut b = broken.lock().unwrap();
        b.clear();
        b.extend(keys.iter().map(|k| k.to_string()));
    };
    let names = || async { k.cw.store().list_jobs().await.unwrap().into_iter().map(|j| j.name).collect::<Vec<_>>() };
    let message = |id: i64, what: &str| {
        format!("source pg_cron: pg_cron job {id}: {what}; it keeps its last declaration until that works")
    };

    // First sight, with job 1's name callback and job 2's options panicking:
    // only those two are skipped.
    set(&["name:1", "options:2"]);
    let first = cron.add(3, "succeeded", T0 - 60_000, T0 - 59_000, Some("ok"));
    k.check().await;
    assert_eq!(names().await, ["j-four", "j-three"]);
    assert_eq!(k.run(&pid(first)).await.unwrap().job, "j-three");
    assert_eq!(
        k.others(),
        [message(1, "job_name panicked: name broke"), message(2, "the options callback panicked: options broke")]
    );

    // Once they work, both are declared; then each callback panics for jobs
    // already declared.
    set(&[]);
    k.check().await;
    assert_eq!(names().await, ["j-four", "j-one", "j-three", "j-two"]);
    set(&["pick:1", "options:3", "name:4"]);
    let seen = k.others().len();
    let later = [
        cron.add(1, "failed", T0 + 1000, T0 + 2000, Some("ERROR:  one")),
        cron.add(3, "succeeded", T0 + 1000, T0 + 2000, Some("ok")),
    ];
    c.advance(5000);
    k.check().await;
    k.check().await;
    assert_eq!(
        k.others()[seen..],
        [
            message(1, "the jobs callback panicked: pick broke"),
            message(3, "the options callback panicked: options broke"),
            message(4, "job_name panicked: name broke"),
        ],
        "each reported once, over two syncs"
    );
    // Each keeps its name and schedule, is not retired, and its runs are
    // still copied.
    for stored in k.cw.store().list_jobs().await.unwrap() {
        assert_eq!(stored.definition.schedule(), "0 * * * *", "{}", stored.name);
        let description = stored.definition.description();
        assert!(!description.contains("no longer") && !description.contains("renamed"), "{}", stored.name);
    }
    assert_eq!(k.run(&pid(later[0])).await.unwrap().job, "j-one");
    assert_eq!(k.run(&pid(later[1])).await.unwrap().job, "j-three");

    // Working again and then failing again is reported again.
    set(&[]);
    k.check().await;
    set(&["pick:1"]);
    k.check().await;
    let others = k.others();
    assert_eq!(others.len(), seen + 4, "{others:?}");
    assert_eq!(others[seen + 3], message(1, "the jobs callback panicked: pick broke"));
}

#[tokio::test]
async fn a_run_cut_off_by_a_restart_is_recorded_and_one_held_run_never_stops_the_others() {
    let c = Clock::new(T0);
    let cron = FakeCron::new();
    cron.job(1, name("fast"), "30 seconds", true);
    cron.job(2, name("other"), "0 * * * *", true);
    let k = Kit::new(&cron, Some(&c), None, PgCronOptions::default());
    cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, Some("1 row"));
    k.check().await;
    // pg_cron restarts while a run is queued: it marks it failed, "server
    // restarted", with no times at all.
    let restarted = cron.add(1, "failed", -1, -1, Some("server restarted"));
    // The fast job then runs far more than a page's worth, and the other job
    // fails after all of them.
    for i in 0..520 {
        cron.add(1, "succeeded", T0 - 50_000 + i, T0 - 50_000 + i + 1, Some("1 row"));
    }
    let failure = cron.add(2, "failed", T0 - 1000, T0 - 500, Some("ERROR:  disk full"));
    let queued = cron.add(1, "starting", -1, -1, None);
    c.advance(1000);
    k.check().await;
    k.check().await;
    let cut = k.run(&pid(restarted)).await.unwrap();
    assert_eq!(cut.status, RunStatus::Failed);
    assert_eq!(cut.error.as_deref(), Some("server restarted"));
    assert_eq!(cut.started_at, T0 - 60_000, "placed at the job's newest run before it");
    assert_eq!(k.run(&pid(failure)).await.unwrap().status, RunStatus::Failed, "the other job's failure is not starved");
    assert!(k.alerts.list().iter().any(|a| a.alert_type == AlertType::Failed && a.job == "other"));
    assert!(k.run(&pid(queued)).await.is_none(), "a queued run is held");

    // Held only so long: then it is copied as running from when it was
    // first seen, and a late start updates nothing but its end.
    c.advance(11 * MIN);
    k.check().await;
    let waiting = k.run(&pid(queued)).await.unwrap();
    assert_eq!(waiting.status, RunStatus::Running);
    assert_eq!(waiting.started_at, T0 + 1000);
    let now = c.now();
    cron.update(queued, |d| {
        d.status = "succeeded".into();
        d.start = Some(now - 2000);
        d.end = Some(now - 1000);
    });
    c.advance(1000);
    k.check().await;
    assert_eq!(k.run(&pid(queued)).await.unwrap().status, RunStatus::Ok);
    assert!(k.others().is_empty(), "{:?}", k.others());
}

#[tokio::test]
async fn first_sight_never_judges_history() {
    let c = Clock::new(T0);
    let cron = FakeCron::new();
    cron.job(1, name("nightly"), "0 3 * * *", true);
    for i in 0..30 {
        cron.add(1, "failed", T0 - (40 - i) * HOUR, T0 - (40 - i) * HOUR + 1000, Some("ERROR:  old"));
    }
    cron.add(1, "failed", -1, -1, Some("server restarted"));
    for i in 0..19 {
        let start = T0 - (10 * HOUR - i * HOUR / 2);
        cron.add(1, "succeeded", start, start + 1000, Some("ok"));
    }
    let k = Kit::new(&cron, Some(&c), None, PgCronOptions::default());
    k.check().await;
    k.check().await;
    assert_eq!(k.runs("nightly", 500).await.len(), 20, "only the newest twenty are copied");
    assert!(k.alerts.types().is_empty(), "no alert from history: {:?}", k.alerts.types());
}

#[tokio::test]
async fn a_renamed_job_leaves_no_scheduled_ghost() {
    let c = Clock::new(T0);
    let cron = FakeCron::new();
    cron.job(1, name("rollup"), "*/5 * * * *", true);
    cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, Some("1 row"));
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let k = Kit::new(&cron, Some(&c), Some(store.clone()), PgCronOptions::default());
    k.check().await;
    cron.update_job(1, |j| j.jobname = name("rollup-v2"));
    let running = cron.add(1, "running", T0 - 1000, -1, None);
    k.check().await;
    let find = |list: &[JobSummary], n: &str| list.iter().find(|j| j.name == n).cloned().unwrap();
    let jobs = k.cw.jobs().await.unwrap();
    let old = find(&jobs, "rollup");
    assert_eq!(old.definition.schedule(), "", "the old name has no schedule");
    assert!(old.definition.description().contains("renamed to rollup-v2"), "{}", old.definition.description());
    assert_eq!(find(&jobs, "rollup-v2").definition.schedule(), "*/5 * * * *");
    let run_id = pid(running);
    assert_eq!(k.run(&run_id).await.unwrap().job, "rollup-v2", "the running run is the new name's");
    cron.update(running, |d| {
        d.status = "succeeded".into();
        d.end = Some(T0);
    });
    c.advance(HOUR);
    cron.add(1, "succeeded", c.now() - 2000, c.now() - 1000, Some("1 row"));
    k.check().await;
    assert_eq!(k.run(&run_id).await.unwrap().status, RunStatus::Ok);
    assert!(k.alerts.list().iter().all(|a| a.job != "rollup"), "the old name alerted");

    // Renamed again while no process watched: the next process retires the
    // name the store still schedules.
    cron.update_job(1, |j| j.jobname = name("rollup-v3"));
    let next = Kit::new(&cron, Some(&c), Some(store), PgCronOptions::default());
    c.advance(MIN);
    next.check().await;
    let jobs = next.cw.jobs().await.unwrap();
    assert_eq!(find(&jobs, "rollup-v2").definition.schedule(), "", "v2 unscheduled");
    assert!(find(&jobs, "rollup-v2").definition.description().contains("renamed to rollup-v3"));
    assert_eq!(find(&jobs, "rollup-v3").definition.schedule(), "*/5 * * * *", "v3 scheduled");
    assert!(next.runs("rollup-v3", 20).await.is_empty(), "runs already copied under an old name are not copied again");
    c.advance(HOUR);
    let result = next.check().await;
    for a in k.alerts.list().iter().chain(next.alerts.list().iter()).chain(result.alerts.iter()) {
        assert_eq!(a.job, "rollup-v3", "only the job's current name can be missed: {} {}", a.alert_type, a.job);
    }
    assert!(k.others().is_empty() && next.others().is_empty(), "{:?} {:?}", k.others(), next.others());
}

#[tokio::test]
async fn a_job_paused_or_renamed_while_missed_closes_missed_with_a_recovery() {
    let c = Clock::new(T0);
    let cron = FakeCron::new();
    cron.job(1, name("hourly"), "0 * * * *", true);
    cron.job(2, name("rollup"), "0 * * * *", true);
    cron.add(1, "succeeded", T0 - 3 * HOUR, T0 - 3 * HOUR + 1000, None);
    cron.add(2, "succeeded", T0 - 3 * HOUR, T0 - 3 * HOUR + 1000, None);
    let k = Kit::new(&cron, Some(&c), None, PgCronOptions::default());
    k.check().await;
    assert_eq!(types_and_jobs(&k.alerts.list()), ["missed hourly", "missed rollup"]);
    cron.update_job(1, |j| j.active = false);
    cron.update_job(2, |j| j.jobname = name("rollup-v2"));
    c.advance(MIN);
    let r = k.check().await;
    let mut got: Vec<String> = r.alerts.iter().map(|a| format!("{} {} {}", a.alert_type, a.job, a.title)).collect();
    got.sort();
    assert_eq!(
        got,
        ["recovered hourly hourly is no longer scheduled", "recovered rollup rollup is no longer scheduled"]
    );
    c.advance(MIN);
    assert!(k.check().await.alerts.is_empty(), "nothing more");
}

#[tokio::test]
async fn a_run_marked_timeout_by_a_check_is_still_read_and_its_late_finish_recorded() {
    let c = Clock::new(T0);
    let cron = FakeCron::new();
    cron.job(1, name("vacuum"), "0 3 * * *", true);
    let k = Kit::new(
        &cron,
        Some(&c),
        None,
        PgCronOptions { options: JobOptions::new().timeout("30m"), ..Default::default() },
    );
    let long = cron.add(1, "running", T0, -1, None);
    let id = pid(long);
    k.check().await;
    assert_eq!(k.run(&id).await.unwrap().status, RunStatus::Running);
    c.advance(45 * MIN);
    k.check().await;
    assert_eq!(k.run(&id).await.unwrap().status, RunStatus::Timeout);
    assert_eq!(k.alerts.types(), ["stuck"]);
    c.advance(10 * MIN);
    let now = c.now();
    cron.update(long, |d| {
        d.status = "succeeded".into();
        d.end = Some(now - 60_000);
        d.message = name("VACUUM");
    });
    k.check().await;
    let done = k.run(&id).await.unwrap();
    assert_eq!(done.status, RunStatus::Ok);
    assert_eq!(done.output.as_deref(), Some("VACUUM"));
    assert_eq!(k.alerts.types(), ["stuck", "recovered"]);
    let s = k.cw.job_summary("vacuum").await.unwrap().unwrap();
    assert_eq!(s.health, cronwatch::JobHealth::Healthy);
}

#[tokio::test]
async fn settings_a_role_may_not_read_are_assumed_and_reported_once() {
    let cron = FakeCron::new();
    cron.tables().settings.clear();
    cron.job(1, name("nightly"), "0 3 * * *", true);
    let k = Kit::new(&cron, None, None, PgCronOptions::default());
    let first = k.check().await;
    k.check().await;
    assert_eq!(first.jobs[0].definition.timezone(), "UTC");
    let errors = k.errors.list();
    assert_eq!(errors.iter().filter(|e| e.contains("cron.timezone")).count(), 1, "reported once: {errors:?}");
    assert!(!errors.iter().any(|e| e.contains("log_run")), "log_run unreadable is taken as on: {errors:?}");
}

#[tokio::test]
async fn the_sources_queries() {
    let cron = FakeCron::new();
    cron.tables().settings.insert("cron.log_run".into(), "off".into());
    cron.job(1, name("nightly"), "0 3 * * *", true);
    cron.add(1, "succeeded", T0 - 1000, T0, None);
    let o = PgCronOptions { timezone: Some("America/New_York".into()), job_ids: Some(vec![1]), ..Default::default() };
    let k = Kit::new(&cron, Some(&Clock::new(T0)), None, o);
    let r = k.check().await;
    assert_eq!(r.jobs[0].definition.schedule(), "", "no schedule when pg_cron records no runs");
    assert!(k.runs("nightly", 20).await.is_empty(), "no runs read");
    for q in &cron.tables().queries {
        assert!(
            !q.contains("current_setting") && !q.contains("COMMIT") && !q.contains("ROLLBACK"),
            "a query that could end the caller's transaction: {q}"
        );
    }
    assert!(k.errors.list().join("\n").contains("cron.log_run is off"), "{:?}", k.errors.list());
    // A job not picked by name or id is not declared.
    let cron2 = FakeCron::new();
    cron2.job(1, name("a"), "0 3 * * *", true);
    cron2.job(2, name("b"), "0 3 * * *", true);
    let k2 = Kit::new(
        &cron2,
        Some(&Clock::new(T0)),
        None,
        PgCronOptions { jobs: Some(vec!["b".into()]), ..Default::default() },
    );
    let r = k2.check().await;
    assert_eq!(r.jobs.iter().map(|j| j.name.as_str()).collect::<Vec<_>>(), ["b"]);
}

#[test]
fn the_helpers_read_as_the_sdk_does() {
    assert_eq!(schedule(" 1  2 * * * 7 ").as_deref(), Some("1 2 * * *"));
    assert_eq!(schedule("0 0 $ * *").as_deref(), Some("0 0 L * *"));
    assert_eq!(schedule("5 Seconds").as_deref(), Some("every 5s"));
    assert_eq!(schedule("@REBOOT"), None);
    assert_eq!(description_job_id("pg_cron job 12 in cw as postgres"), Some(12));
    assert_eq!(description_job_id("pg_cron job x in cw"), None);
    assert_eq!(array_of([1, 22, 3]), "{1,22,3}");
    assert_eq!(array_of([]), "{}");
    let source = PgCron::with_reader(FakeCron::new(), PgCronOptions { prefix: "db:".into(), ..Default::default() });
    assert_eq!(source.run_id_of("pgcron:db:42"), Some(42));
    assert_eq!(source.run_id_of("pgcron:db: 7 "), Some(7));
    assert_eq!(source.run_id_of("pgcron:db:"), Some(0));
    assert_eq!(source.run_id_of("pgcron:db:1.5"), None);
    assert_eq!(source.run_id_of("pgcron:other:1"), None);
    let job = PgCronJob { job_id: 3, job_name: name("  --weird name!! v2 "), ..Default::default() };
    assert_eq!(job_name(&job), "weird-name-v2-");
}
