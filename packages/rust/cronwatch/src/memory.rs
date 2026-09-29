//! The in-memory store (stores/memory.ts).

use std::collections::HashMap;
use std::sync::Mutex;

use crate::store::{BoxError, BoxFuture, Store};
use crate::types::{Definition, JobState, Run, RunStatus, StoredJob};

/// Keeps everything in process memory (stores/memory.ts). The default when
/// no store is given, good for tests and for trying the library out. State
/// is gone on restart, so a missed run cannot be noticed across one.
#[derive(Debug, Default)]
pub struct MemoryStore {
    inner: Mutex<Inner>,
}

#[derive(Debug, Default)]
struct Inner {
    jobs: HashMap<String, StoredJob>,
    /// Each run and the order it was inserted in, which breaks ties between
    /// runs that started in the same millisecond.
    runs: HashMap<String, (Run, u64)>,
    states: HashMap<String, JobState>,
    seq: u64,
}

impl MemoryStore {
    /// An empty in-memory store.
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        // A panic while the lock was held leaves plain data behind, still whole.
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn sorted_runs(&self, keep: impl Fn(&Run) -> bool, newest_first: bool) -> Vec<Run> {
        let inner = self.lock();
        let mut out: Vec<(Run, u64)> = inner.runs.values().filter(|(r, _)| keep(r)).cloned().collect();
        out.sort_by(|(a, sa), (b, sb)| {
            let order = a.started_at.cmp(&b.started_at).then(sa.cmp(sb));
            if newest_first { order.reverse() } else { order }
        });
        out.into_iter().map(|(r, _)| r).collect()
    }
}

fn ready<T: Send + 'static>(value: T) -> BoxFuture<'static, Result<T, BoxError>> {
    Box::pin(std::future::ready(Ok(value)))
}

/// The fields a finish changes, written onto a stored run.
fn finish(existing: &Run, run: &Run) -> Run {
    Run {
        status: run.status.clone(),
        finished_at: run.finished_at,
        duration_ms: run.duration_ms,
        error: run.error.clone(),
        output: run.output.clone(),
        metrics: run.metrics.clone(),
        ..existing.clone()
    }
}

impl Store for MemoryStore {
    fn init(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        ready(())
    }

    fn close(&self) -> BoxFuture<'_, Result<(), BoxError>> {
        ready(())
    }

    fn upsert_job<'a>(&'a self, definition: &'a Definition, now: i64) -> BoxFuture<'a, Result<(), BoxError>> {
        let mut inner = self.lock();
        let name = definition.name().to_string();
        let created_at = inner.jobs.get(&name).map_or(now, |j| j.created_at);
        inner.jobs.insert(name.clone(), StoredJob { name, definition: definition.clone(), created_at, updated_at: now });
        ready(())
    }

    fn get_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<Option<StoredJob>, BoxError>> {
        ready(self.lock().jobs.get(name).cloned())
    }

    /// Every job by name in byte order, as the SQL stores sort.
    fn list_jobs(&self) -> BoxFuture<'_, Result<Vec<StoredJob>, BoxError>> {
        let mut out: Vec<StoredJob> = self.lock().jobs.values().cloned().collect();
        out.sort_by(|a, b| a.name.as_bytes().cmp(b.name.as_bytes()));
        ready(out)
    }

    fn delete_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<(), BoxError>> {
        let mut inner = self.lock();
        inner.jobs.remove(name);
        inner.states.remove(name);
        inner.runs.retain(|_, (r, _)| r.job != name);
        ready(())
    }

    /// Refuses an id already recorded, like SQL's primary key.
    fn insert_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        let mut inner = self.lock();
        if inner.runs.contains_key(&run.id) {
            let err: BoxError = format!("run {} already exists", run.id).into();
            return Box::pin(std::future::ready(Err(err)));
        }
        inner.seq += 1;
        let seq = inner.seq;
        inner.runs.insert(run.id.clone(), (run.clone(), seq));
        ready(())
    }

    /// Changes only the finish's fields; a run that is gone (its job was
    /// forgotten) stays gone, as SQL's `UPDATE` has it.
    fn update_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
        if let Some(entry) = self.lock().runs.get_mut(&run.id) {
            entry.0 = finish(&entry.0, run);
        }
        ready(())
    }

    fn update_run_if<'a>(&'a self, run: &'a Run, from: &'a [RunStatus]) -> BoxFuture<'a, Result<bool, BoxError>> {
        let mut inner = self.lock();
        let wrote = match inner.runs.get_mut(&run.id) {
            Some(entry) if from.contains(&entry.0.status) => {
                entry.0 = finish(&entry.0, run);
                true
            }
            _ => false,
        };
        ready(wrote)
    }

    fn delete_run_if<'a>(&'a self, id: &'a str, job: &'a str, status: &'a RunStatus) -> BoxFuture<'a, Result<bool, BoxError>> {
        let mut inner = self.lock();
        let matches = inner.runs.get(id).is_some_and(|(r, _)| r.job == job && &r.status == status);
        if matches {
            inner.runs.remove(id);
        }
        ready(matches)
    }

    fn get_run<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
        ready(self.lock().runs.get(id).map(|(r, _)| r.clone()))
    }

    fn list_runs<'a>(&'a self, job: &'a str, limit: usize) -> BoxFuture<'a, Result<Vec<Run>, BoxError>> {
        let mut out = self.sorted_runs(|r| r.job == job, true);
        out.truncate(limit);
        ready(out)
    }

    fn last_run<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
        ready(self.sorted_runs(|r| r.job == job, true).into_iter().next())
    }

    fn running_runs(&self) -> BoxFuture<'_, Result<Vec<Run>, BoxError>> {
        ready(self.sorted_runs(|r| r.status == RunStatus::Running, false))
    }

    fn get_state<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<JobState>, BoxError>> {
        ready(self.lock().states.get(job).cloned())
    }

    fn set_state<'a>(&'a self, state: &'a JobState) -> BoxFuture<'a, Result<(), BoxError>> {
        self.lock().states.insert(state.job.clone(), state.clone());
        ready(())
    }

    fn compare_and_set_state<'a>(&'a self, state: &'a JobState, expected: i64) -> BoxFuture<'a, Result<bool, BoxError>> {
        let mut inner = self.lock();
        let current = inner.states.get(&state.job).map_or(0, JobState::version_or_zero);
        if current != expected {
            return ready(false);
        }
        inner.states.insert(state.job.clone(), state.clone());
        ready(true)
    }

    /// Keeps each job's newest run whatever its age: without it, a job that
    /// runs less often than the retention looks like it never ran.
    fn prune(&self, before: i64) -> BoxFuture<'_, Result<u64, BoxError>> {
        let mut inner = self.lock();
        let mut newest: HashMap<String, i64> = HashMap::new();
        for (r, _) in inner.runs.values() {
            let at = newest.entry(r.job.clone()).or_insert(r.started_at);
            *at = (*at).max(r.started_at);
        }
        let before_count = inner.runs.len();
        inner.runs.retain(|_, (r, _)| {
            !(r.status != RunStatus::Running && r.started_at < before && r.started_at < newest[&r.job])
        });
        ready((before_count - inner.runs.len()) as u64)
    }
}
