//! Watches pg_cron jobs, which run inside Postgres where nothing can wrap
//! them (sources/pgcron.ts, as the Go port has it line for line). As a
//! source, on every check it reads `cron.job` and declares each job with its
//! schedule, then copies new rows of `cron.job_run_details` in as runs (ids
//! `pgcron:<prefix><runid>`), so the usual evaluation raises missed, failed,
//! stuck and slow alerts.
//!
//! ```no_run
//! # async fn example(pool: sqlx::PgPool) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! use std::sync::Arc;
//! use cronwatch_sqlx::{PgCron, PgCronOptions, SqlStore};
//!
//! let source = PgCron::new(pool.clone(), PgCronOptions { prefix: "db:".into(), ..Default::default() });
//! let cw = cronwatch::Client::builder().store(SqlStore::postgres(pool)).source(Arc::new(source)).build()?;
//! cw.start_checking(std::time::Duration::from_secs(60));
//! # Ok(())
//! # }
//! ```
//!
//! A job that is renamed, unscheduled or no longer picked keeps its old
//! name's runs and history, and that name is declared again without a
//! schedule, so it is never reported missed. Its description says why.
//!
//! Settings are read from `pg_settings`, which answers no row for a setting
//! the role may not read, where `current_setting()` would raise an error;
//! the source runs each query on the pool on its own and never commits or
//! rolls back anything.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::time::Duration;

use cronwatch::js::Value;
use cronwatch::{
    Alert, BoxError, BoxFuture, Client, Definition, DurationSpec, JobOptions, Metrics, RecordOptions, Run, RunStatus,
    Source, describe_job,
};
use tokio::sync::Mutex;

use crate::rows::{Param, Row};

#[cfg(test)]
mod tests;

/// A row of `cron.job`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PgCronJob {
    pub job_id: i64,
    /// `None` for a job scheduled without a name.
    pub job_name: Option<String>,
    pub schedule: String,
    pub database: String,
    pub username: String,
    pub active: bool,
}

/// A row of `cron.job_run_details`, its times in epoch milliseconds.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PgCronRow {
    pub run_id: i64,
    pub job_id: i64,
    pub status: String,
    pub return_message: Option<String>,
    pub start_time: Option<i64>,
    pub end_time: Option<i64>,
}

/// Picks the jobs to watch.
pub type PickFn = Arc<dyn Fn(&PgCronJob) -> bool + Send + Sync>;
/// Names a job.
pub type NameFn = Arc<dyn Fn(&PgCronJob) -> String + Send + Sync>;
/// Gives a job its options.
pub type OptionsFn = Arc<dyn Fn(&PgCronJob) -> JobOptions + Send + Sync>;

/// What the source watches and how it names and judges it. Every field's
/// default is the SDK's.
#[derive(Clone, Default)]
pub struct PgCronOptions {
    /// The jobs to watch by name; with `job_ids`, only the jobs either
    /// names are watched. Both `None` (the default) is every job the role
    /// can see.
    pub jobs: Option<Vec<String>>,
    /// The jobs to watch by id.
    pub job_ids: Option<Vec<i64>>,
    /// Picks the jobs to watch with a function, in place of `jobs` and
    /// `job_ids`.
    pub pick: Option<PickFn>,
    /// Goes before every job name, to keep them apart from the app's own
    /// (`"db:"`). It also keeps run ids apart.
    pub prefix: String,
    /// The CronWatch name for a job. Default [`job_name`]: its jobname with
    /// anything other than letters, digits, `.`, `_`, `:` and `-` turned into
    /// `-`, or `pg_cron:<jobid>` when it has none. The prefix goes in front
    /// either way. One that panics, like a `pick` or `options_for` that
    /// panics, is reported once and fails only that job, which keeps its
    /// last declaration until the callback works again.
    pub job_name: Option<NameFn>,
    /// Job options (grace, timeout, max duration, expect and the rest) for
    /// every job; `options_for` gives them per job instead. The schedule and
    /// timezone always come from pg_cron.
    pub options: JobOptions,
    /// Job options per job.
    pub options_for: Option<OptionsFn>,
    /// The zone pg_cron reads its cron expressions in. Default the server's
    /// `cron.timezone`, read from `pg_settings`, which shows it only to roles
    /// with `pg_read_all_settings`; UTC (pg_cron's default) is assumed when it
    /// cannot be read.
    pub timezone: Option<String>,
}

impl fmt::Debug for PgCronOptions {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PgCronOptions")
            .field("jobs", &self.jobs)
            .field("job_ids", &self.job_ids)
            .field("prefix", &self.prefix)
            .field("options", &self.options)
            .field("timezone", &self.timezone)
            .finish_non_exhaustive()
    }
}

/// How many of a job's newest runs are copied, without alerting, the first
/// time it is seen.
const BACKFILL: usize = 20;
/// How many run details are read per query, and how many queries one sync
/// makes at most.
const PAGE: usize = 500;
const MAX_PAGES: usize = 10;

/// How long a run pg_cron has queued but not started (no start time yet) is
/// waited for. After that it is copied as running from when it was first
/// seen, so a run that never starts is marked stuck like any other.
pub const HOLD: Duration = Duration::from_secs(10 * 60);

const JOBS_SQL: &str = "SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid";
// pg_settings has no row for a setting the role may not read, where
// current_setting() raises an error that would abort the caller's
// transaction.
const SETTING_SQL: &str = "SELECT setting FROM pg_settings WHERE name = $1";
// Every tracked job's runs after its cursor, and any run still open here,
// whatever its job. The arrays are passed as array literals in text.
const RUNS_SQL: &str = "SELECT d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time
  FROM cron.job_run_details d
  LEFT JOIN unnest($1::text::bigint[], $2::text::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid
  WHERE d.runid > c.after OR d.runid = ANY($3::text::bigint[])
  ORDER BY d.runid LIMIT 500";
const NEWEST_SQL: &str = "SELECT d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time FROM cron.job_run_details d WHERE d.jobid = $1 ORDER BY d.runid DESC LIMIT 20";

/// JavaScript's `\s`, and what `String.prototype.trim` takes off.
fn js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}'
    )
}

fn js_trim(s: &str) -> &str {
    s.trim_matches(js_space)
}

fn finished(status: &str) -> bool {
    status == "succeeded" || status == "failed"
}

/// A pg_cron schedule as a CronWatch one: a cron expression, `$` for the
/// last day of the month read as `L`, or `N seconds` as `every Ns`. pg_cron
/// reads only the first five fields of an expression and ignores the rest,
/// so only those are kept (a sixth would otherwise be read as seconds).
/// `None` for one that has no cadence to watch (`@reboot`).
pub fn schedule(schedule: &str) -> Option<String> {
    let text = js_trim(schedule);
    // /^(\d+)\s*seconds?$/i
    let digits = text.bytes().take_while(u8::is_ascii_digit).count();
    if digits > 0 {
        let rest = text[digits..].trim_start_matches(js_space).to_ascii_lowercase();
        if rest == "second" || rest == "seconds" {
            let n: f64 = text[..digits].parse().unwrap_or(0.0);
            return Some(format!("every {}s", Value::Number(n).to_json()));
        }
    }
    if text.eq_ignore_ascii_case("@reboot") {
        return None;
    }
    let mut fields: Vec<String> = if text.is_empty() {
        vec![String::new()]
    } else {
        text.split(js_space).filter(|f| !f.is_empty()).map(str::to_string).collect()
    };
    if fields.len() > 5 && !fields[0].starts_with('@') {
        fields.truncate(5);
    }
    if fields.len() == 5 && fields[2].contains('$') {
        fields[2] = fields[2].replace('$', "L");
    }
    Some(fields.join(" "))
}

/// The default CronWatch name for a pg_cron job, before the prefix.
pub fn job_name(job: &PgCronJob) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-');
    let mut cleaned = String::new();
    let mut in_run = false;
    for c in job.job_name.as_deref().unwrap_or("").chars() {
        if safe(c) {
            cleaned.push(c);
            in_run = false;
        } else if !in_run {
            cleaned.push('-');
            in_run = true;
        }
    }
    // Every character left is ASCII, so bytes are UTF-16 units.
    let cleaned: String = cleaned.trim_start_matches(|c: char| !c.is_ascii_alphanumeric()).chars().take(100).collect();
    if cleaned.is_empty() { format!("pg_cron:{}", job.job_id) } else { cleaned }
}

/// A row of `cron.job_run_details` as a CronWatch run, or `None` for one
/// that has not started (no start time, not finished). A finished row with
/// no start time (pg_cron writes these for runs a server restart cut off,
/// "server restarted") starts at its end time, else at `fallback_at` (the
/// reader passes the job's newest run's start, or now).
pub fn run_of(row: &PgCronRow, job: &str, id_prefix: &str, fallback_at: i64) -> Option<Run> {
    let done = finished(&row.status);
    if row.start_time.is_none() && !done {
        return None;
    }
    let started_at = row.start_time.or(row.end_time).unwrap_or(fallback_at);
    let message = row.return_message.as_deref().map(js_trim).filter(|m| !m.is_empty()).map(str::to_string);
    let status = match row.status.as_str() {
        "succeeded" => RunStatus::Ok,
        "failed" => RunStatus::Failed,
        _ => RunStatus::Running,
    };
    let end = done.then(|| started_at.max(row.end_time.unwrap_or(started_at)));
    Some(Run {
        id: format!("{id_prefix}{}", row.run_id),
        job: job.to_string(),
        error: (status == RunStatus::Failed)
            .then(|| message.clone().unwrap_or_else(|| "pg_cron reported the run as failed".into())),
        output: if status == RunStatus::Ok { message } else { None },
        status,
        started_at,
        finished_at: end,
        duration_ms: end.map(|e| cronwatch::run_duration(started_at, e)),
        metrics: Metrics::new(),
        trigger: "pg_cron".into(),
    })
}

/// What the source reads through: the app's pool, or a fake in the tests.
pub(crate) trait Reader: Send + Sync + 'static {
    fn query<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<Vec<Row>, BoxError>>;
}

impl Reader for sqlx::PgPool {
    fn query<'a>(&'a self, sql: &'a str, params: Vec<Param>) -> BoxFuture<'a, Result<Vec<Row>, BoxError>> {
        Box::pin(async move {
            let args = crate::rows::pg_arguments(params)?;
            sqlx::query_with(sqlx::AssertSqlSafe(sql.to_string()), args)
                .fetch_all(self)
                .await?
                .iter()
                .map(crate::rows::pg_row)
                .collect()
        })
    }
}

fn job_of(r: &Row) -> PgCronJob {
    PgCronJob {
        job_id: r.int("jobid").unwrap_or(0),
        job_name: r.text("jobname"),
        schedule: r.text("schedule").unwrap_or_default(),
        database: r.text("database").unwrap_or_default(),
        username: r.text("username").unwrap_or_default(),
        active: r.boolean("active"),
    }
}

fn row_of(r: &Row) -> PgCronRow {
    PgCronRow {
        run_id: r.int("runid").unwrap_or(0),
        job_id: r.int("jobid").unwrap_or(0),
        status: r.text("status").unwrap_or_default(),
        return_message: r.text("return_message"),
        start_time: r.time("start_time"),
        end_time: r.time("end_time"),
    }
}

/// A Postgres array literal, `{1,2,3}`.
fn array_of(ids: impl IntoIterator<Item = i64>) -> String {
    let parts: Vec<String> = ids.into_iter().map(|id| id.to_string()).collect();
    format!("{{{}}}", parts.join(","))
}

/// The options of a declared definition that can be declared again, without
/// its schedule.
fn unscheduled(def: &Definition) -> JobOptions {
    let mut out = JobOptions::new();
    if let Some(Value::String(d)) = def.get("description") {
        out = out.description(d.clone());
    }
    if let Some(v) = def.get("tags") {
        let tags: Vec<String> =
            v.as_array().into_iter().flatten().filter_map(|t| t.as_str().map(str::to_string)).collect();
        out = out.tags(tags);
    }
    let duration = |v: Option<&Value>| -> Option<DurationSpec> {
        match v? {
            Value::String(s) => Some(DurationSpec::Text(s.clone())),
            Value::Number(n) => Some(DurationSpec::Millis(*n)),
            _ => None,
        }
    };
    if let Some(d) = duration(def.get("grace")) {
        out = out.grace(d);
    }
    if let Some(d) = duration(def.get("timeout")) {
        out = out.timeout(d);
    }
    if let Some(d) = duration(def.get("maxDuration")) {
        out = out.max_duration(d);
    }
    if let Some(Value::Object(budget)) = def.get("budget") {
        for (metric, ceiling) in budget.iter() {
            if let Some(n) = ceiling.as_f64() {
                out = out.budget(metric, n);
            }
        }
    }
    if let Some(n) = def.get("failuresBeforeAlert").and_then(Value::as_f64) {
        out = out.failures_before_alert(n as u32);
    }
    out
}

fn key_of(def: &Definition) -> String {
    def.to_json()
}

/// Calls one of the app's callbacks; a panic is the error, naming it.
fn guarded<T>(what: &str, f: impl FnOnce() -> T) -> Result<T, String> {
    catch_unwind(AssertUnwindSafe(f)).map_err(|panic| {
        let text = panic
            .downcast_ref::<&str>()
            .map(|s| (*s).to_string())
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "a panic without a message".into());
        format!("{what} panicked: {text}")
    })
}

/// Where the source is between syncs.
#[derive(Default)]
struct State {
    /// The newest runid read for each jobid, once known.
    cursors: HashMap<i64, i64>,
    /// The start of the newest run copied for each jobid: where a restart
    /// row with no times is put.
    last_at: HashMap<i64, i64>,
    /// Runs copied while still going, by runid, with their job: read again
    /// until they finish, even once a check marks them timeout.
    pending: HashMap<i64, String>,
    /// Runs read before they started, by runid, with when they were first
    /// seen.
    held: HashMap<i64, i64>,
    /// Each job's name and definition as last declared, by jobid.
    known: HashMap<i64, (String, Definition)>,
    /// The last definition declared for each name, so an unchanged job is
    /// not declared again.
    declared_keys: HashMap<String, String>,
    /// Names declared again without a schedule, whose open runs are still
    /// read.
    retired: HashSet<String>,
    scanned: bool,
    warned: HashSet<&'static str>,
    /// Jobids whose callback panicked, reported once until it works again.
    failing: HashSet<i64>,
}

/// The pg_cron source. Hand it to [`cronwatch::ClientBuilder::source`].
pub struct PgCron {
    db: Box<dyn Reader>,
    o: PgCronOptions,
    id_prefix: String,
    state: Mutex<State>,
}

impl fmt::Debug for PgCron {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PgCron").field("options", &self.o).finish_non_exhaustive()
    }
}

impl PgCron {
    /// A pg_cron source reading through the app's pool, on the database
    /// pg_cron runs in (its `cron.database_name`).
    pub fn new(pool: sqlx::PgPool, options: PgCronOptions) -> PgCron {
        PgCron::with_reader(pool, options)
    }

    pub(crate) fn with_reader(db: impl Reader, options: PgCronOptions) -> PgCron {
        PgCron {
            db: Box::new(db),
            id_prefix: format!("pgcron:{}", options.prefix),
            o: options,
            state: Mutex::new(State::default()),
        }
    }

    fn warn_once(&self, st: &mut State, host: &Client, key: &'static str, message: &str) {
        if st.warned.insert(key) {
            host.report_error(cronwatch::Error::Other(message.to_string()), "source pg_cron");
        }
    }

    fn picks(&self, j: &PgCronJob) -> bool {
        if let Some(pick) = &self.o.pick {
            return pick(j);
        }
        if self.o.jobs.is_none() && self.o.job_ids.is_none() {
            return true;
        }
        self.o.job_ids.iter().flatten().any(|id| *id == j.job_id)
            || self.o.jobs.iter().flatten().any(|name| j.job_name.as_deref() == Some(name.as_str()))
    }

    /// Asks the app's callbacks about a job: `None` when it is not picked,
    /// else its name before the prefix and its options. A callback that
    /// panics is the error, saying which.
    fn ask(&self, j: &PgCronJob) -> Result<Option<(String, JobOptions)>, String> {
        if !guarded("the jobs callback", || self.picks(j))? {
            return Ok(None);
        }
        let base = match &self.o.job_name {
            Some(f) => guarded("job_name", || f(j))?,
            None => job_name(j),
        };
        let extra = match &self.o.options_for {
            Some(f) => guarded("the options callback", || f(j))?,
            None => self.o.options.clone(),
        };
        Ok(Some((base, extra)))
    }

    /// A server setting from `pg_settings`, or `None` when the role may not
    /// read it (or the read failed).
    async fn setting(&self, name: &str) -> Option<String> {
        let rows = self.db.query(SETTING_SQL, vec![Param::Text(name.into())]).await.ok()?;
        rows.first().and_then(|r| r.text("setting"))
    }

    /// The pg_cron runid of a run id this source made, or `None`.
    fn run_id_of(&self, id: &str) -> Option<i64> {
        let rest = js_trim(id.strip_prefix(&self.id_prefix)?);
        // Number(rest): "" is 0, spaces around it are dropped.
        if rest.is_empty() {
            return Some(0);
        }
        let n: f64 = rest.parse().ok()?;
        (n.is_finite() && n == n.trunc() && n.abs() <= 9_007_199_254_740_991.0).then_some(n as i64)
    }

    /// Declares a name this source no longer uses for any job again, without
    /// its schedule.
    fn retire(&self, st: &mut State, host: &Client, name: &str, def: &Definition, why: &str) {
        let description = match def.get("description") {
            Some(Value::String(d)) => d.clone(),
            _ => "pg_cron job".into(),
        };
        let options = unscheduled(def).description(format!("{description} ({why})"));
        let key = key_of(&describe_job(name, &options));
        if let Err(err) = host.job(name, options) {
            host.report_error(err, &format!("source pg_cron: job {name}"));
            return;
        }
        st.declared_keys.insert(name.to_string(), key);
        st.retired.insert(name.to_string());
    }

    /// Copies one row. A row that cannot be recorded is reported and skipped;
    /// it never stops the others.
    #[allow(clippy::too_many_arguments)]
    async fn record(
        &self,
        st: &mut State,
        host: &Client,
        names: &HashMap<i64, String>,
        mut row: PgCronRow,
        evaluate: bool,
        now: i64,
        alerts: &mut Vec<Alert>,
    ) {
        let Some(name) = st.pending.get(&row.run_id).or_else(|| names.get(&row.job_id)).cloned() else {
            st.held.remove(&row.run_id);
            return;
        };
        let run = if row.start_time.is_none() && !finished(&row.status) {
            let since = st.held.get(&row.run_id).copied().unwrap_or(now);
            if now - since < HOLD.as_millis() as i64 {
                st.held.insert(row.run_id, since);
                return;
            }
            row.start_time = Some(since);
            run_of(&row, &name, &self.id_prefix, now)
        } else {
            let fallback = st.last_at.get(&row.job_id).copied().unwrap_or(now);
            run_of(&row, &name, &self.id_prefix, fallback)
        };
        st.held.remove(&row.run_id);
        let Some(run) = run else { return };
        let options = if evaluate { RecordOptions::new() } else { RecordOptions::new().without_evaluation() };
        let (status, started_at) = (run.status.clone(), run.started_at);
        match host.record_run(run, options).await {
            Err(err) => {
                host.report_error(err, &format!("source pg_cron: run {}", row.run_id));
                return;
            }
            Ok(sent) => alerts.extend(sent),
        }
        if status == RunStatus::Running {
            st.pending.insert(row.run_id, name);
        } else {
            st.pending.remove(&row.run_id);
        }
        let last = st.last_at.entry(row.job_id).or_insert(started_at);
        *last = (*last).max(started_at);
    }

    async fn sync_with(&self, host: &Client) -> Result<Vec<Alert>, BoxError> {
        let mut guard = self.state.lock().await;
        let st = &mut *guard;
        let now = host.now();
        let timezone = match self.o.timezone.as_deref().filter(|t| !t.is_empty()) {
            Some(tz) => tz.to_string(),
            None => {
                let tz = self.setting("cron.timezone").await;
                if tz.is_none() {
                    self.warn_once(
                        st,
                        host,
                        "tz",
                        "could not read cron.timezone; assuming UTC. Grant pg_read_all_settings or set PgCronOptions::timezone.",
                    );
                }
                match tz {
                    Some(tz) if !["gmt", "utc", "z"].contains(&tz.to_ascii_lowercase().as_str()) => tz,
                    _ => "UTC".into(),
                }
            }
        };
        let recording = self.setting("cron.log_run").await.is_none_or(|v| v != "off");
        if !recording {
            self.warn_once(
                st,
                host,
                "log_run",
                "cron.log_run is off, so pg_cron records no runs: jobs are watched without their schedules and no run can fail. Turn it on to watch them.",
            );
        }

        let rows = self.db.query(JOBS_SQL, Vec::new()).await?;
        if rows.is_empty() {
            self.warn_once(
                st,
                host,
                "empty",
                "cron.job shows no jobs. pg_cron's row level security shows a role only the jobs it scheduled: connect as that role, or give this one BYPASSRLS.",
            );
        }
        let all: Vec<PgCronJob> = rows.iter().map(job_of).collect();

        // Declare each job. A paused one (active = false) keeps its failures
        // but loses its schedule, so it is not missed. One forgotten since it
        // was declared (the dashboard's forget) is declared again, though
        // unchanged: record_run takes runs only of a declared job.
        let live: HashSet<String> = host.defined_jobs().iter().map(|d| d.name().to_string()).collect();
        let mut order: Vec<i64> = Vec::new();
        let mut names: HashMap<i64, String> = HashMap::new();
        let mut definitions: HashMap<i64, Definition> = HashMap::new();
        let mut used: HashSet<String> = HashSet::new();
        for j in &all {
            let (base, extra) = match self.ask(j) {
                Ok(Some(asked)) => {
                    st.failing.remove(&j.job_id);
                    asked
                }
                Ok(None) => {
                    st.failing.remove(&j.job_id);
                    continue;
                }
                // A callback of the app's that panicked fails only its job,
                // as a bad row does: reported once until it works again, and
                // the job carries on as last declared (skipped when it never
                // was), so its runs are still copied.
                Err(what) => {
                    if st.failing.insert(j.job_id) {
                        host.report_error(
                            cronwatch::Error::Other(format!(
                                "pg_cron job {}: {what}; it keeps its last declaration until that works",
                                j.job_id
                            )),
                            "source pg_cron",
                        );
                    }
                    if let Some((last, def)) = st.known.get(&j.job_id).cloned()
                        && used.insert(last.clone())
                    {
                        order.push(j.job_id);
                        names.insert(j.job_id, last);
                        definitions.insert(j.job_id, def);
                    }
                    continue;
                }
            };
            let mut name = format!("{}{base}", self.o.prefix);
            if used.contains(&name) {
                name = format!("{name}:{}", j.job_id);
            }
            used.insert(name.clone());
            let sched = if j.active && recording { schedule(&j.schedule) } else { None };
            let paused = if j.active { "" } else { " (paused)" };
            let base_options = JobOptions::new()
                .description(format!("pg_cron job {} in {} as {}{paused}", j.job_id, j.database, j.username))
                .tags(["pg_cron"])
                .merge(extra);
            let unscheduled_options = base_options.clone();
            let options = match &sched {
                Some(s) => base_options.schedule(s.clone()).timezone(timezone.clone()),
                None => base_options,
            };
            let mut definition = describe_job(&name, &options);
            let key = key_of(&definition);
            if st.declared_keys.get(&name) != Some(&key) || !live.contains(&name) {
                if let Err(err) = host.job(&name, options) {
                    if sched.is_none() {
                        host.report_error(err, &format!("source pg_cron: job {}", j.job_id));
                        continue;
                    }
                    // A schedule CronWatch cannot read: watch the runs, not
                    // the cadence.
                    host.report_error(
                        cronwatch::Error::Other(format!(
                            "pg_cron job {}: {err}; watching it without a schedule",
                            j.job_id
                        )),
                        "source pg_cron",
                    );
                    definition = describe_job(&name, &unscheduled_options);
                    if let Err(err) = host.job(&name, unscheduled_options) {
                        host.report_error(err, &format!("source pg_cron: job {}", j.job_id));
                        continue;
                    }
                }
                st.declared_keys.insert(name.clone(), key);
            }
            order.push(j.job_id);
            names.insert(j.job_id, name);
            definitions.insert(j.job_id, definition);
        }

        // A name this source used for a job that has since been renamed,
        // unscheduled or dropped from the jobs picked.
        let in_use: HashSet<String> = names.values().cloned().collect();
        for name in &in_use {
            st.retired.remove(name);
        }
        let known: Vec<(i64, (String, Definition))> = {
            let mut list: Vec<_> = st.known.iter().map(|(k, v)| (*k, v.clone())).collect();
            list.sort_by_key(|(k, _)| *k);
            list
        };
        for (jobid, (previous, def)) in known {
            if in_use.contains(&previous) {
                continue;
            }
            let why = match names.get(&jobid) {
                Some(renamed) => format!("renamed to {renamed}"),
                None => "no longer watched".into(),
            };
            self.retire(st, host, &previous, &def, &why);
        }
        st.known = names.iter().map(|(jobid, name)| (*jobid, (name.clone(), definitions[jobid].clone()))).collect();
        // Once per process, the same for names left scheduled in the store
        // while no process was watching.
        if !st.scanned && !rows.is_empty() {
            st.scanned = true;
            let visible: HashSet<i64> = all.iter().map(|j| j.job_id).collect();
            let stored = match host.store().list_jobs().await {
                Ok(list) => list,
                Err(err) => {
                    host.report_error(cronwatch::Error::Other(err.to_string()), "source pg_cron");
                    Vec::new()
                }
            };
            for job in stored {
                let def = &job.definition;
                if !job.name.starts_with(&self.o.prefix)
                    || in_use.contains(&job.name)
                    || def.schedule().is_empty()
                    || !def.tags().iter().any(|t| t == "pg_cron")
                {
                    continue;
                }
                let Some(jobid) = description_job_id(def.description()) else {
                    continue;
                };
                match names.get(&jobid) {
                    _ if !visible.contains(&jobid) => self.retire(st, host, &job.name, def, "no longer in cron.job"),
                    // Another pg_cron source's name for the same job ends the
                    // same way: that one is left alone.
                    Some(current) if !job.name.ends_with(&current[self.o.prefix.len()..]) => {
                        let why = format!("renamed to {current}");
                        self.retire(st, host, &job.name, def, &why);
                    }
                    _ => {}
                }
            }
        }
        if !recording || names.is_empty() {
            return Ok(Vec::new());
        }

        let mut alerts = Vec::new();

        // Where each job left off. Found from the store the first time, so a
        // restart carries on.
        for &jobid in &order {
            let name = names[&jobid].clone();
            if st.cursors.contains_key(&jobid) {
                continue;
            }
            let runs = host.store().list_runs(&name, BACKFILL).await?;
            let ours: Vec<(i64, &Run)> = runs.iter().filter_map(|r| self.run_id_of(&r.id).map(|id| (id, r))).collect();
            if !ours.is_empty() {
                let (mut cursor, mut last) = (i64::MIN, i64::MIN);
                for (id, r) in ours {
                    cursor = cursor.max(id);
                    last = last.max(r.started_at);
                    if r.status == RunStatus::Running || r.status == RunStatus::Timeout {
                        st.pending.insert(id, r.job.clone());
                    }
                }
                st.cursors.insert(jobid, cursor);
                st.last_at.insert(jobid, last);
                continue;
            }
            // First sight: copy recent history quietly, and judge only from
            // the newest finished run on. The cursor goes to the newest row
            // read, whatever is held, so history is never judged later.
            let found = self.db.query(NEWEST_SQL, vec![Param::Int(jobid)]).await?;
            let ordered: Vec<PgCronRow> = found.iter().rev().map(row_of).collect();
            let last_finished = ordered.iter().rposition(|r| finished(&r.status));
            for (i, row) in ordered.iter().enumerate() {
                // Already copied under another name (the job was renamed while
                // no process watched): left there.
                if host.store().get_run(&format!("{}{}", self.id_prefix, row.run_id)).await?.is_some() {
                    continue;
                }
                let evaluate = last_finished.is_none_or(|lf| i >= lf);
                self.record(st, host, &names, row.clone(), evaluate, now, &mut alerts).await;
            }
            st.cursors.insert(jobid, ordered.last().map_or(0, |r| r.run_id));
        }

        // New runs, runs copied while still going (or since marked timeout),
        // and runs not yet started.
        let mut watched: HashSet<String> = names.values().cloned().collect();
        watched.extend(st.retired.iter().cloned());
        for r in host.store().running_runs().await? {
            if let Some(id) = self.run_id_of(&r.id)
                && watched.contains(&r.job)
            {
                st.pending.insert(id, r.job.clone());
            }
        }
        let mut open: BTreeSet<i64> = st.pending.keys().copied().collect();
        open.extend(st.held.keys().copied());
        let mut complete = false;
        for _ in 0..MAX_PAGES {
            let afters: Vec<i64> = order.iter().map(|j| st.cursors.get(j).copied().unwrap_or(0)).collect();
            let params = vec![
                Param::Text(array_of(order.iter().copied())),
                Param::Text(array_of(afters)),
                Param::Text(array_of(open.iter().copied())),
            ];
            let found = self.db.query(RUNS_SQL, params).await?;
            let count = found.len();
            for r in &found {
                let row = row_of(r);
                open.remove(&row.run_id);
                let (run_id, job_id) = (row.run_id, row.job_id);
                self.record(st, host, &names, row, true, now, &mut alerts).await;
                // Held or not, the cursor moves on: a held run is read again
                // by its runid.
                if names.contains_key(&job_id) && run_id > st.cursors.get(&job_id).copied().unwrap_or(0) {
                    st.cursors.insert(job_id, run_id);
                }
            }
            if count < PAGE {
                complete = true;
                break;
            }
        }
        // Every row was read and these were not among them: pg_cron no longer
        // has them.
        if complete {
            for id in open {
                st.pending.remove(&id);
                st.held.remove(&id);
            }
        }
        Ok(alerts)
    }
}

/// The jobid a description this source wrote names (`pg_cron job 7 in ...`).
fn description_job_id(description: &str) -> Option<i64> {
    let rest = description.strip_prefix("pg_cron job ")?;
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    if digits == 0 || !rest[digits..].starts_with(" in ") {
        return None;
    }
    rest[..digits].parse().ok()
}

impl Source for PgCron {
    /// `"pg_cron"`.
    fn name(&self) -> &str {
        "pg_cron"
    }

    /// Declares the jobs and copies their new runs in, returning the alerts
    /// recording them sent.
    fn sync<'a>(&'a self, host: &'a Client) -> BoxFuture<'a, Result<Vec<Alert>, BoxError>> {
        Box::pin(self.sync_with(host))
    }
}
