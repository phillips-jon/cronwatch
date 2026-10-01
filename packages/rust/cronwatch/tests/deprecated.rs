//! The names deprecated before 1.0 still work, each doing what its
//! replacement does: internal helpers that were public until then, and the
//! names 1.0 renamed. (`start`, `into_router`, `with_client` and the
//! storetest helpers are tested beside what replaced them.)
#![allow(deprecated)]

use cronwatch::JobOptions;
use cronwatch::js::{self, Value};

#[test]
fn the_root_helpers_still_answer() {
    let def = cronwatch::describe_job("j", &JobOptions::new().schedule("@hourly"));
    assert_eq!((def.name(), def.schedule()), ("j", "@hourly"));
    assert_eq!(cronwatch::run_duration(1000, 2500), 1500);
    assert_eq!(cronwatch::state_version(Some(&Value::from(3))), 3);
    assert_eq!(cronwatch::state_version(Some(&Value::from(1.5))), 0);
}

#[test]
fn parse_error_is_json_error() {
    let err: js::ParseError = js::parse("{").unwrap_err();
    let same: cronwatch::JsonError = err;
    assert!(!same.to_string().is_empty());
}

#[cfg(feature = "triage")]
#[test]
fn the_triage_constants_still_answer() {
    assert!(cronwatch::triage::SYSTEM.contains("<job_data>"));
    assert_eq!(cronwatch::triage::REQUEST_TIMEOUT, std::time::Duration::from_secs(24));
    assert!(cronwatch::triage::FALLBACK_BETA.starts_with("server-side-fallback"));
}

#[cfg(feature = "alerts")]
#[test]
fn the_channel_constants_still_answer() {
    assert_eq!(cronwatch::alerts::MAX_SEGMENTS, 10);
    assert_eq!(cronwatch::alerts::post::TIMEOUT, std::time::Duration::from_secs(10));
    assert_eq!(cronwatch::alerts::post::MAX_BODY, 1 << 20);
    assert_eq!(cronwatch::alerts::post::origin("https://hooks.example/a?key=s"), "https://hooks.example");
}
