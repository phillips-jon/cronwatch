//! The SQL store on SQLite: the store contract, the store.json replay, the
//! finish-once scenarios over several stores on one file, the SDK's schema,
//! rows of other shapes, a client end to end, and `conformance/client.json`'s
//! stored fields this release does not know.

#[path = "../../cronwatch/tests/client_fixture/mod.rs"]
mod client_fixture;
mod common;

use std::sync::Arc;

use common::{TempDir, memory_pool, pool, repo, sorted, store};
use cronwatch::js::Value;
use cronwatch::storetest::{
    self,
    kit::{Clock, Process, Shared, T0},
};
use cronwatch::{AlertType, JobOptions, Store};
use cronwatch_sqlx::SqlStore;

#[tokio::test]
async fn the_sqlite_store_passes_the_contract() {
    storetest::run(|| SqlStore::sqlite(memory_pool())).await;
}

#[tokio::test]
async fn the_sqlite_store_passes_the_contract_on_a_file_with_a_prefix() {
    let dir = TempDir::new();
    storetest::run(|| store(&dir.file("contract.db"), "cw_")).await;
}

#[tokio::test]
async fn the_sqlite_store_replays_store_json() {
    let fixture = std::fs::read_to_string(repo().join("conformance/store.json")).expect("conformance/store.json");
    let cases = storetest::kit::replay_fixture(&fixture, || SqlStore::sqlite(memory_pool())).await;
    assert!(cases >= 20, "{cases} cases");
}

#[tokio::test]
async fn the_sqlite_store_keeps_stored_fields_this_release_does_not_know() {
    let dir = TempDir::new();
    let steps = client_fixture::replay_unknown_fields(Arc::new(store(&dir.file("unknown.db"), "cronwatch_"))).await;
    assert_eq!(steps, 5);
}

#[tokio::test]
async fn the_sqlite_store_counts_a_foreign_states_version_as_the_sdk_does() {
    let dir = TempDir::new();
    let file = dir.file("foreign-version.db");
    let fixture = std::fs::read_to_string(repo().join("conformance/store.json")).expect("conformance/store.json");
    let p = pool(&file);
    let cases = storetest::kit::replay_foreign_versions(&fixture, &store(&file, "cronwatch_"), |text| {
        let p = p.clone();
        async move {
            sqlx::query("INSERT INTO cronwatch_state (job, state) VALUES ('v', ?)")
                .bind(text)
                .execute(&p)
                .await
                .unwrap();
        }
    })
    .await;
    assert!(cases >= 10, "{cases} cases");
}

#[tokio::test]
async fn a_check_over_a_run_that_started_at_the_lowest_bigint_on_sqlite() {
    let dir = TempDir::new();
    let file = dir.file("far.db");
    let p = pool(&file);
    storetest::kit::check_over_foreign_rows(store(&file, "cronwatch_"), "cronwatch_", |sql| {
        let p = p.clone();
        async move {
            sqlx::raw_sql(sqlx::AssertSqlSafe(sql)).execute(&p).await.unwrap();
        }
    })
    .await;
}

#[tokio::test]
async fn a_check_and_the_dashboard_over_a_cron_job_whose_last_run_started_far_off_on_sqlite() {
    for started_at in storetest::kit::FAR_STARTS {
        let p = memory_pool();
        storetest::kit::cron_over_foreign_row(SqlStore::sqlite(p.clone()), "cronwatch_", started_at, |sql| {
            let p = p.clone();
            async move {
                sqlx::raw_sql(sqlx::AssertSqlSafe(sql)).execute(&p).await.unwrap();
            }
        })
        .await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_is_finished_once_across_stores_on_one_file() {
    let dir = Arc::new(TempDir::new());
    let mut n = 0;
    storetest::kit::finish_once(move || {
        n += 1;
        let file = dir.file(&format!("finish-{n}.db"));
        Shared { open: Box::new(move || Arc::new(store(&file, "cronwatch_")) as Arc<dyn Store>), done: Box::new(|| {}) }
    })
    .await;
}

#[tokio::test]
async fn a_bad_prefix_is_refused_with_the_sdks_message() {
    let err = SqlStore::sqlite(memory_pool()).prefix("Bad-").unwrap_err();
    assert_eq!(
        err.to_string(),
        "cronwatch: invalid table prefix \"Bad-\". Use lowercase letters, digits, and underscores, not starting with a digit, at most 47 characters."
    );
    let s = SqlStore::sqlite(memory_pool());
    assert_eq!(s.table_prefix(), "cronwatch_");
}

#[tokio::test]
async fn the_tables_are_the_sdks() {
    let dir = TempDir::new();
    let file = dir.file("schema.db");
    let s = store(&file, "cw_");
    s.init().await.unwrap();
    s.init().await.expect("init twice");
    s.close().await.unwrap();
    let rows: Vec<(String,)> =
        sqlx::query_as("SELECT sql FROM sqlite_master WHERE name LIKE 'cw_%' AND sql IS NOT NULL ORDER BY name")
            .fetch_all(&pool(&file))
            .await
            .unwrap();
    let sql: Vec<&str> = rows.iter().map(|r| r.0.as_str()).collect();
    assert_eq!(sql.len(), 5, "{sql:?}");
    assert!(sql.contains(&"CREATE INDEX cw_runs_running ON cw_runs (status) WHERE status = 'running'"), "{sql:?}");
    let mode: (String,) = sqlx::query_as("PRAGMA journal_mode").fetch_one(&pool(&file)).await.unwrap();
    assert_eq!(mode.0, "wal");
}

#[tokio::test]
async fn rows_of_another_shape_are_read_as_the_sdk_reads_them() {
    let dir = TempDir::new();
    let file = dir.file("foreign.db");
    let s = store(&file, "cronwatch_");
    s.init().await.unwrap();
    let p = pool(&file);
    sqlx::query("INSERT INTO cronwatch_jobs (name, definition, created_at, updated_at) VALUES ('odd', '[1]', 1, 2)")
        .execute(&p)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO cronwatch_runs (id, job, status, started_at, metrics) VALUES ('x', 'odd', 'running', 5.0, '{\"a\":\"text\",\"b\":2}')",
    )
    .execute(&p)
    .await
    .unwrap();
    let job = s.get_job("odd").await.unwrap().expect("the job");
    assert_eq!(job.definition.to_json(), r#"{"name":"odd"}"#, "a definition that is not an object is its name alone");
    assert!(!job.is_readable(), "and the job is unreadable");
    assert_eq!(job.updated_at, 2);
    let running = s.running_runs().await.unwrap();
    assert_eq!(running.len(), 1);
    assert_eq!(running[0].metrics.to_json(), r#"{"b":2}"#, "metrics keep the numbers");
    assert_eq!(running[0].started_at, 5);
    assert_eq!(running[0].trigger, "run");

    // Text that is not UTF-8 reads with U+FFFD rather than failing every
    // read of the job's runs (the audit).
    sqlx::query(
        "INSERT INTO cronwatch_runs (id, job, status, started_at, output, trigger) VALUES ('y', 'odd', 'ok', 6, CAST(x'61ff62' AS TEXT), 'run')",
    )
    .execute(&p)
    .await
    .unwrap();
    let runs = s.list_runs("odd", 10).await.expect("the runs read");
    assert_eq!(runs[0].output.as_deref(), Some("a\u{fffd}b"));
}

#[tokio::test]
async fn a_client_records_and_checks_on_sqlite_and_another_reads_it() {
    let dir = TempDir::new();
    let file = dir.file("client.db");
    let clock = Clock::new(T0);
    let one = Process::new(Arc::new(store(&file, "cronwatch_")), &clock);
    let job = one
        .client
        .job("nightly", JobOptions::new().schedule("every 5m").expect("done").failures_before_alert(1))
        .unwrap();
    job.run(|j| async move {
        j.log("done");
        j.metric("rows", 3.0).unwrap();
        Ok::<_, std::io::Error>(())
    })
    .await
    .unwrap();
    clock.advance(60_000);
    let err = job.run(|_| async { Err::<(), _>(std::io::Error::other("disk full")) }).await.unwrap_err();
    assert_eq!(err.to_string(), "disk full");
    assert_eq!(one.alerts.types(), vec![AlertType::Failed.to_string()]);
    clock.advance(20 * 60_000);
    let result = one.client.check().await.unwrap();
    assert_eq!(result.jobs.len(), 1);
    assert_eq!(one.alerts.types(), vec!["failed".to_string(), "missed".into()]);

    let two = Process::new(Arc::new(store(&file, "cronwatch_")), &clock);
    let runs = two.client.runs("nightly", 10).await.unwrap();
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[0].error.as_deref(), Some("Error: disk full"));
    assert_eq!(runs[1].output.as_deref(), Some("done"));
    assert_eq!(runs[1].metrics.to_json(), r#"{"rows":3}"#);
    let summary = two.client.job_summary("nightly").await.unwrap().expect("a summary");
    assert_eq!(summary.consecutive_failures, 1);
    assert!(one.errors.list().is_empty() && two.errors.list().is_empty(), "{:?}", one.errors.list());
}

// ---- store.json foreignRows: rows a foreign, hand-edited, or damaged writer
// could leave, each read leniently, one affecting only its own job.

fn foreign_rows() -> cronwatch::js::Object {
    let text = std::fs::read_to_string(repo().join("conformance/store.json")).expect("conformance/store.json");
    let fixture = cronwatch::js::parse(&text).expect("JSON");
    fixture.as_object().and_then(|o| o.get("foreignRows")).and_then(Value::as_object).cloned().expect("foreignRows")
}

fn list<'a>(o: &'a cronwatch::js::Object, key: &str) -> &'a Vec<Value> {
    o.get(key).and_then(Value::as_array).unwrap_or_else(|| panic!("{key}"))
}

fn text<'a>(o: &'a cronwatch::js::Object, key: &str) -> &'a str {
    o.get(key).and_then(Value::as_str).unwrap_or_else(|| panic!("{key}"))
}

/// One row into `cronwatch_<table>`, each value as SQLite holds it: a string
/// as TEXT, a whole number as INTEGER, another as REAL, null as NULL.
async fn insert_row(p: &sqlx::SqlitePool, table: &str, row: &cronwatch::js::Object) {
    let keys: Vec<&str> = row.keys().collect();
    let sql = format!(
        "INSERT INTO cronwatch_{table} ({}) VALUES ({})",
        keys.join(", "),
        keys.iter().map(|_| "?").collect::<Vec<_>>().join(", ")
    );
    let mut q = sqlx::query(sqlx::AssertSqlSafe(sql));
    for k in &keys {
        q = match row.get(k).unwrap() {
            Value::String(s) => q.bind(s.clone()),
            Value::Number(n) if n.fract() == 0.0 => q.bind(*n as i64),
            Value::Number(n) => q.bind(*n),
            Value::Null => q.bind(None::<String>),
            other => panic!("a column cannot hold {}", other.to_json()),
        };
    }
    q.execute(p).await.unwrap();
}

fn stored_job_value(job: &cronwatch::StoredJob) -> String {
    Value::Object(
        cronwatch::js::Object::new()
            .with("name", job.name.as_str())
            .with("definition", job.definition.as_object().clone())
            .with("createdAt", job.created_at)
            .with("updatedAt", job.updated_at),
    )
    .to_json()
}

/// A state as the client reads it (none for no row, every list present).
fn read_state(s: Option<cronwatch::JobState>, job: &str) -> String {
    let mut s = s.unwrap_or_else(|| cronwatch::JobState::new(job));
    s.pending_recovery.get_or_insert_with(Vec::new);
    s.undelivered.get_or_insert_with(Vec::new);
    s.to_json()
}

/// The fixture's state with each queued alert as this port writes one
/// (whole, every field, as an alert it composed): which alerts are kept is
/// the SDK's.
fn want_state(v: &Value) -> String {
    let mut o = v.as_object().expect("a state").clone();
    if let Some(Value::Array(alerts)) = o.get("undelivered") {
        let read: Vec<Value> =
            alerts.iter().map(|a| cronwatch::Alert::from_value(a).expect("an alert").to_value()).collect();
        o.set("undelivered", read);
    }
    Value::Object(o).to_json()
}

#[tokio::test]
async fn each_foreign_row_reads_leniently_store_json_foreign_rows() {
    let fixture = foreign_rows();
    for c in list(&fixture, "rows") {
        let c = c.as_object().unwrap();
        let table = text(c, "table");
        let row = c.get("row").and_then(Value::as_object).unwrap();
        let label = format!("{table} {}", Value::Object(row.clone()).to_json());
        let dir = TempDir::new();
        let file = dir.file("row.db");
        let s = store(&file, "cronwatch_");
        s.init().await.unwrap();
        insert_row(&pool(&file), table, row).await;
        let read = c.get("read").unwrap();
        match table {
            "jobs" => {
                let job = s.get_job(text(row, "name")).await.unwrap().expect("the job");
                assert_eq!(stored_job_value(&job), read.to_json(), "{label}");
                let readable = !matches!(c.get("readable"), Some(Value::Bool(false)));
                assert_eq!(job.is_readable(), readable, "{label}");
                let listed: Vec<String> = s.list_jobs().await.unwrap().iter().map(stored_job_value).collect();
                assert_eq!(listed, vec![read.to_json()], "{label}");
            }
            "runs" => {
                let run = s.get_run(text(row, "id")).await.unwrap().expect("the run");
                assert_eq!(run.to_json(), read.to_json(), "{label}");
                let runs: Vec<String> =
                    s.list_runs(text(row, "job"), 10).await.unwrap().iter().map(|r| r.to_json()).collect();
                assert_eq!(runs, vec![read.to_json()], "{label}");
            }
            _ => {
                let job = text(row, "job");
                assert_eq!(read_state(s.get_state(job).await.unwrap(), job), want_state(read), "{label}");
            }
        }
    }
}

#[tokio::test]
async fn a_check_a_silence_and_every_page_over_foreign_rows_store_json_foreign_rows() {
    use std::sync::Mutex;
    let fixture = foreign_rows();
    let c = fixture.get("check").and_then(Value::as_object).unwrap();
    let rows: Vec<&cronwatch::js::Object> = list(&fixture, "rows").iter().map(|r| r.as_object().unwrap()).collect();
    let of = |table: &str| -> Vec<cronwatch::js::Object> {
        rows.iter()
            .filter(|r| r.get("table").and_then(Value::as_str) == Some(table))
            .map(|r| r.get("row").and_then(Value::as_object).unwrap().clone())
            .collect()
    };
    let extra = |key: &str| list(c, key).iter().map(|r| r.as_object().unwrap().clone()).collect::<Vec<_>>();
    let jobs: Vec<_> = of("jobs").into_iter().chain(extra("extraJobs")).collect();
    let runs: Vec<_> = of("runs").into_iter().chain(extra("extraRuns")).collect();
    let dir = TempDir::new();
    let file = dir.file("check.db");
    let s = Arc::new(store(&file, "cronwatch_"));
    s.init().await.unwrap();
    let p = pool(&file);
    for row in &jobs {
        insert_row(&p, "jobs", row).await;
    }
    for row in &runs {
        insert_row(&p, "runs", row).await;
    }
    for row in &of("state") {
        insert_row(&p, "state", row).await;
    }
    let names: Vec<String> = jobs.iter().map(|j| text(j, "name").to_string()).collect();
    let wheres = Arc::new(Mutex::new(Vec::<String>::new()));
    let reported = || -> Vec<String> {
        let mut out: Vec<String> = wheres
            .lock()
            .unwrap()
            .drain(..)
            .map(|w| names.iter().find(|n| w.ends_with(&format!(" {n}"))).cloned().unwrap_or(w))
            .collect();
        out.sort();
        out.dedup();
        out
    };
    let strings =
        |v: &Value| -> Vec<String> { v.as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_string()).collect() };
    let sent = cronwatch::storetest::kit::Capture::default();
    let now = c.get("now").and_then(Value::as_f64).unwrap() as i64;
    let w = wheres.clone();
    let cw = cronwatch::Client::builder()
        .store_arc(s.clone())
        .clock(move || now)
        .alerts([Arc::new(sent.clone()) as Arc<dyn cronwatch::Channel>])
        .no_cron_secret()
        .on_error(move |_, where_| w.lock().unwrap().push(where_.to_string()))
        .build()
        .unwrap();

    let result = cw.check().await.expect("the check");
    assert_eq!(reported(), strings(c.get("reported").unwrap()), "reported by the check");
    let alerts: Vec<String> = sent
        .list()
        .iter()
        .map(|a| {
            let o = cronwatch::js::Object::new()
                .with("type", a.alert_type.as_str())
                .with("job", a.job.as_str())
                .with("at", a.at);
            Value::Object(o).to_json()
        })
        .collect();
    let want: Vec<String> = list(c, "alerts").iter().map(Value::to_json).collect();
    assert_eq!(alerts, want, "the alerts sent");
    let mut health: Vec<(String, String)> =
        result.jobs.iter().map(|j| (j.name.clone(), j.health.as_str().to_string())).collect();
    health.sort();
    let mut want_health: Vec<(String, String)> = c
        .get("health")
        .and_then(Value::as_object)
        .unwrap()
        .iter()
        .map(|(k, v)| (k.to_string(), v.as_str().unwrap().to_string()))
        .collect();
    want_health.sort();
    assert_eq!(health, want_health, "each job's health");

    let silence = c.get("silence").and_then(Value::as_object).unwrap();
    let job = text(silence, "job");
    cw.silence(job, text(silence, "for")).await.expect("the silence");
    assert_eq!(reported(), strings(silence.get("reported").unwrap()), "reported by the silence");
    let stored = s.get_state(job).await.unwrap().expect("the silenced state");
    assert_eq!(stored.to_json(), silence.get("state").unwrap().to_json(), "the silenced state");

    // The states as stored: some were never rewritten and are still the
    // foreign values, since a read that changes nothing writes nothing.
    for (job, want) in c.get("states").and_then(Value::as_object).unwrap().iter() {
        let (stored,): (String,) =
            sqlx::query_as("SELECT state FROM cronwatch_state WHERE job = ?").bind(job).fetch_one(&p).await.unwrap();
        assert_eq!(sorted(&stored), sorted(&want.to_json()), "the stored state of {job}");
    }

    let read = c.get("read").and_then(Value::as_object).unwrap();
    let routes = cw.routes(cronwatch::web::RoutesOptions::new().token("tok")).unwrap();
    for page in list(read, "pages") {
        let page = page.as_object().unwrap();
        let path = text(page, "path");
        let res = routes
            .handle(
                cronwatch::web::Request::new("GET", path)
                    .with_header("host", "app.test")
                    .with_header("authorization", "Bearer tok"),
            )
            .await;
        assert_eq!(f64::from(res.status), page.get("status").and_then(Value::as_f64).unwrap(), "GET {path}");
    }
    assert_eq!(reported(), strings(read.get("reported").unwrap()), "reported by the pages");
    cw.close().await.unwrap();
}
