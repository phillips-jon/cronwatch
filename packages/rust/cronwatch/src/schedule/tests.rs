//! The SDK's schedule.test.ts and duration.test.ts, and what only the ports
//! have: zone names in any case, fixed offsets.

use super::*;
use crate::js::{date_utc, iso_string};

const MINUTE: i64 = 60_000;
const HOUR: i64 = 3_600_000;
const DAY: i64 = 86_400_000;

fn utc(y: i64, mo: i64, d: i64, h: i64, mi: i64, s: i64) -> i64 {
    date_utc(y, mo, d, h, mi, s, 0)
}

fn must(schedule: &str, zone: &str) -> Arc<Parsed> {
    parse(schedule, zone).unwrap()
}

fn due(p: &Parsed, last_run_at: Option<i64>, registered_at: i64, grace: f64) -> i64 {
    expect(p, last_run_at, registered_at, grace).expect("no expectation").due_at
}

#[test]
fn parse_accepts_cron_nicknames_and_intervals() {
    for s in ["0 2 * * *", "@hourly", "*/5 * * * *"] {
        assert_eq!(must(s, "").kind, ScheduleKind::Cron, "{s}");
    }
    let every = must("every 5m", "");
    assert!(every.is_interval());
    assert_eq!(every.every_ms, 5 * MINUTE);
    for (bad, want) in [
        ("every 500ms", "shorter than one second"),
        ("banana", "not a cron expression"),
        ("every banana", "not a duration"),
    ] {
        let err = parse(bad, "").unwrap_err();
        assert!(err.contains(want), "{bad}: {err}");
    }
}

#[test]
fn a_parsed_schedule_is_plain_data() {
    assert_eq!(
        must("0 2 * * *", "UTC").to_value().to_json(),
        r#"{"kind":"cron","source":"0 2 * * *","timezone":"UTC"}"#
    );
    assert_eq!(
        must(" every 90s ", "UTC").to_value().to_json(),
        r#"{"kind":"interval","source":"every 90s","everyMs":90000}"#
    );
}

#[test]
fn next_fire_of_crons_and_intervals() {
    let daily = must("0 2 * * *", "");
    assert_eq!(next_fire(&daily, utc(2026, 0, 5, 9, 30, 0), None), Some(utc(2026, 0, 6, 2, 0, 0)));
    let every = must("every 1h", "");
    assert_eq!(next_fire(&every, 1_000, Some(500)), Some(500 + HOUR));
    assert_eq!(next_fire(&every, 1_000, None), Some(1_000 + HOUR));
    // July, EDT (UTC-4): 02:00 local is 06:00Z.
    let toronto = must("0 2 * * *", "America/Toronto");
    assert_eq!(next_fire(&toronto, utc(2026, 6, 10, 0, 0, 0), None), Some(utc(2026, 6, 10, 6, 0, 0)));
}

#[test]
fn expectation_for_a_cron_counts_forward_from_the_last_run() {
    let daily = must("0 2 * * *", "");
    let registered = utc(2026, 0, 4, 12, 0, 0);
    let first = expect(&daily, None, registered, (10 * MINUTE) as f64).unwrap();
    assert_eq!(first.due_at, utc(2026, 0, 5, 2, 0, 0));
    assert_eq!(first.deadline, utc(2026, 0, 5, 2, 10, 0) as f64);
    assert_eq!(
        due(&daily, None, utc(2026, 0, 5, 2, 0, 0), 0.0),
        utc(2026, 0, 5, 2, 0, 0),
        "a fire at registration counts"
    );
    let cases = [
        (utc(2026, 0, 5, 2, 0, 5), utc(2026, 0, 6, 2, 0, 0)), // ran at 02:00:05: the 6th is next
        (utc(2026, 0, 5, 1, 59, 30), utc(2026, 0, 6, 2, 0, 0)), // 30 seconds early still covers 02:00
        (utc(2026, 0, 5, 1, 58, 0), utc(2026, 0, 5, 2, 0, 0)), // two minutes early does not
    ];
    for (ran, want) in cases {
        assert_eq!(due(&daily, Some(ran), registered, 0.0), want, "ran {}", iso_string(ran));
    }
}

#[test]
fn one_run_of_an_every_minute_cron_covers_one_fire() {
    let minutely = must("* * * * *", "");
    let t0 = utc(2026, 0, 5, 9, 0, 0);
    assert_eq!(due(&minutely, Some(t0), t0 - HOUR, 0.0), t0 + MINUTE, "a run on 09:00 covers 09:00 only");
    assert_eq!(
        due(&minutely, Some(t0 + 50_000), t0 - HOUR, 0.0),
        t0 + 2 * MINUTE,
        "a run at 09:00:50 is early for 09:01"
    );
}

#[test]
fn expectation_for_yearly_crons_and_intervals() {
    let yearly = must("0 0 1 1 *", "UTC");
    let last = utc(2026, 0, 1, 0, 0, 3);
    assert_eq!(due(&yearly, Some(last), last - DAY, (10 * MINUTE) as f64), utc(2027, 0, 1, 0, 0, 0));
    let leap = must("0 0 29 2 *", "UTC");
    assert_eq!(due(&leap, Some(utc(2024, 1, 29, 0, 0, 1)), 0, 0.0), utc(2028, 1, 29, 0, 0, 0));
    let every = must("every 1h", "");
    let now = utc(2026, 0, 5, 9, 30, 0);
    let e = expect(&every, Some(now - 2 * HOUR), now - DAY, (5 * MINUTE) as f64).unwrap();
    assert_eq!(e.due_at, now - HOUR);
    assert_eq!(e.deadline, (now - HOUR + 5 * MINUTE) as f64);
    assert_eq!(due(&every, None, now - 30 * MINUTE, (5 * MINUTE) as f64), now + 30 * MINUTE);
}

#[test]
fn spring_forward_run_at_the_jump_covers_a_moved_fire() {
    // 2026-03-08, America/New_York: 02:00 EST jumps to 03:00 EDT at 07:00Z.
    // croner moves the nonexistent 02:30 to 03:30 EDT (07:30Z); vixie cron
    // runs it at 03:00 EDT.
    let tz = "America/New_York";
    let daily = must("30 2 * * *", tz);
    assert_eq!(due(&daily, Some(utc(2026, 2, 7, 7, 30, 0)), 0, 0.0), utc(2026, 2, 8, 7, 30, 0));
    assert_eq!(
        due(&daily, Some(utc(2026, 2, 8, 7, 0, 2)), 0, 0.0),
        utc(2026, 2, 9, 6, 30, 0),
        "the vixie run covers the day"
    );
    assert_eq!(due(&daily, Some(utc(2026, 2, 8, 7, 30, 1)), 0, 0.0), utc(2026, 2, 9, 6, 30, 0), "so does croner's");
    // A cron that fires at the jump itself was not moved: a run then covers only that fire.
    assert_eq!(due(&must("*/10 * * * *", tz), Some(utc(2026, 2, 8, 7, 0, 2)), 0, 0.0), utc(2026, 2, 8, 7, 10, 0));
    assert_eq!(due(&must("0 * * * *", tz), Some(utc(2026, 2, 8, 7, 0, 2)), 0, 0.0), utc(2026, 2, 8, 8, 0, 0));
}

#[test]
fn run_covers_allows_a_minute_at_most_half_the_gap() {
    let d = utc(2026, 0, 5, 2, 0, 0);
    let cases = [
        (d, None, true),
        (d - 59_000, None, true),
        (d + 5 * MINUTE, None, true),
        (d - 61_000, None, false),
        (d - 30_000, Some(d + MINUTE), true),
        (d - 31_000, Some(d + MINUTE), false),
    ];
    for (started, following, want) in cases {
        assert_eq!(run_covers(started, d, following), want, "run_covers({})", started - d);
    }
}

#[test]
fn fires_between_a_span() {
    let hourly = must("0 * * * *", "UTC");
    let from = utc(2026, 0, 5, 9, 30, 0);
    let fires = fires_between(&hourly, from, from + 24 * HOUR, 100).unwrap();
    assert_eq!(fires.len(), 24);
    let mut next = from;
    for fire in fires {
        next = next_fire(&hourly, next, None).unwrap();
        assert_eq!(fire, next, "fires_between and next_fire disagree");
    }
    assert!(fires_between(&hourly, from, from + 24 * HOUR, 23).is_none(), "more than the limit is none");
    assert_eq!(fires_between(&must("0 3 * * *", "UTC"), from, from + HOUR, 5), Some(vec![]), "an empty span is empty");
    // The night clocks go back in New York: fires only ever move forward.
    let night = fires_between(
        &must("30 * * * *", "America/New_York"),
        utc(2026, 10, 1, 4, 0, 0),
        utc(2026, 10, 1, 9, 0, 0),
        20,
    )
    .unwrap();
    assert!(night.windows(2).all(|w| w[1] > w[0]), "fires went backwards");
    assert!((4..=5).contains(&night.len()), "{} fires in the night", night.len());
}

#[test]
fn a_date_no_month_has_never_fires() {
    // croner runs out of stack here; the port walks in a loop and gives up
    // at the year croner does.
    let p = must("0 0 30 2 *", "UTC");
    assert_eq!(next_fire(&p, utc(2026, 0, 1, 0, 0, 0), None), None);
    assert_eq!(expect(&p, None, utc(2026, 0, 1, 0, 0, 0), 0.0), None);
}

#[test]
fn one_time_dates_are_refused() {
    for (text, want) in [
        ("2026-12-01T00:00:00", "CronPattern: a one-time date is not supported by the Rust port"),
        ("0 2:30 * * *", "Invalid ISO8601 passed to timezone parser."),
    ] {
        let err = parse(text, "").unwrap_err();
        assert!(err.ends_with(&format!(": {want}")), "{text}: {err}");
    }
}

#[test]
fn zones() {
    for name in [
        "America/New_York",
        "america/new_york",
        "AMERICA/NEW_YORK",
        "utc",
        "UTC",
        "Etc/GMT+5",
        "etc/gmt+5",
        "+05:30",
        "-0800",
        "+05",
    ] {
        assert!(is_timezone(name), "{name} should be a zone");
    }
    for name in
        ["", "Local", "local", "Bogus/Zone", "+25:00", "+5", "America/New_York/../New_York", "a\0b", "Etc/Unknown"]
    {
        assert!(!is_timezone(name), "{name:?} should not be a zone");
    }
    // A zone named in another case reads the same as its own spelling.
    let lower = must("0 2 * * *", "america/new_york");
    let right = must("0 2 * * *", "America/New_York");
    let from = utc(2026, 6, 10, 0, 0, 0);
    assert_eq!(next_fire(&lower, from, None), Some(utc(2026, 6, 10, 6, 0, 0)));
    assert_eq!(next_fire(&right, from, None), Some(utc(2026, 6, 10, 6, 0, 0)));
    assert_eq!(lower.to_value().to_json(), r#"{"kind":"cron","source":"0 2 * * *","timezone":"america/new_york"}"#);
    let offset = must("0 2 * * *", "+05:30");
    assert_eq!(next_fire(&offset, utc(2026, 0, 1, 0, 0, 0), None), Some(utc(2026, 0, 1, 20, 30, 0)));
    let err = parse("0 2 * * *", "Bogus/Zone").unwrap_err();
    assert!(err.starts_with("CronDate: Failed to convert date to timezone 'Bogus/Zone'"), "{err}");
    assert!(load_zone("").is_ok(), "no zone is the process's");
    assert_eq!(load_zone("nowhere").unwrap_err(), r#"timezone "nowhere" is not an IANA timezone"#);
}

#[test]
fn parse_is_safe_from_many_threads() {
    let threads: Vec<_> = (0..32)
        .map(|_| {
            std::thread::spawn(|| {
                for j in 0..50 {
                    let p = parse("*/15 * * * *", "Europe/London").unwrap();
                    next_fire(&p, utc(2026, 9, 25, 0, 0, j), None);
                }
            })
        })
        .collect();
    for t in threads {
        t.join().unwrap();
    }
}

#[test]
fn parse_duration_text_and_numbers() {
    let good = [
        ("15m", 900_000.0),
        ("1h30m", 5_400_000.0),
        ("90s", 90_000.0),
        ("2d", 172_800_000.0),
        ("1w", 604_800_000.0),
        ("250ms", 250.0),
        (" 1h 5m ", 3_900_000.0),
        ("1.5h", 5_400_000.0),
    ];
    for (text, want) in good {
        assert_eq!(parse_duration_text(text, ""), Ok(want), "{text:?}");
    }
    for (n, want) in [(1234.0, 1234.0), (5.0, 5.0), (1.5, 1.5)] {
        assert_eq!(parse_duration(&Value::Number(n), ""), Ok(want));
    }
    for bad in ["", "abc", "5", "5 minutes", "-1m", "1m2"] {
        let err = parse_duration_text(bad, "").unwrap_err();
        assert!(err.contains("duration"), "{bad:?}: {err}");
    }
    assert_eq!(
        parse_duration(&Value::Number(-5.0), "grace").unwrap_err(),
        "grace must be a non-negative number of milliseconds"
    );
    assert_eq!(
        parse_duration(&Value::Bool(true), "grace").unwrap_err(),
        r#"grace "true" is not a duration like "15m", "1h30m" or "90s""#
    );
    assert_eq!(
        parse_duration(&Value::Object(Object::new()), "grace").unwrap_err(),
        r#"grace "[object Object]" is not a duration like "15m", "1h30m" or "90s""#
    );
}

#[test]
fn a_duration_over_64_characters_is_refused_quoting_its_first_32() {
    // The audit: the scan is quadratic on a long run of digits, and the
    // error quoted the whole value. The conformance cases replay the cap.
    let too_long = "is too long for a duration (more than 64 characters)";
    let text = |s: &str, label: &str| parse_duration(&Value::String(s.into()), label);
    assert_eq!(text(&"1m".repeat(32), ""), Ok(32.0 * 60_000.0));
    let long = format!(" {}", "1m".repeat(32));
    assert_eq!(text(&long, "grace").unwrap_err(), format!("grace \"{}...\" {too_long}", &long[..32]));
    // Characters are code points: forty emoji are eighty UTF-16 units but under the cap.
    let forty = "\u{1f600}".repeat(40);
    assert_eq!(
        text(&forty, "").unwrap_err(),
        format!(r#"duration "{forty}" is not a duration like "15m", "1h30m" or "90s""#)
    );
    assert_eq!(
        text(&"\u{1f600}".repeat(65), "").unwrap_err(),
        format!("duration \"{}...\" {too_long}", "\u{1f600}".repeat(32))
    );
    let started = std::time::Instant::now();
    assert_eq!(
        text(&"1".repeat(1 << 20), "silence duration").unwrap_err(),
        format!("silence duration \"{}...\" {too_long}", "1".repeat(32))
    );
    assert!(started.elapsed() < std::time::Duration::from_secs(1));
}

#[test]
fn format_duration_and_relative() {
    for (ms, want) in
        [(500.0, "500ms"), (1_000.0, "1s"), (90_000.0, "1m 30s"), ((HOUR * 26 + MINUTE * 5) as f64, "1d 2h")]
    {
        assert_eq!(format_duration(ms), want);
    }
    assert_eq!(format_relative(1_000_000, 1_120_000), "2m ago");
    assert_eq!(format_relative(1_120_000, 1_000_000), "in 2m");
    assert_eq!(format_relative(1_000_000, 1_002_000), "now");
}
