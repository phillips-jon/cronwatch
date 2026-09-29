use super::*;

fn at(text: &str) -> DateTime<Utc> {
    text.parse().unwrap()
}

#[test]
fn a_schedule_in_utc_is_taken_as_it_is() {
    let got = convert("0 30 2 * * *", chrono_tz::UTC, "x", at("2026-09-01T00:00:00Z")).unwrap();
    assert_eq!(got, Converted { zone: "UTC".into(), note: None });
    let got = convert("*/15 * * * * *", chrono_tz::UTC, "x", at("2026-09-01T00:00:00Z")).unwrap();
    assert_eq!(got.zone, "UTC");
    let got = convert("0 0 9 * * MON-FRI", chrono_tz::Asia::Kolkata, "x", at("2026-09-01T00:00:00Z")).unwrap();
    assert_eq!(got, Converted { zone: "Asia/Kolkata".into(), note: None }, "a zone that never changes keeps its name");
}

#[test]
fn a_zone_with_daylight_saving_is_read_at_its_offset_when_made() {
    let summer = convert("0 0 2 * * *", chrono_tz::America::New_York, "x", at("2026-07-01T12:00:00Z")).unwrap();
    assert_eq!(summer.zone, "Etc/GMT+4");
    let note = summer.note.unwrap();
    assert!(note.starts_with("x is in America/New_York, which tokio-cron-scheduler reads at the offset it had when the job was made (-04:00)"), "{note}");
    let winter = convert("0 0 2 * * *", chrono_tz::America::New_York, "x", at("2026-12-01T12:00:00Z")).unwrap();
    assert_eq!(winter.zone, "Etc/GMT+5");
    let adelaide = convert("0 0 2 * * *", chrono_tz::Australia::Adelaide, "x", at("2026-07-01T12:00:00Z")).unwrap();
    assert_eq!(adelaide.zone, "+09:30");
}

#[test]
fn a_schedule_the_two_read_differently_is_refused() {
    // tokio-cron-scheduler matches both days; croner matches either.
    let err = convert("0 0 0 1 * MON", chrono_tz::UTC, "cronwatch: job", at("2026-09-01T00:00:00Z")).unwrap_err();
    assert!(err.message().starts_with(r#"cronwatch: job is "0 0 0 1 * MON" in UTC, but after a run at"#), "{err}");
    assert!(err.message().contains("tokio-cron-scheduler runs it next at"), "{err}");
    // Five fields: tokio-cron-scheduler asks for seconds.
    let err = convert("0 2 * * *", chrono_tz::UTC, "cronwatch: job", at("2026-09-01T00:00:00Z")).unwrap_err();
    assert!(err.message().contains("which tokio-cron-scheduler cannot read"), "{err}");
}

#[test]
fn schedules_the_two_agree_on_pass() {
    for expr in
        ["0 0 2 * * *", "0 */5 * * * *", "30 15 10 * * MON-FRI", "0 0 0 1 * *", "0 0 12 L * *", "0 0 6 * JAN,JUL *"]
    {
        let got = convert(expr, chrono_tz::UTC, "x", at("2026-09-01T00:00:00Z"));
        assert!(got.is_ok(), "{expr}: {got:?}");
    }
}

#[test]
fn offsets_are_named_for_every_port() {
    assert_eq!(offset_name(0), "UTC");
    assert_eq!(offset_name(-4 * 3600), "Etc/GMT+4");
    assert_eq!(offset_name(10 * 3600), "Etc/GMT-10");
    assert_eq!(offset_name(5 * 3600 + 1800), "+05:30");
    assert_eq!(offset_name(-(3 * 3600 + 1800)), "-03:30");
}

#[test]
fn daily_names_no_day_or_month() {
    assert!(daily("0 0 2 * * *"));
    assert!(daily("0 0 2 ? * *"));
    assert!(!daily("0 0 2 1 * *"));
    assert!(!daily("0 0 2 * * MON"));
    assert!(!daily("@daily"));
}

#[test]
fn zones_are_read_without_regard_to_case() {
    assert_eq!(zone("america/new_york").unwrap(), chrono_tz::America::New_York);
    assert_eq!(zone("").unwrap(), chrono_tz::UTC);
    assert!(matches!(zone("Mars/Olympus"), Err(Error::Timezone(_))));
}
