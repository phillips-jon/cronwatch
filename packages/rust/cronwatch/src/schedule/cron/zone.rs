//! Zones are jiff's (the system's database, `$TZDIR`, or the one jiff
//! bundles where the system has none), named as `Intl` names them: without
//! regard to case, so "america/new_york" is New York, as
//! `Intl.DateTimeFormat` reads it. A fixed offset ("+05:30", "-0800",
//! "+05") is a zone too, since `Intl` and croner both take one.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use jiff::Timestamp;
use jiff::tz::{Offset, TimeZone};

use crate::js::{civil_from_days, date_utc, floor_div};

static ZONES: LazyLock<Mutex<HashMap<String, TimeZone>>> = LazyLock::new(Default::default);

/// The zone an IANA name (or a fixed offset) names, matched without regard
/// to case; "" is the process's own zone, from `$TZ` or `/etc/localtime`.
pub(crate) fn load_zone(name: &str) -> Result<TimeZone, String> {
    if name.is_empty() {
        return Ok(TimeZone::system());
    }
    let mut zones = ZONES.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(tz) = zones.get(name) {
        return Ok(tz.clone());
    }
    let tz = find_zone(name).ok_or_else(|| format!("unknown time zone {}", crate::js::quote(name)))?;
    if zones.len() >= 1000 {
        zones.clear();
    }
    zones.insert(name.to_string(), tz.clone());
    Ok(tz)
}

fn find_zone(name: &str) -> Option<TimeZone> {
    // "Etc/Unknown" is jiff's name for a zone it could not find, not one
    // Intl takes; "Local" is no IANA zone either.
    if name.eq_ignore_ascii_case("local") || name.eq_ignore_ascii_case("etc/unknown") || name.contains('\0') {
        return None;
    }
    if let Some(tz) = fixed_offset(name) {
        return Some(tz);
    }
    if name.eq_ignore_ascii_case("utc") {
        return Some(TimeZone::UTC);
    }
    // jiff looks names up without regard to ASCII case, among the names the
    // database lists, so a path ("America/New_York/../New_York") is none.
    jiff::tz::db().get(name).ok()
}

/// Reads "+HH", "+HHMM" or "+HH:MM" (or "-"), as `Intl` reads an offset
/// time zone.
fn fixed_offset(name: &str) -> Option<TimeZone> {
    let b = name.as_bytes();
    if b.len() < 3 || (b[0] != b'+' && b[0] != b'-') {
        return None;
    }
    let rest = &name[1..];
    let (hh, mm) = match rest.len() {
        2 => (rest, "00"),
        4 => (rest.get(..2)?, rest.get(2..)?),
        5 if rest.as_bytes()[2] == b':' => (rest.get(..2)?, rest.get(3..)?),
        _ => return None,
    };
    if !hh.bytes().chain(mm.bytes()).all(|c| c.is_ascii_digit()) {
        return None;
    }
    let (h, m): (i32, i32) = (hh.parse().ok()?, mm.parse().ok()?);
    if h > 23 || m > 59 {
        return None;
    }
    let sec = (h * 60 + m) * 60;
    let sec = if b[0] == b'-' { -sec } else { sec };
    Some(TimeZone::fixed(Offset::from_seconds(sec).ok()?))
}

/// The seconds a zone's wall clock is ahead of UTC at epoch second `sec`.
/// Past the instants jiff holds (the years -9999 and 9999), the offset at
/// the end of its range.
pub(crate) fn offset(sec: i64, tz: &TimeZone) -> i64 {
    let sec = sec.clamp(Timestamp::MIN.as_second(), Timestamp::MAX.as_second());
    let at = Timestamp::from_second(sec).unwrap_or(Timestamp::UNIX_EPOCH);
    i64::from(tz.to_offset(at).seconds())
}

/// The wall clock at an epoch second: year, month (1 to 12), day, hour,
/// minute, second.
pub(crate) type Wall = [i64; 6];

pub(crate) fn wall_at(sec: i64, tz: &TimeZone) -> Wall {
    let local = sec + offset(sec, tz);
    let days = floor_div(local, 86_400);
    let rest = local - days * 86_400;
    let (y, m, d) = civil_from_days(days);
    [y, m, d, rest / 3600, rest % 3600 / 60, rest % 60]
}

/// A wall-clock time read as if it were UTC, in epoch seconds (croner's
/// `T()`).
fn civil_seconds(w: Wall) -> i64 {
    floor_div(date_utc(w[0], w[1] - 1, w[2], w[3], w[4], w[5], 0), 1000)
}

/// Croner's `fromTZ`: the instant a wall-clock time names, in epoch
/// seconds. A time in a spring-forward gap moves forward by the gap; a time
/// that happens twice (fall back) is the earlier of the two.
pub(crate) fn to_utc(w: Wall, tz: &TimeZone) -> i64 {
    let target = civil_seconds(w);
    let guess = target + (target - civil_seconds(wall_at(target, tz)));
    let seen = wall_at(guess, tz);
    if seen == w {
        let earlier = guess - 3600;
        if wall_at(earlier, tz) == w {
            return earlier;
        }
        return guess;
    }
    let shifted = guess + target - civil_seconds(seen);
    if wall_at(shifted, tz) == w {
        return shifted;
    }
    guess.max(shifted)
}
