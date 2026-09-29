use crate::js::{format_number, is_space, len16, trim};

/// What croner throws for an expression it will not read: its message.
pub(crate) type Error = String;

// Croner's bits for "the nth weekday of the month"; 32 is the last one, 63 any.
pub(super) const NTH_BITS: [i32; 5] = [1, 2, 4, 8, 16];
pub(super) const LAST_BIT: i32 = 32;
pub(super) const ANY_BITS: i32 = 63;

const MONTH_NAMES: [&str; 12] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const DAY_NAMES: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

/// The fields of a pattern, by croner's names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    Second,
    Minute,
    Hour,
    Day,
    Month,
    DayOfWeek,
    Year,
    NearestWeekdays,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Second => "second",
            Kind::Minute => "minute",
            Kind::Hour => "hour",
            Kind::Day => "day",
            Kind::Month => "month",
            Kind::DayOfWeek => "dayOfWeek",
            Kind::Year => "year",
            Kind::NearestWeekdays => "nearestWeekdays",
        }
    }

    /// How many entries the field's table has, as croner sizes them.
    fn size(self) -> usize {
        match self {
            Kind::Second | Kind::Minute => 60,
            Kind::Hour => 24,
            Kind::Day | Kind::NearestWeekdays => 31,
            Kind::Month => 12,
            Kind::DayOfWeek => 7,
            Kind::Year => 10_000,
        }
    }
}

/// What a field's table is set to: 1 (a match), croner's 63 for any nth
/// weekday, or the text of a day-of-week modifier ("2" of "1#2", "L").
#[derive(Clone, Debug)]
struct Val {
    n: i32,
    s: Option<String>,
}

impl Val {
    fn n(n: i32) -> Self {
        Val { n, s: None }
    }
}

/// Croner's CronPattern: the fields of an expression as tables of what
/// matches.
#[derive(Clone, Debug)]
pub(crate) struct Pattern {
    pattern: String,
    pub(super) second: [i32; 60],
    pub(super) minute: [i32; 60],
    pub(super) hour: [i32; 24],
    pub(super) day: [i32; 31],
    pub(super) month: [i32; 12],
    pub(super) day_of_week: [i32; 7],
    pub(super) nearest_weekdays: [i32; 31],
    // The years that match: every one ("*"), or the table croner keeps,
    // made only when the field names years.
    every_year: bool,
    years: Option<Vec<bool>>,

    pub(super) last_day_of_month: bool,
    pub(super) last_weekday: bool,
    pub(super) star_dom: bool,
    pub(super) star_dow: bool,
    pub(super) star_year: bool,
    pub(super) use_and_logic: bool,
}

impl Pattern {
    /// Reads an expression as croner's CronPattern does.
    pub(crate) fn new(text: &str) -> Result<Pattern, Error> {
        let mut p = Pattern {
            pattern: text.to_string(),
            second: [0; 60],
            minute: [0; 60],
            hour: [0; 24],
            day: [0; 31],
            month: [0; 12],
            day_of_week: [0; 7],
            nearest_weekdays: [0; 31],
            every_year: false,
            years: None,
            last_day_of_month: false,
            last_weekday: false,
            star_dom: false,
            star_dow: false,
            star_year: false,
            use_and_logic: false,
        };
        p.parse()?;
        Ok(p)
    }

    pub(super) fn table(&self, k: Kind) -> &[i32] {
        match k {
            Kind::Second => &self.second,
            Kind::Minute => &self.minute,
            Kind::Hour => &self.hour,
            Kind::Day => &self.day,
            Kind::Month => &self.month,
            Kind::DayOfWeek => &self.day_of_week,
            Kind::NearestWeekdays => &self.nearest_weekdays,
            Kind::Year => &[],
        }
    }

    fn table_mut(&mut self, k: Kind) -> &mut [i32] {
        match k {
            Kind::Second => &mut self.second,
            Kind::Minute => &mut self.minute,
            Kind::Hour => &mut self.hour,
            Kind::Day => &mut self.day,
            Kind::Month => &mut self.month,
            Kind::DayOfWeek => &mut self.day_of_week,
            Kind::NearestWeekdays => &mut self.nearest_weekdays,
            Kind::Year => &mut [],
        }
    }

    /// Croner's `year[y]`: whether year `y` matches (0 outside the table).
    pub(super) fn has_year(&self, y: i64) -> bool {
        if !(0..10_000).contains(&y) {
            return false;
        }
        self.every_year || self.years.as_ref().is_some_and(|t| t[y as usize])
    }

    fn parse(&mut self) -> Result<(), Error> {
        if self.pattern.contains('@') {
            let text = nicknames(&self.pattern)?;
            self.pattern = trim(&text).to_string();
        }
        let mut parts: Vec<String> =
            self.pattern.split(is_space).filter(|s| !s.is_empty()).map(str::to_string).collect();
        if parts.is_empty() {
            parts.push(String::new());
        }
        if parts.len() < 5 || parts.len() > 7 {
            return Err(format!(
                "CronPattern: invalid configuration format ('{}'), exactly five, six, or seven space separated parts are required.",
                self.pattern
            ));
        }
        if parts.len() == 5 {
            parts.insert(0, "0".into());
        }
        if parts.len() == 6 {
            parts.push("*".into());
        }
        if parts[3].to_uppercase() == "LW" {
            self.last_weekday = true;
            parts[3].clear();
        } else if parts[3].to_uppercase().contains('L') {
            parts[3] = replace_fold(&parts[3], "l", "");
            self.last_day_of_month = true;
        }
        if parts[3] == "*" {
            self.star_dom = true;
        }
        if parts[6] == "*" {
            self.star_year = true;
        }
        if len16(&parts[4]) >= 3 {
            for (i, name) in MONTH_NAMES.iter().enumerate() {
                parts[4] = replace_fold(&parts[4], name, &(i + 1).to_string());
            }
        }
        if len16(&parts[5]) >= 3 {
            parts[5] = replace_fold(&parts[5], "-sun", "-7");
            for (i, name) in DAY_NAMES.iter().enumerate() {
                parts[5] = replace_fold(&parts[5], name, &i.to_string());
            }
        }
        if let Some(rest) = parts[5].strip_prefix('+') {
            self.use_and_logic = true;
            parts[5] = rest.to_string();
            if parts[5].is_empty() {
                return Err("CronPattern: Day-of-week field cannot be empty after '+' modifier.".into());
            }
        }
        if parts[5] == "*" {
            self.star_dow = true;
        }
        if self.pattern.contains('?') {
            for part in &mut parts {
                *part = part.replace('?', "*");
            }
        }
        illegal_characters(&parts)?;
        let fields = [
            (Kind::Second, 0.0, Val::n(1)),
            (Kind::Minute, 0.0, Val::n(1)),
            (Kind::Hour, 0.0, Val::n(1)),
            (Kind::Day, -1.0, Val::n(1)),
            (Kind::Month, -1.0, Val::n(1)),
            (Kind::DayOfWeek, 0.0, Val::n(ANY_BITS)),
            (Kind::Year, 0.0, Val::n(1)),
        ];
        for (i, (k, offset, v)) in fields.iter().enumerate() {
            self.part(*k, &parts[i], *offset, v)?;
        }
        Ok(())
    }

    fn part(&mut self, k: Kind, text: &str, offset: f64, v: &Val) -> Result<(), Error> {
        let last_dom = k == Kind::Day && self.last_day_of_month;
        let last_wd = k == Kind::Day && self.last_weekday;
        if text.is_empty() && !last_dom && !last_wd {
            return Err(format!(
                "CronPattern: configuration entry {} ({text}) is empty, check for trailing spaces.",
                k.name()
            ));
        }
        if text == "*" {
            if k == Kind::Year {
                self.every_year = true;
                return Ok(());
            }
            self.table_mut(k).fill(v.n);
            return Ok(());
        }
        let items: Vec<&str> = text.split(',').collect();
        if items.len() > 1 {
            for item in items {
                self.part(k, item, offset, v)?;
            }
        } else if text.contains('-') && text.contains('/') {
            return self.range_with_stepping(text, k, offset, v);
        } else if text.contains('-') {
            return self.range_of(text, k, offset, v);
        } else if text.contains('/') {
            return self.stepping(text, k, v);
        } else if !text.is_empty() {
            return self.number(text, k, offset, v);
        }
        Ok(())
    }

    fn number(&mut self, text: &str, k: Kind, offset: f64, v: &Val) -> Result<(), Error> {
        let (base, nth) = extract_nth(text, k)?;
        let nearest = text.to_uppercase().contains('W');
        if k != Kind::Day && nearest {
            return Err("CronPattern: Nearest weekday modifier (W) only allowed in day-of-month.".into());
        }
        let k = if nearest { Kind::NearestWeekdays } else { k };
        let n = parse_int(base);
        if n.is_nan() {
            return Err(format!("CronPattern: {} is not a number: '{text}'", k.name()));
        }
        self.set(k, n + offset, &modifier_or(nth, v))
    }

    fn set(&mut self, k: Kind, at: f64, v: &Val) -> Result<(), Error> {
        if k == Kind::DayOfWeek {
            let at = if at == 7.0 { 0.0 } else { at };
            if !(0.0..=6.0).contains(&at) {
                return Err(format!("CronPattern: Invalid value for dayOfWeek: {}", format_number(at)));
            }
            return self.nth_weekday(at as usize, v);
        }
        if k == Kind::Year {
            if !(1.0..10_000.0).contains(&at) {
                return Err(format!(
                    "CronPattern: Invalid value for {}: {} (supported range: 1-9999)",
                    k.name(),
                    format_number(at)
                ));
            }
            let years = self.years.get_or_insert_with(|| vec![false; 10_000]);
            years[at as usize] = v.n != 0 || v.s.is_some();
            return Ok(());
        }
        if !(at >= 0.0 && at < k.size() as f64) {
            return Err(format!("CronPattern: Invalid value for {}: {}", k.name(), format_number(at)));
        }
        self.table_mut(k)[at as usize] = v.n;
        Ok(())
    }

    fn range_with_stepping(&mut self, text: &str, k: Kind, offset: f64, v: &Val) -> Result<(), Error> {
        if text.to_uppercase().contains('W') {
            return Err("CronPattern: Syntax error, W is not allowed in ranges with stepping.".into());
        }
        let (base, nth) = extract_nth(text, k)?;
        // /^(\d+)-(\d+)\/(\d+)$/
        let illegal = || format!("CronPattern: Syntax error, illegal range with stepping: '{text}'");
        let (range, step_text) = base.split_once('/').ok_or_else(illegal)?;
        let (low_text, high_text) = range.split_once('-').ok_or_else(illegal)?;
        if !digits_only(low_text) || !digits_only(high_text) || !digits_only(step_text) {
            return Err(illegal());
        }
        let low = low_text.parse::<f64>().unwrap_or(f64::NAN) + offset;
        let high = high_text.parse::<f64>().unwrap_or(f64::NAN) + offset;
        let step = step_text.parse::<f64>().unwrap_or(f64::NAN);
        validate_range(low, high, Some(step), k.size(), text)?;
        let v = modifier_or(nth, v);
        let mut at = low;
        while at <= high {
            self.set(k, at, &v)?;
            at += step;
        }
        Ok(())
    }

    fn range_of(&mut self, text: &str, k: Kind, offset: f64, v: &Val) -> Result<(), Error> {
        if text.to_uppercase().contains('W') {
            return Err("CronPattern: Syntax error, W is not allowed in a range.".into());
        }
        let (base, nth) = extract_nth(text, k)?;
        let bounds: Vec<&str> = base.split('-').collect();
        if bounds.len() != 2 {
            return Err(format!("CronPattern: Syntax error, illegal range: '{text}'"));
        }
        let (low, high) = (parse_int(bounds[0]), parse_int(bounds[1]));
        if low.is_nan() {
            return Err("CronPattern: Syntax error, illegal lower range (NaN)".into());
        }
        if high.is_nan() {
            return Err("CronPattern: Syntax error, illegal upper range (NaN)".into());
        }
        let (low, high) = (low + offset, high + offset);
        validate_range(low, high, None, k.size(), text)?;
        let v = modifier_or(nth, v);
        let mut at = low;
        while at <= high {
            self.set(k, at, &v)?;
            at += 1.0;
        }
        Ok(())
    }

    fn stepping(&mut self, text: &str, k: Kind, v: &Val) -> Result<(), Error> {
        if text.to_uppercase().contains('W') {
            return Err("CronPattern: Syntax error, W is not allowed in parts with stepping.".into());
        }
        let (base, nth) = extract_nth(text, k)?;
        let parts: Vec<&str> = base.split('/').collect();
        if parts.len() != 2 {
            return Err(format!("CronPattern: Syntax error, illegal stepping: '{text}'"));
        }
        if parts[0].is_empty() {
            return Err(format!(
                "CronPattern: Syntax error, stepping with missing prefix ('{text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead."
            ));
        }
        if parts[0] != "*" {
            return Err(format!(
                "CronPattern: Syntax error, stepping with numeric prefix ('{text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead."
            ));
        }
        let step = parse_int(parts[1]);
        if step.is_nan() {
            return Err("CronPattern: Syntax error, illegal stepping: (NaN)".into());
        }
        let size = k.size();
        validate_range(0.0, (size - 1) as f64, Some(step), size, text)?;
        if step > 0.0 {
            let v = modifier_or(nth, v);
            let mut at = 0.0;
            while at < size as f64 {
                self.set(k, at, &v)?;
                at += step;
            }
        }
        Ok(())
    }

    fn nth_weekday(&mut self, day: usize, nth: &Val) -> Result<(), Error> {
        if let Some(s) = &nth.s {
            if s.to_uppercase() == "L" {
                self.day_of_week[day] |= LAST_BIT;
                return Ok(());
            }
        } else if nth.n == ANY_BITS {
            self.day_of_week[day] = ANY_BITS;
            return Ok(());
        }
        let n = match &nth.s {
            Some(s) => to_number(s),
            None => f64::from(nth.n),
        };
        if n < 6.0 && n > 0.0 {
            let index = n - 1.0;
            if index == index.floor() && index >= 0.0 && (index as usize) < NTH_BITS.len() {
                self.day_of_week[day] |= NTH_BITS[index as usize];
            }
            return Ok(());
        }
        match &nth.s {
            Some(s) => {
                Err(format!("CronPattern: nth weekday out of range, should be 1-5 or L. Value: {s}, Type: string"))
            }
            None => Err(format!(
                "CronPattern: nth weekday out of range, should be 1-5 or L. Value: {}, Type: number",
                format_number(n)
            )),
        }
    }
}

/// Croner's `nth[1] || value`: the modifier when there is one, else the
/// field's value.
fn modifier_or(nth: Option<&str>, v: &Val) -> Val {
    match nth {
        Some(s) if !s.is_empty() => Val { n: 0, s: Some(s.to_string()) },
        _ => v.clone(),
    }
}

fn nicknames(pattern: &str) -> Result<String, Error> {
    Ok(match trim(pattern).to_lowercase().as_str() {
        "@yearly" | "@annually" => "0 0 1 1 *".into(),
        "@monthly" => "0 0 1 * *".into(),
        "@weekly" => "0 0 * * 0".into(),
        "@daily" | "@midnight" => "0 0 * * *".into(),
        "@hourly" => "0 * * * *".into(),
        "@reboot" => {
            return Err("CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection.".into());
        }
        _ => pattern.to_string(),
    })
}

/// Croner's check of each field's characters: digits, "/*,-" everywhere, W
/// and L in the day of the month, # and L in the day of the week.
fn illegal_characters(parts: &[String]) -> Result<(), Error> {
    for (i, part) in parts.iter().enumerate() {
        let extra = match i {
            3 => "WwLl",
            5 => "#Ll",
            _ => "",
        };
        if part.chars().any(|c| !"/*0123456789,-".contains(c) && !extra.contains(c)) {
            return Err(format!("CronPattern: configuration entry {i} ({part}) contains illegal characters."));
        }
    }
    Ok(())
}

fn validate_range(low: f64, high: f64, step: Option<f64>, size: usize, text: &str) -> Result<(), Error> {
    if low > high {
        return Err(format!("CronPattern: From value is larger than to value: '{text}'"));
    }
    if let Some(step) = step {
        if step == 0.0 {
            return Err("CronPattern: Syntax error, illegal stepping: 0".into());
        }
        if step > size as f64 {
            return Err(format!(
                "CronPattern: Syntax error, steps cannot be greater than maximum value of part ({size})"
            ));
        }
    }
    Ok(())
}

/// Whether `s` is one or more ASCII digits.
fn digits_only(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit())
}

/// Splits a day-of-week modifier off: "1#2" is 1 and "2", "5L" is 5 and "L".
/// Anywhere else a modifier is an error.
fn extract_nth(text: &str, k: Kind) -> Result<(&str, Option<&str>), Error> {
    if text.contains('#') {
        if k != Kind::DayOfWeek {
            return Err("CronPattern: nth (#) only allowed in day-of-week field".into());
        }
        let mut pieces = text.split('#');
        let base = pieces.next().unwrap_or("");
        return Ok((base, Some(pieces.next().unwrap_or(""))));
    }
    if text.to_uppercase().ends_with('L') {
        if k != Kind::DayOfWeek {
            return Err(
                "CronPattern: L modifier only allowed in day-of-week field (use L alone for day-of-month)".into()
            );
        }
        return Ok((&text[..text.len() - 1], Some("L")));
    }
    Ok((text, None))
}

/// Replaces every occurrence of an ASCII word, matched without regard to
/// ASCII case (a JavaScript /gi regular expression).
fn replace_fold(text: &str, word: &str, with: &str) -> String {
    let (t, w) = (text.as_bytes(), word.as_bytes());
    let mut b = Vec::with_capacity(t.len());
    let mut i = 0;
    while i < t.len() {
        if i + w.len() <= t.len() && t[i..i + w.len()].eq_ignore_ascii_case(w) {
            b.extend_from_slice(with.as_bytes());
            i += w.len();
            continue;
        }
        b.push(t[i]);
        i += 1;
    }
    String::from_utf8_lossy(&b).into_owned()
}

/// `parseInt(text, 10)`: NaN when no digits lead.
pub(super) fn parse_int(text: &str) -> f64 {
    let s = text.trim_start_matches(is_space).as_bytes();
    let mut i = 0;
    if i < s.len() && (s[i] == b'+' || s[i] == b'-') {
        i += 1;
    }
    let mut j = i;
    while j < s.len() && s[j].is_ascii_digit() {
        j += 1;
    }
    if j == i {
        return f64::NAN;
    }
    std::str::from_utf8(&s[..j]).ok().and_then(|n| n.parse().ok()).unwrap_or(f64::NAN)
}

/// JavaScript's `Number(text)` for the characters a field may hold: NaN
/// when it is not a number.
pub(super) fn to_number(text: &str) -> f64 {
    let s = trim(text);
    if s.is_empty() {
        return 0.0;
    }
    let b = s.as_bytes();
    let mut i = 0;
    if b[0] == b'+' || b[0] == b'-' {
        i += 1;
    }
    let (mut digits, mut dot, mut frac) = (0, false, 0);
    while i < b.len() {
        let c = b[i];
        if c.is_ascii_digit() {
            if dot {
                frac += 1;
            } else {
                digits += 1;
            }
        } else if c == b'.' && !dot {
            dot = true;
        } else if (c == b'e' || c == b'E') && digits + frac > 0 {
            let mut rest = &b[i + 1..];
            if !rest.is_empty() && (rest[0] == b'+' || rest[0] == b'-') {
                rest = &rest[1..];
            }
            if rest.is_empty() || !rest.iter().all(u8::is_ascii_digit) {
                return f64::NAN;
            }
            break;
        } else {
            return f64::NAN;
        }
        i += 1;
    }
    if digits + frac == 0 {
        return f64::NAN;
    }
    // Rust reads "2." and ".5" as JavaScript does, and out of range as
    // Infinity or 0.
    s.parse().unwrap_or(f64::NAN)
}
