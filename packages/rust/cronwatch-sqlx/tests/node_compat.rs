//! A Node process and a Rust process sharing one SQLite file: the SDK's store
//! (from the built packages/sdk/dist) and `SqlStore` replay the same store
//! calls (testdata/shared_store.json, the Ruby, Python and Go ports'
//! fixture), and each must read what the other wrote exactly as it reads its
//! own, down to the bytes and SQLite type of every column. Then a Node client
//! and a Rust client take turns on one file, and on one job's state version.
//!
//! Needs node on the PATH, the SDK built and its SQLite driver installed
//! (`npm ci && npm run build` at the repository root); skipped, with the
//! reason, without them.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use common::{TempDir, pool, repo, store};
use cronwatch::js::{self, Object, Value};
use cronwatch::storetest::{Clock, Process};
use cronwatch::{Definition, JobOptions, JobState, Run, Store, StoredJob};
use cronwatch_sqlx::SqlStore;
use sqlx::Row;

fn testdata(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/testdata").join(name)
}

/// Why the test cannot run here, or `None` when it can.
fn missing() -> Option<&'static str> {
    if Command::new("node").arg("--version").output().is_err() {
        return Some("node is not on the PATH");
    }
    if !repo().join("packages/sdk/dist/sqlite.js").exists() {
        return Some("packages/sdk/dist is not built: run `npm ci && npm run build` at the repository root");
    }
    if !repo().join("node_modules/better-sqlite3").exists() {
        return Some("the SDK's SQLite driver is not installed: run `npm ci` at the repository root");
    }
    None
}

macro_rules! need_node {
    () => {
        if let Some(why) = missing() {
            eprintln!("skipped: Node compatibility: {why}");
            return;
        }
    };
}

fn node(action: &str, file: &Path, prefix: &str, args: &[&str]) -> String {
    let out = Command::new("node")
        .arg(testdata("node_store.mjs"))
        .arg(action)
        .arg(file)
        .arg(prefix)
        .args(args)
        .output()
        .expect("node runs");
    assert!(out.status.success(), "node {action}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).expect("UTF-8")
}

fn fixture_path() -> String {
    testdata("shared_store.json").to_string_lossy().into_owned()
}

fn fixture() -> Object {
    let text = std::fs::read_to_string(testdata("shared_store.json")).expect("the fixture");
    js::parse(&text).expect("JSON").as_object().expect("an object").clone()
}

fn strings(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array).into_iter().flatten().filter_map(|s| s.as_str().map(String::from)).collect()
}

fn read_list(f: &Object, key: &str) -> Vec<String> {
    strings(f.get("read").and_then(Value::as_object).and_then(|r| r.get(key)))
}

fn num(o: &Object, key: &str) -> i64 {
    o.get(key).and_then(Value::as_f64).unwrap_or(0.0) as i64
}

/// Replays the fixture's store calls, as node_store.mjs `write` does.
async fn rust_write(store: &SqlStore, f: &Object) -> String {
    store.init().await.unwrap();
    let mut pruned = Vec::new();
    for step in f.get("ops").and_then(Value::as_array).expect("ops") {
        let step = step.as_object().expect("a step");
        let field = |k: &str| step.get(k).cloned().unwrap_or_default();
        match step.get("op").and_then(Value::as_str).unwrap_or("") {
            "upsertJob" => {
                let def = Definition::from_json(&field("definition").to_json()).unwrap();
                store.upsert_job(&def, num(step, "now")).await.unwrap();
            }
            "insertRun" => store.insert_run(&Run::from_value(&field("run")).unwrap()).await.unwrap(),
            "updateRun" => store.update_run(&Run::from_value(&field("run")).unwrap()).await.unwrap(),
            "setState" => store.set_state(&JobState::from_value(&field("state")).unwrap()).await.unwrap(),
            "deleteJob" => store.delete_job(field("name").as_str().unwrap()).await.unwrap(),
            "prune" => pruned.push(Value::from(store.prune(num(step, "before")).await.unwrap() as i64)),
            other => panic!("unknown op {other}"),
        }
    }
    Object::new().with("pruned", pruned).to_json()
}

fn stored_value(j: &StoredJob) -> Value {
    Value::Object(
        Object::new()
            .with("name", j.name.as_str())
            .with("definition", j.definition.as_object().clone())
            .with("createdAt", j.created_at)
            .with("updatedAt", j.updated_at),
    )
}

fn runs_value(runs: &[Run]) -> Value {
    Value::Array(runs.iter().map(Run::to_value).collect())
}

/// What node_store.mjs `read` prints, from the Rust store, in the same key
/// order.
async fn rust_read(store: &SqlStore, f: &Object) -> String {
    let jobs = store.list_jobs().await.unwrap();
    let (mut job, mut runs, mut limited, mut last, mut state) =
        (Object::new(), Object::new(), Object::new(), Object::new(), Object::new());
    for name in read_list(f, "jobs") {
        job.set(name.as_str(), store.get_job(&name).await.unwrap().as_ref().map_or(Value::Null, stored_value));
        runs.set(name.as_str(), runs_value(&store.list_runs(&name, 100).await.unwrap()));
        limited.set(name.as_str(), runs_value(&store.list_runs(&name, 1).await.unwrap()));
        last.set(name.as_str(), store.last_run(&name).await.unwrap().as_ref().map_or(Value::Null, Run::to_value));
        state
            .set(name.as_str(), store.get_state(&name).await.unwrap().as_ref().map_or(Value::Null, JobState::to_value));
    }
    let mut by_id = Object::new();
    for id in read_list(f, "runs") {
        by_id.set(id.as_str(), store.get_run(&id).await.unwrap().as_ref().map_or(Value::Null, Run::to_value));
    }
    Object::new()
        .with("jobs", Value::Array(jobs.iter().map(stored_value).collect()))
        .with("job", job)
        .with("runs", runs)
        .with("limited", limited)
        .with("last", last)
        .with("state", state)
        .with("running", runs_value(&store.running_runs().await.unwrap()))
        .with("run", by_id)
        .to_json()
}

/// Every row of the three tables with each value's SQLite type, the JSON
/// columns as the text the database holds.
async fn raw_rows(file: &Path, p: &str) -> Vec<String> {
    let typed =
        |columns: &[&str]| columns.iter().map(|c| format!("quote({c}), typeof({c})")).collect::<Vec<_>>().join(", ");
    let db = pool(file);
    let mut out = Vec::new();
    for q in [
        format!(
            "SELECT {} FROM {p}jobs ORDER BY created_at, name",
            typed(&["name", "definition", "created_at", "updated_at"])
        ),
        format!(
            "SELECT {} FROM {p}runs ORDER BY rowid",
            typed(&[
                "rowid",
                "id",
                "job",
                "status",
                "started_at",
                "finished_at",
                "duration_ms",
                "error",
                "output",
                "metrics",
                "trigger"
            ])
        ),
        format!("SELECT {} FROM {p}state ORDER BY job", typed(&["job", "state"])),
    ] {
        for row in sqlx::query(sqlx::AssertSqlSafe(q)).fetch_all(&db).await.unwrap() {
            let values: Vec<String> = (0..row.len()).map(|i| row.get::<String, _>(i)).collect();
            out.push(values.join(" | "));
        }
    }
    db.close().await;
    out
}

async fn schema_of(file: &Path, p: &str) -> Vec<String> {
    let db = pool(file);
    let rows = sqlx::query(
        "SELECT type || '|' || name || '|' || tbl_name || '|' || coalesce(sql, '') FROM sqlite_master WHERE name LIKE ? ORDER BY name",
    )
    .bind(format!("{p}%"))
    .fetch_all(&db)
    .await
    .unwrap();
    db.close().await;
    rows.iter().map(|r| r.get::<String, _>(0).replace(p, "PREFIX_")).collect()
}

#[tokio::test]
async fn rust_reads_what_node_wrote() {
    need_node!();
    let f = fixture();
    let dir = TempDir::new();
    let file = dir.file("shared.db");
    assert_eq!(node("write", &file, "cw_", &[&fixture_path()]), r#"{"pruned":[1]}"#);
    let s = store(&file, "cw_");
    s.init().await.unwrap();
    let node_view = node("read", &file, "cw_", &[&fixture_path()]);
    assert!(!node_view.contains("never stored"), "an update of a run that is not there was stored");
    assert_eq!(rust_read(&s, &f).await, node_view, "Rust reads Node's rows differently");
    s.close().await.unwrap();
}

#[tokio::test]
async fn node_reads_what_rust_wrote_and_the_rows_are_the_same() {
    need_node!();
    let f = fixture();
    let dir = TempDir::new();
    let (node_file, rust_file) = (dir.file("node.db"), dir.file("rust.db"));
    let written = node("write", &node_file, "cw_", &[&fixture_path()]);
    let s = store(&rust_file, "cw_");
    assert_eq!(rust_write(&s, &f).await, written, "pruned");
    s.close().await.unwrap();
    assert_eq!(
        node("read", &rust_file, "cw_", &[&fixture_path()]),
        node("read", &node_file, "cw_", &[&fixture_path()]),
        "Node reads Rust's rows differently from its own"
    );
    let (rust_rows, node_rows) = (raw_rows(&rust_file, "cw_").await, raw_rows(&node_file, "cw_").await);
    assert!(!rust_rows.is_empty());
    for (i, (r, n)) in rust_rows.iter().zip(&node_rows).enumerate() {
        assert_eq!(r, n, "row {i}");
    }
    assert_eq!(rust_rows.len(), node_rows.len(), "rows");
}

#[tokio::test]
async fn the_tables_are_the_same_whoever_creates_them() {
    need_node!();
    let dir = TempDir::new();
    let file = dir.file("both.db");
    node("write", &file, "node_", &[&fixture_path()]);
    let s = store(&file, "rust_");
    s.init().await.unwrap();
    s.close().await.unwrap();
    let (a, b) = (schema_of(&file, "rust_").await, schema_of(&file, "node_").await);
    assert_eq!(a.len(), 5, "{a:?}");
    assert_eq!(a, b, "schema");
}

#[tokio::test]
async fn node_carries_on_from_rust_and_rust_from_node() {
    need_node!();
    let f = fixture();
    let dir = TempDir::new();
    let file = dir.file("turns.db");
    node("write", &file, "cw_", &[&fixture_path()]);
    let s = Arc::new(store(&file, "cw_"));
    // A Rust client finishes a run of a job Node wrote, and checks every job.
    let clock = Clock::new(1_767_606_100_000);
    let p = Process::new(s.clone(), &clock);
    let job =
        p.client.job("every-5", JobOptions::new().schedule("every 5m").timeout("2m").max_duration("90s")).unwrap();
    job.run(|j| async move {
        j.log("from rust");
        Ok::<_, std::io::Error>(())
    })
    .await
    .unwrap();
    clock.advance(10 * 60_000);
    let result = p.client.check().await.unwrap();
    assert!(result.jobs.iter().any(|j| j.name == "nightly-report"), "checked {:?}", result.jobs.len());
    assert_eq!(s.last_run("every-5").await.unwrap().and_then(|r| r.output).as_deref(), Some("from rust"));
    let raw = node("read", &file, "cw_", &[&fixture_path()]);
    let view = js::parse(&raw).unwrap();
    let node_output = view
        .as_object()
        .and_then(|o| o.get("last"))
        .and_then(Value::as_object)
        .and_then(|l| l.get("every-5"))
        .and_then(Value::as_object)
        .and_then(|r| r.get("output"))
        .and_then(Value::as_str)
        .map(String::from);
    assert_eq!(node_output.as_deref(), Some("from rust"), "node reads the output");
    assert_eq!(rust_read(&s, &f).await, raw, "after Rust's turn, Rust and Node read the file differently");

    // And Node takes a turn on the same file: Rust reads its run and state.
    clock.advance(10 * 60_000);
    let node_run = node("run", &file, "cw_", &[&clock.now().to_string()]);
    assert!(node_run.contains("\"every-5\""), "node run {node_run}");
    assert_eq!(s.last_run("every-5").await.unwrap().and_then(|r| r.output).as_deref(), Some("from node"));
    assert_eq!(rust_read(&s, &f).await, node("read", &file, "cw_", &[&fixture_path()]), "after Node's turn");
    let again = p.client.check().await.unwrap();
    assert!(!again.jobs.is_empty(), "no jobs checked");
    assert!(p.errors.list().is_empty(), "errors: {:?}", p.errors.list());
    s.close().await.unwrap();
}

#[tokio::test]
async fn node_and_rust_take_turns_on_one_jobs_state_version() {
    need_node!();
    let dir = TempDir::new();
    let file = dir.file("versions.db");
    let s = store(&file, "cw_");
    s.init().await.unwrap();
    let v = |version: i64, failures: i64, job: &str| {
        JobState::from_json(&format!(
            r#"{{"job":"{job}","open":{{}},"consecutiveFailures":{failures},"silencedUntil":null,"lastAlertAt":null,"version":{version}}}"#
        ))
        .unwrap()
    };
    let node_cas = |state: JobState, expected: i64| {
        let out = js::parse(&node("cas", &file, "cw_", &[&state.to_json(), &expected.to_string()])).unwrap();
        let o = out.as_object().unwrap().clone();
        (o.get("written").and_then(Value::as_bool).unwrap(), o.get("state").cloned().unwrap_or_default().to_json())
    };
    assert!(s.compare_and_set_state(&v(1, 1, "v"), 0).await.unwrap(), "Rust writes the first version");
    assert!(!node_cas(v(1, 9, "v"), 0).0, "Node's write from before it is refused");
    let (written, state) = node_cas(v(2, 2, "v"), 1);
    assert!(written && state.contains(r#""version":2"#), "Node's fresh write {written} {state}");
    assert!(!s.compare_and_set_state(&v(2, 7, "v"), 1).await.unwrap(), "Rust's stale write is refused");
    assert!(s.compare_and_set_state(&v(3, 3, "v"), 2).await.unwrap(), "Rust writes the next version");
    let (written, state) = node_cas(v(3, 0, "v"), 2);
    let stored = s.get_state("v").await.unwrap().expect("a state");
    assert!(!written, "Node's stale write is refused");
    assert_eq!(state, stored.to_json(), "Node reads Rust's version");
    // State written before versions existed counts as 0 for both.
    s.set_state(
        &JobState::from_json(
            r#"{"job":"old","open":{},"consecutiveFailures":4,"silencedUntil":null,"lastAlertAt":null}"#,
        )
        .unwrap(),
    )
    .await
    .unwrap();
    assert!(node_cas(v(1, 5, "old"), 0).0, "Node writes over state without a version");
    assert_eq!(s.get_state("old").await.unwrap().and_then(|s| s.version), Some(1));
    s.close().await.unwrap();
}
