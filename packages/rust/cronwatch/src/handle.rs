//! Runs that span calls (client.ts `start()`, `resume()` and the
//! `RunHandle`): a run recorded as running now and finished later, perhaps
//! by another process.

use std::any::Any;
use std::fmt;
use std::sync::{Arc, Mutex};

use tokio::sync::watch;

use crate::client::{Client, JobDef, lock, new_id};
use crate::error::Error;
use crate::evaluate::on_run_start;
use crate::js::{self, Value};
use crate::output::{self, OUTPUT_CAP, Recorder};
use crate::run::{Job, StartOptions, error_text, text_of};
use crate::types::{Metrics, Run, RunStatus};

/// Starts the run ids of the pg_cron source, so no other run may use it.
pub const RESERVED_RUN_ID_PREFIX: &str = "pgcron:";

/// The SDK's error for a run id no store could hold, or one reserved for the
/// pg_cron source.
fn check_run_id(job: &str, id: &str, method: &str) -> Result<(), Error> {
    let n = js::len16(id);
    if n == 0 || n > 200 {
        return Err(Error::Invalid(format!(
            "job {}: {method}() needs a run id of 1 to 200 characters (got {n} characters)",
            js::quote(job)
        )));
    }
    if id.starts_with(RESERVED_RUN_ID_PREFIX) {
        return Err(Error::Invalid(format!(
            "job {}: {method}() cannot take a run id starting with {}, which the pg_cron source uses for its runs",
            js::quote(job),
            js::quote(RESERVED_RUN_ID_PREFIX)
        )));
    }
    Ok(())
}

impl Job {
    /// Records a running run now, to finish later with the handle, perhaps
    /// from another process (see [`resume`](Self::resume)). Store failures go
    /// to the error handler; it returns an error only for an invalid run id
    /// or one that belongs to another job. A run that is never finished is
    /// marked stuck by the first check after the job's timeout.
    pub async fn start(&self, options: StartOptions) -> Result<RunHandle, Error> {
        let trigger = options.trigger.unwrap_or_else(|| "start".into());
        let (c, def) = (&self.client, &self.def);
        let Some(id) = options.id else {
            return c.record_start(def, trigger, None).await;
        };
        check_run_id(&def.name, &id, "start")?;
        // Keyed by job as well, so another job's start with the same id is
        // not handed this job's run: it fails as it would one call later.
        let key = format!("{}\n{id}", def.name);
        let (mut rx, tx) = {
            let mut declared = lock(&c.inner.declared);
            match declared.starting.get(&key) {
                Some(rx) => (rx.clone(), None),
                None => {
                    let (tx, rx) = watch::channel(None);
                    declared.starting.insert(key.clone(), rx.clone());
                    (rx, Some(tx))
                }
            }
        };
        if let Some(tx) = tx {
            // The start runs in a task of its own, so a caller that drops this
            // future part way still ends the call, and the starts of this id
            // waiting on it are not left waiting for good.
            let (client, def) = (c.clone(), def.clone());
            let task = c.inner.handle.spawn(async move { client.record_start(&def, trigger, Some(id)).await });
            let client = c.clone();
            let name = self.def.name.clone();
            c.inner.handle.spawn(async move {
                let result = task
                    .await
                    .unwrap_or_else(|_| Err(Error::Other(format!("starting a run of {} panicked", js::quote(&name)))));
                lock(&client.inner.declared).starting.remove(&key);
                let _ = tx.send(Some(result));
            });
        }
        let result = rx.wait_for(Option::is_some).await.map(|v| v.clone());
        match result {
            Ok(Some(result)) => result,
            _ => Err(Error::Other("the start ended before it could be read".into())),
        }
    }

    /// A handle on a run this job started elsewhere, by its id, so this
    /// process can log to it and finish it.
    pub async fn resume(&self, run_id: &str) -> Result<RunHandle, Error> {
        self.client.resume_handle(&self.def, run_id).await
    }
}

impl Client {
    /// [`Job::resume`] for a job declared in this process, by name.
    pub async fn resume_run(&self, name: &str, run_id: &str) -> Result<RunHandle, Error> {
        let Some(def) = self.declared(name) else {
            return Err(Error::Invalid(format!("resumeRun: job {} is not declared; call job first", js::quote(name))));
        };
        self.resume_handle(&def, run_id).await
    }

    /// The start of `execute` without the function: the run is inserted and
    /// missed and stuck close. A store that fails is reported and the handle
    /// inserts the finished run instead, as `execute` does.
    async fn record_start(&self, def: &Arc<JobDef>, trigger: String, id: Option<String>) -> Result<RunHandle, Error> {
        let name = &def.name;
        let has_id = id.is_some();
        if let Some(id) = &id {
            let stored = match self.ensure_ready().await {
                Ok(()) => self.inner.store.get_run(id).await.map_err(Error::store),
                Err(err) => Err(err),
            };
            match stored {
                Ok(Some(stored)) => return self.existing_handle(def, stored),
                Ok(None) => {}
                Err(err) => self.report(err, &format!("recording {name}")),
            }
        }
        let run = Run {
            id: id.unwrap_or_else(new_id),
            job: name.clone(),
            status: RunStatus::Running,
            started_at: self.now(),
            finished_at: None,
            duration_ms: None,
            error: None,
            output: None,
            metrics: Metrics::new(),
            trigger,
        };
        let inserted = match self.sync(def).await {
            Ok(()) => self.inner.store.insert_run(&run).await.map_err(Error::store),
            Err(err) => Err(err),
        };
        let recorded = match inserted {
            Ok(()) => true,
            Err(err) => {
                // Another process may have started a run with this id first.
                if has_id {
                    if let Ok(Some(stored)) = self.inner.store.get_run(&run.id).await {
                        return self.existing_handle(def, stored);
                    }
                }
                self.report(err, &format!("recording {name}"));
                false
            }
        };
        if recorded {
            if let Err(err) = self.update_state(name, async { Ok(()) }, |s, _| Ok((on_run_start(&s), ()))).await {
                self.report(err, &format!("starting {name}"));
            }
        }
        Ok(RunHandle::new(self, def, run.id.clone(), Some(run), recorded, None))
    }

    /// `Job::resume` and `Client::resume_run`. A store that cannot be read is
    /// reported, and `finish` reads it again.
    async fn resume_handle(&self, def: &Arc<JobDef>, run_id: &str) -> Result<RunHandle, Error> {
        check_run_id(&def.name, run_id, "resume")?;
        let stored = match self.ensure_ready().await {
            Ok(()) => self.inner.store.get_run(run_id).await.map_err(Error::store),
            Err(err) => Err(err),
        };
        match stored {
            Err(err) => {
                self.report(err, &format!("resuming {}", def.name));
                Ok(RunHandle::new(self, def, run_id.to_string(), None, true, None))
            }
            Ok(None) => Ok(RunHandle::new(self, def, run_id.to_string(), None, true, Some("was not found".into()))),
            Ok(Some(stored)) => self.existing_handle(def, stored),
        }
    }

    /// A handle on a stored run. One still running, or marked timeout by a
    /// check, can be finished.
    fn existing_handle(&self, def: &Arc<JobDef>, stored: Run) -> Result<RunHandle, Error> {
        if stored.job != def.name {
            return Err(Error::Invalid(format!(
                "run {} belongs to job {}, not {}",
                js::quote(&stored.id),
                js::quote(&stored.job),
                js::quote(&def.name)
            )));
        }
        let inactive = matches!(stored.status, RunStatus::Ok | RunStatus::Failed)
            .then(|| format!("already finished as {}", stored.status));
        Ok(RunHandle::new(self, def, stored.id.clone(), Some(stored), true, inactive))
    }
}

/// A run recorded by [`Job::start`] or found by [`Job::resume`], to finish
/// later. Lines and metrics wait in the handle until [`flush`](Self::flush)
/// or [`finish`](Self::finish) merges them onto a fresh read of the stored
/// run. Cheap to clone; every clone is the same handle. A handle dropped while
/// active records nothing: it is a handle to a run another call may finish,
/// and a run left unfinished is what the stuck check is for.
#[derive(Clone)]
pub struct RunHandle {
    inner: Arc<HandleInner>,
}

struct HandleInner {
    client: Client,
    def: Arc<JobDef>,
    id: String,
    base: Option<Run>,
    recorded: bool,
    /// Why `finish` has nothing to do, or `None`.
    inactive: Option<String>,
    /// Orders `flush` and `finish`, as the SDK's inTurn queue does.
    turn: tokio::sync::Mutex<()>,
    state: Mutex<HandleState>,
}

struct HandleState {
    rec: Arc<Recorder>,
    finished: bool,
    finish_called: bool,
    /// The first 16 KB of every line flushed from this handle, unredacted, or
    /// `None` before the first flush. The stored output keeps only the tail,
    /// so without it an expect rule at finish would miss a line logged early,
    /// which `run` would have seen.
    head: Option<String>,
}

impl fmt::Debug for RunHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RunHandle").field("id", &self.inner.id).field("job", &self.inner.def.name).finish()
    }
}

/// Two stretches of text as one, a line apart; either may be absent.
fn join_lines(before: Option<&str>, after: Option<String>) -> Option<String> {
    match (before.filter(|b| !b.is_empty()), after) {
        (None, after) => after,
        (Some(b), None) => Some(b.to_string()),
        (Some(b), Some(a)) => Some(format!("{b}\n{a}")),
    }
}

/// Output appended to stored output, capped like any run's.
fn join_output(before: Option<&str>, after: Option<String>) -> Option<String> {
    join_lines(before, after).map(|t| output::cap_output(&t))
}

fn recorder_metrics(rec: &Recorder) -> Metrics {
    Metrics::lenient(&Value::Object(rec.metrics()))
}

impl RunHandle {
    fn new(
        client: &Client,
        def: &Arc<JobDef>,
        id: String,
        base: Option<Run>,
        recorded: bool,
        inactive: Option<String>,
    ) -> RunHandle {
        let finished = inactive.is_some();
        RunHandle {
            inner: Arc::new(HandleInner {
                client: client.clone(),
                def: def.clone(),
                id,
                base,
                recorded,
                inactive,
                turn: tokio::sync::Mutex::new(()),
                state: Mutex::new(HandleState {
                    rec: Arc::new(Recorder::new()),
                    finished,
                    finish_called: false,
                    head: None,
                }),
            }),
        }
    }

    /// The run's id.
    pub fn id(&self) -> &str {
        &self.inner.id
    }

    /// The job's name.
    pub fn job(&self) -> &str {
        &self.inner.def.name
    }

    /// When the run started, in epoch milliseconds; `None` when a resumed run
    /// could not be read.
    pub fn started_at(&self) -> Option<i64> {
        self.inner.base.as_ref().map(|r| r.started_at)
    }

    /// False once finished, and from the start for a resumed run that already
    /// finished or does not exist.
    pub fn is_active(&self) -> bool {
        !lock(&self.inner.state).finished
    }

    /// Adds a line of output, kept in the handle until `flush` or `finish`.
    pub fn log(&self, line: impl fmt::Display) {
        let text = line.to_string();
        lock(&self.inner.state).rec.log(text);
    }

    /// Reports a number for this run. A later value for the same name replaces
    /// an earlier one.
    pub fn metric(&self, name: &str, value: f64) -> Result<(), Error> {
        lock(&self.inner.state).rec.metric(name, value).map_err(Error::Invalid)
    }

    fn ignored(&self, why: &str) {
        let name = &self.inner.def.name;
        self.inner.client.report(
            Error::Other(format!("run {} of {name} {why}; ignored", self.inner.id)),
            &format!("finishing {name}"),
        );
    }

    /// Appends the lines and metrics added so far to the stored run, which
    /// must still be running and belong to this job. A read, change and write
    /// of the run's row, written only while it is still running: two
    /// processes appending to one run at the same moment can lose one's
    /// lines, but a flush never undoes a finish. Problems go to the error
    /// handler.
    pub async fn flush(&self) {
        let h = &self.inner;
        let _turn = h.turn.lock().await;
        let (c, name) = (&h.client, &h.def.name);
        let (taken, lines, metrics) = {
            let mut state = lock(&h.state);
            if state.finished || !h.recorded {
                return;
            }
            let lines = state.rec.output();
            let metrics = recorder_metrics(&state.rec);
            if lines.is_none() && metrics.is_empty() {
                return;
            }
            // Lines logged while this waits on the store go to a new recorder.
            let taken = std::mem::replace(&mut state.rec, Arc::new(Recorder::new()));
            (taken, lines, metrics)
        };
        let put_back = || {
            let mut state = lock(&h.state);
            let later = std::mem::replace(&mut state.rec, Arc::new(Recorder::new()));
            for text in [taken.expect_text(), later.expect_text()].into_iter().flatten() {
                state.rec.log(text);
            }
            for (k, v) in recorder_metrics(&taken).merged(&recorder_metrics(&later)).iter() {
                let _ = state.rec.metric(k, v);
            }
        };
        let stored = match c.inner.store.get_run(&h.id).await {
            Ok(stored) => stored,
            Err(err) => {
                put_back();
                c.report(Error::store(err), &format!("flushing {name}"));
                return;
            }
        };
        // Not running: the lines stay here for finish, which reports why it
        // cannot record them.
        let Some(stored) = stored.filter(|s| s.status == RunStatus::Running) else {
            put_back();
            return;
        };
        if &stored.job != name {
            put_back();
            c.report(
                Error::Other(format!("run {} of {name} belongs to job {}; ignored", h.id, js::quote(&stored.job))),
                &format!("flushing {name}"),
            );
            return;
        }
        let mut next = stored.clone();
        if let Some(lines) = lines {
            next.output = join_output(stored.output.as_deref(), Some(output::strip_nul(&c.redact(&lines))));
        }
        next.metrics = stored.metrics.merged(&metrics);
        // Only over a row still running, so a flush never undoes a finish
        // written meanwhile.
        match c.write_run_if(&next, &[RunStatus::Running]).await {
            Err(err) => {
                put_back();
                c.report(err, &format!("flushing {name}"));
            }
            Ok(false) => put_back(),
            Ok(true) => {
                if let Some(text) = taken.expect_text() {
                    let mut state = lock(&h.state);
                    if state.head.as_deref().is_none_or(|head| js::len16(head) < OUTPUT_CAP) {
                        let joined = join_lines(state.head.as_deref(), Some(text)).unwrap_or_default();
                        state.head = Some(js::head16(&joined, OUTPUT_CAP));
                    }
                }
            }
        }
    }

    /// Finishes the run successfully (unless an expect rule says otherwise),
    /// judges it like any other and sends what that produces. Returns the run
    /// as recorded, or `None` when nothing was recorded: the run was already
    /// finished (here or elsewhere), was not found, or belongs to another
    /// job, which is reported to the error handler. When several processes
    /// finish one run, only the one whose write lands judges it. A store that
    /// fails is reported, nothing is recorded, and the handle stays active so
    /// `finish` can be called again.
    pub async fn finish(&self) -> Option<Run> {
        self.finish_inner(None, None).await
    }

    /// Finishes the run with a result, treated like the value a `run`
    /// function returns: a `String` or `&str` is the output when nothing was
    /// logged (and what an expect rule checks).
    pub async fn finish_with<T: Any + Send>(&self, result: T) -> Option<Run> {
        self.finish_inner(text_of(&result), None).await
    }

    /// Finishes the run as failed with `err`, written like an error a `run`
    /// function returned.
    pub async fn fail<E: fmt::Display + ?Sized>(&self, err: &E) -> Option<Run> {
        self.finish_inner(None, Some(error_text(err))).await
    }

    /// `fail` for an error already written out, with its type's name: the
    /// blocking client's.
    #[cfg(feature = "blocking")]
    pub(crate) async fn fail_named(&self, type_name: &str, message: &str) -> Option<Run> {
        self.finish_inner(None, Some(output::error_message(output::error_name(type_name), message, &[]))).await
    }

    async fn finish_inner(&self, result_text: Option<String>, failure: Option<String>) -> Option<Run> {
        let h = &self.inner;
        let was_inactive = {
            let mut state = lock(&h.state);
            if state.finish_called {
                drop(state);
                self.ignored("was already finished by this handle");
                return None;
            }
            state.finish_called = true;
            let was = state.finished;
            state.finished = true;
            was
        };
        // The store failed part way and nothing was recorded, so the handle
        // can be finished again.
        let retryable = |err: Error| {
            let mut state = lock(&h.state);
            state.finish_called = false;
            state.finished = false;
            drop(state);
            h.client.report(err, &format!("finishing {}", h.def.name));
            None
        };
        let _turn = h.turn.lock().await;
        let (c, name) = (&h.client, &h.def.name);
        if was_inactive {
            self.ignored(h.inactive.as_deref().unwrap_or("was already finished"));
            return None;
        }
        let mut from = h.base.clone();
        if h.recorded {
            match c.inner.store.get_run(&h.id).await {
                Err(err) => return retryable(Error::store(err)),
                Ok(Some(stored)) => from = Some(stored),
                Ok(None) => {}
            }
        }
        let Some(from) = from else {
            self.ignored("was not found");
            return None;
        };
        if &from.job != name {
            self.ignored(&format!("belongs to job {}", js::quote(&from.job)));
            return None;
        }
        if matches!(from.status, RunStatus::Ok | RunStatus::Failed) {
            self.ignored(&format!("was already finished as {}", from.status));
            return None;
        }
        let (rec, head) = {
            let state = lock(&h.state);
            (state.rec.clone(), state.head.clone())
        };
        let finished_at = c.now();
        let mut added = rec.output();
        if added.is_none() {
            added = result_text.as_deref().map(output::cap_output);
        }
        let mut run = from.clone();
        run.status = RunStatus::Running;
        run.finished_at = Some(finished_at);
        run.duration_ms = Some((finished_at - from.started_at).max(0));
        run.error = None;
        run.output = join_output(from.output.as_deref(), added);
        run.metrics = from.metrics.merged(&recorder_metrics(&rec));
        let expect_text = rec.expect_text().or(result_text);
        let expect_text = join_lines(head.as_deref(), join_lines(from.output.as_deref(), expect_text));
        c.conclude(&h.def, &mut run, failure, expect_text.as_deref());
        match c.record_finish(&h.def, &run, h.recorded, finished_at).await {
            Err(err) => retryable(err),
            Ok(Some(why)) => {
                self.ignored(&why);
                None
            }
            Ok(None) => Some(run),
        }
    }
}
