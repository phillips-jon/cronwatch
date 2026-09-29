//! Rows and parameters as the store and the pg_cron source use them, the
//! same on every database: a row is its columns by name, each value as the
//! database gave it (another writer may have given a column another type),
//! and a parameter is one of the types a JavaScript driver binds.

#![cfg_attr(not(any(feature = "sqlite", feature = "postgres", feature = "mysql")), allow(dead_code, unused_imports))]

use cronwatch::BoxError;
use cronwatch::js;

/// A column's value. Postgres alone gives timestamps, and SQLite no
/// booleans.
#[cfg_attr(not(feature = "postgres"), allow(dead_code))]
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Cell {
    Null,
    Int(i64),
    Real(f64),
    Bool(bool),
    Text(String),
    /// A timestamp, in epoch milliseconds.
    Time(i64),
}

/// One row, its columns by (lowercase) name.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Row(pub(crate) Vec<(String, Cell)>);

impl Row {
    pub(crate) fn get(&self, name: &str) -> &Cell {
        self.0.iter().find(|(n, _)| n == name).map_or(&Cell::Null, |(_, c)| c)
    }

    /// A column as text, `None` for NULL.
    pub(crate) fn text(&self, name: &str) -> Option<String> {
        Some(match self.get(name) {
            Cell::Null => return None,
            Cell::Int(n) | Cell::Time(n) => n.to_string(),
            Cell::Real(f) => js::Value::Number(*f).to_json(),
            Cell::Bool(b) => b.to_string(),
            Cell::Text(t) => t.clone(),
        })
    }

    /// A column as a whole number, `None` for NULL: text is read as a
    /// number, and a fraction is cut to its whole part.
    pub(crate) fn int(&self, name: &str) -> Option<i64> {
        match self.get(name) {
            Cell::Null => None,
            Cell::Int(n) | Cell::Time(n) => Some(*n),
            Cell::Real(f) => Some(*f as i64),
            Cell::Bool(b) => Some(i64::from(*b)),
            Cell::Text(t) => {
                let t = t.trim();
                Some(t.parse::<i64>().ok().or_else(|| t.parse::<f64>().ok().map(|f| f as i64)).unwrap_or(0))
            }
        }
    }

    /// A boolean column, however the driver sent it.
    #[cfg_attr(not(feature = "pgcron"), allow(dead_code))]
    pub(crate) fn boolean(&self, name: &str) -> bool {
        match self.get(name) {
            Cell::Bool(b) => *b,
            Cell::Int(n) => *n != 0,
            Cell::Text(t) => matches!(t.to_ascii_lowercase().as_str(), "t" | "true" | "1" | "yes" | "on"),
            _ => false,
        }
    }

    /// A timestamp column in epoch milliseconds, `None` for NULL.
    #[cfg_attr(not(feature = "pgcron"), allow(dead_code))]
    pub(crate) fn time(&self, name: &str) -> Option<i64> {
        match self.get(name) {
            Cell::Time(ms) => Some(*ms),
            Cell::Text(t) => parse_timestamp(t),
            _ => None,
        }
    }
}

/// A statement's parameter, in the types a JavaScript driver binds: text,
/// integers, null, and JSON (text everywhere but Postgres, where it is sent
/// as JSONB so the SDK's statements need no cast).
#[derive(Clone, Debug)]
pub(crate) enum Param {
    Text(String),
    OptText(Option<String>),
    Int(i64),
    OptInt(Option<i64>),
    Json(String),
}

/// The epoch milliseconds of a day in the proleptic Gregorian calendar.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// A timestamp as Postgres writes one in text (`2026-01-05 03:00:00.123+00`,
/// with `:MM` or `:MM:SS` on the offset, a `T` or a `Z` from ISO forms), in
/// epoch milliseconds, cut to the millisecond. A timestamp with no offset is
/// read as UTC.
pub(crate) fn parse_timestamp(text: &str) -> Option<i64> {
    let t = text.trim().as_bytes();
    let num = |s: &[u8]| -> Option<i64> {
        if s.is_empty() || !s.iter().all(u8::is_ascii_digit) {
            return None;
        }
        std::str::from_utf8(s).ok()?.parse().ok()
    };
    if t.len() < 19 || t[4] != b'-' || t[7] != b'-' || !(t[10] == b' ' || t[10] == b'T') || t[13] != b':' {
        return None;
    }
    let (y, mo, d) = (num(&t[0..4])?, num(&t[5..7])?, num(&t[8..10])?);
    let (h, mi, s) = (num(&t[11..13])?, num(&t[14..16])?, num(&t[17..19])?);
    let mut rest = &t[19..];
    let mut ms = 0;
    if rest.first() == Some(&b'.') {
        let digits = rest[1..].iter().take_while(|c| c.is_ascii_digit()).count();
        let frac = &rest[1..1 + digits];
        let mut padded = [b'0'; 3];
        for (i, c) in frac.iter().take(3).enumerate() {
            padded[i] = *c;
        }
        ms = num(&padded)?;
        rest = &rest[1 + digits..];
    }
    let offset = match rest {
        [] | [b'Z'] | [b'z'] => 0,
        [sign @ (b'+' | b'-'), tail @ ..] => {
            // Each part of an offset is two digits at most, so no offset
            // can overflow the arithmetic below.
            let two = |s: &[u8]| if s.len() <= 2 { num(s) } else { None };
            let parts: Vec<&[u8]> = tail.split(|c| *c == b':').collect();
            let (oh, om, os) = match parts.as_slice() {
                [hh] if hh.len() == 4 => (two(&hh[..2])?, two(&hh[2..])?, 0),
                [hh] => (two(hh)?, 0, 0),
                [hh, mm] => (two(hh)?, two(mm)?, 0),
                [hh, mm, ss] => (two(hh)?, two(mm)?, two(ss)?),
                _ => return None,
            };
            let secs = oh * 3600 + om * 60 + os;
            if *sign == b'-' { -secs } else { secs }
        }
        _ => return None,
    };
    let days = days_from_civil(y, mo, d);
    Some(((days * 86_400 + h * 3600 + mi * 60 + s - offset) * 1000) + ms)
}

/// Postgres's own epoch, 2000-01-01, in Unix epoch milliseconds.
#[cfg(feature = "postgres")]
const PG_EPOCH_MS: i64 = 946_684_800_000;

// ---- SQLite

#[cfg(feature = "sqlite")]
pub(crate) fn sqlite_row(row: &sqlx::sqlite::SqliteRow) -> Result<Row, BoxError> {
    use sqlx::{Column, Row as _, TypeInfo, ValueRef};
    let mut out = Vec::with_capacity(row.len());
    for (i, column) in row.columns().iter().enumerate() {
        let raw = row.try_get_raw(i)?;
        let cell = if raw.is_null() {
            Cell::Null
        } else {
            match raw.type_info().name() {
                "INTEGER" => Cell::Int(row.try_get_unchecked::<i64, _>(i)?),
                "REAL" => Cell::Real(row.try_get_unchecked::<f64, _>(i)?),
                // Text read as bytes, so one value that is not UTF-8 reads with
                // U+FFFD, as the SDK reads it, rather than failing every read
                // its row is part of.
                _ => Cell::Text(String::from_utf8_lossy(&row.try_get_unchecked::<Vec<u8>, _>(i)?).into_owned()),
            }
        };
        out.push((column.name().to_ascii_lowercase(), cell));
    }
    Ok(Row(out))
}

// ---- Postgres

/// JSON bound as Postgres's `JSONB`, in its binary form (a version byte, 1,
/// then the text), so the SDK's statements need no `::jsonb` cast: sqlx
/// sends a `String` typed as `text`, which a `JSONB` column refuses.
#[cfg(feature = "postgres")]
#[derive(Debug)]
pub(crate) struct Jsonb(pub(crate) String);

#[cfg(feature = "postgres")]
impl sqlx::Type<sqlx::Postgres> for Jsonb {
    fn type_info() -> sqlx::postgres::PgTypeInfo {
        // jsonb's fixed oid.
        sqlx::postgres::PgTypeInfo::with_oid(sqlx::postgres::types::Oid(3802))
    }
}

#[cfg(feature = "postgres")]
impl sqlx::Encode<'_, sqlx::Postgres> for Jsonb {
    fn encode_by_ref(
        &self,
        buf: &mut sqlx::postgres::PgArgumentBuffer,
    ) -> Result<sqlx::encode::IsNull, sqlx::error::BoxDynError> {
        buf.push(1);
        buf.extend_from_slice(self.0.as_bytes());
        Ok(sqlx::encode::IsNull::No)
    }
}

#[cfg(feature = "postgres")]
pub(crate) fn pg_arguments(params: Vec<Param>) -> Result<sqlx::postgres::PgArguments, BoxError> {
    use sqlx::Arguments;
    let mut args = sqlx::postgres::PgArguments::default();
    for p in params {
        match p {
            Param::Text(s) => args.add(s)?,
            Param::OptText(s) => args.add(s)?,
            Param::Int(n) => args.add(n)?,
            Param::OptInt(n) => args.add(n)?,
            Param::Json(s) => args.add(Jsonb(s))?,
        }
    }
    Ok(args)
}

/// A Postgres value from its bytes, in the binary form sqlx asks for or in
/// text.
#[cfg(feature = "postgres")]
fn pg_cell(raw: sqlx::postgres::PgValueRef<'_>) -> Result<Cell, BoxError> {
    use sqlx::postgres::PgValueFormat;
    use sqlx::{TypeInfo, ValueRef};
    if raw.is_null() {
        return Ok(Cell::Null);
    }
    let kind = raw.type_info().name().to_string();
    let bytes = raw.as_bytes()?;
    let binary = raw.format() == PgValueFormat::Binary;
    let text = || String::from_utf8_lossy(bytes).into_owned();
    let bad = || -> BoxError { format!("an unexpected {kind} value").into() };
    Ok(match (kind.as_str(), binary) {
        ("INT2" | "INT4" | "INT8" | "OID", true) => Cell::Int(match bytes.len() {
            2 => i64::from(i16::from_be_bytes(bytes.try_into()?)),
            4 => i64::from(i32::from_be_bytes(bytes.try_into()?)),
            8 => i64::from_be_bytes(bytes.try_into()?),
            _ => return Err(bad()),
        }),
        ("INT2" | "INT4" | "INT8" | "OID", false) => Cell::Int(text().trim().parse()?),
        ("FLOAT4", true) => Cell::Real(f64::from(f32::from_be_bytes(bytes.try_into()?))),
        ("FLOAT8", true) => Cell::Real(f64::from_be_bytes(bytes.try_into()?)),
        ("FLOAT4" | "FLOAT8", false) => Cell::Real(text().trim().parse()?),
        ("BOOL", true) => Cell::Bool(bytes.first().is_some_and(|b| *b != 0)),
        ("BOOL", false) => Cell::Bool(bytes.first() == Some(&b't')),
        ("JSONB", true) => match bytes.split_first() {
            Some((1, rest)) => Cell::Text(String::from_utf8_lossy(rest).into_owned()),
            _ => return Err(bad()),
        },
        ("TIMESTAMPTZ" | "TIMESTAMP", true) => {
            // Microseconds since Postgres's epoch; infinity is the ends of i64.
            let us = i64::from_be_bytes(bytes.try_into()?);
            Cell::Time(PG_EPOCH_MS.saturating_add(us.div_euclid(1000)))
        }
        ("TIMESTAMPTZ" | "TIMESTAMP", false) => parse_timestamp(&text()).map_or(Cell::Null, Cell::Time),
        _ => Cell::Text(text()),
    })
}

#[cfg(feature = "postgres")]
pub(crate) fn pg_row(row: &sqlx::postgres::PgRow) -> Result<Row, BoxError> {
    use sqlx::{Column, Row as _};
    let mut out = Vec::with_capacity(row.len());
    for (i, column) in row.columns().iter().enumerate() {
        out.push((column.name().to_ascii_lowercase(), pg_cell(row.try_get_raw(i)?)?));
    }
    Ok(Row(out))
}

// ---- MySQL

#[cfg(feature = "mysql")]
pub(crate) fn mysql_arguments(params: Vec<Param>) -> Result<sqlx::mysql::MySqlArguments, BoxError> {
    use sqlx::Arguments;
    let mut args = sqlx::mysql::MySqlArguments::default();
    for p in params {
        match p {
            Param::Text(s) | Param::Json(s) => args.add(s)?,
            Param::OptText(s) => args.add(s)?,
            Param::Int(n) => args.add(n)?,
            Param::OptInt(n) => args.add(n)?,
        }
    }
    Ok(args)
}

/// A MySQL row. A `utf8mb4_bin` column is flagged binary, so sqlx names its
/// type `VARBINARY` or `BLOB`: everything but numbers is read as bytes and
/// taken as UTF-8.
#[cfg(feature = "mysql")]
pub(crate) fn mysql_row(row: &sqlx::mysql::MySqlRow) -> Result<Row, BoxError> {
    use sqlx::{Column, Row as _, TypeInfo, ValueRef};
    let mut out = Vec::with_capacity(row.len());
    for (i, column) in row.columns().iter().enumerate() {
        let raw = row.try_get_raw(i)?;
        let cell = if raw.is_null() {
            Cell::Null
        } else {
            let kind = raw.type_info().name().to_string();
            match kind.trim_end_matches(" UNSIGNED") {
                "TINYINT" | "SMALLINT" | "MEDIUMINT" | "INT" | "BIGINT" | "YEAR" => {
                    Cell::Int(row.try_get_unchecked::<i64, _>(i)?)
                }
                "BOOLEAN" => Cell::Bool(row.try_get_unchecked::<i64, _>(i)? != 0),
                "FLOAT" | "DOUBLE" => Cell::Real(row.try_get_unchecked::<f64, _>(i)?),
                _ => Cell::Text(String::from_utf8_lossy(&row.try_get_unchecked::<Vec<u8>, _>(i)?).into_owned()),
            }
        };
        out.push((column.name().to_ascii_lowercase(), cell));
    }
    Ok(Row(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_in_postgres_text_are_read_to_the_millisecond() {
        let base = 1_767_582_000_000; // 2026-01-05T03:00:00Z
        assert_eq!(parse_timestamp("2026-01-05 03:00:00+00"), Some(base));
        assert_eq!(parse_timestamp("2026-01-05 03:00:00.123456+00"), Some(base + 123));
        assert_eq!(parse_timestamp("2026-01-05T03:00:00.1Z"), Some(base + 100));
        assert_eq!(parse_timestamp("2026-01-04 22:00:00-05"), Some(base));
        assert_eq!(parse_timestamp("2026-01-05 08:30:00+05:30"), Some(base));
        assert_eq!(parse_timestamp("2026-01-05 03:00:00"), Some(base));
        assert_eq!(parse_timestamp("1969-12-31 23:59:59.999+00"), Some(-1));
        assert_eq!(parse_timestamp("yesterday"), None);
        // An offset too long to be one is refused, not overflowed (the audit).
        assert_eq!(parse_timestamp("2026-01-05 03:00:00+99999999999999999"), None);
        assert_eq!(parse_timestamp("2026-01-05 03:00:00+05:999999999999999999"), None);
    }

    #[test]
    fn columns_are_read_whatever_type_they_came_as() {
        let row = Row(vec![
            ("a".into(), Cell::Text(" 42 ".into())),
            ("b".into(), Cell::Real(5.9)),
            ("c".into(), Cell::Text("t".into())),
            ("d".into(), Cell::Null),
        ]);
        assert_eq!(row.int("a"), Some(42));
        assert_eq!(row.int("b"), Some(5));
        assert_eq!(row.text("b").as_deref(), Some("5.9"));
        assert!(row.boolean("c"));
        assert_eq!(row.text("d"), None);
        assert_eq!(row.int("missing"), None);
    }
}
