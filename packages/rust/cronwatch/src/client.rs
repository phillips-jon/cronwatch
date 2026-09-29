//! The client (client.ts): jobs, runs, state updates. Evaluation is in
//! evaluate.rs as pure functions; everything with a side effect is here and
//! in run.rs, handle.rs, check.rs and deliver.rs.

use std::collections::{HashMap, HashSet};
use std::fmt;
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicI64};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::runtime::Handle;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::check::CheckResultShared;
use crate::deliver::{Channel, Console, Source, Triage};
use crate::env::environment;
use crate::error::Error;
use crate::evaluate::normalize_state;
use crate::js::{self, Object};
use crate::memory::MemoryStore;
use crate::options::{Deliver, DurationSpec, JobOptions, valid_name, validate_definition};
use crate::output::redact_secrets;
use crate::panics::panic_text;
use crate::run::{Job, StartCall};
use crate::schedule;
use crate::serialize::{ExpectRule, to_stored};
use crate::store::Store;
use crate::types::{Definition, JobState};

/// Reads and writes of one job's state before an update gives up on a store
/// that keeps changing under it.
const STATE_ATTEMPTS: u32 = 10;

/// The options `ClientBuilder::defaults` takes, as the SDK's defaults.
const DEFAULTABLE: [&str; 4] = ["grace", "timeout", "timezone", "failuresBeforeAlert"];

type ErrorHandler = Arc<dyn Fn(&Error, &str) + Send + Sync>;
type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;
type RedactFn = Arc<dyn Fn(&str) -> String + Send + Sync>;

/// How output and errors are redacted before they are stored.
#[derive(Clone)]
enum Redact {
    /// The SDK's patterns ([`redact_secrets`](crate::redact_secrets)).
    Default,
    Custom(RedactFn),
    Off,
}

/// Makes a [`Client`]. Every option has the SDK's default.
pub struct ClientBuilder {
    store: Option<Arc<dyn Store>>,
    alerts: Vec<Arc<dyn Channel>>,
    triage: Option<Arc<dyn Triage>>,
    sources: Vec<Arc<dyn Source>>,
    cron_secret: Option<Option<String>>,
    retention: DurationSpec,
    defaults: Option<JobOptions>,
    redact: Redact,
    deliver: Deliver,
    on_error: Option<ErrorHandler>,
    clock: Option<Clock>,
}

impl fmt::Debug for ClientBuilder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClientBuilder").finish_non_exhaustive()
    }
}

impl Default for ClientBuilder {
    fn default() -> Self {
        ClientBuilder {
            store: None,
            alerts: vec![Arc::new(Console)],
            triage: None,
            sources: Vec::new(),
            cron_secret: None,
            retention: DurationSpec::Text("30d".into()),
            defaults: None,
            redact: Redact::Default,
            deliver: Deliver::Now,
            on_error: None,
            clock: None,
        }
    }
}

impl ClientBuilder {
    /// Where jobs, runs and state live. The default is a [`MemoryStore`],
    /// which forgets on restart.
    pub fn store(mut self, store: impl Store) -> Self {
        self.store = Some(Arc::new(store));
        self
    }

    /// [`store`](Self::store) for a store already shared.
    pub fn store_arc(mut self, store: Arc<dyn Store>) -> Self {
        self.store = Some(store);
        self
    }

    /// Adds a channel alerts go to. The first call replaces the default
    /// console channel.
    pub fn alert(mut self, channel: Arc<dyn Channel>) -> Self {
        if self.alerts.len() == 1 && self.alerts[0].name() == "console" {
            self.alerts.clear();
        }
        self.alerts.push(channel);
        self
    }

    /// Where alerts go, replacing the default console channel. An empty list
    /// sends nowhere.
    pub fn alerts(mut self, channels: impl IntoIterator<Item = Arc<dyn Channel>>) -> Self {
        self.alerts = channels.into_iter().collect();
        self
    }

    /// Adds a short diagnosis to every alert except recoveries.
    pub fn triage(mut self, triage: Arc<dyn Triage>) -> Self {
        self.triage = Some(triage);
        self
    }

    /// Adds a source of runs this process does not wrap (the pg_cron
    /// source). Each is synced at the start of every check; one that fails is
    /// reported to the error handler and the check carries on.
    pub fn source(mut self, source: Arc<dyn Source>) -> Self {
        self.sources.push(source);
        self
    }

    /// The shared secret job handlers' requests must carry. The default is
    /// `$CRON_SECRET`; `""` counts as unset.
    pub fn cron_secret(mut self, secret: impl Into<String>) -> Self {
        self.cron_secret = Some(Some(secret.into()));
        self
    }

    /// Lets job handlers run without a secret.
    pub fn no_cron_secret(mut self) -> Self {
        self.cron_secret = Some(None);
        self
    }

    /// How long finished runs are kept. Default `"30d"`.
    pub fn retention(mut self, d: impl Into<DurationSpec>) -> Self {
        self.retention = d.into();
        self
    }

    /// Grace, timeout, timezone and failures before alert for every job that
    /// does not set its own. [`build`](Self::build) refuses any other option.
    pub fn defaults(mut self, defaults: JobOptions) -> Self {
        self.defaults = Some(defaults);
        self
    }

    /// Replaces the default redaction ([`redact_secrets`](crate::redact_secrets))
    /// of every run's output and error before it is stored, shown or sent
    /// anywhere. A redact function that panics is reported to the error
    /// handler and the default is used.
    pub fn redact(mut self, redact: impl Fn(&str) -> String + Send + Sync + 'static) -> Self {
        self.redact = Redact::Custom(Arc::new(redact));
        self
    }

    /// Keeps output and errors exactly as logged.
    pub fn no_redaction(mut self) -> Self {
        self.redact = Redact::Off;
        self
    }

    /// Where alerts are sent from: [`Deliver::Now`] (the default) or
    /// [`Deliver::AtCheck`].
    pub fn deliver(mut self, deliver: Deliver) -> Self {
        self.deliver = deliver;
        self
    }

    /// Called with anything that goes wrong outside a job: the store failing,
    /// an alert channel failing, a triage timeout. The second argument says
    /// what was being done (`recording nightly`, `alert channel slack`). The
    /// default writes to standard error.
    pub fn on_error(mut self, handler: impl Fn(&Error, &str) + Send + Sync + 'static) -> Self {
        self.on_error = Some(Arc::new(handler));
        self
    }

    /// Replaces the clock, in epoch milliseconds. Tests use it.
    pub fn clock(mut self, now: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.clock = Some(Arc::new(now));
        self
    }

    /// Makes the client. It must be called inside a tokio runtime, whose
    /// handle the client keeps for the tasks it spawns; a program with no
    /// runtime of its own uses the blocking client (the `blocking` feature).
    pub fn build(self) -> Result<Client, Error> {
        let handle = Handle::try_current().map_err(|_| {
            Error::Invalid(
                "Client::build needs a tokio runtime; outside one, use cronwatch::blocking::Client (the blocking feature)"
                    .into(),
            )
        })?;
        let mut defaults = Object::new();
        if let Some(options) = self.defaults {
            if let Some(key) = options.set.iter().find(|k| !DEFAULTABLE.contains(k)) {
                return Err(Error::Invalid(format!(
                    "defaults takes grace, timeout, timezone and failuresBeforeAlert, not {key}"
                )));
            }
            defaults = options.fields;
        }
        let retention_ms = schedule::parse_duration(&self.retention.to_value(), "retention").map_err(Error::Invalid)?;
        let default_store = self.store.is_none();
        let cron_secret = match self.cron_secret {
            Some(secret) => secret,
            None => std::env::var("CRON_SECRET").ok(),
        }
        .filter(|s| !s.is_empty());
        Ok(Client {
            inner: Arc::new(Inner {
                store: self.store.unwrap_or_else(|| Arc::new(MemoryStore::new())),
                default_store,
                alerts: self.alerts,
                triage: self.triage,
                sources: self.sources,
                cron_secret,
                retention_ms,
                defaults,
                redact: self.redact,
                defer_delivery: self.deliver == Deliver::AtCheck,
                on_error: self
                    .on_error
                    .unwrap_or_else(|| Arc::new(|err: &Error, where_: &str| eprintln!("[cronwatch] {where_}: {err}"))),
                now: self.clock.unwrap_or_else(|| {
                    Arc::new(|| SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64))
                }),
                handle,
                declared: Mutex::new(Declared::default()),
                job_locks: Mutex::new(HashMap::new()),
                ready: tokio::sync::Mutex::new(false),
                checking: Mutex::new(None),
                last_prune_at: AtomicI64::new(0),
                timer: Mutex::new(None),
                warned_deferred_start: AtomicBool::new(false),
            }),
        })
    }
}

/// A declared job: its stored definition, and the live expect rule the stored
/// one only describes.
#[derive(Debug)]
pub(crate) struct JobDef {
    pub name: String,
    pub stored: Definition,
    pub expect: Option<ExpectRule>,
}

#[derive(Default)]
pub(crate) struct Declared {
    /// Declared names, in the order first declared.
    pub order: Vec<String>,
    pub definitions: HashMap<String, Arc<JobDef>>,
    pub synced: HashSet<String>,
    /// Starts with an id still in flight, so two at once in this process
    /// record one run and get one handle.
    pub starting: HashMap<String, StartCall>,
}

pub(crate) struct Inner {
    pub store: Arc<dyn Store>,
    default_store: bool,
    pub alerts: Vec<Arc<dyn Channel>>,
    pub triage: Option<Arc<dyn Triage>>,
    pub sources: Vec<Arc<dyn Source>>,
    cron_secret: Option<String>,
    pub retention_ms: f64,
    defaults: Object,
    redact: Redact,
    pub defer_delivery: bool,
    on_error: ErrorHandler,
    now: Clock,
    pub handle: Handle,
    pub declared: Mutex<Declared>,
    job_locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    ready: tokio::sync::Mutex<bool>,
    pub checking: Mutex<Option<watch::Receiver<Option<CheckResultShared>>>>,
    pub last_prune_at: AtomicI64,
    pub timer: Mutex<Option<JoinHandle<()>>>,
    pub warned_deferred_start: AtomicBool,
}

/// Watches an app's jobs: it records their runs in a store, judges each one,
/// sends alerts, and runs the checks that find missed and stuck runs. One per
/// app, made once with [`Client::builder`]. A cheap handle (an `Arc`
/// inside): clone it into tasks and an app's state.
#[derive(Clone)]
pub struct Client {
    pub(crate) inner: Arc<Inner>,
}

impl fmt::Debug for Client {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Client").finish_non_exhaustive()
    }
}

/// A poisoned lock still holds whole data here: each critical section only
/// reads or replaces entries.
pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Client {
    /// A builder with the SDK's defaults: an in-memory store, alerts to the
    /// console.
    pub fn builder() -> ClientBuilder {
        ClientBuilder::default()
    }

    /// Where this client keeps jobs, runs and state.
    pub fn store(&self) -> &Arc<dyn Store> {
        &self.inner.store
    }

    /// The client's clock, in epoch milliseconds.
    pub fn now(&self) -> i64 {
        (self.inner.now)()
    }

    /// The secret job handlers' requests must carry, or `None`.
    pub fn cron_secret(&self) -> Option<&str> {
        self.inner.cron_secret.as_deref()
    }

    /// Hands an error to the client's error handler, as the client reports
    /// its own. A source uses it.
    pub fn report_error(&self, err: Error, where_: &str) {
        self.report(err, where_);
    }

    /// Calls the error handler, carrying on even when it panics.
    pub(crate) fn report(&self, err: Error, where_: &str) {
        let handler = self.inner.on_error.clone();
        let _ = catch_unwind(AssertUnwindSafe(|| handler(&err, where_)));
    }

    /// The client's redaction applied to a run's output or error.
    pub(crate) fn redact(&self, text: &str) -> String {
        match &self.inner.redact {
            Redact::Off => text.to_string(),
            Redact::Default => redact_secrets(text),
            Redact::Custom(f) => match catch_unwind(AssertUnwindSafe(|| f(text))) {
                Ok(out) => out,
                Err(panic) => {
                    // A broken redact must not stop the run finishing, nor leak
                    // what it was given.
                    self.report(Error::Other(format!("redact panicked: {}", panic_text(&*panic))), "redact");
                    redact_secrets(text)
                }
            },
        }
    }

    /// Declares a job and returns its handle. Call it once, at startup, and
    /// keep the handle. Declaring a name again replaces its definition.
    pub fn job(&self, name: &str, options: JobOptions) -> Result<Job, Error> {
        if !valid_name(name) {
            return Err(Error::Invalid(format!(
                "job name {} must be 1 to 120 characters of letters, digits, \".\", \"_\", \":\" or \"-\"",
                js::quote(name)
            )));
        }
        let mut fields = self.inner.defaults.clone();
        for (k, v) in options.fields.iter() {
            fields.set(k, v.clone());
        }
        fields.set("name", name);
        let def = Arc::new(JobDef {
            name: name.to_string(),
            stored: to_stored(&fields, options.expect.as_ref()),
            expect: options.expect,
        });
        validate_definition(name, &def.stored)?;
        let mut declared = lock(&self.inner.declared);
        if !declared.definitions.contains_key(name) {
            declared.order.push(name.to_string());
        }
        declared.definitions.insert(name.to_string(), def.clone());
        declared.synced.remove(name);
        drop(declared);
        Ok(Job { client: self.clone(), def })
    }

    /// The definitions declared in this process, in the order they were first
    /// declared.
    pub fn defined_jobs(&self) -> Vec<Definition> {
        let declared = lock(&self.inner.declared);
        declared.order.iter().map(|n| declared.definitions[n].stored.clone()).collect()
    }

    pub(crate) fn declared(&self, name: &str) -> Option<Arc<JobDef>> {
        lock(&self.inner.declared).definitions.get(name).cloned()
    }

    pub(crate) fn declared_all(&self) -> Vec<Arc<JobDef>> {
        let declared = lock(&self.inner.declared);
        declared.order.iter().map(|n| declared.definitions[n].clone()).collect()
    }

    /// Initializes the store once. One that fails is tried again on the next
    /// call rather than failing forever.
    pub(crate) async fn ensure_ready(&self) -> Result<(), Error> {
        let mut ready = self.inner.ready.lock().await;
        if *ready {
            return Ok(());
        }
        self.inner.store.init().await.map_err(Error::store)?;
        *ready = true;
        if self.inner.default_store && environment() == "production" {
            eprintln!(
                "[cronwatch] using the in-memory store: runs and state are lost on restart. Pass a store with ClientBuilder::store, such as cronwatch_sqlx::SqlStore over the app's database."
            );
        }
        Ok(())
    }

    /// Writes a declared definition to the store once per declaration.
    pub(crate) async fn sync(&self, def: &Arc<JobDef>) -> Result<(), Error> {
        self.ensure_ready().await?;
        let done = {
            let declared = lock(&self.inner.declared);
            declared.synced.contains(&def.name)
                && declared.definitions.get(&def.name).is_some_and(|d| Arc::ptr_eq(d, def))
        };
        if done {
            return Ok(());
        }
        self.inner.store.upsert_job(&def.stored, self.now()).await.map_err(Error::store)?;
        let mut declared = lock(&self.inner.declared);
        if declared.definitions.get(&def.name).is_some_and(|d| Arc::ptr_eq(d, def)) {
            declared.synced.insert(def.name.clone());
        }
        Ok(())
    }

    /// Writes the definition declared in this process under `name` to the
    /// store now, unless the store already holds that definition (whatever
    /// order its keys come back in), and says whether it wrote. A run or a
    /// check writes a declaration anyway, once; a scheduler integration calls
    /// this so a process that only schedules still puts its jobs where the
    /// processes that run and check them read them. A name not declared here
    /// is an error.
    pub async fn sync_job(&self, name: &str) -> Result<bool, Error> {
        let Some(def) = self.declared(name) else {
            return Err(Error::Invalid(format!("job {} is not declared in this process", js::quote(name))));
        };
        self.ensure_ready().await?;
        let stored = self.inner.store.get_job(name).await.map_err(Error::store)?;
        let write = stored.is_none_or(|s| !equal_json(&s.definition, &def.stored));
        if write {
            self.inner.store.upsert_job(&def.stored, self.now()).await.map_err(Error::store)?;
        }
        let mut declared = lock(&self.inner.declared);
        if declared.definitions.get(name).is_some_and(|d| Arc::ptr_eq(d, &def)) {
            declared.synced.insert(name.to_string());
        }
        Ok(write)
    }

    /// The lock every state update of a job in this process takes in turn
    /// (the SDK's `serial()`). Other processes are coordinated by
    /// `update_state`'s conditional writes instead.
    fn job_lock(&self, job: &str) -> Arc<tokio::sync::Mutex<()>> {
        lock(&self.inner.job_locks).entry(job.to_string()).or_default().clone()
    }

    pub(crate) async fn read_state(&self, job: &str) -> Result<JobState, Error> {
        let s = self.inner.store.get_state(job).await.map_err(Error::store)?;
        Ok(normalize_state(s.as_ref(), job))
    }

    /// Every read-modify-write of a job's state. In turn with this process's
    /// other updates to the job, it runs `prepare` once, reads the state, asks
    /// `change` for the next one, and writes it with the version one higher,
    /// only if the stored version is still the one read. When another process
    /// wrote in between, the write is refused and it starts again from a
    /// fresh read, up to `STATE_ATTEMPTS` times. So `change` may run more than
    /// once and must only compute: what it returns from the attempt that was
    /// written is the result. Nothing is written when the state is unchanged.
    /// Returns the state as stored.
    pub(crate) async fn update_state<P, R>(
        &self,
        job: &str,
        prepare: impl Future<Output = Result<P, Error>>,
        mut change: impl FnMut(JobState, &P) -> Result<(JobState, R), Error>,
    ) -> Result<(JobState, R), Error> {
        let job_lock = self.job_lock(job);
        let _turn = job_lock.lock().await;
        let prepared = prepare.await?;
        let mut attempt = 1;
        loop {
            let current = self.read_state(job).await?;
            let (mut next, result) = change(current.clone(), &prepared)?;
            if next.to_json() == current.to_json() {
                return Ok((current, result));
            }
            let version = current.version_or_zero();
            next.version = Some(version + 1);
            if self.write_state(&next, version).await? {
                return Ok((next, result));
            }
            if attempt >= STATE_ATTEMPTS {
                return Err(Error::Other(format!(
                    "the state of {job} changed under {STATE_ATTEMPTS} attempts in a row to update it; gave up"
                )));
            }
            attempt += 1;
        }
    }

    /// A conditional write, or for a store without `compare_and_set_state`,
    /// a plain one that always succeeds.
    async fn write_state(&self, state: &JobState, expected: i64) -> Result<bool, Error> {
        match self.inner.store.compare_and_set_state(state, expected).await {
            Err(err) if crate::store::is_unsupported(&err) => {
                self.inner.store.set_state(state).await.map_err(Error::store)?;
                Ok(true)
            }
            other => other.map_err(Error::store),
        }
    }

    /// Stops the interval [`start`](Self::start) began and closes the store.
    pub async fn close(&self) -> Result<(), Error> {
        self.stop();
        self.inner.store.close().await.map_err(Error::store)
    }
}

/// The definition these options give a job, before any client's defaults and
/// without checking them: what a source compares to tell whether a job it
/// declares has changed (the SDK compares the options object's JSON).
pub fn describe_job(name: &str, options: &JobOptions) -> Definition {
    let mut fields = options.fields.clone();
    fields.set("name", name);
    to_stored(&fields, options.expect.as_ref())
}

/// Whether two definitions write the same JSON, keys in any order (Postgres's
/// JSONB gives them back in an order of its own).
fn equal_json(a: &Definition, b: &Definition) -> bool {
    fn same(a: &js::Value, b: &js::Value) -> bool {
        match (a, b) {
            (js::Value::Object(x), js::Value::Object(y)) => {
                x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
            }
            (js::Value::Array(x), js::Value::Array(y)) => {
                x.len() == y.len() && x.iter().zip(y).all(|(v, w)| same(v, w))
            }
            (js::Value::Number(x), js::Value::Number(y)) => x == y,
            _ => a == b,
        }
    }
    same(&js::Value::Object(a.0.clone()), &js::Value::Object(b.0.clone()))
}

/// A random UUID (version 4), as `crypto.randomUUID()` makes one.
pub(crate) fn new_id() -> String {
    let mut b = [0u8; 16];
    if getrandom::fill(&mut b).is_err() {
        // No system randomness: fall back on the clock and a counter, which
        // keeps ids unique within the process.
        static COUNTER: AtomicI64 = AtomicI64::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let t = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos());
        b[..8].copy_from_slice(&(t as u64).to_le_bytes());
        b[8..].copy_from_slice(&n.to_le_bytes());
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let hex = b.iter().fold(String::new(), |mut out, x| {
        use std::fmt::Write;
        let _ = write!(out, "{x:02x}");
        out
    });
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// A whole number from `min` to 500.
pub(crate) fn clamp_limit(limit: usize, min: usize) -> usize {
    limit.clamp(min, 500)
}
