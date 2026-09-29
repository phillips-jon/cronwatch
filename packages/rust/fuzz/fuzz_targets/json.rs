//! `js::parse`, which reads request bodies and every stored JSON column:
//! what it reads, `stringify` writes as JSON it reads back to the same text.
#![no_main]

use cronwatch::js;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|text: &str| {
    if let Ok(value) = js::parse(text) {
        let once = js::stringify(&value);
        let again = js::parse(&once).unwrap_or_else(|e| panic!("{once:?} does not read back: {e}"));
        assert_eq!(js::stringify(&again), once);
    }
});
