use super::*;

#[test]
fn a_deferred_attempt_or_a_task_cancelled_is_given_back() {
    assert!(given_back(&DeferredError::new("later")));
    let boxed: BoxDynError = Box::new(DeferredError::new("later"));
    assert!(given_back(&boxed));
    let failed: BoxDynError = "down".into();
    assert!(!given_back(&failed));
    let aborted: BoxDynError = Box::new(AbortError::new("stop retrying"));
    assert!(!given_back(&aborted), "an abort the task asked for is a failure");
    assert!(!given_back(&std::io::Error::other("down")));
}

#[test]
fn a_schedule_ticks_after_the_last_tick() {
    let mut s = schedule("0 2 * * *", "UTC").unwrap();
    let day = 86_400_000;
    let first = s.next_after(10 * day).unwrap();
    assert_eq!(first, 10 * day + 2 * 3_600_000);
    // Asked again at the tick (the scheduler asks as it fires), the next day's.
    assert_eq!(s.next_after(first), Some(11 * day + 2 * 3_600_000));
    // A clock behind the last tick never ticks twice.
    assert_eq!(s.next_after(first - 5_000), Some(12 * day + 2 * 3_600_000));
    let mut every = schedule("every 90s", "").unwrap();
    assert_eq!(every.next_after(1_000), Some(91_000));
    assert_eq!(every.next_after(91_000), Some(181_000));
}

#[test]
fn a_tick_is_never_before_its_fire() {
    let mut every = schedule("every 1500ms", "").unwrap();
    let tick: Tick = apalis_cron::Schedule::next_tick(&mut every, &apalis_cron::timezone::Utc).unwrap();
    let fire = every.last.unwrap();
    assert!(tick.get_timestamp() as i64 * 1000 >= fire);
}
