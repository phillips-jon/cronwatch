//! The walk's habits, each checked against what croner answers (the fuzz
//! test in the schedule module checks thousands more against croner
//! itself).

use super::pattern::{parse_int, to_number};
use super::zone::{to_utc, wall_at};
use super::*;
use crate::js::{date_utc, iso_string};

fn runs(text: &str, zone: &str, count: usize, from: i64) -> Vec<String> {
    let tz = load_zone(zone).unwrap();
    let c = Cron::new(text, tz).unwrap();
    c.next_runs(count, from).into_iter().map(iso_string).collect()
}

#[test]
fn croners_habits() {
    let jan = date_utc(2026, 0, 1, 0, 0, 0, 0);
    let cases: &[(&str, &str, &str, usize, &[&str])] = &[
        (
            "a wall-clock time in a spring-forward gap moves forward by the gap",
            "30 2 8 3 *",
            "America/New_York",
            1,
            &["2026-03-08T07:30:00.000Z"],
        ),
        (
            "a time that happens twice is the earlier one",
            "30 1 1 11 *",
            "America/New_York",
            2,
            &["2026-11-01T05:30:00.000Z", "2027-11-01T05:30:00.000Z"],
        ),
        ("a year field fires in that year only", "0 0 0 1 1 * 2030", "UTC", 2, &["2030-01-01T00:00:00.000Z"]),
        ("a fixed offset is a zone", "0 2 * * *", "+05:30", 1, &["2026-01-01T20:30:00.000Z"]),
        ("a date no month has never fires", "0 0 30 2 *", "UTC", 1, &[]),
        (
            "the last weekday of the month",
            "0 0 LW * *",
            "UTC",
            2,
            &["2026-01-30T00:00:00.000Z", "2026-02-27T00:00:00.000Z"],
        ),
        (
            "the nearest weekday to the first",
            "0 0 1W * *",
            "UTC",
            2,
            &["2026-02-02T00:00:00.000Z", "2026-03-02T00:00:00.000Z"],
        ),
        ("the second Friday", "0 0 * * 5#2", "UTC", 2, &["2026-01-09T00:00:00.000Z", "2026-02-13T00:00:00.000Z"]),
    ];
    for (name, text, zone, count, want) in cases {
        assert_eq!(runs(text, zone, *count, jan), *want, "{name}: {text}");
    }
}

#[test]
fn croners_messages() {
    let cases = [
        (
            "",
            "CronPattern: invalid configuration format (''), exactly five, six, or seven space separated parts are required.",
        ),
        ("0 0 * * 5W", "CronPattern: configuration entry 5 (5W) contains illegal characters."),
        ("0 0 1#2 * *", "CronPattern: configuration entry 3 (1#2) contains illegal characters."),
        ("0 0 * 2L *", "CronPattern: configuration entry 4 (2L) contains illegal characters."),
        ("0 0 1-5W * *", "CronPattern: Syntax error, W is not allowed in a range."),
        ("* * * * * * 0", "CronPattern: Invalid value for year: 0 (supported range: 1-9999)"),
        ("0 0 * * 1#2.5", "CronPattern: configuration entry 5 (1#2.5) contains illegal characters."),
        (
            "@reboot",
            "CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection.",
        ),
        // Croner takes this for a one-time date; the port refuses it (see the module doc).
        ("0 12:30 * * *", "Invalid ISO8601 passed to timezone parser."),
    ];
    for (text, want) in cases {
        assert_eq!(Cron::new(text, TimeZone::UTC).unwrap_err(), want, "{text:?}");
    }
}

#[test]
fn from_tz() {
    let ny = load_zone("America/New_York").unwrap();
    // 02:30 does not exist on 2026-03-08: croner's fromTZ moves it to 03:30 EDT.
    assert_eq!(to_utc([2026, 3, 8, 2, 30, 0], &ny) * 1000, date_utc(2026, 2, 8, 7, 30, 0, 0));
    // 01:30 happens twice on 2026-11-01: the earlier, EDT.
    assert_eq!(to_utc([2026, 11, 1, 1, 30, 0], &ny) * 1000, date_utc(2026, 10, 1, 5, 30, 0, 0));
    assert_eq!(wall_at(date_utc(2026, 6, 1, 12, 0, 0, 0) / 1000, &ny), [2026, 7, 1, 8, 0, 0]);
}

#[test]
fn to_number_and_parse_int() {
    for (text, want) in [("5", 5.0), (" 7x", 7.0), ("-3", -3.0), ("+2", 2.0)] {
        assert_eq!(parse_int(text), want, "parseInt({text:?})");
    }
    for (text, want) in [("", 0.0), (" 2 ", 2.0), ("1e1", 10.0), ("2.", 2.0), (".5", 0.5)] {
        assert_eq!(to_number(text), want, "Number({text:?})");
    }
    for text in ["x", "1L", "e1", ".", "1e", "--1"] {
        assert!(to_number(text).is_nan(), "Number({text:?})");
    }
}

#[test]
fn a_start_no_javascript_date_holds_has_no_fires() {
    // A foreign row's time near i64::MIN or i64::MAX overflowed the walk
    // (found by the cron fuzz target); croner is never given one.
    for text in ["0 * * * *", "0 0 L * ?", "0 0 * * 5#2"] {
        for from in [i64::MIN, i64::MIN + 1, -8_640_000_000_000_001, 8_640_000_000_000_001, i64::MAX] {
            assert_eq!(runs(text, "Europe/London", 2, from), Vec::<String>::new(), "{text} from {from}");
        }
    }
    assert_eq!(runs("0 0 1 1 *", "UTC", 1, -8_640_000_000_000_000), ["-271820-01-01T00:00:00.000Z"]);
}
