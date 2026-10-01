//! outbox.test.ts: an alert is written with the state that opens its
//! condition, so a process that dies before sending it does not lose it.

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;

use common::{Boom, Held, Kit, MIN, Mortal, T0};
use cronwatch::{Alert, Deliver, JobOptions, MemoryStore, Store, channel_fn, triage_fn};

/// How long an alert in `sending` is left to its sender (evaluate.ts
/// `SEND_LEASE_MS`).
const SEND_LEASE_MS: i64 = 5 * 60_000;

/// A run of `name` that fails, in a task of its own, in a process that may
/// never finish recording it.
fn failing_run(k: &Kit, name: &str) -> tokio::task::JoinHandle<()> {
    let job = k.cw.job(name, JobOptions::new()).unwrap();
    tokio::spawn(async move {
        let _ = job.run(|_| async { Err::<(), _>(Boom("disk full")) }).await;
    })
}

async fn state(store: &MemoryStore, name: &str) -> cronwatch::JobState {
    store.get_state(name).await.unwrap().expect("a state")
}

/// Lets every task that can run get as far as it can, on the test's one
/// thread.
async fn settle() {
    for _ in 0..50 {
        tokio::task::yield_now().await;
    }
}

#[tokio::test]
async fn the_write_that_opens_a_condition_holds_its_alert_so_a_process_that_dies_before_sending_it_does_not_lose_it() {
    let shared = Arc::new(MemoryStore::new());
    let mortal = Mortal::new(&shared);
    let triaging = Arc::new(tokio::sync::Notify::new());
    // The process dies while its triage call is out: no channel was ever called.
    let (dies, told) = (mortal.clone(), triaging.clone());
    let dying = Kit::with(|b| {
        b.store_arc(mortal.clone()).triage(triage_fn(move |_| {
            dies.kill();
            told.notify_one();
            std::future::pending()
        }))
    });
    let _run = failing_run(&dying, "nightly");
    triaging.notified().await;
    let s = state(&shared, "nightly").await;
    assert_eq!(s.open_at(&cronwatch::Condition::Failed), Some(T0));
    let sending = s.sending.clone().expect("an alert being sent");
    assert_eq!(sending.len(), 1);
    assert_eq!(sending[0].until, Some(T0 + SEND_LEASE_MS));
    let held = sending[0].alert.as_ref().expect("its alert");
    assert_eq!((held.alert_type.to_string(), held.at), ("failed".to_string(), T0));
    assert!(held.triage.is_none() && !held.triage_tried, "triage is made at send time, never stored here");
    assert_eq!(s.undelivered, Some(Vec::new()));

    // Another process's checks leave it alone while its sender's lease runs.
    let server =
        Kit::with(|b| b.store_arc(shared.clone()).triage(triage_fn(|_| async { Ok("The disk is full.".into()) })));
    server.advance(MIN);
    server.check().await;
    assert!(server.types().is_empty());

    // Once it has run out, the next check sends it, triaged, once.
    server.set(T0 + SEND_LEASE_MS + 1);
    let result = server.check().await;
    assert_eq!(common::alert_types(&result.alerts), ["failed"]);
    let sent: Vec<(String, i64, Option<String>)> =
        server.alert_list().into_iter().map(|a| (a.alert_type.to_string(), a.at, a.triage)).collect();
    assert_eq!(sent, [("failed".to_string(), T0, Some("The disk is full.".to_string()))]);
    let after = state(&shared, "nightly").await;
    assert_eq!(after.sending, None, "the key goes once nothing is being sent");
    assert_eq!(after.undelivered, Some(Vec::new()));
    assert!(!after.to_json().contains("sending"));
    server.check().await;
    let job = server.cw.job("nightly", JobOptions::new()).unwrap();
    assert!(job.run(|_| async { Err::<(), _>(Boom("again")) }).await.is_err());
    assert_eq!(server.types(), ["failed"], "the condition still alerts once");
}

#[tokio::test]
async fn an_alert_a_channel_took_just_before_its_process_died_is_sent_again_after_the_lease() {
    let shared = Arc::new(MemoryStore::new());
    let mortal = Mortal::new(&shared);
    let took = Arc::new(tokio::sync::Notify::new());
    // Accepted, then the process is gone before it records that.
    let (dies, told) = (mortal.clone(), took.clone());
    let first = channel_fn("first", move |_: Alert| {
        dies.kill();
        told.notify_one();
        async { Ok(()) }
    });
    let dying = Kit::with(|b| b.store_arc(mortal.clone()).alerts([first]));
    let _run = failing_run(&dying, "nightly");
    took.notified().await;
    let server = Kit::with(|b| b.store_arc(shared.clone()));
    server.set(T0 + SEND_LEASE_MS + 1);
    server.check().await;
    assert_eq!(server.types(), ["failed"], "sent a second time: the one duplicate a crash can cause");
}

#[tokio::test]
async fn while_an_alert_is_being_sent_no_check_anywhere_sends_it_too() {
    let shared = Arc::new(MemoryStore::new());
    let held = Held::new();
    let channel = held.channel();
    let worker = Kit::with(|b| b.store_arc(shared.clone()).alerts([channel]));
    let server = Kit::with(|b| b.store_arc(shared.clone()));
    let run = failing_run(&worker, "nightly");
    held.sending.notified().await;
    server.advance(MIN);
    server.check().await;
    // The sending process's own check, too.
    let cw = worker.cw.clone();
    let own_check = tokio::spawn(async move { cw.check().await.unwrap() });
    settle().await;
    held.open();
    run.await.unwrap();
    own_check.await.unwrap();
    assert_eq!(held.types(), ["failed"]);
    assert!(server.types().is_empty());
    let s = state(&shared, "nightly").await;
    assert_eq!(s.sending, None);
    assert_eq!(s.undelivered, Some(Vec::new()));
    assert_eq!(s.last_alert_at, Some(T0), "the time the run was judged, as before");
    server.set(T0 + SEND_LEASE_MS + MIN);
    worker.set(T0 + SEND_LEASE_MS + MIN);
    server.check().await;
    worker.check().await;
    assert!(server.types().is_empty());
    assert_eq!(held.types(), ["failed"]);
}

#[tokio::test]
async fn an_alert_no_channel_took_moves_from_the_outbox_to_the_retry_queue_with_its_triage() {
    let down = channel_fn("down", |_: Alert| async { Err("down".into()) });
    let k = Kit::with(|b| b.alerts([down]).triage(triage_fn(|_| async { Ok("Look at the disk.".into()) })));
    let job = k.cw.job("nightly", JobOptions::new()).unwrap();
    assert!(job.run(|_| async { Err::<(), _>(Boom("x")) }).await.is_err());
    let s = k.state("nightly").await.expect("a state");
    assert_eq!(s.sending, None);
    let queued: Vec<(String, Option<String>)> =
        s.undelivered.unwrap().into_iter().map(|a| (a.alert_type.to_string(), a.triage)).collect();
    assert_eq!(queued, [("failed".to_string(), Some("Look at the disk.".to_string()))]);
}

#[tokio::test]
async fn a_process_that_queues_its_alerts_for_a_check_elsewhere_writes_them_with_the_state_that_opens_the_condition() {
    let shared = Arc::new(MemoryStore::new());
    let counting = Mortal::new(&shared);
    let k = Kit::with(|b| b.store_arc(counting.clone()).deliver(Deliver::AtCheck));
    let job = k.cw.job("backup", JobOptions::new()).unwrap();
    assert!(job.run(|_| async { Err::<(), _>(Boom("disk full")) }).await.is_err());
    let s = state(&shared, "backup").await;
    assert_eq!(common::alert_types(&s.undelivered.unwrap()), ["failed"]);
    assert_eq!(s.sending, None);
    assert_eq!(counting.state_writes.load(Ordering::SeqCst), 1, "one write: the failure and its alert together");
}

#[tokio::test]
async fn a_queued_alert_keeps_the_fields_a_newer_release_gave_it_through_a_failed_retry_and_into_the_one_that_lands() {
    use cronwatch::js::Value;
    let shared = Arc::new(MemoryStore::new());
    let quiet = Kit::with(|b| b.store_arc(shared.clone()).deliver(Deliver::AtCheck));
    let job = quiet.cw.job("backup", JobOptions::new()).unwrap();
    assert!(job.run(|_| async { Err::<(), _>(Boom("disk full")) }).await.is_err());
    // A newer writer's alert: a field at its top level and one in its details.
    let mut stored = state(&shared, "backup").await.to_value();
    let Value::Object(o) = &mut stored else { panic!("a state object") };
    let Some(Value::Array(queue)) = o.get("undelivered").cloned() else { panic!("a queue") };
    let mut alert = queue[0].as_object().unwrap().clone();
    alert.set("futureAlertField", "kept");
    let mut details = alert.get("details").unwrap().as_object().unwrap().clone();
    details.set("futureDetail", 1);
    alert.set("details", details);
    o.set("undelivered", vec![Value::Object(alert)]);
    shared.set_state(&cronwatch::JobState::from_value(&stored).unwrap()).await.unwrap();

    let down = channel_fn("down", |_: Alert| async { Err("down".into()) });
    let failing = Kit::with(|b| b.store_arc(shared.clone()).alerts([down]));
    failing.advance(MIN);
    failing.check().await;
    let kept = state(&shared, "backup").await.to_json();
    assert!(kept.contains(r#""futureAlertField":"kept""#), "{kept}");
    assert!(kept.contains(r#","futureDetail":1}"#), "{kept}");

    let sender = Kit::with(|b| b.store_arc(shared.clone()));
    sender.advance(2 * MIN);
    sender.check().await;
    let sent = sender.alert_list();
    assert_eq!(common::alert_types(&sent), ["failed"]);
    let body = sent[0].to_json();
    assert!(body.contains(r#""futureAlertField":"kept""#), "{body}");
    assert!(body.contains(r#","futureDetail":1}"#), "{body}");
}
