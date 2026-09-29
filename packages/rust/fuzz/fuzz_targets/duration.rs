//! Duration text, through the public doors only (a job's grace, timeout and
//! longest run, the client's retention, an `every` schedule and a silence),
//! so the target stands whatever the parser inside looks like. Text a
//! dashboard user sends reaches the parser through the silence.
#![no_main]

use std::sync::OnceLock;

use cronwatch::bridge::Schedule;
use cronwatch::{Client, JobOptions};
use libfuzzer_sys::fuzz_target;
use tokio::runtime::Runtime;

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap())
}

fn client() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(|| Client::builder().build().unwrap())
}

fuzz_target!(|text: &str| {
    let _runtime = runtime().enter();
    let _ = Client::builder().retention(text).build();
    let cw = client();
    let _ = cw.job("grace", JobOptions::new().grace(text));
    let _ = cw.job("timeout", JobOptions::new().timeout(text));
    let _ = cw.job("longest", JobOptions::new().max_duration(text));
    let _ = Schedule::parse(&format!("every {text}"), "UTC");
    if cw.job("silenced", JobOptions::new()).is_ok() {
        let _ = runtime().block_on(cw.silence("silenced", text));
    }
});
