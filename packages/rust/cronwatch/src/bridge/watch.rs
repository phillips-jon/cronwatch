//! `Watch`: the jobs an integration declared for one scheduler, the jobs
//! gone from it, and the jobs a worker runs that another process declared.
//! The Go port's `bridge/watch.go` and `Fallback`, with its audits' fixes.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::watch;

use super::options::{options_of, unscheduled};
use super::{app_name, app_tag};
use crate::client::{Client, describe_job, lock};
use crate::error::Error;
use crate::js;
use crate::options::JobOptions;
use crate::run::Job;

/// Bounds one write of a declaration to the store, so a store that hangs
/// never holds the writing task for good.
const SAVE_TIMEOUT: Duration = Duration::from_secs(30);

/// One job a scheduler runs, as an integration reads it.
#[derive(Clone, Debug, Default)]
pub struct Entry {
    /// The job's name.
    pub name: String,
    /// Names the entry in messages: `tokio-cron-scheduler job
    /// "nightly-report"`.
    pub label: String,
    /// The scheduler's schedule as CronWatch reads it, `""` for none.
    pub schedule: String,
    /// The zone the schedule is read in, `""` for the process's own.
    pub timezone: String,
    /// Why an entry with a schedule of its own has none here, or a note
    /// about the one it has: reported once.
    pub problem: Option<String>,
    /// The integration's options for every job, applied before the
    /// schedule, as the SDK spreads a client's defaults first.
    pub defaults: JobOptions,
    /// The options the app gave this entry, applied after the schedule, so a
    /// schedule among them replaces the scheduler's.
    pub options: JobOptions,
}

/// What an integration keeps for one scheduler: the jobs it declared, by
/// name, and the problems it reported. A cheap handle (an `Arc` inside),
/// safe to use from many tasks at once.
#[derive(Clone)]
pub struct Watch {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for Watch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Watch").field("tag", &self.inner.tag).field("app_tag", &self.inner.app_tag).finish()
    }
}

struct Inner {
    cw: Client,
    tag: String,
    app_tag: String,
    scheduler: String,
    /// Holds one declaration at a time (`declare`, the end of `fallback`,
    /// `unschedule`'s declarations), so one never takes another's entries
    /// for gone or leaves the client holding a job without its schedule.
    declaring: Mutex<()>,
    state: Mutex<State>,
    /// False while declarations are being written to the store.
    settled: watch::Sender<bool>,
}

#[derive(Default)]
struct State {
    jobs: HashMap<String, Declared>,
    /// Jobs declared for runs of jobs this watch did not declare.
    fallback: HashMap<String, Job>,
    reported: HashSet<String>,
    /// Whether this process ever declared an entry: until it has, it takes
    /// no job for one the scheduler dropped (a process that runs a check and
    /// no scheduler must not unschedule the app's jobs).
    seen: bool,
    /// Names declared and not yet written to the store, which one task at a
    /// time writes.
    pending: BTreeSet<String>,
    saving: bool,
}

struct Declared {
    job: Job,
    /// The definition's JSON, to tell a changed declaration.
    key: String,
    /// The entry is still in the scheduler.
    current: bool,
}

impl Watch {
    /// A watch for one scheduler: `tag` is the integration's
    /// (`tokio-cron-scheduler`), `app` the app's name for its tag (`None`
    /// for [`app_name`]), and `scheduler` how messages name the scheduler.
    pub fn new(cw: &Client, tag: &str, app: Option<&str>, scheduler: &str) -> Watch {
        let app = app.filter(|a| !a.is_empty()).map_or_else(app_name, str::to_string);
        Watch {
            inner: Arc::new(Inner {
                cw: cw.clone(),
                tag: tag.to_string(),
                app_tag: app_tag(tag, &app),
                scheduler: scheduler.to_string(),
                declaring: Mutex::new(()),
                state: Mutex::new(State::default()),
                settled: watch::Sender::new(true),
            }),
        }
    }

    /// The client the watch declares jobs on.
    pub fn client(&self) -> &Client {
        &self.inner.cw
    }

    /// The integration's tag.
    pub fn tag(&self) -> &str {
        &self.inner.tag
    }

    /// The app's tag under the integration's.
    pub fn app_tag(&self) -> &str {
        &self.inner.app_tag
    }

    /// Hands `message` to the client's error handler the first time this
    /// watch sees it for that `where_`.
    pub fn report_once(&self, message: &str, where_: &str) {
        let first = lock(&self.inner.state).reported.insert(format!("{where_}\0{message}"));
        if first {
            self.inner.cw.report_error(Error::Other(message.to_string()), where_);
        }
    }

    /// The job declared under `name`, or one declared for a run of it
    /// ([`fallback`](Self::fallback)).
    pub fn job(&self, name: &str) -> Option<Job> {
        let state = lock(&self.inner.state);
        state.jobs.get(name).map(|d| d.job.clone()).or_else(|| state.fallback.get(name).cloned())
    }

    /// Whether `name` was declared from a scheduler entry by this watch.
    pub fn declares(&self, name: &str) -> bool {
        lock(&self.inner.state).jobs.contains_key(name)
    }

    /// Declares every entry the scheduler has now, one job per name, and
    /// declares again without its schedule a job this watch declared whose
    /// entries are all gone. Several entries of one name on different
    /// schedules are one job without a schedule, reported once. Each job is
    /// tagged with the integration's tag and the app's. A declaration that
    /// has not changed is left alone; one the client refuses is reported, as
    /// is each entry's problem, once. What is declared is written to the
    /// store in a task of its own ([`settle`](Self::settle) waits for it),
    /// since a process that only schedules neither runs nor checks, and a
    /// declaration kept in memory would never reach the processes that do.
    pub fn declare(&self, entries: &[Entry]) {
        let _turn = lock(&self.inner.declaring);
        let mut order: Vec<&str> = Vec::new();
        let mut by_name: HashMap<&str, Vec<&Entry>> = HashMap::new();
        for e in entries {
            if !by_name.contains_key(e.name.as_str()) {
                order.push(&e.name);
            }
            by_name.entry(&e.name).or_default().push(e);
        }
        {
            let mut state = lock(&self.inner.state);
            if !entries.is_empty() {
                state.seen = true;
            }
            for d in state.jobs.values_mut() {
                d.current = false;
            }
        }

        for name in order {
            let group = &by_name[name];
            let first = group[0];
            let (mut sched, mut zone) = (first.schedule.as_str(), first.timezone.as_str());
            let mut times: Vec<String> = Vec::new();
            for e in group {
                if let Some(problem) = &e.problem {
                    self.report_once(problem, &format!("declaring {}", e.label));
                }
                let mut text = e.schedule.clone();
                if !e.timezone.is_empty() {
                    text = format!("{text} in {}", e.timezone);
                }
                if text.is_empty() {
                    text = "no schedule".into();
                }
                if !times.contains(&text) {
                    times.push(text);
                }
            }
            if times.len() > 1 {
                (sched, zone) = ("", "");
                self.report_once(
                    &format!(
                        "cronwatch: {} is run by {} {} entries on different schedules ({}), so it is watched without a schedule; give each a name of its own",
                        js::quote(name),
                        group.len(),
                        self.inner.scheduler,
                        times.join("; ")
                    ),
                    &format!("declaring {}", first.label),
                );
            }
            let mut options = first.defaults.clone();
            if !sched.is_empty() {
                options = options.schedule(sched);
                if !zone.is_empty() {
                    options = options.timezone(zone);
                }
            }
            let options = options.merge(first.options.clone());
            self.declare_one(name, &first.label, self.tagged(name, options), true);
        }

        // Jobs whose entries are gone keep their runs and lose their schedule.
        let mut gone: Vec<(String, crate::types::Definition)> = lock(&self.inner.state)
            .jobs
            .iter()
            .filter(|(_, d)| !d.current && !d.job.definition().schedule().is_empty())
            .map(|(name, d)| (name.clone(), d.job.definition().clone()))
            .collect();
        gone.sort_by(|a, b| a.0.cmp(&b.0));
        for (name, def) in gone {
            self.declare_one(&name, &js::quote(&name), unscheduled(&def), false);
        }
    }

    /// `options` with the integration's and the app's tags added to the
    /// ones the options give.
    pub fn tagged(&self, name: &str, options: JobOptions) -> JobOptions {
        let mut tags = describe_job(name, &options).tags();
        for t in [&self.inner.tag, &self.inner.app_tag] {
            if !tags.contains(t) {
                tags.push(t.clone());
            }
        }
        options.tags(tags)
    }

    fn declare_one(&self, name: &str, label: &str, options: JobOptions, current: bool) {
        let key = describe_job(name, &options).to_json();
        {
            let mut state = lock(&self.inner.state);
            if let Some(d) = state.jobs.get_mut(name) {
                if d.key == key {
                    d.current = d.current || current;
                    return;
                }
            }
        }
        let job = match self.inner.cw.job(name, options) {
            Ok(job) => job,
            Err(err) => {
                self.report_once(&err.to_string(), &format!("declaring {label}"));
                return;
            }
        };
        {
            let mut state = lock(&self.inner.state);
            state.fallback.remove(name);
            match state.jobs.get_mut(name) {
                Some(d) => {
                    d.job = job;
                    d.key = key;
                    d.current = d.current || current;
                }
                None => {
                    state.jobs.insert(name.to_string(), Declared { job, key, current });
                }
            }
        }
        self.save(name);
    }

    /// Writes `name`'s declaration to the store in the background, one task
    /// at a time, each write the client's declaration as it is then.
    fn save(&self, name: &str) {
        let mut state = lock(&self.inner.state);
        state.pending.insert(name.to_string());
        if state.saving {
            return;
        }
        state.saving = true;
        self.inner.settled.send_replace(false);
        let watch = self.clone();
        self.inner.cw.inner.handle.spawn(async move { watch.save_all().await });
    }

    async fn save_all(&self) {
        loop {
            let names = {
                let mut state = lock(&self.inner.state);
                if state.pending.is_empty() {
                    state.saving = false;
                    self.inner.settled.send_replace(true);
                    return;
                }
                std::mem::take(&mut state.pending)
            };
            let defined = self.defined();
            for name in names {
                if !defined.contains(&name) {
                    continue; // forgotten since
                }
                if let Err(err) = self.sync_job(&name).await {
                    self.inner.cw.report_error(err, &format!("declaring {name}"));
                }
            }
        }
    }

    /// `Client::sync_job` within `SAVE_TIMEOUT`.
    async fn sync_job(&self, name: &str) -> Result<bool, Error> {
        match tokio::time::timeout(SAVE_TIMEOUT, self.inner.cw.sync_job(name)).await {
            Ok(result) => result,
            Err(_) => Err(Error::Other(format!(
                "writing the declaration of {} took longer than {} seconds; gave up",
                js::quote(name),
                SAVE_TIMEOUT.as_secs()
            ))),
        }
    }

    fn defined(&self) -> HashSet<String> {
        self.inner.cw.defined_jobs().into_iter().map(|d| d.name().to_string()).collect()
    }

    /// Waits until what [`declare`](Self::declare) declared has been
    /// written to the store, for tests and a clean exit.
    pub async fn settle(&self) {
        let mut rx = self.inner.settled.subscribe();
        let _ = rx.wait_for(|settled| *settled).await;
    }

    /// The job a run in this process belongs to when this process has not
    /// declared it from a scheduler of its own (a worker whose app schedules
    /// the job in another process): declared again from the definition the
    /// store holds, when that is this app's (tagged with its app tag), so
    /// the schedule another process stored is kept, else with `options` and
    /// this watch's tags. Declared once per name in this process. `None`,
    /// with the reason reported, when the client refuses it or the store
    /// cannot be read (the run then goes unrecorded, and the next one asks
    /// again), since a declaration made without the stored one would write
    /// over its schedule. A job [`declare`](Self::declare) has declared is
    /// `declare`'s.
    pub async fn fallback(&self, name: &str, options: JobOptions) -> Option<Job> {
        if let Some(job) = self.job(name) {
            return Some(job);
        }
        let cw = &self.inner.cw;
        let stored = match cw.ensure_ready().await {
            Ok(()) => cw.inner.store.get_job(name).await.map_err(Error::store),
            Err(err) => Err(err),
        };
        let stored = match stored {
            Ok(stored) => stored,
            Err(err) => {
                cw.report_error(err, &format!("declaring {name}"));
                return None;
            }
        };
        let made = match stored {
            Some(job) if job.definition.tags().contains(&self.inner.app_tag) => options_of(&job.definition),
            _ => self.tagged(name, options),
        };
        // In turn with declare, and after looking again: a job declared from
        // a scheduler entry meanwhile is that one, so the client never ends
        // up holding the declaration without the schedule.
        let _turn = lock(&self.inner.declaring);
        if let Some(job) = self.job(name) {
            return Some(job);
        }
        match cw.job(name, made) {
            Ok(job) => {
                lock(&self.inner.state).fallback.insert(name.to_string(), job.clone());
                Some(job)
            }
            Err(err) => {
                self.report_once(&err.to_string(), &format!("declaring {name}"));
                None
            }
        }
    }

    /// Declares again without its schedule every job of this app's (tagged
    /// with its app tag) that the store holds with a schedule and this
    /// process has not declared: a scheduler entry taken out since the job
    /// was declared, by this process or an earlier one, so it is never
    /// reported missed and a missed alert already open closes. Call it just
    /// before a check. It first writes back this process's own declarations
    /// wherever the store holds something else (an older release still up
    /// during a deploy may have taken the schedule out of a job it does not
    /// run). A process that never declared an entry of its scheduler leaves
    /// every job alone. Everything is written before it returns. Returns the
    /// names declared again.
    pub async fn unschedule(&self) -> Result<Vec<String>, Error> {
        let (seen, mut mine) = {
            let state = lock(&self.inner.state);
            (state.seen, state.jobs.keys().cloned().collect::<Vec<_>>())
        };
        if !seen {
            return Ok(Vec::new());
        }
        let cw = &self.inner.cw;
        let mut failed: Vec<String> = Vec::new();
        let defined = self.defined();
        mine.sort();
        for name in mine.iter().filter(|n| defined.contains(*n)) {
            if let Err(err) = self.sync_job(name).await {
                failed.push(format!("declaring {name}: {err}"));
            }
        }
        let stored = match cw.ensure_ready().await {
            Ok(()) => cw.inner.store.list_jobs().await.map_err(Error::store),
            Err(err) => Err(err),
        };
        let stored = match stored {
            Ok(stored) => stored,
            Err(err) => {
                failed.push(err.to_string());
                return Err(Error::Other(failed.join("\n")));
            }
        };
        // In turn with declare and fallback, and with what is declared read
        // again: a job declared since the first read (a scheduler entry added
        // while the store was read) must keep its schedule.
        let mut names = Vec::new();
        {
            let _turn = lock(&self.inner.declaring);
            let defined = self.defined();
            for job in stored {
                let def = &job.definition;
                if defined.contains(&job.name) || def.schedule().is_empty() || !def.tags().contains(&self.inner.app_tag)
                {
                    continue;
                }
                match cw.job(&job.name, unscheduled(def)) {
                    Ok(_) => names.push(job.name),
                    Err(err) => failed.push(format!("declaring {}: {err}", job.name)),
                }
            }
        }
        // Written before returning, and in order with this call's other
        // writes: a process that never checks would otherwise leave the
        // schedule in the store, and a write left to run behind could land
        // after another process has put the schedule back. sync_job writes
        // what is declared at the time, so a job declared again since keeps
        // its schedule.
        for name in &names {
            if let Err(err) = self.sync_job(name).await {
                failed.push(format!("declaring {name}: {err}"));
            }
        }
        if failed.is_empty() { Ok(names) } else { Err(Error::Other(failed.join("\n"))) }
    }
}
