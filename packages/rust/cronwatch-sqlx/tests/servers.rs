//! The SQL store on Postgres, MySQL and MariaDB, each when its variable is
//! set (see `common/server.rs`): the store contract, the store.json replay,
//! the finish-once scenarios over several stores (each on a pool of its own)
//! on one database, a client end to end, and each dialect's own tests
//! (stores.test.ts's for Postgres, the PHP port's MysqlStoreTest for MySQL
//! and MariaDB), as the Go port's sqltest module has them, and
//! `conformance/client.json`'s stored fields this release does not know.

#[path = "../../cronwatch/tests/client_fixture/mod.rs"]
mod client_fixture;
mod common;

use std::sync::Arc;

use common::server::{mysqls, postgres, servers};
use common::{definition, repo, state};
use cronwatch::storetest::{
    self,
    kit::{Clock, Process, Shared, T0},
};
use cronwatch::{JobOptions, Metrics, Run, RunStatus, StartOptions, Store};
use cronwatch_sqlx::Dialect;

const MIN: i64 = 60_000;

fn run(id: &str, job: &str, status: RunStatus, started_at: i64) -> Run {
    storetest::kit::new_run_plain(id, job, status, started_at)
}

#[tokio::test]
async fn each_server_passes_the_contract() {
    for s in servers() {
        storetest::run(|| s.store("contract")).await;
        s.cleanup().await;
    }
}

#[tokio::test]
async fn each_server_replays_store_json() {
    let fixture = std::fs::read_to_string(repo().join("conformance/store.json")).expect("conformance/store.json");
    for s in servers() {
        let cases = storetest::kit::replay_fixture(&fixture, || s.store("replay")).await;
        assert!(cases >= 20, "{}: {cases} cases", s.name);
        s.cleanup().await;
    }
}

#[tokio::test]
async fn each_server_keeps_stored_fields_this_release_does_not_know() {
    for s in servers() {
        assert_eq!(client_fixture::replay_unknown_fields(Arc::new(s.store("unknown"))).await, 5, "{}", s.name);
        s.cleanup().await;
    }
}

#[tokio::test]
async fn each_server_counts_a_foreign_states_version_as_the_sdk_does() {
    let fixture = std::fs::read_to_string(repo().join("conformance/store.json")).expect("conformance/store.json");
    for s in servers() {
        let store = s.store("fv");
        let p = store.table_prefix().to_string();
        let cast = if s.dialect == Dialect::Postgres { "::jsonb" } else { "" };
        let db = Arc::new(s.db());
        let cases = storetest::kit::replay_foreign_versions(&fixture, &store, |text| {
            let (db, p) = (db.clone(), p.clone());
            async move { db.exec(&format!("INSERT INTO {p}state (job, state) VALUES ('v', '{text}'{cast})")).await }
        })
        .await;
        assert!(cases >= 10, "{}: {cases} cases", s.name);
        s.cleanup().await;
    }
}

#[tokio::test]
async fn a_check_over_a_run_that_started_at_the_lowest_bigint_on_each_server() {
    for s in servers() {
        let store = s.store("far");
        let p = store.table_prefix().to_string();
        let db = Arc::new(s.db());
        storetest::kit::check_over_foreign_rows(store, &p, |sql| {
            let db = db.clone();
            async move { db.exec(&sql).await }
        })
        .await;
        s.cleanup().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_check_and_the_dashboard_over_a_cron_job_whose_last_run_started_far_off_on_each_server() {
    for s in servers() {
        for (i, started_at) in storetest::kit::FAR_STARTS.into_iter().enumerate() {
            let store = s.store(&format!("farcron{i}"));
            let p = store.table_prefix().to_string();
            let db = Arc::new(s.db());
            storetest::kit::cron_over_foreign_row(store, &p, started_at, |sql| {
                let db = db.clone();
                async move { db.exec(&sql).await }
            })
            .await;
        }
        s.cleanup().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_is_finished_once_across_stores_on_each_server() {
    for s in servers() {
        let server = s.clone();
        storetest::kit::finish_once(move || {
            let p = server.prefix("once");
            let on = server.clone();
            Shared { open: Box::new(move || Arc::new(on.store_on(&p)) as Arc<dyn Store>), done: Box::new(|| {}) }
        })
        .await;
        s.cleanup().await;
    }
}

/// A client from end to end: jobs declared, runs that succeed and fail, a
/// check that finds a stuck run and a missed one, the alerts sent and the
/// state's version moving on every write.
#[tokio::test]
async fn a_client_records_and_checks_on_each_server() {
    for s in servers() {
        let store = Arc::new(s.store("e2e"));
        let clock = Clock::new(T0);
        let p = Process::new(store.clone() as Arc<dyn Store>, &clock);
        let cw = &p.client;
        let nightly =
            cw.job("nightly", JobOptions::new().schedule("every 5m").grace("1m").timeout("2m")).expect("a job");
        cw.job("hourly", JobOptions::new().schedule("every 1h").grace("1m")).expect("a job");
        nightly
            .run(|j| async move {
                j.log("rows: 12");
                j.metric("rows", 12.0)
            })
            .await
            .expect("a run");
        clock.advance(MIN);
        let err = nightly.run(|_| async { Err::<(), _>(std::io::Error::other("boom")) }).await.unwrap_err();
        assert_eq!(err.to_string(), "boom", "{}", s.name);
        let st = store.get_state("nightly").await.unwrap().expect("a state");
        assert_eq!(st.consecutive_failures, 1, "{}", s.name);
        let before = st.version.expect("a version");
        assert!(before >= 2, "{}: version {before}", s.name);

        clock.advance(MIN);
        let h = nightly.start(StartOptions::new()).await.expect("a start");
        h.log("started");
        h.flush().await;
        clock.advance(3 * MIN); // past nightly's timeout
        let first = cw.check().await.expect("a check");
        clock.advance(61 * MIN); // hourly, declared at T0, is now missed
        let second = cw.check().await.expect("a check");

        let mut types = p.alerts.types();
        types.sort();
        for want in ["failed", "missed", "stuck"] {
            assert!(types.iter().any(|t| t == want), "{}: no {want} among {types:?}", s.name);
        }
        let runs = cw.runs("nightly", 10).await.unwrap();
        let statuses: Vec<&str> = runs.iter().map(|r| r.status.as_str()).collect();
        assert_eq!(statuses, ["timeout", "failed", "ok"], "{}", s.name);
        assert_eq!(runs[0].output.as_deref(), Some("started"));
        assert_eq!(runs[2].output.as_deref(), Some("rows: 12"));
        assert_eq!(runs[2].metrics.to_json(), r#"{"rows":12}"#);
        let st = store.get_state("nightly").await.unwrap().expect("a state");
        assert!(st.version.unwrap() > before, "{}: the version did not move", s.name);
        assert_eq!((first.jobs.len(), second.jobs.len()), (2, 2));
        assert!(p.errors.list().is_empty(), "{}: {:?}", s.name, p.errors.list());
        cw.close().await.unwrap();

        // Another process reads it all back.
        let two = Process::new(Arc::new(s.store_on(store.table_prefix())), &clock);
        let summary = two.client.job_summary("nightly").await.unwrap().expect("a summary");
        assert_eq!(summary.consecutive_failures, 2, "{}: the failure and the stuck run", s.name);
        assert_eq!(two.client.runs("nightly", 10).await.unwrap().len(), 3);
        s.cleanup().await;
    }
}

/// A run recorded while the app has a transaction open survives the app's
/// rollback: the store writes each statement on its own, never inside the
/// app's transaction.
#[tokio::test]
async fn a_run_survives_the_apps_rollback() {
    for s in servers() {
        let store = s.store("tx");
        let p = store.table_prefix().to_string();
        let cw = cronwatch::Client::builder().store(store).alerts([]).no_cron_secret().build().unwrap();
        let orders = format!("{p}orders");
        let result = match s.db() {
            common::server::Db::Pg(pool) => {
                sqlx::raw_sql(sqlx::AssertSqlSafe(format!("CREATE TABLE {orders} (id INT PRIMARY KEY)")))
                    .execute(&pool)
                    .await
                    .unwrap();
                let mut tx = pool.begin().await.unwrap();
                sqlx::raw_sql(sqlx::AssertSqlSafe(format!("INSERT INTO {orders} VALUES (1)")))
                    .execute(&mut *tx)
                    .await
                    .unwrap();
                let out = cw.run("import", None, |_| async { Ok::<_, std::io::Error>("imported") }).await;
                tx.rollback().await.unwrap();
                out
            }
            common::server::Db::My(pool) => {
                sqlx::raw_sql(sqlx::AssertSqlSafe(format!("CREATE TABLE {orders} (id INT PRIMARY KEY)")))
                    .execute(&pool)
                    .await
                    .unwrap();
                let mut tx = pool.begin().await.unwrap();
                sqlx::raw_sql(sqlx::AssertSqlSafe(format!("INSERT INTO {orders} VALUES (1)")))
                    .execute(&mut *tx)
                    .await
                    .unwrap();
                let out = cw.run("import", None, |_| async { Ok::<_, std::io::Error>("imported") }).await;
                tx.rollback().await.unwrap();
                out
            }
        };
        result.unwrap().unwrap();
        assert_eq!(s.db().column(&format!("SELECT CAST(COUNT(*) AS CHAR) FROM {orders}")).await, ["0"], "{}", s.name);
        let runs = cw.runs("import", 10).await.unwrap();
        assert_eq!(runs.len(), 1, "{}: the run was lost with the app's rollback", s.name);
        assert_eq!(runs[0].output.as_deref(), Some("imported"));
        s.cleanup().await;
    }
}

/// A row another writer (or a hand edit) left in a shape of its own, valid
/// JSON but not what the SDK writes, is read as the SDK reads it rather than
/// failing every read it is part of.
#[tokio::test]
async fn a_row_of_another_shape_does_not_blind_the_checks() {
    for s in servers() {
        let store = s.store("audit");
        let p = store.table_prefix().to_string();
        store.init().await.unwrap();
        store.insert_run(&run("good", "a", RunStatus::Running, 1)).await.unwrap();
        store.upsert_job(&definition(r#"{"name":"a","schedule":"0 * * * *"}"#), 1).await.unwrap();
        let db = s.db();
        db.exec(&format!(
            r#"INSERT INTO {p}runs (id, job, status, started_at, metrics) VALUES ('bad', 'b', 'running', 2, '{{"rows":"12","n":3}}')"#
        ))
        .await;
        db.exec(&format!("INSERT INTO {p}jobs (name, definition, created_at, updated_at) VALUES ('b', '[]', 1, 1)"))
            .await;
        let running = store.running_runs().await.unwrap();
        assert_eq!(running.len(), 2, "{}", s.name);
        let bad = running.iter().find(|r| r.id == "bad").unwrap();
        assert_eq!(bad.metrics.to_json(), r#"{"n":3}"#, "{}: the numbers are kept", s.name);
        assert_eq!(store.list_jobs().await.unwrap().len(), 2, "{}", s.name);
        let cw = cronwatch::Client::builder().store(store).alerts([]).no_cron_secret().build().unwrap();
        cw.check().await.unwrap_or_else(|e| panic!("{}: the check: {e}", s.name));
        s.cleanup().await;
    }
}

// ---- Postgres

#[tokio::test]
async fn the_postgres_schema_is_the_sdks() {
    let Some(s) = postgres() else { return };
    let store = s.store("schema");
    let p = store.table_prefix().to_string();
    store.init().await.unwrap();
    store.init().await.expect("IF NOT EXISTS: a second init changes nothing");
    let db = s.db();
    let columns = db
        .column(&format!(
            "SELECT table_name || '.' || column_name || ' ' || data_type || ' ' || coalesce(column_default, '') FROM information_schema.columns
             WHERE table_name LIKE '{p}%' ORDER BY table_name, ordinal_position"
        ))
        .await;
    let runs: Vec<String> = columns
        .iter()
        .filter(|c| c.starts_with(&format!("{p}runs.")))
        .map(|c| c[p.len() + 5..].split(' ').next().unwrap().to_string())
        .collect();
    assert_eq!(
        runs,
        [
            "seq",
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
        ]
    );
    for want in [
        format!("{p}runs.seq bigint nextval("),
        format!("{p}runs.started_at bigint "),
        format!("{p}runs.metrics jsonb '{{}}'::jsonb"),
        format!("{p}runs.trigger text 'run'::text"),
        format!("{p}jobs.definition jsonb "),
        format!("{p}state.state jsonb "),
    ] {
        assert!(columns.iter().any(|c| c.starts_with(&want)), "no {want} among {columns:?}");
    }
    let indexes =
        db.column(&format!("SELECT indexname FROM pg_indexes WHERE indexname LIKE '{p}%' ORDER BY indexname")).await;
    assert_eq!(
        indexes,
        [
            format!("{p}jobs_pkey"),
            format!("{p}runs_job_started"),
            format!("{p}runs_pkey"),
            format!("{p}runs_running"),
            format!("{p}state_pkey")
        ]
    );
    let partial = db.column(&format!("SELECT indexdef FROM pg_indexes WHERE indexname = '{p}runs_running'")).await;
    assert!(partial[0].ends_with("WHERE (status = 'running'::text)"), "{partial:?}");

    // Numbers come back as numbers, and JSONB as Postgres orders it: keys by
    // length, then bytes.
    let mut r = run("r1", "nightly", RunStatus::Ok, T0);
    r.finished_at = Some(T0 + 1000);
    r.duration_ms = Some(1000);
    r.output = Some("tab\tand \"quotes\" \u{1F600}".into());
    let mut m = Metrics::new();
    m.set("ratio", 0.30000000000000004);
    m.set("tiny", 1e-7);
    m.set("huge", 1e21);
    r.metrics = m;
    store.insert_run(&r).await.unwrap();
    let read = store.get_run("r1").await.unwrap().expect("the run");
    assert_eq!((read.started_at, read.duration_ms, read.output.as_deref()), (T0, Some(1000), r.output.as_deref()));
    assert_eq!(read.metrics.to_json(), r#"{"huge":1e+21,"tiny":1e-7,"ratio":0.30000000000000004}"#);
    // Postgres keeps JSONB numbers as numeric, and writes them out in full.
    assert_eq!(
        db.column(&format!("SELECT metrics::text FROM {p}runs WHERE id = 'r1'")).await,
        [r#"{"huge": 1000000000000000000000, "tiny": 0.0000001, "ratio": 0.30000000000000004}"#]
    );
    store.upsert_job(&definition(r#"{"name":"a","schedule":"every 5m","tags":["x"]}"#), 1).await.unwrap();
    let j = store.get_job("a").await.unwrap().unwrap();
    assert_eq!(j.definition.keys().collect::<Vec<_>>(), ["name", "tags", "schedule"]);
    // Runs started in one millisecond come back in insertion order (seq).
    for id in ["t1", "t2", "t3"] {
        store.insert_run(&run(id, "ties", RunStatus::Ok, 5)).await.unwrap();
    }
    let ties: Vec<String> = store.list_runs("ties", 10).await.unwrap().into_iter().map(|r| r.id).collect();
    assert_eq!(ties, ["t3", "t2", "t1"]);
    // Names sort by byte, whatever the database's collation.
    for name in ["b", "B", "_c"] {
        store.upsert_job(&definition(&format!(r#"{{"name":"{name}"}}"#)), 1).await.unwrap();
    }
    let names: Vec<String> = store.list_jobs().await.unwrap().into_iter().map(|j| j.name).collect();
    assert_eq!(names, ["B", "_c", "a", "b"]);
    s.cleanup().await;
}

#[tokio::test]
async fn nul_characters_are_still_recorded_on_postgres() {
    let Some(s) = postgres() else { return };
    let store = Arc::new(s.store("nul"));
    let clock = Clock::new(T0);
    let p = Process::new(store.clone() as Arc<dyn Store>, &clock);
    let err = p
        .client
        .run("nul", None, |j| async move {
            j.log("before\0after");
            Err::<(), _>(std::io::Error::other("bad\0byte"))
        })
        .await
        .unwrap()
        .unwrap_err();
    assert_eq!(err.to_string(), "bad\0byte", "the job's own error comes back");
    let runs = p.client.runs("nul", 10).await.unwrap();
    assert_eq!(runs[0].status, RunStatus::Failed);
    assert_eq!(runs[0].output.as_deref(), Some("beforeafter"));
    assert!(runs[0].error.as_deref().unwrap().starts_with("Error: badbyte"), "{:?}", runs[0].error);
    let st = store.get_state("nul").await.unwrap().unwrap();
    assert_eq!(st.consecutive_failures, 1, "the state, with its alert, was written too");
    // So are a trigger, metric names and a definition's text.
    let nul2 = p.client.job("nul2", JobOptions::new().description("a\0b").tags(["t\0"]).budget("c\0", 5.0)).unwrap();
    nul2.run_with(cronwatch::RunOptions::new().trigger("cr\0on"), |j| async move {
        j.metric("ro\0ws", 2.0)?;
        Ok::<(), cronwatch::Error>(())
    })
    .await
    .unwrap();
    let second = &p.client.runs("nul2", 10).await.unwrap()[0];
    assert_eq!((second.status.clone(), second.trigger.as_str()), (RunStatus::Ok, "cron"));
    assert_eq!(second.metrics.iter().collect::<Vec<_>>(), [("rows", 2.0)]);
    let stored = store.get_job("nul2").await.unwrap().unwrap();
    storetest::kit::same_json(
        "nul2",
        &stored.definition.to_json(),
        r#"{"name":"nul2","description":"ab","tags":["t"],"budget":{"c":5}}"#,
    );
    assert!(p.errors.list().is_empty(), "{:?}", p.errors.list());
    s.cleanup().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_stores_racing_on_one_jobs_state_on_postgres() {
    let Some(s) = postgres() else { return };
    let p = s.prefix("race");
    let one = Arc::new(s.store_on(&p));
    let two = Arc::new(s.store_on(&p));
    one.init().await.unwrap();
    two.init().await.unwrap();
    let st = |version: i64, n: i64| {
        state(&format!(
            r#"{{"job":"r","open":{{}},"consecutiveFailures":{n},"silencedUntil":null,"lastAlertAt":null,"version":{version}}}"#
        ))
    };
    for (what, a, b, expected) in
        [("exactly one insert wins", st(1, 1), st(1, 2), 0), ("exactly one update wins", st(2, 3), st(2, 4), 1)]
    {
        let (x, y) = (one.clone(), two.clone());
        let ta = tokio::spawn(async move { x.compare_and_set_state(&a, expected).await.unwrap() });
        let tb = tokio::spawn(async move { y.compare_and_set_state(&b, expected).await.unwrap() });
        let (ra, rb) = (ta.await.unwrap(), tb.await.unwrap());
        assert_ne!(ra, rb, "{what}");
    }
    assert_eq!(one.get_state("r").await.unwrap().unwrap().version, Some(2));
    s.cleanup().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn many_postgres_stores_init_at_once() {
    let Some(s) = postgres() else { return };
    let p = s.prefix("init");
    let stores: Vec<Arc<cronwatch_sqlx::SqlStore>> = (0..8).map(|_| Arc::new(s.store_on(&p))).collect();
    let tasks: Vec<_> = stores.iter().cloned().map(|st| tokio::spawn(async move { st.init().await })).collect();
    for t in tasks {
        t.await.unwrap().expect("init");
    }
    stores[0].upsert_job(&definition(r#"{"name":"a"}"#), 1).await.unwrap();
    assert_eq!(stores[7].get_job("a").await.unwrap().unwrap().created_at, 1);
    s.cleanup().await;
}

// ---- MySQL and MariaDB

#[tokio::test]
async fn mysql_keeps_the_sdks_json_byte_for_byte() {
    for s in mysqls() {
        let store = s.store("bytes");
        let p = store.table_prefix().to_string();
        store.init().await.unwrap();
        store.init().await.expect("IF NOT EXISTS: a second init changes nothing");
        let db = s.db();
        let columns = db
            .column(&format!(
                "SELECT CONCAT(TABLE_NAME, '.', COLUMN_NAME, ' ', DATA_TYPE, ' ', COALESCE(COLLATION_NAME, '')) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE '{p}%' ORDER BY TABLE_NAME, ORDINAL_POSITION"
            ))
            .await;
        for want in [
            // text, never the JSON type, which rewrites what it holds
            format!("{p}jobs.definition longtext utf8mb4_bin"),
            format!("{p}runs.metrics longtext utf8mb4_bin"),
            format!("{p}state.state longtext utf8mb4_bin"),
            // names compare as bytes: "b" and "B" are two jobs
            format!("{p}jobs.name varchar utf8mb4_bin"),
        ] {
            assert!(columns.contains(&want), "{}: no {want} among {columns:?}", s.name);
        }
        let runs: Vec<&str> = columns
            .iter()
            .filter(|c| c.starts_with(&format!("{p}runs.")))
            .map(|c| c[p.len() + 5..].split(' ').next().unwrap())
            .collect();
        assert_eq!(
            runs,
            [
                "seq",
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
            ]
        );

        let def = definition(
            r#"{"grace":"15m","schedule":"0 2 * * *","budget":{"cost":2},"tags":["café ☃ 😀"],"name":"nightly"}"#,
        );
        store.upsert_job(&def, 1).await.unwrap();
        let mut r = run("r1", "nightly", RunStatus::Ok, 1);
        r.finished_at = Some(2);
        r.duration_ms = Some(1);
        r.output = Some("tab\tand \"quotes\" 😀".into());
        let mut m = Metrics::new();
        for (k, v) in [("ratio", 0.30000000000000004), ("tiny", 1e-7), ("huge", 1e21), ("üml", 7.0)] {
            m.set(k, v);
        }
        r.metrics = m;
        store.insert_run(&r).await.unwrap();
        let st = state(
            r#"{"job":"nightly","open":{"failed":5},"consecutiveFailures":1,"silencedUntil":null,"lastAlertAt":null,"pendingRecovery":["missed"],"undelivered":[],"version":3}"#,
        );
        store.set_state(&st).await.unwrap();
        assert_eq!(db.column(&format!("SELECT definition FROM {p}jobs")).await, [def.to_json()], "{}", s.name);
        assert_eq!(
            db.column(&format!("SELECT metrics FROM {p}runs")).await,
            [r#"{"ratio":0.30000000000000004,"tiny":1e-7,"huge":1e+21,"üml":7}"#],
            "{}",
            s.name
        );
        assert_eq!(db.column(&format!("SELECT state FROM {p}state")).await, [st.to_json()], "{}", s.name);
        assert_eq!(store.get_run("r1").await.unwrap().unwrap().to_json(), r.to_json(), "{}", s.name);
        s.cleanup().await;
    }
}

/// MySQL answers how many rows an UPDATE changed, not how many it matched,
/// unless the connection asks for found rows (sqlx's do). Neither may make a
/// conditional write that landed read as refused.
#[tokio::test]
async fn mysql_conditional_writes_do_not_lean_on_how_rows_are_counted() {
    for s in mysqls() {
        let store = s.store("rows");
        store.init().await.unwrap();
        let v = |job: &str, version: i64, failures: i64| {
            state(&format!(
                r#"{{"job":"{job}","open":{{}},"consecutiveFailures":{failures},"silencedUntil":null,"lastAlertAt":null,"version":{version}}}"#
            ))
        };
        let cas = async |what: &str, st: cronwatch::JobState, expected: i64, want: bool| {
            assert_eq!(store.compare_and_set_state(&st, expected).await.unwrap(), want, "{}: {what}", s.name);
        };
        cas("first", v("j", 1, 0), 0, true).await;
        cas("a write from a stale read is refused", v("j", 1, 9), 0, false).await;
        cas("another version", v("j", 3, 0), 2, false).await;
        cas("the version read", v("j", 2, 1), 1, true).await;
        assert_eq!(store.get_state("j").await.unwrap().unwrap().version, Some(2));
        store
            .set_state(&state(
                r#"{"job":"old","open":{},"consecutiveFailures":3,"silencedUntil":null,"lastAlertAt":null}"#,
            ))
            .await
            .unwrap();
        cas("state written before versions counts as 0", v("old", 1, 4), 0, true).await;
        let zero = state(r#"{"job":"zero","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null}"#);
        store.set_state(&zero).await.unwrap();
        cas("a write of what version 0 already holds still wrote", zero, 0, true).await;
        // A write from version 0 whose insert landed but whose answer was
        // lost: the row holding exactly what was sent is the write's own.
        let landed = v("landed", 1, 0);
        store.set_state(&landed).await.unwrap();
        cas("a landed write is counted as written", landed, 0, true).await;

        // A flush that writes what the row already holds still wrote.
        let mut r = run("r", "j", RunStatus::Running, 1);
        r.output = Some("same".into());
        store.insert_run(&r).await.unwrap();
        assert!(store.update_run_if(&r, &[RunStatus::Running]).await.unwrap(), "{}", s.name);
        assert!(!store.update_run_if(&r, &[RunStatus::Timeout]).await.unwrap(), "{}", s.name);
        s.cleanup().await;
    }
}

/// MySQL's trigger column is VARCHAR(255): a longer trigger is cut to fit
/// rather than lose the whole run.
#[tokio::test]
async fn mysql_keeps_a_run_with_a_long_trigger() {
    for s in mysqls() {
        let store = s.store("trigger");
        store.init().await.unwrap();
        let mut r = run("r", "j", RunStatus::Running, 1);
        r.trigger = "é".repeat(300);
        store.insert_run(&r).await.unwrap();
        assert_eq!(store.get_run("r").await.unwrap().unwrap().trigger, "é".repeat(255), "{}", s.name);
        s.cleanup().await;
    }
}

/// State rows a damaged or hand-edited row could hold in MySQL's LONGTEXT:
/// text that is not JSON, JSON that is not an object, and objects whose
/// version is not a number. A check, a silence and a second check answer
/// with no error, and the silence replaces each row (it counts as version
/// 0, as on SQLite).
#[tokio::test]
async fn mysql_replaces_a_damaged_state_row() {
    const DAMAGED: [&str; 10] = [
        "{",
        "not json",
        "5",
        r#""x""#,
        "[]",
        "null",
        r#"{"version":"x"}"#,
        r#"{"version":true}"#,
        r#"{"version":{"a":1}}"#,
        r#"{"version":[1]}"#,
    ];
    for s in mysqls() {
        let store = Arc::new(s.store("damaged"));
        store.init().await.unwrap();
        let p = store.table_prefix().to_string();
        let db = s.db();
        for (i, text) in DAMAGED.iter().enumerate() {
            store.upsert_job(&definition(&format!(r#"{{"name":"dmg{i}"}}"#)), 1).await.unwrap();
            db.exec(&format!("INSERT INTO {p}state (job, state) VALUES ('dmg{i}', '{text}')")).await;
        }
        let clock = Clock::new(T0);
        let proc = Process::new(store.clone() as Arc<dyn Store>, &clock);
        proc.client.check().await.unwrap();
        for (i, text) in DAMAGED.iter().enumerate() {
            let name = format!("dmg{i}");
            if let Err(e) = proc.client.silence(&name, "1h").await {
                panic!("{}: silencing over {text}: {e}", s.name);
            }
            let st = store.get_state(&name).await.unwrap().expect("the state");
            assert_eq!(st.silenced_until, Some(T0 + 3_600_000), "{}: over {text}", s.name);
        }
        proc.client.check().await.unwrap();
        assert_eq!(proc.errors.list(), Vec::<String>::new(), "{}", s.name);
        s.cleanup().await;
    }
}

#[tokio::test]
async fn each_server_names_its_dialect() {
    for s in servers() {
        let store = s.store("dialect");
        assert_eq!(store.dialect(), s.dialect);
        assert!(matches!(store.dialect(), Dialect::Postgres | Dialect::Mysql));
    }
}
