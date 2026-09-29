//! Stored rows as another process (or another port) may have written them:
//! a run, a definition, a state, an alert and metrics, each read, written
//! and read again to the same text; a definition is also declared, as the
//! scheduler integrations declare one the store holds.
#![no_main]

use std::sync::OnceLock;

use cronwatch::bridge;
use cronwatch::{Alert, Client, Definition, JobState, Metrics, Run};
use libfuzzer_sys::fuzz_target;

fn client() -> &'static Client {
    static STATE: OnceLock<(tokio::runtime::Runtime, Client)> = OnceLock::new();
    let (_, client) = STATE.get_or_init(|| {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
        let client = runtime.block_on(async { Client::builder().build().unwrap() });
        (runtime, client)
    });
    client
}

macro_rules! round_trip {
    ($ty:ty, $text:expr) => {
        if let Ok(value) = <$ty>::from_json($text) {
            let once = value.to_json();
            let again = <$ty>::from_json(&once).unwrap_or_else(|e| panic!("{once:?} does not read back: {e}"));
            assert_eq!(again.to_json(), once);
        }
    };
}

fuzz_target!(|data: &[u8]| {
    let Some((&kind, rest)) = data.split_first() else {
        return;
    };
    let Ok(text) = std::str::from_utf8(rest) else {
        return;
    };
    match kind % 5 {
        0 => round_trip!(Run, text),
        1 => {
            round_trip!(Definition, text);
            if let Ok(def) = Definition::from_json(text) {
                let cw = client();
                let _ = cw.job(def.name(), bridge::options_of(&def));
                let _ = cw.job(def.name(), bridge::unscheduled(&def));
            }
        }
        2 => round_trip!(JobState, text),
        3 => round_trip!(Alert, text),
        _ => round_trip!(Metrics, text),
    }
});
