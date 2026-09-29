use super::{floor_div, modulo};

/// The days since 1970-01-01 of a proleptic Gregorian date, month 1 to 12.
pub(crate) fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = floor_div(y, 400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The date of a day counted from 1970-01-01: year, month (1 to 12) and day.
pub(crate) fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = floor_div(z, 146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let mut y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mut m = mp + 3;
    if m > 12 {
        m -= 12;
    }
    if m <= 2 {
        y += 1;
    }
    (y, m, d)
}

/// `Date.UTC(year, month, day, hour, minute, second, ms)` with a 0-based
/// month, every field free to overflow into the next, as `Date.UTC` allows.
pub(crate) fn date_utc(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, ms: i64) -> i64 {
    let year = year + floor_div(month, 12);
    let month = modulo(month, 12);
    let days = days_from_civil(year, month + 1, 1) + day - 1;
    days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000 + ms
}

/// `new Date(ms).toISOString()`: `"2026-01-05T09:30:00.000Z"`, with a signed
/// six-digit year outside 0 to 9999.
pub(crate) fn iso_string(ms: i64) -> String {
    let days = floor_div(ms, 86_400_000);
    let rest = ms.rem_euclid(86_400_000);
    let (y, m, d) = civil_from_days(days);
    let year = if y < 0 {
        format!("-{:06}", -y)
    } else if y > 9999 {
        format!("+{y:06}")
    } else {
        format!("{y:04}")
    };
    format!(
        "{year}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z",
        rest / 3_600_000,
        rest / 60_000 % 60,
        rest / 1000 % 60,
        rest % 1000
    )
}

/// The first millisecond written as a date: 0001-01-01T00:00:00.000Z.
pub(crate) const FIRST_DATE_MS: i64 = -62_135_596_800_000;
/// The last millisecond written as a date: 9999-12-31T23:59:59.999Z.
pub(crate) const LAST_DATE_MS: i64 = 253_402_300_799_999;

/// Whether `ms` falls in the years 1 to 9999, the times written as dates.
pub(crate) fn in_date_range(ms: f64) -> bool {
    ms >= FIRST_DATE_MS as f64 && ms <= LAST_DATE_MS as f64
}

/// `"2026-01-05T09:30:00.000Z"`, or `None` for a time before the year 1 or
/// after 9999, such as a start read from a foreign or damaged row, which is
/// not written as a date at all (the SDK's `isoTime`).
pub(crate) fn iso_time(ms: i64) -> Option<String> {
    in_date_range(ms as f64).then(|| iso_string(ms))
}

/// The words that stand in for a time `iso_time` does not write (the SDK's
/// `beyondDates`).
pub(crate) fn beyond_dates(ms: f64) -> &'static str {
    if ms > LAST_DATE_MS as f64 { "after 9999-12-31 23:59:59 UTC" } else { "before 0001-01-01 00:00:00 UTC" }
}

/// `iso_time`, or the words for a time outside its years.
pub(crate) fn iso_or_words(ms: i64) -> String {
    iso_time(ms).unwrap_or_else(|| beyond_dates(ms as f64).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_as_javascript_writes_them() {
        assert_eq!(iso_string(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_string(1_767_605_400_000), "2026-01-05T09:30:00.000Z");
        assert_eq!(iso_string(-1), "1969-12-31T23:59:59.999Z");
        assert_eq!(iso_string(253_402_300_800_000), "+010000-01-01T00:00:00.000Z");
        assert_eq!(iso_time(FIRST_DATE_MS).as_deref(), Some("0001-01-01T00:00:00.000Z"));
        assert_eq!(iso_time(LAST_DATE_MS).as_deref(), Some("9999-12-31T23:59:59.999Z"));
        assert_eq!(iso_time(FIRST_DATE_MS - 1), None);
        assert_eq!(iso_time(LAST_DATE_MS + 1), None);
        assert_eq!(iso_or_words(i64::MIN), "before 0001-01-01 00:00:00 UTC");
        assert_eq!(iso_or_words(i64::MAX), "after 9999-12-31 23:59:59 UTC");
        assert_eq!(date_utc(2026, 0, 5, 9, 30, 0, 0), 1_767_605_400_000);
        assert_eq!(date_utc(2025, 12, 5, 9, 30, 0, 0), 1_767_605_400_000);
        assert_eq!(civil_from_days(days_from_civil(2024, 2, 29)), (2024, 2, 29));
    }
}
