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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_as_javascript_writes_them() {
        assert_eq!(iso_string(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_string(1_767_605_400_000), "2026-01-05T09:30:00.000Z");
        assert_eq!(iso_string(-1), "1969-12-31T23:59:59.999Z");
        assert_eq!(iso_string(253_402_300_800_000), "+010000-01-01T00:00:00.000Z");
        assert_eq!(date_utc(2026, 0, 5, 9, 30, 0, 0), 1_767_605_400_000);
        assert_eq!(date_utc(2025, 12, 5, 9, 30, 0, 0), 1_767_605_400_000);
        assert_eq!(civil_from_days(days_from_civil(2024, 2, 29)), (2024, 2, 29));
    }
}
