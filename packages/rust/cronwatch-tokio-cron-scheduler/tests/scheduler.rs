//! A real tokio-cron-scheduler scheduler, on the wall clock (it reads
//! `Utc::now()`, so tokio's paused clock cannot drive it): jobs every second
//! whose runs, errors and panics are recorded, a job removed while it runs,
//! the check job, and two apps on one store.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cronwatch::{Client, JobOptions, MemoryStore, RunStatus, Store};
use cronwatch_tokio_cron_scheduler::{Error, Options, TRIGGER, Watcher};
use tokio_cron_scheduler::JobScheduler;

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

fn options(app: &str) -> Options {
    Options { app: Some(app.into()), ..Options::default() }
}

async fn stored(store: &dyn Store, name: &str) -> String {
    store.get_job(name).await.unwrap().unwrap_or_else(|| panic!("{name} is not stored")).definition.to_json()
}

/// Waits (on the wall clock) until `cond` holds, for at most ten seconds.
async fn until<F, Fut>(what: &str, mut cond: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    for _ in 0..200 {
        if cond().await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

#[derive(Debug)]
struct Failed(&'static str);

impl std::fmt::Display for Failed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn runs_errors_and_panics_are_recorded() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (cw, errors) = client(store.clone());
    let watcher = Watcher::new(&cw, Options { defaults: JobOptions::new().grace("1m"), ..options("billing") });
    let scheduler = JobScheduler::new().await.unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = calls.clone();
    scheduler
        .add(
            watcher
                .job(
                    "every-second",
                    "* * * * * *",
                    "UTC",
                    move |job| {
                        let n = counted.fetch_add(1, Ordering::SeqCst);
                        async move {
                            job.log(format!("run {n}"));
                            job.metric("n", n as f64).unwrap();
                            if n == 1 {
                                return Err(Failed("the second run failed"));
                            }
                            if n == 2 {
                                panic!("the third run panicked");
                            }
                            Ok(())
                        }
                    },
                    JobOptions::new().description("Every second"),
                )
                .unwrap(),
        )
        .await
        .unwrap();
    watcher.follow(&scheduler);
    scheduler.start().await.unwrap();
    until("four runs", || async {
        cw.runs("every-second", 10).await.unwrap().iter().filter(|r| r.status != RunStatus::Running).count() >= 4
    })
    .await;
    let mut scheduler = scheduler;
    scheduler.shutdown().await.unwrap();

    assert_eq!(
        stored(&*store, "every-second").await,
        r#"{"grace":"1m","schedule":"* * * * * *","timezone":"UTC","description":"Every second","tags":["tokio-cron-scheduler","tokio-cron-scheduler:billing"],"name":"every-second"}"#
    );
    let mut runs = cw.runs("every-second", 10).await.unwrap();
    runs.retain(|r| r.status != RunStatus::Running);
    runs.reverse();
    assert_eq!(runs[0].status, RunStatus::Ok);
    assert_eq!(runs[0].output.as_deref(), Some("run 0"));
    assert_eq!(runs[0].trigger, TRIGGER);
    assert_eq!(
        (runs[1].status.clone(), runs[1].error.as_deref()),
        (RunStatus::Failed, Some("Failed: the second run failed"))
    );
    assert_eq!(
        (runs[2].status.clone(), runs[2].error.as_deref()),
        (RunStatus::Failed, Some("panic: the third run panicked"))
    );
    assert_eq!(runs[3].status, RunStatus::Ok);
    assert!(errors.lock().unwrap().is_empty(), "{:?}", errors.lock().unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_job_removed_loses_its_schedule_at_once() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (cw, errors) = client(store.clone());
    let watcher = Watcher::new(&cw, options("billing"));
    let scheduler = JobScheduler::new().await.unwrap();
    let keep = watcher.job("kept", "0 0 3 * * *", "", |_| async { Ok::<_, Failed>(()) }, JobOptions::new()).unwrap();
    let gone = watcher
        .job("gone", "0 0 4 * * *", "", |_| async { Ok::<_, Failed>(()) }, JobOptions::new().timeout("2h"))
        .unwrap();
    let following = watcher.follow(&scheduler);
    scheduler.add(keep).await.unwrap();
    let uuid = scheduler.add(gone).await.unwrap();
    watcher.wait().await;
    assert!(stored(&*store, "gone").await.contains(r#""schedule":"0 0 4 * * *""#));
    scheduler.remove(&uuid).await.unwrap();
    until("the job gone declared again", || async {
        stored(&*store, "gone").await
            == r#"{"description":"A scheduled task (no longer scheduled)","tags":["tokio-cron-scheduler","tokio-cron-scheduler:billing"],"timeout":"2h","name":"gone"}"#
    })
    .await;
    assert!(stored(&*store, "kept").await.contains(r#""schedule":"0 0 3 * * *""#));
    assert!(errors.lock().unwrap().is_empty(), "{:?}", errors.lock().unwrap());
    // The audit: the task outlives a shutdown, so the app is given its handle.
    let mut scheduler = scheduler;
    scheduler.shutdown().await.unwrap();
    assert!(!following.is_finished(), "a shutdown does not end it");
    following.abort();
    assert!(following.await.unwrap_err().is_cancelled());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_job_removed_and_added_again_gets_its_schedule_back_at_once() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (cw, errors) = client(store.clone());
    let watcher = Watcher::new(&cw, options("billing"));
    let scheduler = JobScheduler::new().await.unwrap();
    let paused =
        watcher.job("paused", "0 0 4 * * *", "", |_| async { Ok::<_, Failed>(()) }, JobOptions::new()).unwrap();
    let following = watcher.follow(&scheduler);
    let uuid = scheduler.add(paused.clone()).await.unwrap();
    watcher.wait().await;
    scheduler.remove(&uuid).await.unwrap();
    until("the job declared without its schedule", || async {
        stored(&*store, "paused").await.contains("no longer scheduled")
    })
    .await;
    // Resumed: the same job, the same uuid, with no sync to follow.
    assert_eq!(scheduler.add(paused).await.unwrap(), uuid);
    until("the job declared with its schedule again", || async {
        stored(&*store, "paused").await.contains(r#""schedule":"0 0 4 * * *""#)
    })
    .await;
    assert!(errors.lock().unwrap().is_empty(), "{:?}", errors.lock().unwrap());
    following.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_sync_finds_a_job_removed_without_following_and_one_another_release_dropped() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    // An earlier release scheduled "dropped", which this one does not make.
    let (earlier, _) = client(store.clone());
    let old = Watcher::new(&earlier, options("billing"));
    let _ = old.job("dropped", "0 0 5 * * *", "", |_| async { Ok::<_, Failed>(()) }, JobOptions::new()).unwrap();
    old.wait().await;
    // Another app's job is left alone.
    let (search, _) = client(store.clone());
    let other = Watcher::new(&search, options("search"));
    let _ = other.job("reindex", "0 0 6 * * *", "", |_| async { Ok::<_, Failed>(()) }, JobOptions::new()).unwrap();
    other.wait().await;

    let (cw, errors) = client(store.clone());
    let watcher = Watcher::new(&cw, options("billing"));
    let scheduler = JobScheduler::new().await.unwrap();
    let uuid = scheduler
        .add(watcher.job("removed", "0 0 3 * * *", "", |_| async { Ok::<_, Failed>(()) }, JobOptions::new()).unwrap())
        .await
        .unwrap();
    watcher.sync(&scheduler).await.unwrap();
    assert!(stored(&*store, "removed").await.contains(r#""schedule""#), "present, so kept");
    scheduler.remove(&uuid).await.unwrap();
    watcher.sync(&scheduler).await.unwrap();
    assert!(stored(&*store, "removed").await.contains("no longer scheduled"));
    assert!(stored(&*store, "dropped").await.contains("no longer scheduled"), "the earlier release's job");
    assert!(stored(&*store, "reindex").await.contains(r#""schedule":"0 0 6 * * *""#), "another app's job");
    assert!(errors.lock().unwrap().is_empty(), "{:?}", errors.lock().unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_check_job_syncs_and_checks_and_is_never_a_job() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (cw, errors) = client(store.clone());
    let watcher = Watcher::new(&cw, options("billing"));
    let scheduler = JobScheduler::new().await.unwrap();
    let _ = watcher.job("nightly", "0 0 2 * * *", "", |_| async { Ok::<_, Failed>(()) }, JobOptions::new()).unwrap();
    scheduler.add(watcher.check_job(Duration::from_secs(1)).unwrap()).await.unwrap();
    scheduler.start().await.unwrap();
    until("a check", || async {
        store.get_state("nightly").await.unwrap().is_some() || store.list_jobs().await.unwrap().len() == 1
    })
    .await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let mut scheduler = scheduler;
    scheduler.shutdown().await.unwrap();
    let names: Vec<String> = store.list_jobs().await.unwrap().into_iter().map(|j| j.name).collect();
    assert_eq!(names, ["nightly"], "the check is never a job");
    // "nightly" was made and never added, so the scheduler never had it:
    // it keeps its schedule rather than be taken for removed.
    assert!(stored(&*store, "nightly").await.contains(r#""schedule""#));
    assert!(errors.lock().unwrap().is_empty(), "{:?}", errors.lock().unwrap());
}

#[tokio::test]
async fn what_cronwatch_or_the_scheduler_refuses_is_an_error() {
    let (cw, errors) = client(Arc::new(MemoryStore::new()));
    let watcher = Watcher::new(&cw, options("billing"));
    let ok = |_| async { Ok::<_, Failed>(()) };
    let bad_name = watcher.job("no spaces", "0 0 2 * * *", "", ok, JobOptions::new()).err().unwrap();
    assert!(matches!(bad_name, Error::Invalid(_)), "{bad_name}");
    let bad_grace = watcher.job("x", "0 0 2 * * *", "", ok, JobOptions::new().grace("soon")).err().unwrap();
    assert!(matches!(bad_grace, Error::Invalid(_)), "{bad_grace}");
    assert!(matches!(watcher.job("x", "0 0 2 * * *", "Mars/Olympus", ok, JobOptions::new()), Err(Error::Timezone(_))));
    assert!(matches!(watcher.job("x", "0 2 * * *", "", ok, JobOptions::new()), Err(Error::Scheduler(_))));
    assert!(cw.defined_jobs().is_empty(), "nothing declared");

    // A schedule the two read differently is watched without it, reported once.
    let _ = watcher.job("both-days", "0 0 0 1 * MON", "", ok, JobOptions::new()).unwrap();
    assert_eq!(cw.defined_jobs()[0].schedule(), "");
    let errors = errors.lock().unwrap().clone();
    assert_eq!(errors.len(), 1);
    assert!(errors[0].starts_with(r#"declaring tokio-cron-scheduler job "both-days": cronwatch: tokio-cron-scheduler job "both-days" is "0 0 0 1 * MON" in UTC, but after a run at"#), "{errors:?}");
}

#[tokio::test]
async fn a_repeated_job_is_every_whole_seconds() {
    let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
    let (cw, _) = client(store.clone());
    let watcher = Watcher::new(&cw, options("billing"));
    let _ = watcher
        .repeated("poll", Duration::from_millis(90_500), |_| async { Ok::<_, Failed>(()) }, JobOptions::new())
        .unwrap();
    watcher.wait().await;
    assert_eq!(
        stored(&*store, "poll").await,
        r#"{"schedule":"every 1m30s","tags":["tokio-cron-scheduler","tokio-cron-scheduler:billing"],"name":"poll"}"#
    );
}

// The audit: two jobs made at once could declare their lists in the wrong
// order, the older list taking the newer job for gone and stripping its
// schedule.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn jobs_made_at_once_all_keep_their_schedules() {
    let (cw, errors) = client(Arc::new(MemoryStore::new()));
    let watcher = Watcher::new(&cw, options("billing"));
    for round in 0..20 {
        let barrier = Arc::new(std::sync::Barrier::new(8));
        let threads: Vec<_> = (0..8)
            .map(|i| {
                let (watcher, barrier) = (watcher.clone(), barrier.clone());
                let handle = tokio::runtime::Handle::current();
                std::thread::spawn(move || {
                    let _entered = handle.enter();
                    barrier.wait();
                    let name = format!("job-{round}-{i}");
                    let ok = |_| async { Ok::<_, Failed>(()) };
                    watcher.job(&name, "0 0 2 * * *", "", ok, JobOptions::new()).unwrap();
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
    }
    watcher.wait().await;
    let defined = cw.defined_jobs();
    assert_eq!(defined.len(), 160);
    for def in defined {
        assert_eq!(def.schedule(), "0 0 2 * * *", "{}", def.to_json());
    }
    assert!(errors.lock().unwrap().is_empty(), "{:?}", errors.lock().unwrap());
}
