//! The SDK's routes tests (routes.test.ts, routes-security.test.ts,
//! routes-origin.test.ts, routes-pwa.test.ts in part), as the Go port has
//! them, and what only a Rust server has: the base path found from axum's
//! mount, the body cap, a body cut short, a request whose future is
//! dropped, and HTTP/2's split cookies. The tests that need an environment
//! of their own (development, a missing token) are in `routes_env.rs`.

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use bytes::Bytes;
use common::{HOUR, Kit, MIN, T0, TestStore};
use cronwatch::js::{self, Object, Value};
use cronwatch::web::{Body, MAX_BODY, Request, Response, Routes, RoutesOptions};
use cronwatch::{
    BoxError, BoxFuture, Client, Definition, JobHealth, JobOptions, JobState, MemoryStore, Run, Store, StoredJob,
};
use http_body_util::BodyExt;
use sha2::{Digest, Sha256};
use tower::ServiceExt;

fn token_cookie() -> String {
    let sum = Sha256::digest(b"cronwatch-cookie:tok");
    let mut cookie = String::from("cronwatch_token=");
    for b in sum {
        cookie.push_str(&format!("{b:02x}"));
    }
    cookie
}

const AUTH: (&str, &str) = ("authorization", "Bearer tok");
const FORM: (&str, &str) = ("content-type", "application/x-www-form-urlencoded");
const JSON: (&str, &str) = ("content-type", "application/json");

/// A client, its routes, and a way to send them a request.
struct Web {
    k: Kit,
    routes: Routes,
}

impl Web {
    fn new() -> Web {
        Web::with(RoutesOptions::new().token("tok").base_path("/cronwatch"), |b| b)
    }

    fn with(options: RoutesOptions, more: impl FnOnce(cronwatch::ClientBuilder) -> cronwatch::ClientBuilder) -> Web {
        let k = Kit::with(more);
        let routes = k.cw.routes(options).unwrap();
        Web { k, routes }
    }

    async fn send(&self, method: &str, path: &str, headers: &[(&str, &str)], body: &str) -> Response {
        serve(&self.routes, method, &format!("http://app.test{path}"), headers, body).await
    }

    async fn get(&self, path: &str, headers: &[(&str, &str)]) -> Response {
        self.send("GET", path, headers, "").await
    }

    async fn ok(&self, name: &str) {
        self.k.cw.run(name, None, |_| async { Ok::<_, std::io::Error>(()) }).await.unwrap().unwrap();
    }
}

/// A request for a full URL, as a server would hand it over.
fn request(method: &str, url: &str, headers: &[(&str, &str)], body: &str) -> Request {
    let tls = url.starts_with("https://");
    let rest = url.trim_start_matches("http://").trim_start_matches("https://");
    let (host, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let path = if path.is_empty() { "/" } else { path };
    let mut req = Request::new(method, path).with_header("host", host).with_tls(tls);
    for (k, v) in headers {
        req = req.with_header(*k, v);
    }
    if !body.is_empty() {
        req = req.with_body(body);
    }
    req
}

async fn serve(routes: &Routes, method: &str, url: &str, headers: &[(&str, &str)], body: &str) -> Response {
    routes.handle(request(method, url, headers, body)).await
}

fn json(res: &Response) -> Object {
    match js::parse(&res.text()) {
        Ok(Value::Object(o)) => o,
        other => panic!("not a JSON object: {other:?}: {}", res.text()),
    }
}

fn field<'a>(o: &'a Object, path: &[&str]) -> &'a Value {
    let mut v = o.get(path[0]).unwrap_or_else(|| panic!("no {}", path[0]));
    for key in &path[1..] {
        v = v.as_object().and_then(|o| o.get(key)).unwrap_or_else(|| panic!("no {key}"));
    }
    v
}

#[track_caller]
fn status(what: &str, res: &Response, want: u16) {
    assert_eq!(res.status, want, "{what}: {}", res.text().chars().take(300).collect::<String>());
}

#[track_caller]
fn contains(what: &str, text: &str, want: &str) {
    assert!(text.contains(want), "{what}: {want:?} is not in {:?}", text.chars().take(600).collect::<String>());
}

fn with<'a>(sets: &[&[(&'a str, &'a str)]]) -> Vec<(&'a str, &'a str)> {
    sets.iter().flat_map(|s| s.iter().copied()).collect()
}

#[tokio::test]
async fn everything_needs_the_token() {
    let w = Web::new();
    status("page", &w.get("/cronwatch", &[]).await, 401);
    status("api", &w.get("/cronwatch/api/jobs", &[]).await, 401);
    status("wrong", &w.get("/cronwatch/api/jobs", &[("authorization", "Bearer wrong")]).await, 401);
    status("right", &w.get("/cronwatch/api/jobs", &[AUTH]).await, 200);
    status("any case and spaces", &w.get("/cronwatch/api/jobs", &[("authorization", "bEaReR \t tok")]).await, 200);
    assert_eq!(w.routes.token(), Some("tok"));
}

#[tokio::test]
async fn check_accepts_the_cron_secret_and_nothing_else_does() {
    let secret = format!("cron-{}", "s3cret");
    let w = Web::with(RoutesOptions::new().token("tok"), |b| b.cron_secret(secret.clone()));
    let bearer = format!("Bearer {secret}");
    status("check", &w.get("/cronwatch/api/check", &[("authorization", &bearer)]).await, 200);
    status("jobs", &w.get("/cronwatch/api/jobs", &[("authorization", &bearer)]).await, 401);
    status("only as a bearer", &w.get(&format!("/cronwatch/api/check?token={secret}"), &[]).await, 401);
}

#[tokio::test]
async fn sign_in_sets_a_cookie_and_redirects_to_a_clean_url() {
    let w = Web::new();
    let cookie = token_cookie();
    let res = w.get("/cronwatch/?token=tok", &[]).await;
    status("sign-in", &res, 303);
    assert_eq!(res.header_str("location"), Some("/cronwatch/"));
    let set = res.header_str("set-cookie").unwrap();
    assert_eq!(set.split(';').next(), Some(cookie.as_str()), "a digest, not the token");
    contains("cookie", set, "; Path=/cronwatch; HttpOnly; SameSite=Lax; Max-Age=2592000");
    let page = w.get("/cronwatch/", &[("cookie", &format!("other=1; {cookie}"))]).await;
    status("with the cookie", &page, 200);
    contains("type", page.header_str("content-type").unwrap(), "text/html");
    status("the raw token is not a cookie", &w.get("/cronwatch/", &[("cookie", "cronwatch_token=tok")]).await, 401);
    // HTTP/2 may send each cookie as a header of its own.
    status("split cookies", &w.get("/cronwatch/", &[("cookie", "other=1"), ("cookie", &cookie)]).await, 200);
    let other = w.get("/cronwatch/jobs/x?view=all&token=tok&a=b+c", &[]).await;
    assert_eq!(other.header_str("location"), Some("/cronwatch/jobs/x?view=all&a=b+c"), "the rest of the query is kept");
}

#[tokio::test]
async fn pages_render_and_the_api_answers() {
    let w = Web::new();
    let job =
        w.k.cw.job("nightly-report", JobOptions::new().schedule("0 2 * * *").description("Builds the PDF")).unwrap();
    job.run(|j| {
        j.log("built");
        w.k.advance(2000);
        async { Ok::<_, std::io::Error>(()) }
    })
    .await
    .unwrap();
    let _ = w.k.cw.run("broken", None, |_| async { Err::<(), _>(std::io::Error::other("kaboom <script>")) }).await;

    let dash = w.get("/cronwatch", &[AUTH]).await.text().into_owned();
    for want in [
        "nightly-report",
        "Builds the PDF",
        "healthy",
        "failing",
        r#"<p class="headline">2 jobs, <b>1 needing attention</b>.</p>"#,
        r#"<div class="bad"><dt><i class="sq bad" aria-hidden="true"></i>failing</dt><dd>1</dd></div>"#,
        r#"<figure class="timeline day">"#,
        r#"<table class="board">"#,
        r#"<form class="inline" method="post" action="/cronwatch/check"><button class="primary" type="submit">Run check now</button></form>"#,
    ] {
        contains("dashboard", &dash, want);
    }
    let page = w.get("/cronwatch/jobs/broken", &[AUTH]).await;
    status("job page", &page, 200);
    let html = page.text();
    contains("escaped", &html, "kaboom &lt;script&gt;");
    assert!(!html.contains("<script>"), "an unescaped <script>");
    contains("heading", &html, r#"<h1 class="jobname">broken</h1>"#);
    contains("week", &html, r#"<figure class="timeline week">"#);
    contains(
        "error",
        &html,
        r#"<details class="out error" open><summary>error</summary><pre>Error: kaboom &lt;script&gt;"#,
    );

    let list = json(&w.get("/cronwatch/api/jobs", &[AUTH]).await);
    assert_eq!(field(&list, &["jobs"]).as_array().unwrap().len(), 2);
    let one = json(&w.get("/cronwatch/api/jobs/nightly-report?runs=5", &[AUTH]).await);
    assert_eq!(field(&one, &["job", "health"]).as_str(), Some("healthy"));
    let runs = field(&one, &["runs"]).as_array().unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].as_object().unwrap().get("output").and_then(Value::as_str), Some("built"));
    status("api missing", &w.get("/cronwatch/api/jobs/missing", &[AUTH]).await, 404);
    status("page missing", &w.get("/cronwatch/jobs/missing", &[AUTH]).await, 404);
    status("nope", &w.get("/cronwatch/nope", &[AUTH]).await, 404);
    let run_id = runs[0].as_object().unwrap().get("id").and_then(Value::as_str).unwrap().to_string();
    let run = json(&w.get(&format!("/cronwatch/api/runs/{run_id}"), &[AUTH]).await);
    assert_eq!(field(&run, &["run", "job"]).as_str(), Some("nightly-report"));
}

#[tokio::test]
async fn names_break_after_their_separators_only_as_text() {
    let w = Web::new();
    let name = "wp:store_sync.inventory--eu";
    w.ok(name).await;
    let shown = "wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu";
    let href = "/cronwatch/jobs/wp%3Astore_sync.inventory--eu";
    let dash = w.get("/cronwatch", &[AUTH]).await.text().into_owned();
    contains("the lane", &dash, &format!(r#"<a class="name" href="{href}">{shown}</a><span class="sched">"#));
    contains("the board", &dash, &format!(r#"<td class="job"><a class="name" href="{href}">{shown}</a></td>"#));
    contains("the words", &dash, "<li>wp:store_sync.inventory--eu (");
    let page = w.get(href, &[AUTH]).await.text().into_owned();
    contains("crumb", &page, &format!(r#"<span class="crumb">{shown}</span>"#));
    contains("heading", &page, &format!(r#"<h1 class="jobname">{shown}</h1>"#));
    contains("title", &page, "<title>wp:store_sync.inventory--eu: CronWatch</title>");
    contains("marks", &page, "<title>wp:store_sync.inventory--eu, ");
    assert_eq!(page.matches("<wbr>").count(), 8, "only in the crumb and the heading");
}

#[tokio::test]
async fn api_writes() {
    let w = Web::new();
    w.ok("s").await;
    let post = |path: &'static str, body: &'static str| w.send("POST", path, &[AUTH, JSON], body);
    let result = json(&post("/cronwatch/api/check", "").await);
    assert_eq!(field(&result, &["ok"]).as_bool(), Some(true));
    assert_eq!(field(&result, &["jobs"]).as_array().unwrap().len(), 1);
    let silenced = json(&post("/cronwatch/api/jobs/s/silence", r#"{"for":"2h"}"#).await);
    assert_eq!(field(&silenced, &["state", "silencedUntil"]).as_f64(), Some((T0 + 2 * HOUR) as f64));
    assert_eq!(w.k.summary("s").await.unwrap().health, JobHealth::Silenced);
    let un = json(&post("/cronwatch/api/jobs/s/unsilence", "").await);
    assert!(field(&un, &["state", "silencedUntil"]).is_null());
    status("ghost", &post("/cronwatch/api/jobs/nope/silence", r#"{"for":"1h"}"#).await, 404);
    status("delete", &w.send("DELETE", "/cronwatch/api/jobs/s", &[AUTH], "").await, 200);
    assert!(w.k.summary("s").await.is_none(), "the job was not forgotten");
    status("delete again", &w.send("DELETE", "/cronwatch/api/jobs/s", &[AUTH], "").await, 404);
}

#[tokio::test]
async fn forms_post_and_redirect_back() {
    let w = Web::new();
    w.ok("f").await;
    let res = w
        .send(
            "POST",
            "/cronwatch/jobs/f/silence",
            &[AUTH, FORM, ("referer", "http://app.test/cronwatch/jobs/f")],
            "for=4h",
        )
        .await;
    status("silence", &res, 303);
    assert_eq!(res.header_str("location"), Some("http://app.test/cronwatch/jobs/f"));
    assert_eq!(w.k.summary("f").await.unwrap().health, JobHealth::Silenced);
    let elsewhere =
        w.send("POST", "/cronwatch/jobs/f/unsilence", &[AUTH, ("referer", "https://evil.example/phish")], "").await;
    assert_eq!(elsewhere.header_str("location"), Some("/cronwatch/"), "a foreign referer is not followed");
    let multipart = "--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n--b--\r\n";
    let res = w
        .send(
            "POST",
            "/cronwatch/jobs/f/silence",
            &[AUTH, ("content-type", "multipart/form-data; boundary=b")],
            multipart,
        )
        .await;
    status("multipart", &res, 303);
    assert_eq!(w.k.summary("f").await.unwrap().silenced_until, Some(T0 + 2 * HOUR), "silenced for two hours");
    status("forget", &w.send("POST", "/cronwatch/jobs/f/forget", &[AUTH], "").await, 303);
    assert!(w.k.summary("f").await.is_none(), "the job was not forgotten");
}

#[tokio::test]
async fn cross_site_writes_are_refused() {
    let w = Web::new();
    w.ok("x").await;
    let cookie = token_cookie();
    let cookie: (&str, &str) = ("cookie", &cookie);
    for headers in [
        &[("origin", "https://evil.example")][..],
        &[("origin", "null")],
        &[("sec-fetch-site", "cross-site")],
        &[("sec-fetch-site", "same-site")],
        &[("origin", "http://app.test"), ("sec-fetch-site", "cross-site")],
    ] {
        status(
            "form",
            &w.send("POST", "/cronwatch/jobs/x/silence", &with(&[&[cookie, FORM], headers]), "for=1h").await,
            403,
        );
        status("check", &w.send("POST", "/cronwatch/api/check", &with(&[&[AUTH], headers]), "").await, 403);
        status("delete", &w.send("DELETE", "/cronwatch/api/jobs/x", &with(&[&[cookie], headers]), "").await, 403);
    }
    let s = w.k.summary("x").await.expect("the job");
    assert_eq!(s.silenced_until, None, "a cross-site write went through");
    let same = [
        ("origin", "http://app.test"),
        ("sec-fetch-site", "same-origin"),
        ("referer", "http://app.test/cronwatch/jobs/x"),
    ];
    status("run check now", &w.send("POST", "/cronwatch/check", &with(&[&[cookie], &same]), "").await, 303);
    status("api client", &w.send("POST", "/cronwatch/api/jobs/x/unsilence", &[AUTH], "").await, 200);
    status("none", &w.send("POST", "/cronwatch/api/check", &[AUTH, ("sec-fetch-site", "none")], "").await, 200);
    let refused = w.send("POST", "/cronwatch/api/check", &[AUTH, ("origin", "https://evil.example")], "").await;
    assert_eq!(refused.text(), r#"{"ok":false,"error":"Cross-site request refused"}"#);
}

#[tokio::test]
async fn get_check_needs_a_bearer_and_query_tokens_only_sign_in() {
    let w = Web::new();
    w.ok("x").await;
    let cookie = token_cookie();
    let cookie: (&str, &str) = ("cookie", &cookie);
    let via_cookie = w.get("/cronwatch/api/check", &[cookie]).await;
    status("cookie GET", &via_cookie, 405);
    assert_eq!(via_cookie.header_str("allow"), Some("POST"));
    status("cookie POST", &w.send("POST", "/cronwatch/api/check", &[cookie], "").await, 200);
    status("bearer GET", &w.get("/cronwatch/api/check", &[AUTH]).await, 200);
    status("api", &w.get("/cronwatch/api/jobs?token=tok", &[]).await, 401);
    status("api job", &w.get("/cronwatch/api/jobs/x?token=tok", &[]).await, 401);
    status("api check", &w.send("POST", "/cronwatch/api/check?token=tok", &[], "").await, 401);
    status("check", &w.send("POST", "/cronwatch/check?token=tok", &[], "").await, 401);
    status("forget", &w.send("POST", "/cronwatch/jobs/x/forget?token=tok", &[], "").await, 401);
    assert!(w.k.summary("x").await.is_some(), "forgotten by a query token");
    status("page", &w.get("/cronwatch/jobs/x?token=tok", &[]).await, 303);
}

#[tokio::test]
async fn malformed_cookies_and_paths_are_answered() {
    let w = Web::new();
    status("cookie", &w.get("/cronwatch/", &[("cookie", "cronwatch_token=%E0%A4%A")]).await, 401);
    status("cookie %", &w.get("/cronwatch/api/jobs", &[("cookie", "cronwatch_token=%")]).await, 401);
    status("path", &w.get("/cronwatch/jobs/%E0%A4%A", &[AUTH]).await, 400);
    let api = w.get("/cronwatch/api/jobs/%zz", &[AUTH]).await;
    status("api path", &api, 400);
    assert_eq!(json(&api).get("ok").and_then(Value::as_bool), Some(false));
    status("api silence", &w.send("POST", "/cronwatch/api/jobs/%zz/silence", &[AUTH], "").await, 400);
    status("not UTF-8", &w.get("/cronwatch/jobs/%E9", &[AUTH]).await, 400);
}

#[tokio::test]
async fn runs_is_clamped() {
    let w = Web::new();
    for _ in 0..3 {
        w.ok("r").await;
    }
    for (value, want) in
        [("0", 1), ("-5", 1), ("2.7", 2), ("abc", 3), ("", 3), ("1e9", 3), ("Infinity", 3), ("0x2", 2), ("%202%20", 2)]
    {
        let res = json(&w.get(&format!("/cronwatch/api/jobs/r?runs={value}"), &[AUTH]).await);
        assert_eq!(field(&res, &["runs"]).as_array().unwrap().len(), want, "runs={value}");
    }
}

#[tokio::test]
async fn an_unexpected_error_is_a_generic_500() {
    let store = Arc::new(TestStore::default());
    let w = Web::with(RoutesOptions::new().token("tok"), |b| b.store_arc(store.clone()));
    store.breaks(&["list_jobs"]);
    let api = w.get("/cronwatch/api/jobs", &[AUTH]).await;
    status("api", &api, 500);
    assert_eq!(api.text(), r#"{"ok":false,"error":"Internal error"}"#);
    let page = w.get("/cronwatch/", &[AUTH]).await;
    status("page", &page, 500);
    contains("type", page.header_str("content-type").unwrap(), "text/html");
    assert!(!page.text().contains("list_jobs failed"), "the error reached the page");
    assert_eq!(w.k.wheres(), ["routes", "routes"]);
    assert_eq!(w.k.messages(), ["list_jobs failed", "list_jobs failed"]);

    let throwing = Client::builder()
        .store_arc(store.clone())
        .no_cron_secret()
        .on_error(|_, _| panic!("logger down"))
        .build()
        .unwrap();
    let routes = throwing.routes(RoutesOptions::new().token("tok")).unwrap();
    status(
        "a panicking error handler",
        &serve(&routes, "GET", "http://app.test/cronwatch/api/jobs", &[AUTH], "").await,
        500,
    );
}

/// A store that panics listing jobs.
struct PanickingStore(MemoryStore);

macro_rules! delegate {
    () => {
        fn init(&self) -> BoxFuture<'_, Result<(), BoxError>> {
            self.0.init()
        }
        fn upsert_job<'a>(&'a self, d: &'a Definition, now: i64) -> BoxFuture<'a, Result<(), BoxError>> {
            self.0.upsert_job(d, now)
        }
        fn get_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<Option<StoredJob>, BoxError>> {
            self.0.get_job(name)
        }
        fn delete_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<(), BoxError>> {
            self.0.delete_job(name)
        }
        fn insert_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
            self.0.insert_run(run)
        }
        fn update_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>> {
            self.0.update_run(run)
        }
        fn get_run<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
            self.0.get_run(id)
        }
        fn list_runs<'a>(&'a self, job: &'a str, limit: usize) -> BoxFuture<'a, Result<Vec<Run>, BoxError>> {
            self.0.list_runs(job, limit)
        }
        fn last_run<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>> {
            self.0.last_run(job)
        }
        fn running_runs(&self) -> BoxFuture<'_, Result<Vec<Run>, BoxError>> {
            self.0.running_runs()
        }
        fn get_state<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<JobState>, BoxError>> {
            self.0.get_state(job)
        }
        fn set_state<'a>(&'a self, state: &'a JobState) -> BoxFuture<'a, Result<(), BoxError>> {
            self.0.set_state(state)
        }
        fn prune(&self, before: i64) -> BoxFuture<'_, Result<u64, BoxError>> {
            self.0.prune(before)
        }
        fn close(&self) -> BoxFuture<'_, Result<(), BoxError>> {
            self.0.close()
        }
    };
}

impl Store for PanickingStore {
    delegate!();
    fn list_jobs(&self) -> BoxFuture<'_, Result<Vec<StoredJob>, BoxError>> {
        panic!("the store fell over")
    }
}

#[tokio::test]
async fn a_panic_is_a_generic_500_reported_as_routes() {
    let w = Web::with(RoutesOptions::new().token("tok"), |b| b.store(PanickingStore(MemoryStore::new())));
    let api = w.get("/cronwatch/api/jobs", &[AUTH]).await;
    status("api", &api, 500);
    assert_eq!(w.k.wheres(), ["routes"]);
    assert_eq!(w.k.messages(), ["panic: the store fell over"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_body_nested_deeply_is_refused_not_a_stack_overflow() {
    let w = Web::new();
    w.ok("s").await;
    let body = format!("{}{}", "[".repeat(100_000), "]".repeat(100_000));
    // On a worker thread, whose stack is tokio's 2 MiB.
    let routes = w.routes.clone();
    let res = tokio::spawn(async move {
        serve(&routes, "POST", "http://app.test/cronwatch/api/jobs/s/silence", &[AUTH, JSON], &body).await
    })
    .await
    .expect("answered, not aborted");
    status("deep", &res, 200);
}

#[tokio::test]
async fn silence_durations() {
    let w = Web::new();
    w.ok("s").await;
    async fn silence(w: &Web, body: &str) -> Response {
        w.send("POST", "/cronwatch/api/jobs/s/silence", &[AUTH, JSON], body).await
    }
    for bad in [r#""forever""#, r#""2 hours""#, r#""""#, r#""-5""#, r#""1h then some""#, "true"] {
        let res = silence(&w, &format!(r#"{{"for":{bad}}}"#)).await;
        status(bad, &res, 400);
        contains(bad, field(&json(&res), &["error"]).as_str().unwrap(), "silence duration");
    }
    assert_eq!(w.k.summary("s").await.unwrap().silenced_until, None, "a bad duration silenced the job");
    async fn until(w: &Web, body: &str) -> i64 {
        field(&json(&silence(w, body).await), &["state", "silencedUntil"]).as_f64().unwrap() as i64 - T0
    }
    assert_eq!(until(&w, r#"{"for":7200000}"#).await, 7_200_000, "a number");
    assert_eq!(until(&w, r#"{"for":"60000"}"#).await, 60_000, "a numeric string");
    assert_eq!(until(&w, r#"{"for":"90m"}"#).await, 90 * MIN, "text");
    assert_eq!(until(&w, "{}").await, HOUR, "absent");
    assert_eq!(until(&w, "\u{feff}{\"for\":\"2h\"}").await, 2 * HOUR, "a byte order mark");
    status("query", &w.send("POST", "/cronwatch/api/jobs/s/silence?for=forever", &[AUTH], "").await, 400);
    let query = json(&w.send("POST", "/cronwatch/api/jobs/s/silence?for=3h", &[AUTH], "").await);
    assert_eq!(
        field(&query, &["state", "silencedUntil"]).as_f64(),
        Some((T0 + 3 * HOUR) as f64),
        "the query when the body has none"
    );
}

/// A memory store whose job list never comes back, as a network store's
/// might while its caller gives up.
struct HangingStore(MemoryStore, AtomicBool);

impl Store for HangingStore {
    delegate!();
    fn list_jobs(&self) -> BoxFuture<'_, Result<Vec<StoredJob>, BoxError>> {
        if self.1.load(Ordering::SeqCst) {
            return Box::pin(std::future::pending());
        }
        self.0.list_jobs()
    }
}

// The Go port's audit: a request that ended before its answer (a platform
// cron that timed out, a browser gone elsewhere) was reported as a
// failure. Here a request ends by its future being dropped, which reports
// nothing and leaves the routes answering the next one.
#[tokio::test]
async fn a_request_that_ended_is_not_reported() {
    let store = Arc::new(HangingStore(MemoryStore::new(), AtomicBool::new(true)));
    let w = Web::with(RoutesOptions::new().token("tok"), |b| b.store_arc(store.clone()));
    let ended = tokio::time::timeout(Duration::from_millis(50), w.get("/cronwatch/api/jobs", &[AUTH])).await;
    assert!(ended.is_err(), "the request was answered");
    assert!(w.k.wheres().is_empty(), "reported: {:?}", w.k.messages());
    store.1.store(false, Ordering::SeqCst);
    status("a request still open", &w.get("/cronwatch/api/jobs", &[AUTH]).await, 200);
    assert!(w.k.wheres().is_empty());
}

// The Go port's audit: a body cut short was read as far as it came, so
// "for=7d" silenced the job for 7 ms. The SDK reads a body it cannot read
// as none.
#[tokio::test]
async fn a_body_cut_short_is_none() {
    let w = Web::new();
    w.ok("s").await;
    let req = request("POST", "http://app.test/cronwatch/api/jobs/s/silence", &[AUTH, FORM], "")
        .with_body(Body::lazy(Some(6), |_| async {
            Err::<Vec<u8>, BoxError>("the client went away after for=7".into())
        }));
    status("silenced", &w.routes.handle(req).await, 200);
    assert_eq!(w.k.summary("s").await.unwrap().silenced_until, Some(T0 + HOUR), "the default hour");

    // Through the tower service, a body whose stream fails part way.
    let body = CutShort(vec![Ok(Bytes::from_static(b"for=7")), Err("connection reset".into())].into_iter());
    let req = http::Request::post("/cronwatch/api/jobs/s/silence")
        .header("host", "app.test")
        .header("authorization", "Bearer tok")
        .header("content-type", "application/x-www-form-urlencoded")
        .body(body)
        .unwrap();
    w.k.advance(1000);
    let res = w.routes.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), 200);
    assert_eq!(w.k.summary("s").await.unwrap().silenced_until, Some(T0 + 1000 + HOUR), "the default hour again");
}

/// A body that sends its first bytes and then fails, as one whose client
/// went away does.
struct CutShort(std::vec::IntoIter<Result<Bytes, BoxError>>);

impl http_body::Body for CutShort {
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        mut self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Result<http_body::Frame<Bytes>, BoxError>>> {
        std::task::Poll::Ready(self.0.next().map(|r| r.map(http_body::Frame::data)))
    }
}

#[tokio::test]
async fn the_silence_form_shows_an_error() {
    let w = Web::new();
    w.ok("s").await;
    let cookie = token_cookie();
    let f = [("cookie", cookie.as_str()), FORM];
    let bad = w.send("POST", "/cronwatch/jobs/s/silence", &f, "for=forever").await;
    status("bad", &bad, 400);
    contains("type", bad.header_str("content-type").unwrap(), "text/html");
    contains("message", &bad.text(), "silence duration &quot;forever&quot;");
    status("ghost", &w.send("POST", "/cronwatch/jobs/ghost/silence", &f, "for=1h").await, 404);
    status("ghost unsilence", &w.send("POST", "/cronwatch/jobs/ghost/unsilence", &f, "").await, 404);
    status("explode", &w.send("POST", "/cronwatch/jobs/s/explode", &f, "").await, 404);
}

#[tokio::test]
async fn a_body_past_the_cap_is_413() {
    let w = Web::new();
    w.ok("s").await;
    let big = format!(r#"{{"for":"2h","pad":"{}"}}"#, "x".repeat(MAX_BODY));
    let api = w.send("POST", "/cronwatch/api/jobs/s/silence", &[AUTH, JSON], &big).await;
    status("api", &api, 413);
    assert_eq!(api.text(), r#"{"ok":false,"error":"Request body too large"}"#);
    let page = w
        .send("POST", "/cronwatch/jobs/s/silence", &[AUTH, FORM], &format!("for=2h&pad={}", "x".repeat(MAX_BODY)))
        .await;
    status("form", &page, 413);
    contains("form body", &page.text(), "The request was too large.");
    // Without a length, by reading one byte past the cap.
    let data = big.clone().into_bytes();
    let req = request("POST", "http://app.test/cronwatch/api/jobs/s/silence", &[AUTH, JSON], "")
        .with_body(Body::lazy(None, move |_| async move { Ok(data) }));
    status("chunked", &w.routes.handle(req).await, 413);
    // Through the tower service, by its Content-Length alone.
    let req = http::Request::post("/cronwatch/api/jobs/s/silence")
        .header("host", "app.test")
        .header("authorization", "Bearer tok")
        .header("content-type", "application/json")
        .body(http_body_util::Full::new(Bytes::from(big.clone())))
        .unwrap();
    assert_eq!(w.routes.clone().oneshot(req).await.unwrap().status(), 413);
    assert_eq!(w.k.summary("s").await.unwrap().silenced_until, None, "a body past the cap silenced the job");
    // Refused before the body is read: no token, no read.
    let read = Arc::new(AtomicUsize::new(0));
    let counted = read.clone();
    let req = request("POST", "http://app.test/cronwatch/api/jobs/s/silence", &[JSON], "").with_body(Body::lazy(
        None,
        move |_| async move {
            counted.fetch_add(1, Ordering::SeqCst);
            Ok(Vec::new())
        },
    ));
    status("no token", &w.routes.handle(req).await, 401);
    assert_eq!(read.load(Ordering::SeqCst), 0, "a body was read without the token");
}

#[tokio::test]
async fn security_headers() {
    let w = Web::new();
    w.ok("h").await;
    for path in ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope"] {
        let res = w.get(path, &[AUTH]).await;
        assert_eq!(
            res.header_str("content-security-policy"),
            Some(
                "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
            )
        );
        assert_eq!(res.header_str("x-frame-options"), Some("DENY"));
        assert_eq!(res.header_str("x-content-type-options"), Some("nosniff"));
        assert_eq!(res.header_str("referrer-policy"), Some("same-origin"));
        assert_eq!(res.header_str("cache-control"), Some("no-store"));
        let text = res.text();
        let scripts: Vec<&str> = text
            .match_indices("<script")
            .map(|(i, _)| &text[i..i + text[i..].find("</script>").unwrap() + 9])
            .collect();
        assert_eq!(scripts, [r#"<script src="/cronwatch/app.js" defer></script>"#], "{path}: one script");
    }
    let api = w.get("/cronwatch/api/jobs", &[AUTH]).await;
    assert_eq!(api.header_str("x-content-type-options"), Some("nosniff"));
    assert_eq!(api.header_str("cache-control"), Some("no-store"));
}

#[tokio::test]
async fn markup_stays_escaped() {
    let w = Web::new();
    let job =
        w.k.cw
            .job("m", JobOptions::new().schedule("0 2 * * *").description("<img src=x>").tags(["<t>"]).expect("<e>"))
            .unwrap();
    let _ = job
        .run(|j| {
            j.log("<o>");
            j.metric("<k>", 1.0).unwrap();
            async { Ok::<_, std::io::Error>(()) }
        })
        .await;
    for path in ["/cronwatch/", "/cronwatch/jobs/m", "/cronwatch/jobs/%3Cx%3E"] {
        let text = w.get(path, &[AUTH]).await.text().into_owned();
        for bad in ["<img", "<t>", "<e>", "<o>", "<k>", "<x>"] {
            assert!(!text.contains(bad), "{path}: {bad} unescaped");
        }
    }
}

#[tokio::test]
async fn origins() {
    let internal = "http://10.0.0.5:8080";
    let cookie = token_cookie();
    let cookie: (&str, &str) = ("cookie", &cookie);
    let app = |options: RoutesOptions| async move {
        let w = Web::with(options.token("tok").base_path("/cronwatch"), |b| b);
        w.ok("x").await;
        w
    };
    let send = |w: &Web,
                method: &'static str,
                path: &'static str,
                headers: Vec<(&'static str, &'static str)>,
                body: &'static str| {
        let routes = w.routes.clone();
        let mut owned: Vec<(String, String)> = headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        owned.push(("cookie".into(), cookie.1.to_string()));
        async move {
            let headers: Vec<(&str, &str)> = owned.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
            serve(&routes, method, &format!("{internal}{path}"), &headers, body).await
        }
    };

    // The request's own origin by default.
    let w = app(RoutesOptions::new()).await;
    status(
        "foreign",
        &send(&w, "POST", "/cronwatch/jobs/x/silence", vec![FORM, ("origin", "https://app.example.com")], "for=1h")
            .await,
        403,
    );
    assert_eq!(w.k.summary("x").await.unwrap().silenced_until, None);
    status(
        "own",
        &send(&w, "POST", "/cronwatch/jobs/x/silence", vec![FORM, ("origin", internal)], "for=1h").await,
        303,
    );
    let set = send(&w, "GET", "/cronwatch/?token=tok", vec![], "").await;
    assert!(!set.header_str("set-cookie").unwrap().contains("Secure"), "Secure over http");

    // The origin option replaces it.
    let w = app(RoutesOptions::new().origin("https://app.example.com/ignored/path")).await;
    status(
        "internal",
        &send(&w, "POST", "/cronwatch/jobs/x/silence", vec![FORM, ("origin", internal)], "for=1h").await,
        403,
    );
    assert_eq!(w.k.summary("x").await.unwrap().silenced_until, None);
    let referer = "https://app.example.com/cronwatch/jobs/x";
    let res = send(
        &w,
        "POST",
        "/cronwatch/jobs/x/silence",
        vec![FORM, ("origin", "https://app.example.com"), ("referer", referer)],
        "for=2h",
    )
    .await;
    status("public", &res, 303);
    assert_eq!(res.header_str("location"), Some(referer));
    assert_eq!(w.k.summary("x").await.unwrap().silenced_until, Some(T0 + 2 * HOUR));
    let sign_in = send(&w, "GET", "/cronwatch/jobs/x?token=tok", vec![], "").await;
    assert_eq!(sign_in.header_str("location"), Some("/cronwatch/jobs/x"));
    assert!(sign_in.header_str("set-cookie").unwrap().ends_with("; Secure"), "not Secure over https");

    // The origin option wins over trust_proxy.
    let w = app(RoutesOptions::new().origin("https://app.example.com").trust_proxy()).await;
    let fwd = [("x-forwarded-proto", "https"), ("x-forwarded-host", "other.example")];
    status(
        "forwarded",
        &send(&w, "POST", "/cronwatch/check", with(&[&fwd, &[("origin", "https://other.example")]]), "").await,
        403,
    );
    status(
        "configured",
        &send(&w, "POST", "/cronwatch/check", with(&[&fwd, &[("origin", "https://app.example.com")]]), "").await,
        303,
    );

    // trust_proxy takes the first forwarded values.
    let w = app(RoutesOptions::new().trust_proxy()).await;
    let fwd = [("x-forwarded-proto", "https, http"), ("x-forwarded-host", "app.example.com, 10.0.0.5:8080")];
    status(
        "internal",
        &send(&w, "POST", "/cronwatch/jobs/x/silence", with(&[&fwd, &[FORM, ("origin", internal)]]), "for=1h").await,
        403,
    );
    status(
        "public",
        &send(
            &w,
            "POST",
            "/cronwatch/jobs/x/silence",
            with(&[&fwd, &[FORM, ("origin", "https://app.example.com")]]),
            "for=1h",
        )
        .await,
        303,
    );
    assert!(
        send(&w, "GET", "/cronwatch/?token=tok", fwd.to_vec(), "")
            .await
            .header_str("set-cookie")
            .unwrap()
            .ends_with("; Secure")
    );
    status(
        "proto only",
        &send(
            &w,
            "POST",
            "/cronwatch/check",
            vec![("x-forwarded-proto", "https"), ("origin", "https://10.0.0.5:8080")],
            "",
        )
        .await,
        303,
    );
    status("neither", &send(&w, "POST", "/cronwatch/check", vec![("origin", internal)], "").await, 303);
    for (headers, origin) in [
        ([("x-forwarded-proto", "javascript"), ("x-forwarded-host", "evil.example")], "javascript://evil.example"),
        ([("x-forwarded-proto", "https"), ("x-forwarded-host", "evil.example/path")], "https://evil.example"),
        ([("x-forwarded-proto", "https"), ("x-forwarded-host", "user@evil.example")], "https://evil.example"),
    ] {
        status(origin, &send(&w, "POST", "/cronwatch/check", with(&[&headers, &[("origin", origin)]]), "").await, 403);
        status(
            origin,
            &send(&w, "POST", "/cronwatch/check", with(&[&headers, &[("origin", internal)]]), "").await,
            303,
        );
    }

    // Without trust_proxy forwarded headers change nothing.
    let w = Web::new();
    w.ok("x").await;
    let spoofed = [("x-forwarded-host", "evil.example"), ("x-forwarded-proto", "https")];
    status(
        "foreign",
        &w.send(
            "POST",
            "/cronwatch/jobs/x/silence",
            &with(&[&[cookie, FORM], &spoofed, &[("origin", "https://evil.example")]]),
            "for=1h",
        )
        .await,
        403,
    );
    let back = w
        .send(
            "POST",
            "/cronwatch/check",
            &with(&[
                &[cookie],
                &spoofed,
                &[("origin", "http://app.test"), ("referer", "https://evil.example/cronwatch/jobs/x")],
            ]),
            "",
        )
        .await;
    assert_eq!(back.header_str("location"), Some("/cronwatch/"));
    assert!(
        !w.get("/cronwatch/?token=tok", &spoofed).await.header_str("set-cookie").unwrap().contains("Secure"),
        "Secure from a spoofed header"
    );
    // TLS makes the request's own origin https.
    let tls = serve(&w.routes, "GET", "https://app.test/cronwatch/?token=tok", &[], "").await;
    assert!(tls.header_str("set-cookie").unwrap().ends_with("; Secure"), "not Secure over TLS");

    // A bad origin is an error from routes.
    let k = Kit::new();
    let err = k.cw.routes(RoutesOptions::new().token("tok").origin("app.example.com")).unwrap_err();
    assert_eq!(
        err.to_string(),
        r#"routes: origin must be an absolute URL such as "https://app.example.com", got "app.example.com""#
    );
    let err = k.cw.routes(RoutesOptions::new().token("tok").origin("ftp://app.example.com")).unwrap_err();
    assert_eq!(err.to_string(), r#"routes: origin must be http or https, got "ftp://app.example.com""#);
    assert!(k.cw.routes(RoutesOptions::new().token("tok").origin("")).is_ok());

    // Origins are read as URL#origin reads them.
    for (given, want) in [
        (" HTTPS://App.Example.COM:443/x ", "https://app.example.com"),
        ("http:\\\\example.com:8080", "http://example.com:8080"),
        ("http://0x7f.1", "http://127.0.0.1"),
        ("http://[0:0::1]:80", "http://[::1]"),
        ("https://bücher.example", "https://xn--bcher-kva.example"),
        ("http://user:pw@example.com", "http://example.com"),
    ] {
        let routes = k.cw.routes(RoutesOptions::new().token("tok").origin(given)).unwrap();
        status(
            given,
            &serve(&routes, "POST", "http://10.0.0.5/cronwatch/api/check", &[AUTH, ("origin", want)], "").await,
            200,
        );
    }
}

// The Go port's second audit: a Host header outside ASCII over 1024 bytes
// is not punycoded (which takes time in its length times its distinct
// characters) or read as a URL; the request is answered all the same.
#[tokio::test]
async fn a_long_host_outside_ascii_is_not_read_as_a_url() {
    let w = Web::new();
    w.ok("x").await;
    let host: String = (0..2000).map(|i| char::from_u32(0x4e00 + i).unwrap()).collect();
    let started = std::time::Instant::now();
    let req = Request::new("POST", "/cronwatch/api/check")
        .with_header("host", host.as_bytes())
        .with_header("authorization", "Bearer tok");
    status("answered", &w.routes.handle(req).await, 200);
    let origin = format!("http://{host}");
    let req = Request::new("POST", "/cronwatch/api/check")
        .with_header("host", host.as_bytes())
        .with_header("authorization", "Bearer tok")
        .with_header("origin", origin.as_bytes());
    status("its own origin", &w.routes.handle(req).await, 200);
    assert!(started.elapsed() < Duration::from_secs(2), "the host took {:?}", started.elapsed());
}

#[tokio::test]
async fn the_app_shell_is_public_and_only_for_reads() {
    for options in [RoutesOptions::new().token("tok"), RoutesOptions::new().no_token()] {
        let k = Kit::new();
        let routes = k.cw.routes(options).unwrap();
        for path in ["/manifest.webmanifest", "/sw.js", "/app.js", "/offline", "/icons/icon.svg", "/icons/icon-192.png"]
        {
            let url = format!("http://app.test/cronwatch{path}");
            status(path, &serve(&routes, "GET", &url, &[], "").await, 200);
            status(path, &serve(&routes, "HEAD", &url, &[], "").await, 200);
        }
        let sw = serve(&routes, "GET", "http://app.test/cronwatch/sw.js", &[], "").await;
        assert_eq!(sw.header_str("service-worker-allowed"), Some("/cronwatch/"));
        let svg = serve(&routes, "GET", "http://app.test/cronwatch/icons/icon.svg", &[], "").await;
        assert_eq!(
            svg.header_str("content-security-policy"),
            Some("default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'")
        );
        assert_eq!(svg.header_str("cache-control"), Some("public, max-age=31536000, immutable"));
    }
    let w = Web::new();
    status("a write to the shell", &w.send("POST", "/cronwatch/sw.js", &[], "").await, 401);
    status("HEAD elsewhere", &w.send("HEAD", "/cronwatch/", &[AUTH], "").await, 404);
    let open = Kit::new().cw.routes(RoutesOptions::new().no_token()).unwrap();
    assert_eq!(open.token(), None);
    status("open", &serve(&open, "GET", "http://app.test/cronwatch/api/jobs", &[], "").await, 200);
}

async fn manifest_id(routes: &Routes, url: &str) -> String {
    let res = serve(routes, "GET", url, &[], "").await;
    if res.status != 200 {
        return res.status.to_string();
    }
    field(&json(&res), &["id"]).as_str().unwrap().to_string()
}

/// A GET through a real server running `app`, answering the status and body.
async fn through(app: axum::Router, path: &str) -> (u16, String) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await });
    let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
    let (mut sender, conn) = hyper::client::conn::http1::handshake(hyper_util::rt::TokioIo::new(stream)).await.unwrap();
    tokio::spawn(conn);
    let req = http::Request::get(path).header("host", "app.test").body(http_body_util::Empty::<Bytes>::new()).unwrap();
    let res = sender.send_request(req).await.unwrap();
    let status = res.status().as_u16();
    let body = res.into_body().collect().await.unwrap().to_bytes();
    server.abort();
    (status, String::from_utf8_lossy(&body).into_owned())
}

async fn id_through(app: axum::Router, path: &str) -> String {
    let (status, body) = through(app, path).await;
    match js::parse(&body) {
        Ok(Value::Object(o)) => o.get("id").and_then(Value::as_str).unwrap_or("").to_string(),
        _ => format!("{status} {body}"),
    }
}

#[tokio::test]
async fn the_base_path() {
    let k = Kit::new();
    k.cw.run("x", None, |_| async { Ok::<_, std::io::Error>(()) }).await.unwrap().unwrap();
    let open = k.cw.routes(RoutesOptions::new().no_token()).unwrap();
    assert_eq!(
        manifest_id(&open, "http://app.test/cronwatch/manifest.webmanifest").await,
        "/cronwatch/",
        "the default"
    );
    let root = k.cw.routes(RoutesOptions::new().no_token().base_path("")).unwrap();
    assert_eq!(manifest_id(&root, "http://app.test/manifest.webmanifest").await, "/", "at the root");
    let deep = k.cw.routes(RoutesOptions::new().no_token().base_path("/a/b/")).unwrap();
    assert_eq!(manifest_id(&deep, "http://app.test/a/b/manifest.webmanifest").await, "/a/b/", "a base with its slash");
    let mounted = Request::new("GET", "/x/y/manifest.webmanifest").with_header("host", "app.test").with_mount("/x/y/");
    assert_eq!(field(&json(&open.handle(mounted).await), &["id"]).as_str(), Some("/x/y/"), "an adapter's mount");
    let configured = Request::new("GET", "/a/b/manifest.webmanifest").with_header("host", "app.test").with_mount("/x");
    assert_eq!(field(&json(&deep.handle(configured).await), &["id"]).as_str(), Some("/a/b/"), "the option wins");

    let nest = |path: &str| axum::Router::new().nest_service(path, open.clone());
    assert_eq!(id_through(nest("/ops/cron"), "/ops/cron/manifest.webmanifest").await, "/ops/cron/", "nested in axum");
    assert_eq!(
        id_through(nest("/t/{tenant}/cw"), "/t/acme/cw/manifest.webmanifest").await,
        "/t/acme/cw/",
        "under a path parameter"
    );
    assert_eq!(
        id_through(axum::Router::new().nest("/admin", nest("/cronwatch")), "/admin/cronwatch/manifest.webmanifest")
            .await,
        "/admin/cronwatch/",
        "nested twice"
    );
    assert_eq!(
        id_through(open.clone().into_router(), "/cronwatch/manifest.webmanifest").await,
        "/cronwatch/",
        "into_router"
    );
    assert_eq!(
        id_through(deep.clone().into_router(), "/a/b/manifest.webmanifest").await,
        "/a/b/",
        "into_router at the configured base"
    );
    assert_eq!(id_through(root.clone().into_router(), "/manifest.webmanifest").await, "/", "into_router at the root");

    // The pages link under the base found, and the job links resolve.
    let (status_code, body) = through(nest("/ops"), "/ops/").await;
    assert_eq!(status_code, 200);
    contains("link", &body, r#"href="/ops/jobs/x""#);
    assert_eq!(through(nest("/ops"), "/ops/jobs/x").await.0, 200, "the job page");
    assert_eq!(through(nest("/ops"), "/ops").await.0, 200, "the mount itself");
}

#[tokio::test]
async fn paths_are_read_as_the_url_parser_leaves_them() {
    let w = Web::new();
    w.ok("x").await;
    for path in [
        "/cronwatch/./jobs/x",
        "/cronwatch/nope/../jobs/x",
        "/cronwatch\\jobs\\x",
        "/cronwatch/%2e/jobs/x",
        "/cronwatch/jobs/%78",
    ] {
        let res = w.get(path, &[AUTH]).await;
        status(path, &res, 200);
        contains(path, &res.text(), r#"<h1 class="jobname">x</h1>"#);
    }
    status("a slash inside a name", &w.get("/cronwatch/api/jobs/a%2Fb", &[AUTH]).await, 404);
}

// The Go port's audit: an interval past what an i64 of milliseconds holds
// wrapped round, and drawing the board's timeline never ended; a silence
// for longer than that ended at once.
#[tokio::test]
async fn huge_durations_neither_hang_nor_wrap() {
    let w = Web::new();
    let job = w.k.cw.job("rare", JobOptions::new().schedule("every 20000000000w")).unwrap();
    job.run(|_| async { Ok::<_, std::io::Error>(()) }).await.unwrap();
    w.k.advance(10 * 24 * HOUR);
    let codes = tokio::time::timeout(Duration::from_secs(10), async {
        w.k.cw.check().await.unwrap();
        let mut codes = Vec::new();
        for path in ["/cronwatch/", "/cronwatch/jobs/rare", "/cronwatch/api/jobs/rare"] {
            codes.push(w.get(path, &[AUTH]).await.status);
        }
        codes
    })
    .await
    .expect("the dashboard never answered");
    assert_eq!(codes, [200, 200, 200]);
    let silenced = json(
        &w.send("POST", "/cronwatch/api/jobs/rare/silence", &[AUTH, JSON], r#"{"for":"99999999999999999999999"}"#)
            .await,
    );
    let until = field(&silenced, &["state", "silencedUntil"]).as_f64().unwrap();
    assert!(until > w.k.now() as f64, "a long silence ended at once: {until}");
}
