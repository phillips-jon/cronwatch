//! `Job::run_or_discard`: an attempt a queue gives back without failing (an
//! apalis task deferred, a River snooze) leaves no run behind, neither a
//! failure nor a success, as the Go port's `DiscardWhen` and the PHP port's
//! released Laravel job have it.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::{HOUR, Kit, MIN, TestStore};
use cronwatch::{JobOptions, RunOptions, RunStatus};

#[derive(Debug, PartialEq)]
enum Attempt {
    Snoozed,
    Down(&'static str),
}

impl std::fmt::Display for Attempt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Attempt::Snoozed => f.write_str("snoozed"),
            Attempt::Down(why) => f.write_str(why),
        }
    }
}

fn snoozed(err: &Attempt) -> bool {
    *err == Attempt::Snoozed
}

async fn attempt(job: &cronwatch::Job, outcome: Result<(), Attempt>) -> Result<(), Attempt> {
    job.run_or_discard(RunOptions::new(), snoozed, |j| {
        j.log("attempt");
        async move { outcome }
    })
    .await
}

// The Go port's audit: a run given back used to close missed at its start
// all the same, so an overdue job that snoozed had missed opened again by
// the next check, one alert per snooze.
#[tokio::test]
async fn a_given_back_run_leaves_missed_open() {
    let k = Kit::new();
    let job = k.cw.job("q", JobOptions::new().schedule("every 1h").grace("5m")).unwrap();
    attempt(&job, Ok(())).await.unwrap();
    k.advance(HOUR + 10 * MIN);
    k.check().await;
    assert_eq!(k.types(), ["missed"]);
    for _ in 0..3 {
        k.advance(MIN);
        let _ = attempt(&job, Err(Attempt::Snoozed)).await;
        k.advance(MIN);
        k.check().await;
    }
    assert_eq!(k.types(), ["missed"], "one missed alert, still open");
    attempt(&job, Ok(())).await.unwrap();
    assert_eq!(k.types(), ["missed", "recovered"], "the run that was not given back recovers it");
}

#[tokio::test]
async fn a_run_given_back_is_taken_back() {
    let k = Kit::new();
    let job = k.cw.job("q", JobOptions::new().failures_before_alert(2)).unwrap();

    // A failure, a snooze, then another failure: two in a row, so an alert.
    k.advance(1000);
    assert_eq!(attempt(&job, Err(Attempt::Down("down"))).await, Err(Attempt::Down("down")));
    k.advance(1000);
    assert_eq!(attempt(&job, Err(Attempt::Snoozed)).await, Err(Attempt::Snoozed), "the error is returned");
    assert_eq!(k.runs("q").await.len(), 1, "the snooze is not a run");
    assert_eq!(k.state("q").await.unwrap().consecutive_failures, 1, "failures in a row kept");
    assert!(k.types().is_empty());
    k.advance(1000);
    let _ = attempt(&job, Err(Attempt::Down("down again"))).await;
    assert_eq!(k.types(), ["failed"], "the second failure alerts");
    assert_eq!(k.runs("q").await.len(), 2);

    // A snooze does not close the alert; a success does.
    k.advance(1000);
    let _ = attempt(&job, Err(Attempt::Snoozed)).await;
    assert_eq!(k.types(), ["failed"]);
    k.advance(1000);
    attempt(&job, Ok(())).await.unwrap();
    assert_eq!(k.types(), ["failed", "recovered"]);
    assert_eq!(k.runs("q").await.len(), 3);
    assert!(k.wheres().is_empty(), "nothing reported: {:?}", k.messages());

    // A panic is never taken back.
    let panicked = tokio::spawn({
        let job = job.clone();
        async move {
            job.run_or_discard(
                RunOptions::new(),
                |_: &Attempt| true,
                |_| async {
                    if true {
                        panic!("snoozed");
                    }
                    Ok::<(), Attempt>(())
                },
            )
            .await
        }
    })
    .await;
    assert!(panicked.is_err());
    assert_eq!(k.runs("q").await[0].status, RunStatus::Failed, "a panic is a failed run");
}

#[tokio::test]
async fn a_store_without_delete_run_if_records_the_run() {
    let store = Arc::new(TestStore { no_delete: true, ..TestStore::default() });
    let k = Kit::with(|b| b.store_arc(store.clone()));
    let job = k.cw.job("q", JobOptions::new()).unwrap();
    assert_eq!(attempt(&job, Err(Attempt::Snoozed)).await, Err(Attempt::Snoozed));
    let runs = k.runs("q").await;
    assert_eq!(runs[0].status, RunStatus::Failed, "recorded as it ended");
    assert_eq!(
        k.errors.lock().unwrap().clone(),
        [(
            "discarding q".to_string(),
            "the store cannot take back a run (it does not implement Store::delete_run_if); recorded as it ended"
                .to_string()
        )]
    );
}

#[tokio::test]
async fn a_run_a_check_marked_stuck_is_left_as_it_is() {
    let k = Kit::new();
    let job = k.cw.job("q", JobOptions::new().timeout(Duration::from_secs(60))).unwrap();
    let err = job
        .run_or_discard(RunOptions::new(), snoozed, |_| async {
            k.advance(2 * MIN);
            k.check().await;
            Err::<(), _>(Attempt::Snoozed)
        })
        .await;
    assert_eq!(err, Err(Attempt::Snoozed));
    assert_eq!(k.runs("q").await[0].status, RunStatus::Timeout, "left as the check marked it");
    let messages = k.messages();
    assert_eq!(messages.len(), 1);
    assert!(messages[0].ends_with("is no longer running; left as it is"), "{messages:?}");
}

// The Go port's audit: a predicate that panicked escaped the run and left it
// running.
#[tokio::test]
async fn a_predicate_that_panics_is_reported_and_the_run_recorded() {
    let k = Kit::new();
    let job = k.cw.job("q", JobOptions::new()).unwrap();
    let err = job
        .run_or_discard(
            RunOptions::new(),
            |_: &Attempt| panic!("predicate broke"),
            |_| async { Err::<(), _>(Attempt::Down("later")) },
        )
        .await;
    assert_eq!(err, Err(Attempt::Down("later")));
    assert_eq!(k.runs("q").await[0].status, RunStatus::Failed);
    assert_eq!(k.wheres(), ["discarding q"]);
    assert_eq!(k.messages(), ["panicked: predicate broke"]);
}

#[tokio::test]
async fn a_success_and_an_error_not_given_back_are_judged_as_ever() {
    let k = Kit::new();
    let job = k.cw.job("q", JobOptions::new().expect("done")).unwrap();
    job.run_or_discard(RunOptions::new().trigger("apalis"), snoozed, |j| {
        j.log("done");
        async { Ok::<_, Attempt>(()) }
    })
    .await
    .unwrap();
    let runs = k.runs("q").await;
    assert_eq!((runs[0].status.clone(), runs[0].trigger.as_str()), (RunStatus::Ok, "apalis"));
}
