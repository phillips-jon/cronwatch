//! The Go port's bridge tests, with its audits' regressions.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::*;
use crate::js::date_utc;
use crate::store::{BoxError, BoxFuture, Store};
use crate::types::{Definition, JobState, Run, RunStatus, StoredJob};
use crate::{Client, JobOptions, MemoryStore};

#[test]
fn the_app_tag_is_the_php_ports() {
    // What the PHP port's Bridge\Unscheduled::appTag() gives for each name.
    let x39 = "x".repeat(39);
    let cases = [
        ("Billing", "laravel-scheduler:billing".to_string()),
        ("  My App! v2 ", "laravel-scheduler:my-app-v2".to_string()),
        ("acme_web.prod-1", "laravel-scheduler:acme_web.prod-1".to_string()),
        ("!!!", "laravel-scheduler:6dd07555".to_string()),
        (&*"x".repeat(50), format!("laravel-scheduler:{x39}-62f01267")),
        ("\u{dc}n\u{ef}code \u{c4}pp", "laravel-scheduler:n-code-pp".to_string()),
        ("\u{212a}", "laravel-scheduler:f7781178".to_string()),
    ];
    for (app, want) in cases {
        assert_eq!(app_tag("laravel-scheduler", app), want, "{app:?}");
    }
}

#[test]
fn every_text_is_exact_to_the_millisecond() {
    assert_eq!(every_text(Duration::from_secs(90 * 60)), "every 1h30m");
    assert_eq!(every_text(Duration::from_millis(36 * 3_600_000 + 1500)), "every 1d12h1s500ms");
    assert_eq!(every_text(Duration::ZERO), "every 0ms");
}

#[test]
fn a_schedule_fires_as_cronwatch_expects() {
    let s = Schedule::parse("0 2 * * *", "Europe/London").unwrap();
    let from = date_utc(2026, 5, 1, 0, 0, 0, 0);
    assert_eq!(s.fire_after(from), Some(date_utc(2026, 5, 1, 1, 0, 0, 0)), "02:00 BST is 01:00 UTC");
    assert_eq!(s.every(), None);
    let every = Schedule::parse("every 5m", "").unwrap();
    assert_eq!(every.fire_after(from), Some(from + 300_000));
    assert_eq!(every.every(), Some(Duration::from_secs(300)));
    assert!(Schedule::parse("not a cron", "UTC").unwrap_err().to_string().contains("is not a cron expression"));
    assert_eq!(
        Schedule::parse("0 2 * * *", "Mars/Olympus").unwrap_err().to_string(),
        r#"timezone "Mars/Olympus" is not an IANA timezone"#
    );
}

/// A scheduler that runs at hour:00 UTC every `step` days from the epoch.
fn daily(hour: i64, step: i64) -> impl Fn(i64, Option<i64>) -> Result<Vec<i64>, ScheduleError> {
    move |start, end| {
        let at = |day: i64| day * 86_400_000 + hour * 3_600_000;
        let mut day = start.div_euclid(86_400_000);
        while at(day) > start || day % step != 0 {
            day -= 1;
        }
        let mut out = vec![at(day)];
        loop {
            day += step;
            out.push(at(day));
            if (end.is_none() && out.len() > SAMPLE_RUNS) || end.is_some_and(|e| at(day) > e) {
                return Ok(out);
            }
        }
    }
}

#[test]
fn check_fires_compares_the_schedulers_own_runs() {
    let now = date_utc(2026, 8, 1, 0, 0, 0, 0);
    check_fires(&daily(2, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now).unwrap();
    let err = check_fires(&daily(2, 2), "0 2 * * *", "UTC", "cronwatch: x", "a scheduler", true, now).unwrap_err();
    assert!(err.message().contains(r#"cronwatch: x is "0 2 * * *" in UTC, but after a run at"#), "{err}");
    assert!(err.message().contains("a scheduler runs it next at"), "{err}");
    assert!(check_fires(&daily(3, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now).is_err());
    let never = |_: i64, _: Option<i64>| Err(never_fires("no fire time"));
    let err = check_fires(&never, "0 2 * * *", "UTC", "x", "a scheduler", true, now).unwrap_err();
    assert!(err.message().ends_with("which never fires: no fire time"), "{err}");
    let err = check_fires(&daily(2, 1), "not a cron", "UTC", "x", "a scheduler", true, now).unwrap_err();
    assert!(err.message().contains("which CronWatch cannot read"), "{err}");
}

#[test]
fn check_fires_names_a_time_the_clock_change_skips() {
    // A scheduler that skips 02:30 in New York the night clocks go forward,
    // where CronWatch (croner) moves it past the jump.
    let tz = crate::schedule::load_zone("America/New_York").unwrap();
    let cron = crate::schedule::parse("30 2 * * *", "America/New_York").unwrap();
    let runs = move |start: i64, end: Option<i64>| {
        let mut out = Vec::new();
        let mut at = start - 3 * 86_400_000;
        while let Some(fire) = crate::schedule::fire_after(&cron, at) {
            at = fire;
            let w = crate::schedule::cron::wall_at(fire / 1000, &tz);
            if w[3] != 2 {
                continue; // the moved fire: this scheduler skips the day
            }
            if fire <= start {
                out.clear();
            }
            out.push(fire);
            if (end.is_none() && out.len() > SAMPLE_RUNS) || end.is_some_and(|e| fire > e) {
                break;
            }
        }
        Ok(out)
    };
    let now = date_utc(2026, 8, 1, 0, 0, 0, 0);
    let err = check_fires(&runs, "30 2 * * *", "America/New_York", "job", "a scheduler", true, now).unwrap_err();
    assert!(err.message().contains("due at a time that does not exist in America/New_York on 2026-03-08, when clocks go forward from 02:00 to 03:00"), "{err}");
}

/// A client on a memory store (or the one given) that keeps its errors.
fn client(store: Arc<dyn Store>) -> (Client, Arc<Mutex<Vec<String>>>) {
    let errors = Arc::new(Mutex::new(Vec::new()));
    let kept = errors.clone();
    let cw = Client::builder()
        .store_arc(store)
        .alerts([])
        .on_error(move |err, where_| kept.lock().unwrap().push(format!("{where_}: {err}")))
        .build()
        .unwrap();
    (cw, errors)
}

async fn stored(store: &dyn Store, name: &str) -> String {
    store.get_job(name).await.unwrap().unwrap_or_else(|| panic!("{name} is not stored")).definition.to_json()
}

fn entry(name: &str, label: &str, schedule: &str) -> Entry {
    Entry { name: name.into(), label: label.into(), schedule: schedule.into(), ..Entry::default() }
}

#[tokio::test]
async fn a_watch_declares_entries_and_unschedules_the_gone() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (cw, errors) = client(store.clone());
    let w = Watch::new(&cw, "gocron", Some("billing"), "gocron");
    let nightly = Entry {
        timezone: "UTC".into(),
        defaults: JobOptions::new().grace("5m"),
        options: JobOptions::new().budget("cost", 2.0).tags(["reports"]),
        ..entry("nightly", "entry 1", "0 2 * * *")
    };
    let odd = Entry { problem: Some("cronwatch: entry 4 cannot be read".into()), ..entry("odd", "entry 4", "") };
    w.declare(&[nightly.clone(), entry("twice", "entry 2", "0 3 * * *"), entry("twice", "entry 3", "0 4 * * *"), odd]);
    cw.check().await.unwrap();
    assert_eq!(
        stored(&*store, "nightly").await,
        r#"{"grace":"5m","schedule":"0 2 * * *","timezone":"UTC","budget":{"cost":2},"tags":["reports","gocron","gocron:billing"],"name":"nightly"}"#
    );
    assert_eq!(stored(&*store, "twice").await, r#"{"tags":["gocron","gocron:billing"],"name":"twice"}"#);
    assert_eq!(stored(&*store, "odd").await, r#"{"tags":["gocron","gocron:billing"],"name":"odd"}"#);
    assert_eq!(
        errors.lock().unwrap().join("\n"),
        "declaring entry 2: cronwatch: \"twice\" is run by 2 gocron entries on different schedules (0 3 * * *; 0 4 * * *), so it is watched without a schedule; give each a name of its own\n\
         declaring entry 4: cronwatch: entry 4 cannot be read"
    );

    // Declaring again changes nothing and reports nothing again; an entry
    // gone keeps its runs and loses its schedule.
    let first = w.job("nightly").unwrap();
    w.declare(&[nightly, entry("twice", "entry 2", "0 3 * * *"), entry("twice", "entry 3", "0 4 * * *")]);
    assert!(std::ptr::eq(w.job("nightly").unwrap().definition(), first.definition()), "the same job");
    assert_eq!(errors.lock().unwrap().len(), 2, "reported once");
    w.declare(&[]);
    cw.check().await.unwrap();
    assert_eq!(
        stored(&*store, "nightly").await,
        r#"{"description":"A scheduled task (no longer scheduled)","tags":["reports","gocron","gocron:billing"],"grace":"5m","budget":{"cost":2},"name":"nightly"}"#
    );
}

#[tokio::test]
async fn unschedule_takes_only_this_apps_jobs() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (earlier, _) = client(store.clone());
    for (name, tag) in [("invoices", "gocron:billing"), ("dunning", "gocron:billing"), ("reindex", "gocron:search")] {
        earlier
            .job(name, JobOptions::new().schedule("0 1 * * *").tags(["gocron", tag]).timeout("2h").description("Bills"))
            .unwrap();
    }
    earlier.check().await.unwrap();

    let (cw, _) = client(store.clone());
    let w = Watch::new(&cw, "gocron", Some("billing"), "gocron");
    assert!(w.unschedule().await.unwrap().is_empty(), "a watch that saw no entry takes nothing");
    w.declare(&[entry("invoices", "x", "0 1 * * *")]);
    assert_eq!(w.unschedule().await.unwrap(), ["dunning"]);
    // Written without a check (the Go audit: a process that never checks
    // left the schedule in the store).
    assert!(stored(&*store, "dunning").await.contains("no longer scheduled"));
    cw.check().await.unwrap();
    assert_eq!(
        stored(&*store, "dunning").await,
        r#"{"description":"Bills (no longer scheduled)","tags":["gocron","gocron:billing"],"timeout":"2h","name":"dunning"}"#
    );
    assert!(stored(&*store, "reindex").await.contains(r#""schedule":"0 1 * * *""#), "reindex is search's");
    assert!(stored(&*store, "invoices").await.contains(r#""schedule":"0 1 * * *""#), "invoices kept");
}

#[tokio::test]
async fn a_fallback_keeps_the_stored_definition() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (scheduler, _) = client(store.clone());
    scheduler
        .job(
            "report",
            JobOptions::new()
                .grace("5m")
                .schedule("0 2 * * *")
                .timezone("UTC")
                .timeout(7_200_000u64)
                .max_duration("30m")
                .budget("cost", 2.0)
                .budget("rows", 10.0)
                .failures_before_alert(2)
                .description("Nightly")
                .tags(["river", "river:billing"])
                .expect("Report written"),
        )
        .unwrap();
    scheduler.check().await.unwrap();
    let before = stored(&*store, "report").await;

    let (worker, _) = client(store.clone());
    let w = Watch::new(&worker, "river", Some("billing"), "River");
    let job = w.fallback("report", JobOptions::new()).await.unwrap();
    assert_eq!(job.definition().to_json(), before);
    assert!(std::ptr::eq(w.fallback("report", JobOptions::new()).await.unwrap().definition(), job.definition()));
    job.run(|_| async { Ok::<_, std::io::Error>(()) }).await.unwrap();
    let runs = worker.runs("report", 1).await.unwrap();
    assert_eq!(runs[0].error.as_deref(), Some(r#"Output did not contain "Report written""#), "the expect rule holds");
    assert_eq!(stored(&*store, "report").await, before, "the stored definition is unchanged");

    // A job of another app's is not taken for this one's.
    let other = Watch::new(&worker, "river", Some("search"), "River");
    let (fresh, _) = client(store.clone());
    let other_fresh = Watch::new(&fresh, "river", Some("search"), "River");
    let made = other_fresh.fallback("report", JobOptions::new().grace("1m")).await.unwrap();
    assert_eq!(made.definition().to_json(), r#"{"grace":"1m","tags":["river","river:search"],"name":"report"}"#);
    drop(other);
}

// The Go audit: a process that only schedules neither runs nor checks, and
// kept its declarations in memory, so the store never held its jobs.
#[tokio::test]
async fn declaring_writes_the_jobs_to_the_store() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (cw, errors) = client(store.clone());
    let w = Watch::new(&cw, "asynq", Some("billing"), "Asynq");
    w.declare(&[entry("invoices", "x", "0 1 * * *")]);
    w.settle().await;
    assert_eq!(
        stored(&*store, "invoices").await,
        r#"{"schedule":"0 1 * * *","tags":["asynq","asynq:billing"],"name":"invoices"}"#
    );
    assert!(errors.lock().unwrap().is_empty());
}

// The Go audit: a job another process of the app took the schedule out of
// (an older release still up during a deploy) stayed unscheduled until this
// process restarted. Unschedule puts it back.
#[tokio::test]
async fn a_job_another_process_unscheduled_is_put_back() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (newer, _) = client(store.clone());
    let wn = Watch::new(&newer, "gocron", Some("billing"), "gocron");
    wn.declare(&[entry("old", "a", "0 1 * * *"), entry("added", "b", "0 2 * * *")]);
    wn.settle().await;
    newer.check().await.unwrap();

    let (older, _) = client(store.clone());
    let wo = Watch::new(&older, "gocron", Some("billing"), "gocron");
    wo.declare(&[entry("old", "a", "0 1 * * *")]);
    wo.unschedule().await.unwrap();
    older.check().await.unwrap();
    assert!(!stored(&*store, "added").await.contains(r#""schedule""#), "the older release took it out");

    wn.unschedule().await.unwrap();
    assert_eq!(
        stored(&*store, "added").await,
        r#"{"schedule":"0 2 * * *","tags":["gocron","gocron:billing"],"name":"added"}"#
    );
}

/// A memory store whose `get_job` fails while `failing` is set, and whose
/// `list_jobs` calls `meanwhile` once.
#[derive(Default)]
struct Odd {
    inner: MemoryStore,
    failing: AtomicBool,
    /// `get_job` panics once while this is set.
    panics: AtomicBool,
    meanwhile: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}

impl Store for Odd {
    fn init(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        self.inner.init()
    }
    fn upsert_job<'a>(&'a self, d: &'a Definition, now: i64) -> BoxFuture<'a, Result<(), BoxError>> {
        self.inner.upsert_job(d, now)
    }
    fn get_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<Option<StoredJob>, BoxError>> {
        if self.failing.load(Ordering::SeqCst) {
            return Box::pin(async { Err("the store blinked".into()) });
        }
        if self.panics.swap(false, Ordering::SeqCst) {
            panic!("the store fell over");
        }
        self.inner.get_job(name)
    }
    fn list_jobs(&self) -> BoxFuture<'_, Result<Vec<StoredJob>, BoxError>> {
        Box::pin(async {
            let jobs = self.inner.list_jobs().await;
            let meanwhile = self.meanwhile.lock().unwrap().take();
            if let Some(f) = meanwhile {
                f();
            }
            jobs
        })
    }
    fn delete_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<(), BoxError>> {
        self.inner.delete_job(name)
    }
    fn insert_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        self.inner.insert_run(run)
    }
    fn update_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        self.inner.update_run(run)
    }
    fn get_run<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
        self.inner.get_run(id)
    }
    fn list_runs<'a>(&'a self, job: &'a str, limit: usize) -> BoxFuture<'a, Result<Vec<Run>, BoxError>> {
        self.inner.list_runs(job, limit)
    }
    fn last_run<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
        self.inner.last_run(job)
    }
    fn running_runs(&self) -> BoxFuture<'_, Result<Vec<Run>, BoxError>> {
        self.inner.running_runs()
    }
    fn get_state<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<JobState>, BoxError>> {
        self.inner.get_state(job)
    }
    fn set_state<'a>(&'a self, state: &'a JobState) -> BoxFuture<'a, Result<(), BoxError>> {
        self.inner.set_state(state)
    }
    fn prune(&self, before: i64) -> BoxFuture<'_, Result<u64, BoxError>> {
        self.inner.prune(before)
    }
    fn close(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        self.inner.close()
    }
    fn update_run_if<'a>(&'a self, run: &'a Run, from: &'a [RunStatus]) -> BoxFuture<'a, Result<bool, BoxError>> {
        self.inner.update_run_if(run, from)
    }
    fn compare_and_set_state<'a>(
        &'a self,
        state: &'a JobState,
        expected: i64,
    ) -> BoxFuture<'a, Result<bool, BoxError>> {
        self.inner.compare_and_set_state(state, expected)
    }
}

// The Go audit: a lookup that failed once had the fallback declare the job
// without its schedule, keep that for good, and write it over the
// scheduler's definition at the next run.
#[tokio::test]
async fn a_fallback_does_not_declare_over_a_store_it_could_not_read() {
    let store = Arc::new(Odd::default());
    let (scheduler, _) = client(store.clone());
    scheduler.job("report", JobOptions::new().schedule("0 2 * * *").tags(["river", "river:billing"])).unwrap();
    scheduler.check().await.unwrap();
    let before = stored(&*store, "report").await;

    let (worker, errors) = client(store.clone());
    let w = Watch::new(&worker, "river", Some("billing"), "River");
    store.failing.store(true, Ordering::SeqCst);
    assert!(w.fallback("report", JobOptions::new()).await.is_none(), "declared without reading the store");
    assert_eq!(errors.lock().unwrap().len(), 1);
    store.failing.store(false, Ordering::SeqCst);
    let job = w.fallback("report", JobOptions::new()).await.expect("a job once the store answers");
    job.run(|_| async { Ok::<_, std::io::Error>(()) }).await.unwrap();
    assert_eq!(stored(&*store, "report").await, before, "the schedule is kept");
}

// The .NET audit: a run that fired before the scheduler was read held the
// fallback's job, declared without a schedule, and wrote it over the entry's
// declaration once that was in the store.
#[tokio::test]
async fn a_run_holding_the_fallbacks_job_does_not_write_over_the_entrys_declaration() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (cw, errors) = client(store.clone());
    let w = Watch::new(&cw, "asynq", Some("billing"), "Asynq");
    let held = w.fallback("invoices", JobOptions::new()).await.unwrap();
    assert_eq!(held.definition().schedule(), "");
    w.declare(&[entry("invoices", "x", "0 1 * * *")]);
    w.settle().await;
    let declared = stored(&*store, "invoices").await;
    assert_eq!(declared, r#"{"schedule":"0 1 * * *","tags":["asynq","asynq:billing"],"name":"invoices"}"#);
    held.run(|_| async { Ok::<_, std::io::Error>(()) }).await.unwrap();
    assert_eq!(stored(&*store, "invoices").await, declared, "the schedule is kept");
    cw.check().await.unwrap();
    assert_eq!(stored(&*store, "invoices").await, declared, "and after a check");
    assert!(errors.lock().unwrap().is_empty());
}

// The audit: a store that panicked while a declaration was written left the
// writing task marked busy, so nothing was written again and settle waited
// for good.
#[tokio::test]
async fn a_declaration_whose_store_panics_does_not_stop_the_next() {
    let store = Arc::new(Odd::default());
    let (cw, errors) = client(store.clone());
    let w = Watch::new(&cw, "river", Some("billing"), "River");
    store.panics.store(true, Ordering::SeqCst);
    w.declare(&[entry("first", "x", "0 1 * * *")]);
    tokio::time::timeout(Duration::from_secs(5), w.settle()).await.expect("settled");
    assert_eq!(errors.lock().unwrap().clone(), ["declaring first: panicked: the store fell over"]);
    w.declare(&[entry("first", "x", "0 1 * * *"), entry("second", "y", "0 2 * * *")]);
    tokio::time::timeout(Duration::from_secs(5), w.settle()).await.expect("settled");
    assert!(stored(&*store, "second").await.contains("0 2 * * *"));
}

// The review: the dashboard's forget took a job out of the client, the
// watch kept it as unchanged and never declared it again, the next run
// wrote it back, and unschedule took it for an entry gone, so the job the
// scheduler still runs lost its schedule until restart.
#[tokio::test]
async fn a_job_forgotten_while_the_scheduler_runs_it_keeps_its_schedule() {
    let entries = [entry("nightly", "x", "0 2 * * *")];
    let want = r#"{"schedule":"0 2 * * *","tags":["gocron","gocron:billing"],"name":"nightly"}"#;
    for order in ["a run, then a declare", "a run, then unschedule", "unschedule before any run"] {
        let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
        let (cw, errors) = client(store.clone());
        let w = Watch::new(&cw, "gocron", Some("billing"), "gocron");
        w.declare(&entries);
        w.settle().await;
        cw.forget("nightly").await.unwrap();
        if order.starts_with("a run") {
            w.job("nightly").unwrap().run(|_| async { Ok::<_, std::io::Error>(()) }).await.unwrap();
        }
        if order == "a run, then a declare" {
            w.declare(&entries);
        }
        for _ in 0..2 {
            assert!(w.unschedule().await.unwrap().is_empty(), "nothing unscheduled ({order})");
            w.declare(&entries);
            w.settle().await;
            cw.check().await.unwrap();
        }
        assert_eq!(stored(&*store, "nightly").await, want, "{order}");
        let defined = cw.defined_jobs();
        assert_eq!(defined.len(), 1, "{order}");
        assert_eq!(defined[0].schedule(), "0 2 * * *", "{order}");
        assert!(errors.lock().unwrap().is_empty(), "{order}: {:?}", errors.lock().unwrap());
    }
}

#[tokio::test]
async fn a_fallback_declares_a_forgotten_job_again() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (cw, _) = client(store.clone());
    let w = Watch::new(&cw, "river", Some("billing"), "River");
    let first = w.fallback("report", JobOptions::new().grace("1m")).await.unwrap();
    cw.forget("report").await.unwrap();
    let again = w.fallback("report", JobOptions::new().grace("1m")).await.unwrap();
    assert!(!std::ptr::eq(again.definition(), first.definition()), "made again");
    assert_eq!(cw.defined_jobs().len(), 1, "declared again");
}

// The Go audit: an entry declared while unschedule read the store was taken
// for gone, and its job lost its schedule for the life of the process.
#[tokio::test]
async fn unschedule_keeps_an_entry_declared_meanwhile() {
    let store = Arc::new(Odd::default());
    let (earlier, _) = client(store.clone());
    earlier.job("added", JobOptions::new().schedule("0 2 * * *").tags(["gocron", "gocron:billing"])).unwrap();
    earlier.check().await.unwrap();

    let (cw, _) = client(store.clone());
    let w = Watch::new(&cw, "gocron", Some("billing"), "gocron");
    let entries = vec![entry("first", "x", "0 1 * * *")];
    w.declare(&entries);
    w.settle().await;
    let again = w.clone();
    *store.meanwhile.lock().unwrap() = Some(Box::new(move || {
        let mut more = entries.clone();
        more.push(entry("added", "y", "0 2 * * *"));
        again.declare(&more);
    }));
    assert!(w.unschedule().await.unwrap().is_empty());
    assert_eq!(cw.defined_jobs()[1].schedule(), "0 2 * * *", "kept");
    w.settle().await;
    assert!(stored(&*store, "added").await.contains(r#""schedule":"0 2 * * *""#));
}

#[test]
fn options_of_rebuilds_an_expect_pattern_and_a_custom_function() {
    struct Pattern;
    impl Matcher for Pattern {
        fn is_match(&self, _: &str) -> bool {
            false
        }
        fn source(&self) -> String {
            r"/done \d+/i".into()
        }
    }
    use crate::serialize::Matcher;
    let def = crate::client::describe_job("x", &JobOptions::new().expect_match(Pattern));
    let rebuilt = crate::client::describe_job("x", &options_of(&def));
    assert_eq!(rebuilt.to_json(), def.to_json());
    let options = options_of(&def);
    let rule = options.expect.as_ref().unwrap();
    assert_eq!(rule.check("Done 12"), None, "run by the JavaScript engine, /i and all");
    assert!(rule.check("nothing").is_some());
    let custom = crate::client::describe_job("x", &JobOptions::new().expect_fn(|_| false));
    assert_eq!(
        crate::client::describe_job("x", &options_of(&custom)).to_json(),
        r#"{"name":"x","expect":"custom function"}"#
    );
}

#[test]
fn a_stored_pattern_too_deep_to_match_fails_rather_than_aborting() {
    // The audit: `(?:ab)*` over a long output overflowed a worker's stack.
    let def = Definition::from_json(r#"{"name":"x","expect":"matches /(?:ab)*done/"}"#).unwrap();
    let passed = std::thread::Builder::new()
        .stack_size(2 * 1024 * 1024)
        .spawn(move || {
            let rule = options_of(&def).expect.unwrap();
            (rule.check(&format!("{}done", "ab".repeat(16_000))), rule.check("abdone"), rule.check("nothing"))
        })
        .unwrap()
        .join()
        .unwrap();
    assert_eq!(passed.0.as_deref(), Some("Output did not match /(?:ab)*done/"), "it gave up, so it does not match");
    assert_eq!(passed.1, None);
    assert!(passed.2.is_some());
}

#[test]
fn a_stored_pattern_that_backtracks_without_end_fails_quickly() {
    // The fuzzer: stars back to back, or a dot star, over a long output
    // they do not match backtrack polynomially; the step budget stops them
    // and the run fails with the ordinary message.
    for (source, text, good) in [
        (r"/\n*\n*\n*\n*\n*x/", "\n".repeat(32_000), "\n\nx"),
        ("/.*x/", "a".repeat(32_000), "aax"),
        (r"/(?:\s*,)*\s*;/", " ".repeat(32_000), "  ,  ;"),
    ] {
        let def =
            Definition::from_json(&format!(r#"{{"name":"x","expect":"matches {}"}}"#, source.replace('\\', "\\\\")))
                .unwrap();
        let rule = options_of(&def).expect.unwrap();
        let started = std::time::Instant::now();
        let got = rule.check(&text);
        let took = started.elapsed();
        assert_eq!(got, Some(format!("Output did not match {source}")));
        // Steps bound it, not time; a debug build on a slow runner is slower.
        let limit = std::time::Duration::from_secs(if cfg!(debug_assertions) { 60 } else { 5 });
        assert!(took < limit, "{source} took {took:?}");
        assert_eq!(rule.check(good), None, "{source} still matches");
    }
}
