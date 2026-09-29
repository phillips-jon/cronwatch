//! A schedule read in a zone (the croner port), then its next fire times
//! from any instant: each is later than the one before.
#![no_main]

use cronwatch::bridge::Schedule;
use libfuzzer_sys::arbitrary::{self, Arbitrary};
use libfuzzer_sys::fuzz_target;

/// Zones with and without daylight saving, a half and a quarter hour off,
/// one whose change is half an hour, and the process's own (`""`).
const ZONES: [&str; 9] = [
    "UTC",
    "",
    "Europe/London",
    "America/New_York",
    "Asia/Kolkata",
    "Asia/Kathmandu",
    "Australia/Lord_Howe",
    "America/Sao_Paulo",
    "Pacific/Chatham",
];

/// JavaScript's `Date` range, in milliseconds either side of the epoch.
const DATE_RANGE: i64 = 8_640_000_000_000_000;

#[derive(Arbitrary, Debug)]
struct Input<'a> {
    expr: &'a str,
    zone: u8,
    own_zone: Option<&'a str>,
    from: i64,
}

fuzz_target!(|input: Input<'_>| {
    let zone = input.own_zone.unwrap_or(ZONES[input.zone as usize % ZONES.len()]);
    let Ok(schedule) = Schedule::parse(input.expr, zone) else {
        return;
    };
    let mut at = input.from;
    for _ in 0..4 {
        let Some(next) = schedule.fire_after(at) else {
            break;
        };
        if at.abs() < DATE_RANGE && next.abs() < DATE_RANGE {
            assert!(next > at, "{:?} in {zone:?}: {next} is not after {at}", input.expr);
        }
        at = next;
    }
});
