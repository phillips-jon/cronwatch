use jiff::tz::TimeZone;

use super::pattern::{ANY_BITS, Error, Kind, LAST_BIT, NTH_BITS, Pattern};
use super::zone::{to_utc, wall_at};
use crate::js::{civil_from_days, date_utc, floor_div, modulo};

const DAYS_IN_MONTH: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

// The fields of a date, by index.
const YEAR: usize = 0;
const MONTH: usize = 1;
const DAY: usize = 2;
const HOUR: usize = 3;
const MINUTE: usize = 4;
const SECOND: usize = 5;
const MILLIS: usize = 6;

/// A step of the walk: the field, the field above it, and the offset from a
/// field value to its pattern index (croner's fieldOrder).
#[derive(Clone, Copy)]
struct Step {
    field: usize,
    above: usize,
    k: Kind,
    offset: i64,
}

const ORDER: [Step; 5] = [
    Step { field: MONTH, above: YEAR, k: Kind::Month, offset: 0 },
    Step { field: DAY, above: MONTH, k: Kind::Day, offset: -1 },
    Step { field: HOUR, above: DAY, k: Kind::Hour, offset: 0 },
    Step { field: MINUTE, above: HOUR, k: Kind::Minute, offset: 0 },
    Step { field: SECOND, above: MINUTE, k: Kind::Second, offset: 0 },
];

/// Croner's CronDate: a wall-clock time whose fields are moved forward to
/// the next match, a field at a time, spilling into the next month or year
/// as croner does. The fields are year, month (0 based), day, hour, minute,
/// second and milliseconds.
#[derive(Clone, Debug)]
pub(super) struct Date {
    f: [i64; 7],
}

/// Croner's `getLastDayOfMonth`, month 0 based; None for a month outside 0
/// to 11 (croner's undefined).
fn last_day_of_month(year: i64, month: i64) -> Option<i64> {
    if month != 1 {
        return (0..12).contains(&month).then(|| DAYS_IN_MONTH[month as usize]);
    }
    Some(civil_from_days(floor_div(date_utc(year, month + 1, 0, 0, 0, 0, 0), 86_400_000)).2)
}

/// `new Date(Date.UTC(year, month, day)).getUTCDay()`, month 0 based and free
/// to overflow. 0 is Sunday.
fn weekday(year: i64, month: i64, day: i64) -> i64 {
    modulo(floor_div(date_utc(year, month, day, 0, 0, 0, 0), 86_400_000) + 4, 7)
}

impl Date {
    /// `new CronDate(new Date(at), tz)`.
    pub(super) fn from_ms(at: i64, tz: &TimeZone) -> Date {
        let sec = floor_div(at, 1000);
        let w = wall_at(sec, tz);
        Date { f: [w[0], w[1] - 1, w[2], w[3], w[4], w[5], at - sec * 1000] }
    }

    /// Croner's `apply()`: fields out of their range are carried into the
    /// fields above, as a Date made from them would be. It says whether it
    /// changed anything.
    fn apply(&mut self) -> bool {
        let [year, month, day, hour, minute, second, millis] = self.f;
        let out = !(0..12).contains(&month)
            || day > DAYS_IN_MONTH[month as usize]
            || day < 1
            || hour > 59
            || minute > 59
            || second > 59
            || hour < 0
            || minute < 0
            || second < 0;
        if !out {
            return false;
        }
        let at = date_utc(year, month, day, hour, minute, second, millis);
        let sec = floor_div(at, 1000);
        let days = floor_div(sec, 86_400);
        let rest = sec - days * 86_400;
        let (y, mo, d) = civil_from_days(days);
        self.f = [y, mo - 1, d, rest / 3600, rest % 3600 / 60, rest % 60, at - sec * 1000];
        true
    }

    fn last_weekday(year: i64, month: i64) -> i64 {
        let last = last_day_of_month(year, month).unwrap_or(0);
        match weekday(year, month, last) {
            0 => last - 2,
            6 => last - 1,
            _ => last,
        }
    }

    fn nearest_weekday(year: i64, month: i64, day: i64) -> i64 {
        let last = last_day_of_month(year, month);
        if last.is_some_and(|last| day > last) {
            return -1;
        }
        match weekday(year, month, day) {
            0 if last == Some(day) => day - 2,
            0 => day + 1,
            6 if day == 1 => day + 2,
            6 => day - 1,
            _ => day,
        }
    }

    fn is_nth_weekday(year: i64, month: i64, day: i64, bits: i32) -> bool {
        let wd = weekday(year, month, day);
        let count = (1..=day).filter(|&x| weekday(year, month, x) == wd).count();
        if bits & ANY_BITS != 0 && (1..=NTH_BITS.len()).contains(&count) && NTH_BITS[count - 1] & bits != 0 {
            return true;
        }
        if bits & LAST_BIT != 0 {
            let last = last_day_of_month(year, month).unwrap_or(0);
            return !(day + 1..=last).any(|x| weekday(year, month, x) == wd);
        }
        false
    }

    /// Croner's `findNext`: 1 when the field already matches, 2 when it was
    /// moved forward to a match, 3 when none is left in its range.
    fn find_next(&mut self, p: &Pattern, s: Step) -> Result<i32, Error> {
        let before = self.f[s.field];
        let table = p.table(s.k);
        let size = table.len() as i64;
        let (year, month) = (self.f[YEAR], self.f[MONTH]);
        let last = if p.last_day_of_month { last_day_of_month(year, month) } else { None };
        let first_weekday = if !p.star_dow && s.k == Kind::Day { weekday(year, month, 1) } else { 0 };
        let mut u = before + s.offset;
        while u < size {
            let mut matched = if u >= 0 { table[u as usize] } else { 0 };
            if s.k == Kind::Day && matched == 0 {
                for (c, &nearest) in p.nearest_weekdays.iter().enumerate() {
                    if nearest != 0 {
                        let m = Self::nearest_weekday(year, month, c as i64 - s.offset);
                        if m == -1 {
                            continue;
                        }
                        if m == u - s.offset {
                            matched = 1;
                            break;
                        }
                    }
                }
            }
            if s.k == Kind::Day && p.last_weekday && u - s.offset == Self::last_weekday(year, month) {
                matched = 1;
            }
            if s.k == Kind::Day && p.last_day_of_month && last == Some(u - s.offset) {
                matched = 1;
            }
            if s.k == Kind::Day && !p.star_dow {
                let mut bits = p.day_of_week[modulo(first_weekday + (u - s.offset - 1), 7) as usize];
                if bits != 0 && bits & ANY_BITS != 0 {
                    bits = i32::from(Self::is_nth_weekday(year, month, u - s.offset, bits));
                } else if bits != 0 {
                    return Err(format!("CronDate: Invalid value for dayOfWeek encountered. {bits}"));
                }
                if p.use_and_logic {
                    if matched != 0 {
                        matched = bits;
                    }
                } else if !p.star_dom {
                    if matched == 0 {
                        matched = bits;
                    }
                } else if matched != 0 {
                    matched = bits;
                }
            }
            if matched != 0 {
                self.f[s.field] = u - s.offset;
                return Ok(if before != self.f[s.field] { 2 } else { 1 });
            }
            u += 1;
        }
        Ok(3)
    }

    /// Croner's `recurse()`, walked in a loop: each field in turn from the
    /// month down is moved to its next match, a field that runs out carries
    /// into the one above and the walk starts again from the month. Croner
    /// recurses a year at a time, so for a date no month has it runs out of
    /// stack; the loop answers false (never) at the year croner gives up at.
    fn recurse(&mut self, p: &Pattern) -> Result<bool, Error> {
        const YEARS: i64 = 10_000;
        let n_order = ORDER.len() as i64;
        let mut level: i64 = 0;
        loop {
            if level == 0 && !p.star_year {
                let y = self.f[YEAR];
                if (0..YEARS).contains(&y) && !p.has_year(y) {
                    let Some(found) = (y + 1..YEARS).find(|&y| p.has_year(y)) else {
                        return Ok(false);
                    };
                    self.f = [found, 0, 1, 0, 0, 0, 0];
                }
                if self.f[YEAR] >= YEARS {
                    return Ok(false);
                }
            }
            // A level below 0 counts from the end, as a negative index does
            // in the Python port and in croner's own array lookup of it.
            let s = ORDER[level.rem_euclid(n_order) as usize];
            let n = self.find_next(p, s)?;
            if n > 1 {
                for i in level + 1..n_order {
                    let f = ORDER[i.rem_euclid(n_order) as usize];
                    self.f[f.field] = -f.offset;
                }
                if n == 3 {
                    self.f[s.above] += 1;
                    self.f[s.field] = -s.offset;
                    self.apply();
                    if level == 0 && !p.star_year {
                        while (0..YEARS).contains(&self.f[YEAR]) && !p.has_year(self.f[YEAR]) {
                            self.f[YEAR] += 1;
                        }
                        if self.f[YEAR] >= YEARS {
                            return Ok(false);
                        }
                    }
                    level = 0;
                    continue;
                }
                if self.apply() {
                    level -= 1;
                    continue;
                }
            }
            level += 1;
            if level >= n_order {
                return Ok(true);
            }
            if (p.star_year && self.f[YEAR] >= 3000) || (!p.star_year && self.f[YEAR] >= YEARS) {
                return Ok(false);
            }
        }
    }

    /// Croner's `increment()`: one second on, then the next match. False when
    /// there is none.
    pub(super) fn increment(&mut self, p: &Pattern) -> Result<bool, Error> {
        self.f[SECOND] += 1;
        self.f[MILLIS] = 0;
        self.apply();
        self.recurse(p)
    }

    /// `getDate(false).getTime()`: the instant this wall-clock time names.
    pub(super) fn time_ms(&self, tz: &TimeZone) -> i64 {
        let [y, m, d, h, mi, s, _] = self.f;
        to_utc([y, m + 1, d, h, mi, s], tz) * 1000
    }
}
