//! The memory store against the store contract, the store.json replay and
//! the finish-once scenarios (the `storetest` feature).

use std::sync::Arc;

use cronwatch::{MemoryStore, Store, storetest};

fn fixture() -> String {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../conformance/store.json");
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

#[tokio::test]
async fn the_memory_store_passes_the_contract() {
    storetest::run(MemoryStore::new).await;
}

#[tokio::test]
async fn the_memory_store_replays_store_json() {
    let cases = storetest::replay_fixture(&fixture(), MemoryStore::new).await;
    assert!(cases >= 20, "{cases} cases");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_is_finished_once_across_processes() {
    storetest::finish_once(|| {
        // Every "process" shares the one memory store, as processes share a
        // database.
        let store: Arc<dyn Store> = Arc::new(MemoryStore::new());
        storetest::Shared { open: Box::new(move || store.clone()), done: Box::new(|| {}) }
    })
    .await;
}
