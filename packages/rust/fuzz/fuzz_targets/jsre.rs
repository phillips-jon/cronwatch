//! The JavaScript regular expression engine: a pattern as a stored
//! `matches /source/flags` rule gives it (another process's row), run over
//! a job's output, and the default redaction over any output.
#![no_main]

use libfuzzer_sys::arbitrary::{self, Arbitrary};
use libfuzzer_sys::fuzz_target;

#[derive(Arbitrary, Debug)]
struct Input<'a> {
    source: &'a str,
    flags: &'a str,
    text: &'a str,
}

fuzz_target!(|input: Input<'_>| {
    cronwatch::fuzz::regexp(input.source, input.flags, input.text);
    let _ = cronwatch::redact_secrets(input.text);
});
