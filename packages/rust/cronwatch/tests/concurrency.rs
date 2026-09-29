//! concurrency.test.ts, on the memory store, as the Go port has it; and the
//! interval `start` runs. The SQLite case is `cronwatch-sqlx`'s.

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use common::{Boom, Kit, TestStore};
use cronwatch::{Condition, JobOptions, JobState, MemoryStore, RunStatus, Store};

/// A store whose state reads take a while, as over a network: two processes
/// reading at about the same time both get the old state before either
/// writes.
fn slow_reads(inner: &Arc<MemoryStore>, no_cas: bool) -> Arc<SharedStore> {
    Arc::new(SharedStore { inner: inner.clone(), no_cas })
}

/// A second view of one memory store, with slow state reads, standing for
/// another process.
struct SharedStore {
    inner: Arc<MemoryStore>,
    no_cas: bool,
}

impl Store for SharedStore {
    fn init(&self) -> cronwatch::BoxFuture<'_, Result<(), cronwatch::BoxError>> {
        self.inner.init()
    }
    fn upsert_job<'a>(
        &'a self,
        d: &'a cronwatch::Definition,
        now: i64,
    ) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
        self.inner.upsert_job(d, now)
    }
    fn get_job<'a>(
        &'a self,
        name: &'a str,
    ) -> cronwatch::BoxFuture<'a, Result<Option<cronwatch::StoredJob>, cronwatch::BoxError>> {
        self.inner.get_job(name)
    }
    fn list_jobs(&self) -> cronwatch::BoxFuture<'_, Result<Vec<cronwatch::StoredJob>, cronwatch::BoxError>> {
        self.inner.list_jobs()
    }
    fn delete_job<'a>(&'a self, name: &'a str) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
        self.inner.delete_job(name)
    }
    fn insert_run<'a>(&'a self, run: &'a cronwatch::Run) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
        self.inner.insert_run(run)
    }
    fn update_run<'a>(&'a self, run: &'a cronwatch::Run) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
        self.inner.update_run(run)
    }
    fn get_run<'a>(
        &'a self,
        id: &'a str,
    ) -> cronwatch::BoxFuture<'a, Result<Option<cronwatch::Run>, cronwatch::BoxError>> {
        self.inner.get_run(id)
    }
    fn list_runs<'a>(
        &'a self,
        job: &'a str,
        limit: usize,
    ) -> cronwatch::BoxFuture<'a, Result<Vec<cronwatch::Run>, cronwatch::BoxError>> {
        self.inner.list_runs(job, limit)
    }
    fn last_run<'a>(
        &'a self,
        job: &'a str,
    ) -> cronwatch::BoxFuture<'a, Result<Option<cronwatch::Run>, cronwatch::BoxError>> {
        self.inner.last_run(job)
    }
    fn running_runs(&self) -> cronwatch::BoxFuture<'_, Result<Vec<cronwatch::Run>, cronwatch::BoxError>> {
        self.inner.running_runs()
    }
    fn get_state<'a>(
        &'a self,
        job: &'a str,
    ) -> cronwatch::BoxFuture<'a, Result<Option<JobState>, cronwatch::BoxError>> {
        Box::pin(async move {
            let state = self.inner.get_state(job).await;
            tokio::time::sleep(Duration::from_millis(25)).await;
            state
        })
    }
    fn set_state<'a>(&'a self, state: &'a JobState) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
        self.inner.set_state(state)
    }
    fn prune(&self, before: i64) -> cronwatch::BoxFuture<'_, Result<u64, cronwatch::BoxError>> {
        self.inner.prune(before)
    }
    fn close(&self) -> cronwatch::BoxFuture<'_, Result<(), cronwatch::BoxError>> {
        self.inner.close()
    }
    fn update_run_if<'a>(
        &'a self,
        run: &'a cronwatch::Run,
        from: &'a [RunStatus],
    ) -> cronwatch::BoxFuture<'a, Result<bool, cronwatch::BoxError>> {
        self.inner.update_run_if(run, from)
    }
    fn compare_and_set_state<'a>(
        &'a self,
        state: &'a JobState,
        expected: i64,
    ) -> cronwatch::BoxFuture<'a, Result<bool, cronwatch::BoxError>> {
        if self.no_cas {
            return Box::pin(async { Err(cronwatch::Unsupported.into()) });
        }
        self.inner.compare_and_set_state(state, expected)
    }
}

/// Two clients, as two processes sharing one store, each failing the job
/// once at the same time.
async fn race(a: Arc<SharedStore>, b: Arc<SharedStore>) -> (JobState, Vec<String>) {
    let one = Kit::with(|x| x.store_arc(a.clone()));
    let two = Kit::with(|x| x.store_arc(b));
    let options = JobOptions::new().failures_before_alert(2);
    one.cw.run("shared", Some(options.clone()), |_| async { Ok::<_, Boom>(()) }).await.unwrap().unwrap();
    let (x, y) = tokio::join!(
        one.cw.run("shared", Some(options.clone()), |_| async { Err::<(), _>(Boom("x")) }),
        two.cw.run("shared", Some(options), |_| async { Err::<(), _>(Boom("x")) }),
    );
    assert!(x.unwrap().is_err() && y.unwrap().is_err());
    let state = a.get_state("shared").await.unwrap().unwrap();
    let mut types = one.types();
    types.extend(two.types());
    (state, types)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_processes_failing_at_once_both_count_and_alert_once() {
    let store = Arc::new(MemoryStore::new());
    let (state, types) = race(slow_reads(&store, false), slow_reads(&store, false)).await;
    assert_eq!(state.consecutive_failures, 2, "neither failure was lost");
    assert_eq!(state.open.len(), 1);
    assert_eq!(state.open[0].condition, Condition::Failed);
    assert_eq!(types, ["failed"], "one alert");
    assert!(state.version.is_some_and(|v| v >= 3), "every write bumped the version ({:?})", state.version);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_store_without_compare_and_set_cannot_keep_two_processes_apart() {
    let store = Arc::new(MemoryStore::new());
    let (state, types) = race(slow_reads(&store, true), slow_reads(&store, true)).await;
    // The documented caveat: the later write wins, so one failure is lost.
    assert_eq!(state.consecutive_failures, 1);
    assert!(types.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_silence_made_by_one_process_survives_anothers_run() {
    let store = Arc::new(MemoryStore::new());
    let runner = Kit::with(|b| b.store_arc(slow_reads(&store, false)));
    let admin = Kit::with(|b| b.store_arc(slow_reads(&store, false)));
    runner.cw.run("s", None, |_| async { Ok::<_, Boom>(()) }).await.unwrap().unwrap();
    let (_, silenced) =
        tokio::join!(runner.cw.run("s", None, |_| async { Err::<(), _>(Boom("x")) }), admin.cw.silence("s", "1h"));
    silenced.unwrap();
    let state = store.get_state("s").await.unwrap().unwrap();
    assert!(state.silenced_until.is_some(), "the silence was overwritten");
    assert_eq!(state.consecutive_failures, 1, "nor was the failure");
}

#[tokio::test]
async fn an_update_that_keeps_losing_gives_up_and_the_run_finishes() {
    let store = Arc::new(TestStore { cas_refuses: true, ..Default::default() });
    let k = Kit::with(|b| b.store_arc(store));
    assert!(k.cw.run("busy", None, |_| async { Err::<(), _>(Boom("x")) }).await.unwrap().is_err());
    assert_eq!(k.wheres(), ["evaluating busy"]);
    assert_eq!(k.runs("busy").await[0].status, RunStatus::Failed);
    assert_eq!(k.messages(), ["the state of busy changed under 10 attempts in a row to update it; gave up"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn many_tasks_running_one_job() {
    let k = Kit::new();
    let job = k.cw.job("fanout", JobOptions::new().failures_before_alert(1000)).unwrap();
    const N: usize = 50;
    let tasks: Vec<_> = (0..N)
        .map(|i| {
            let job = job.clone();
            tokio::spawn(async move {
                job.run(|j| async move {
                    j.log(format!("worker {i}"));
                    j.metric("i", i as f64).unwrap();
                    if i % 2 == 1 { Err(Boom("odd")) } else { Ok(()) }
                })
                .await
            })
        })
        .collect();
    for t in tasks {
        let _ = t.await.unwrap();
    }
    let list = k.cw.runs("fanout", 500).await.unwrap();
    assert_eq!(list.len(), N);
    assert_eq!(list.iter().filter(|r| r.status == RunStatus::Failed).count(), N / 2);
    for r in &list {
        assert!(r.output.is_some() && r.metrics.len() == 1, "run {} lost its output or metrics", r.id);
    }
    assert!(k.wheres().is_empty(), "{:?}", k.messages());
    assert!(k.state("fanout").await.unwrap().version.is_some_and(|v| v >= 1), "state written");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_checks_share_one_check() {
    let store = Arc::new(TestStore::default());
    let k = Kit::with(|b| b.store_arc(store.clone()));
    k.cw.job("a", JobOptions::new().schedule("every 1h")).unwrap();
    k.check().await;
    let before = store.running_runs_calls.load(Ordering::SeqCst);
    let gate = store.running_runs_gate.lock().await;
    let first = tokio::spawn({
        let cw = k.cw.clone();
        async move { cw.check().await.unwrap() }
    });
    common::wait_for("the first check to reach the store", || async {
        store.running_runs_calls.load(Ordering::SeqCst) > before
    })
    .await;
    let others: Vec<_> = (0..3)
        .map(|_| {
            let cw = k.cw.clone();
            tokio::spawn(async move { cw.check().await.unwrap() })
        })
        .collect();
    tokio::time::sleep(Duration::from_millis(20)).await;
    drop(gate);
    let first = first.await.unwrap();
    for other in others {
        assert_eq!(other.await.unwrap(), first, "every caller got the shared result");
    }
    assert_eq!(store.running_runs_calls.load(Ordering::SeqCst) - before, 1, "one check ran");
    // And a later call runs a check of its own.
    k.check().await;
    assert_eq!(store.running_runs_calls.load(Ordering::SeqCst) - before, 2, "a second check");
}

#[tokio::test]
async fn a_check_that_panics_is_that_checks_error() {
    struct Panicking(MemoryStore);
    impl Store for Panicking {
        fn init(&self) -> cronwatch::BoxFuture<'_, Result<(), cronwatch::BoxError>> {
            self.0.init()
        }
        fn upsert_job<'a>(
            &'a self,
            d: &'a cronwatch::Definition,
            now: i64,
        ) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
            self.0.upsert_job(d, now)
        }
        fn get_job<'a>(
            &'a self,
            name: &'a str,
        ) -> cronwatch::BoxFuture<'a, Result<Option<cronwatch::StoredJob>, cronwatch::BoxError>> {
            self.0.get_job(name)
        }
        fn list_jobs(&self) -> cronwatch::BoxFuture<'_, Result<Vec<cronwatch::StoredJob>, cronwatch::BoxError>> {
            self.0.list_jobs()
        }
        fn delete_job<'a>(&'a self, name: &'a str) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
            self.0.delete_job(name)
        }
        fn insert_run<'a>(
            &'a self,
            r: &'a cronwatch::Run,
        ) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
            self.0.insert_run(r)
        }
        fn update_run<'a>(
            &'a self,
            r: &'a cronwatch::Run,
        ) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
            self.0.update_run(r)
        }
        fn get_run<'a>(
            &'a self,
            id: &'a str,
        ) -> cronwatch::BoxFuture<'a, Result<Option<cronwatch::Run>, cronwatch::BoxError>> {
            self.0.get_run(id)
        }
        fn list_runs<'a>(
            &'a self,
            job: &'a str,
            limit: usize,
        ) -> cronwatch::BoxFuture<'a, Result<Vec<cronwatch::Run>, cronwatch::BoxError>> {
            self.0.list_runs(job, limit)
        }
        fn last_run<'a>(
            &'a self,
            job: &'a str,
        ) -> cronwatch::BoxFuture<'a, Result<Option<cronwatch::Run>, cronwatch::BoxError>> {
            self.0.last_run(job)
        }
        fn running_runs(&self) -> cronwatch::BoxFuture<'_, Result<Vec<cronwatch::Run>, cronwatch::BoxError>> {
            Box::pin(async { panic!("the store fell over") })
        }
        fn get_state<'a>(
            &'a self,
            job: &'a str,
        ) -> cronwatch::BoxFuture<'a, Result<Option<JobState>, cronwatch::BoxError>> {
            self.0.get_state(job)
        }
        fn set_state<'a>(&'a self, s: &'a JobState) -> cronwatch::BoxFuture<'a, Result<(), cronwatch::BoxError>> {
            self.0.set_state(s)
        }
        fn prune(&self, before: i64) -> cronwatch::BoxFuture<'_, Result<u64, cronwatch::BoxError>> {
            self.0.prune(before)
        }
        fn close(&self) -> cronwatch::BoxFuture<'_, Result<(), cronwatch::BoxError>> {
            self.0.close()
        }
    }
    let k = Kit::with(|b| b.store(Panicking(MemoryStore::new())));
    let err = k.cw.check().await.unwrap_err();
    assert_eq!(err.to_string(), "the check panicked: the store fell over");
    let again = k.cw.check().await.unwrap_err();
    assert_eq!(again.to_string(), "the check panicked: the store fell over", "the next check runs anew");
}

#[tokio::test(start_paused = true)]
async fn start_checks_after_a_second_then_on_the_interval_until_stop() {
    let store = Arc::new(TestStore::default());
    let k = Kit::with(|b| b.store_arc(store.clone()));
    let calls = || store.running_runs_calls.load(Ordering::SeqCst);
    k.cw.start(Duration::from_secs(10));
    k.cw.start(Duration::from_secs(1)); // a second start does nothing
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(calls(), 0, "not before a second");
    tokio::time::sleep(Duration::from_millis(1000)).await;
    assert_eq!(calls(), 1, "the first check");
    tokio::time::sleep(Duration::from_secs(10)).await;
    assert_eq!(calls(), 2, "then on the interval");
    k.cw.stop();
    tokio::time::sleep(Duration::from_secs(60)).await;
    assert_eq!(calls(), 2, "stopped");
}
