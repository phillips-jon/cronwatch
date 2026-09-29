//! What the port needs of JavaScript's own behaviour, so that every value
//! the SDK writes, compares or counts is written, compared and counted the
//! same way here: numbers as `Number.prototype.toString` prints them,
//! `JSON.stringify` and `JSON.parse` (objects keep JavaScript's key order),
//! string lengths and cuts in UTF-16 code units, the characters `\s`
//! matches, and `Date`'s calendar arithmetic.
//!
//! [`Value`] and [`Object`] are public because a job's [`Definition`](crate::Definition)
//! hands its fields out as JSON values; the rest is the crate's own.

mod date;
mod json;
#[cfg(any(feature = "alerts", feature = "triage"))]
mod lone;
mod number;
mod text;

pub(crate) use date::*;
pub use json::{Object, ParseError, Value, parse, stringify};
pub(crate) use json::{array_index, quote};
#[cfg(any(feature = "alerts", feature = "triage"))]
pub(crate) use lone::*;
pub(crate) use number::*;
pub(crate) use text::*;
