//! The pg_cron source against a real pg_cron, as the SDK's pgcron.test.ts
//! and the Go port's sqltest run it, when CRONWATCH_TEST_PGCRON is the URL of
//! a Postgres with pg_cron preloaded (cron.database_name naming that
//! database). A test with it unset says so and passes.

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cronwatch::storetest::kit::{Capture, Errors};
use cronwatch::{AlertType, Channel, Client, JobOptions, JobSummary, RunStatus};
use cronwatch_sqlx::{PgCron, PgCronJob, PgCronOptions, SqlStore};
use sqlx::{AssertSqlSafe, PgPool};

async fn pgcron() -> Option<PgPool> {
    let url = std::env::var("CRONWATCH_TEST_PGCRON").ok().filter(|u| !u.is_empty());
    let Some(url) = url else {
        eprintln!("pg_cron: skipped; set CRONWATCH_TEST_PGCRON to run");
        return None;
    };
    let pool = PgPool::connect(&url).await.expect("the pg_cron server");
    // The tests start at once, and two CREATE EXTENSIONs race.
    exec(&pool, "BEGIN; SELECT pg_advisory_xact_lock(7307); CREATE EXTENSION IF NOT EXISTS pg_cron; COMMIT").await;
    Some(pool)
}

async fn exec(pool: &PgPool, sql: &str) {
    sqlx::raw_sql(AssertSqlSafe(sql.to_string())).execute(pool).await.unwrap_or_else(|e| panic!("{sql}: {e}"));
}

/// The first column of each row, a bigint.
async fn ids(pool: &PgPool, sql: &str) -> Vec<i64> {
    sqlx::query_scalar::<_, i64>(AssertSqlSafe(sql.to_string()))
        .fetch_all(pool)
        .await
        .unwrap_or_else(|e| panic!("{sql}: {e}"))
}

fn tag(label: &str) -> String {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_nanos() % 10_000;
    format!("cwrs{label}{}x{nanos}", std::process::id())
}

fn find<'a>(jobs: &'a [JobSummary], name: &str) -> Option<&'a JobSummary> {
    jobs.iter().find(|j| j.name == name)
}

fn others(errors: &Errors) -> Vec<String> {
    errors.list().into_iter().filter(|e| !e.contains("cron.") && !e.contains("row level")).collect()
}

fn picks(tag: &str) -> Arc<dyn Fn(&PgCronJob) -> bool + Send + Sync> {
    let tag = tag.to_string();
    Arc::new(move |j: &PgCronJob| j.job_name.as_deref().is_some_and(|n| n.starts_with(&tag)))
}

async fn unschedule(pool: &PgPool, tag: &str) {
    exec(pool, &format!("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE '{tag}%'")).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_source_against_a_real_pg_cron() {
    let Some(pool) = pgcron().await else { return };
    let tag = tag("real");
    let (ok, fail, sleep) = (format!("{tag}-ok"), format!("{tag}-fail"), format!("{tag}-sleep"));
    let store = Arc::new(SqlStore::postgres(pool.clone()).prefix(&format!("{tag}_")).unwrap());
    let offset = Arc::new(AtomicI64::new(0));
    let alerts = Capture::default();
    let new_client = || {
        let offset = offset.clone();
        Client::builder()
            .store_arc(store.clone())
            .alerts([Arc::new(alerts.clone()) as Arc<dyn Channel>])
            .clock(move || {
                SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as i64 + offset.load(Ordering::SeqCst)
            })
            .no_cron_secret()
            .on_error(|_, _| {})
            .source(Arc::new(PgCron::new(
                pool.clone(),
                PgCronOptions {
                    pick: Some(picks(&tag)),
                    options: JobOptions::new().grace("30s"),
                    ..Default::default()
                },
            )))
            .build()
            .unwrap()
    };
    exec(&pool, &format!("SELECT cron.schedule('{ok}', '1 seconds', 'SELECT 1')")).await;
    exec(&pool, &format!("SELECT cron.schedule('{fail}', '1 seconds', 'SELECT 1/0')")).await;
    exec(&pool, &format!("SELECT cron.schedule('{sleep}', '1 seconds', 'SELECT pg_sleep(3)')")).await;
    tokio::time::sleep(Duration::from_millis(3500)).await;

    let cw = new_client();
    let first = cw.check().await.unwrap();
    let ok_job = find(&first.jobs, &ok).expect("the ok job");
    assert_eq!((ok_job.definition.schedule(), ok_job.definition.timezone()), ("every 1s", "UTC"));
    let ok_runs = cw.runs(&ok, 20).await.unwrap();
    assert!(ok_runs.len() >= 2, "ok runs imported ({})", ok_runs.len());
    for r in &ok_runs {
        assert!(r.id.starts_with("pgcron:") && r.trigger == "pg_cron", "run {} from {}", r.id, r.trigger);
    }
    assert!(
        ok_runs.iter().any(|r| r.status == RunStatus::Ok && r.output.as_deref() == Some("1 row")),
        "no run with its output"
    );
    let fail_runs = cw.runs(&fail, 20).await.unwrap();
    assert!(
        fail_runs.iter().any(
            |r| r.status == RunStatus::Failed && r.error.as_deref().is_some_and(|e| e.contains("division by zero"))
        ),
        "the failure and its message were not imported"
    );
    let sent: Vec<String> = first.alerts.iter().map(|a| format!("{} {}", a.alert_type, a.job)).collect();
    assert_eq!(sent, [format!("failed {fail}")]);
    assert_eq!(ok_job.health, cronwatch::JobHealth::Healthy);

    // A run imported while it was going is updated when it finishes.
    let mut running = 0;
    for _ in 0..40 {
        let found = ids(
            &pool,
            &format!(
                "SELECT d.runid FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = '{sleep}' AND d.status = 'running' AND d.start_time IS NOT NULL"
            ),
        )
        .await;
        if let Some(id) = found.first() {
            running = *id;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(running > 0, "never saw the sleeping job running");
    let id = format!("pgcron:{running}");
    cw.check().await.unwrap();
    assert_eq!(cw.get_run(&id).await.unwrap().map(|r| r.status), Some(RunStatus::Running), "{id}");
    tokio::time::sleep(Duration::from_millis(3500)).await;
    cw.check().await.unwrap();
    let slept = cw.get_run(&id).await.unwrap().expect("the slept run");
    assert_eq!(slept.status, RunStatus::Ok, "{slept:?}");
    assert!(slept.duration_ms.unwrap() >= 2900, "{slept:?}");

    // New runs keep arriving; nothing is copied twice, even by a fresh
    // client after a restart.
    let before = cw.runs(&ok, 500).await.unwrap().len();
    tokio::time::sleep(Duration::from_secs(2)).await;
    cw.check().await.unwrap();
    let after = cw.runs(&ok, 500).await.unwrap();
    assert!(after.len() > before, "later runs were not imported");
    let mut seen = std::collections::HashSet::new();
    for r in &after {
        assert!(seen.insert(r.id.clone()), "{} copied twice", r.id);
    }

    // The ok job is unscheduled and the failing one paused: neither is
    // missed.
    exec(&pool, &format!("SELECT cron.unschedule('{ok}')")).await;
    exec(&pool, &format!("SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = '{fail}'")).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let cw = new_client();
    cw.check().await.unwrap();
    let settled = cw.runs(&fail, 500).await.unwrap().len();
    cw.check().await.unwrap();
    assert_eq!(cw.runs(&fail, 500).await.unwrap().len(), settled, "re-import added runs");
    offset.store(2 * 60_000, Ordering::SeqCst);
    let late = cw.check().await.unwrap();
    for a in &late.alerts {
        assert!(!(a.alert_type == AlertType::Missed && (a.job == ok || a.job == fail)), "{} missed", a.job);
    }
    let ok_job = find(&late.jobs, &ok).expect("the unscheduled job");
    assert_eq!(ok_job.definition.schedule(), "");
    assert!(ok_job.definition.description().contains("no longer in cron.job"), "{}", ok_job.definition.description());

    unschedule(&pool, &tag).await;
    for table in ["jobs", "runs", "state"] {
        exec(&pool, &format!("DROP TABLE IF EXISTS {tag}_{table}")).await;
    }
}

#[tokio::test]
async fn restart_rows_a_crowded_job_first_sight_and_a_rename() {
    let Some(pool) = pgcron().await else { return };
    let tag = tag("row");
    let (busy, quiet, hist) = (format!("{tag}-busy"), format!("{tag}-quiet"), format!("{tag}-hist"));
    let insert = async |jobid: i64, status: &str, times: &str, message: &str| -> i64 {
        ids(
            &pool,
            &format!(
                "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
                 SELECT {jobid}, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', '{status}', '{message}', {times} RETURNING runid"
            ),
        )
        .await[0]
    };
    let mut jobids = std::collections::HashMap::new();
    for name in [&busy, &quiet, &hist] {
        let id = ids(&pool, &format!("SELECT cron.schedule('{name}', '0 3 * * *', 'SELECT 1')")).await[0];
        // Paused, so pg_cron itself adds no rows while the test writes its own.
        exec(&pool, &format!("SELECT cron.alter_job({id}, active := false)")).await;
        jobids.insert(name.clone(), id);
    }
    // First sight of a job whose newest rows include a run cut off by a
    // restart, and older failures.
    exec(
        &pool,
        &format!(
            "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
             SELECT {}, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'failed', 'ERROR: old', now() - interval '3 days', now() - interval '3 days' FROM generate_series(1, 5)",
            jobids[&hist]
        ),
    )
    .await;
    insert(jobids[&hist], "failed", "NULL, NULL", "server restarted").await;
    exec(
        &pool,
        &format!(
            "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
             SELECT {}, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - make_interval(mins => 30 - g), now() - make_interval(mins => 30 - g) FROM generate_series(1, 19) g",
            jobids[&hist]
        ),
    )
    .await;

    let (alerts, errors) = (Capture::default(), Errors::default());
    let errs = errors.clone();
    let cw = Client::builder()
        .alerts([Arc::new(alerts.clone()) as Arc<dyn Channel>])
        .no_cron_secret()
        .on_error(move |e, w| errs.add(e, w))
        .source(Arc::new(PgCron::new(
            pool.clone(),
            PgCronOptions { pick: Some(picks(&tag)), timezone: Some("UTC".into()), ..Default::default() },
        )))
        .build()
        .unwrap();
    cw.check().await.unwrap();
    assert_eq!(cw.runs(&hist, 500).await.unwrap().len(), 20, "the twenty newest are copied");
    assert!(alerts.types().is_empty(), "history was judged: {:?}", alerts.types());
    cw.check().await.unwrap();
    assert_eq!(cw.runs(&hist, 500).await.unwrap().len(), 20, "after a second read");

    // A restart cuts off a busy job's queued run; the busy job then runs past
    // a page; then the quiet job fails.
    let cut = insert(jobids[&busy], "failed", "NULL, NULL", "server restarted").await;
    exec(
        &pool,
        &format!(
            "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time)
             SELECT {}, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - make_interval(secs => 600 - g), now() - make_interval(secs => 600 - g) FROM generate_series(1, 520) g",
            jobids[&busy]
        ),
    )
    .await;
    let disk = insert(jobids[&quiet], "failed", "now(), now()", "ERROR: disk full").await;
    for _ in 0..3 {
        cw.check().await.unwrap();
    }
    let cut_run = cw.get_run(&format!("pgcron:{cut}")).await.unwrap().expect("the cut off run");
    assert_eq!(cut_run.error.as_deref(), Some("server restarted"));
    let disk_run = cw.get_run(&format!("pgcron:{disk}")).await.unwrap().expect("the quiet job's failure");
    assert_eq!(disk_run.status, RunStatus::Failed);
    assert!(
        alerts.list().iter().any(|a| a.alert_type == AlertType::Failed && a.job == quiet),
        "the quiet job's failure did not alert"
    );

    // Renamed in pg_cron: the old name keeps its runs and loses its schedule.
    exec(&pool, &format!("UPDATE cron.job SET jobname = '{quiet}-v2' WHERE jobid = {}", jobids[&quiet])).await;
    exec(&pool, &format!("SELECT cron.alter_job({}, active := true)", jobids[&quiet])).await;
    cw.check().await.unwrap();
    let jobs = cw.jobs().await.unwrap();
    let old = find(&jobs, &quiet).expect("the old name");
    assert_eq!(old.definition.schedule(), "");
    assert!(old.definition.description().contains("renamed to"), "{}", old.definition.description());
    assert_eq!(find(&jobs, &format!("{quiet}-v2")).expect("the new name").definition.schedule(), "0 3 * * *");
    assert!(others(&errors).is_empty(), "{:?}", others(&errors));
    unschedule(&pool, &tag).await;
}

/// A role that may not read pg_cron's settings is given UTC and told once,
/// and the reads never fail the check.
#[tokio::test]
async fn a_role_that_may_not_read_cron_settings_is_given_utc() {
    let Some(admin) = pgcron().await else { return };
    let role = tag("role");
    exec(&admin, &format!("CREATE ROLE {role} LOGIN PASSWORD 'pw'")).await;
    exec(&admin, &format!("GRANT USAGE ON SCHEMA cron TO {role}")).await;
    exec(&admin, &format!("GRANT SELECT ON cron.job, cron.job_run_details TO {role}")).await;
    let options = admin.connect_options().as_ref().clone().username(&role).password("pw");
    let pool = PgPool::connect_with(options).await.unwrap();
    exec(&pool, &format!("SELECT cron.schedule('{role}-job', '0 3 * * *', 'SELECT 1')")).await;

    let errors = Errors::default();
    let errs = errors.clone();
    let cw = Client::builder()
        .alerts([])
        .no_cron_secret()
        .on_error(move |e, w| errs.add(e, w))
        .source(Arc::new(PgCron::new(pool.clone(), PgCronOptions::default())))
        .build()
        .unwrap();
    let result = cw.check().await.unwrap();
    cw.check().await.unwrap();
    let job = find(&result.jobs, &format!("{role}-job")).expect("the role's job");
    assert_eq!(
        (job.definition.timezone(), job.definition.schedule()),
        ("UTC", "0 3 * * *"),
        "assumed UTC, and cron.log_run unreadable taken as on"
    );
    let told = errors.list().iter().filter(|e| e.contains("could not read cron.timezone")).count();
    assert_eq!(told, 1, "{:?}", errors.list());
    pool.close().await;

    // Every job of the role goes before the role: pg_cron's scheduler stops
    // on a job whose role is gone.
    exec(&admin, &format!("SELECT cron.unschedule(jobid) FROM cron.job WHERE username = '{role}'")).await;
    exec(&admin, &format!("DROP OWNED BY {role}")).await;
    exec(&admin, &format!("DROP ROLE IF EXISTS {role}")).await;
}
