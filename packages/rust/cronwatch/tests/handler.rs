//! `Job::handler`: the SDK's handler tests (client.test.ts and
//! client-hardening.test.ts), as the Go port has them, and the Rust
//! answers: a `web::Response` or an `http::Response` the function returns,
//! `run` and `run_http` failing a run for an answer of 400 or more, and a
//! real server in front. Without a secret, and in development, it is tested
//! in `env.rs`.

mod common;

use bytes::Bytes;
use common::{Kit, T0};
use cronwatch::js::{self, Object, Value};
use cronwatch::web::{Request, Response};
use cronwatch::{HandlerOptions, JobOptions, RunStatus};
use http_body_util::{BodyExt, Full};
use tower::ServiceExt;

fn json(res: &Response) -> Object {
    match js::parse(&res.text()) {
        Ok(Value::Object(o)) => o,
        other => panic!("not a JSON object: {other:?}: {}", res.text()),
    }
}

fn secret() -> String {
    format!("s3{}", "cret")
}

#[tokio::test]
async fn the_handler_checks_the_bearer_and_reports_the_run() {
    let secret = secret();
    let k = Kit::with(|b| b.cron_secret(secret.clone()));
    let job = k.cw.job("hourly", JobOptions::new().schedule("@hourly")).unwrap();
    let h = job.handler(
        |j, req| async move {
            j.log(req.target());
            if req.header("x-fail").is_some() {
                return Err(std::io::Error::other("nope\nsecond line"));
            }
            Ok(())
        },
        HandlerOptions::new(),
    );
    let get = |auth: Option<String>, fail: bool| {
        let mut req = Request::new("GET", "/api/cron/hourly");
        if let Some(auth) = auth {
            req = req.with_header("authorization", auth);
        }
        if fail {
            req = req.with_header("x-fail", "1");
        }
        h.handle(req)
    };
    assert_eq!(get(None, false).await.status, 401, "no auth");
    let wrong = get(Some("Bearer wrong".into()), false).await;
    assert_eq!(wrong.text(), r#"{"ok":false,"error":"Unauthorized"}"#);
    assert_eq!(get(Some(format!("bearer {secret}")), false).await.status, 401, "a lowercase bearer");
    let res = get(Some(format!("Bearer {secret}")), false).await;
    assert_eq!(res.status, 200);
    assert_eq!(res.header_str("content-type"), Some("application/json; charset=utf-8"));
    assert_eq!(res.header_str("cache-control"), Some("no-store"));
    let runs = k.runs("hourly").await;
    assert_eq!(
        res.text(),
        format!(r#"{{"ok":true,"job":"hourly","run":"{}","status":"ok","durationMs":0}}"#, runs[0].id)
    );
    k.advance(1000);
    let failed = get(Some(format!("Bearer {secret}")), true).await;
    assert_eq!(failed.status, 500);
    assert_eq!(json(&failed).get("error").and_then(Value::as_str), Some("Error: nope"), "the error's first line");
    let runs = k.runs("hourly").await;
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[1].output.as_deref(), Some("/api/cron/hourly"));
    assert_eq!(runs[0].trigger, "handler");
    assert_eq!(runs[0].error.as_deref(), Some("Error: nope\nsecond line"));
}

#[tokio::test]
async fn a_secret_of_its_own_replaces_the_clients() {
    let client_secret = format!("client-{}", "secret");
    let own = format!("own-{}", "secret");
    let k = Kit::with(|b| b.cron_secret(client_secret.clone()));
    let job = k.cw.job("own", JobOptions::new()).unwrap();
    let ok = |_: cronwatch::JobContext, _: Request| async { Ok::<_, std::io::Error>(()) };
    let h = job.handler(ok, HandlerOptions::new().secret(own.clone()));
    async fn post(h: &cronwatch::Handler, secret: &str) -> Response {
        h.handle(Request::new("POST", "/").with_header("authorization", format!("Bearer {secret}"))).await
    }
    assert_eq!(post(&h, &client_secret).await.status, 401, "the client's");
    assert_eq!(post(&h, &own).await.status, 200, "its own");
    let empty = job.handler(ok, HandlerOptions::new().secret(""));
    assert_eq!(post(&empty, &client_secret).await.status, 200, "an empty one is the client's");
    let open = job.handler(ok, HandlerOptions::new().no_secret());
    assert_eq!(open.handle(Request::new("POST", "/")).await.status, 200, "no_secret lets anyone in");
}

#[tokio::test]
async fn a_response_is_the_answer_and_fails_the_run_at_400() {
    let k = Kit::new();
    let job = k.cw.job("h", JobOptions::new()).unwrap();
    let returned = job.handler(
        |_, _| async { Ok::<_, std::io::Error>(Response::new(503).with_header("x-upstream", "1").with_body("bad")) },
        HandlerOptions::new(),
    );
    let res = returned.handle(Request::new("GET", "/")).await;
    assert_eq!(res.status, 503, "passed through");
    assert_eq!(res.text(), "bad");
    assert_eq!(res.header_str("x-upstream"), Some("1"));
    assert_eq!(k.runs("h").await[0].error.as_deref(), Some("HTTP 503 Service Unavailable"));
    assert_eq!(k.types(), ["failed"]);

    // An http::Response, with the tower feature.
    let http = job.handler(
        |_, _| async {
            Ok::<_, std::io::Error>(http::Response::builder().status(404).body("not here".to_string()).unwrap())
        },
        HandlerOptions::new(),
    );
    k.advance(1000);
    let res = http.handle(Request::new("GET", "/")).await;
    assert_eq!(res.status, 404);
    assert_eq!(res.text(), "not here");
    assert_eq!(k.runs("h").await[0].error.as_deref(), Some("HTTP 404 Not Found"));

    let fine = job.handler(
        |_, _| async {
            Ok::<_, std::io::Error>(
                http::Response::builder()
                    .status(202)
                    .header("content-type", "text/plain")
                    .body(Full::new(Bytes::from_static(b"queued")))
                    .unwrap(),
            )
        },
        HandlerOptions::new(),
    );
    k.advance(1000);
    let res = fine.handle(Request::new("GET", "/")).await;
    assert_eq!(res.status, 202);
    assert_eq!(res.text(), "queued");
    assert_eq!(res.header_str("content-type"), Some("text/plain"));
    assert_eq!(k.runs("h").await[0].status, RunStatus::Ok, "an ok run");

    let text =
        job.handler(|_, _| async { Ok::<_, std::io::Error>("Report written".to_string()) }, HandlerOptions::new());
    k.advance(1000);
    let res = text.handle(Request::new("GET", "/")).await;
    assert_eq!(res.status, 200, "a string");
    assert_eq!(k.runs("h").await[0].output.as_deref(), Some("Report written"), "its output");
}

// A function returns either a response or an error, never both, so the Go
// port's audit (a response returned with an error was the answer) cannot
// happen here: an error is always the run's JSON answer.
#[tokio::test]
async fn an_error_is_answered_with_the_run() {
    let k = Kit::new();
    let job = k.cw.job("h", JobOptions::new()).unwrap();
    let failing = job.handler(
        |_, _| async { Err::<Response, _>(std::io::Error::other("the report was empty")) },
        HandlerOptions::new(),
    );
    let res = failing.handle(Request::new("GET", "/")).await;
    assert_eq!(res.status, 500, "the run's answer");
    assert_eq!(json(&res).get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(k.runs("h").await[0].error.as_deref(), Some("Error: the report was empty"));
}

#[tokio::test]
async fn a_panic_is_a_failed_run_answered_500() {
    let secret = secret();
    let k = Kit::with(|b| b.cron_secret(secret.clone()));
    let h = k.cw.job("p", JobOptions::new()).unwrap().handler(
        |_, _| async {
            if T0 > 0 {
                panic!("boom");
            }
            Ok::<_, std::io::Error>(())
        },
        HandlerOptions::new(),
    );
    let res = h.handle(Request::new("GET", "/").with_header("authorization", format!("Bearer {secret}"))).await;
    assert_eq!(res.status, 500, "answered");
    assert_eq!(res.header_str("content-type"), Some("application/json; charset=utf-8"));
    let runs = k.runs("p").await;
    assert_eq!(runs[0].status, RunStatus::Failed);
    assert_eq!(runs[0].error.as_deref(), Some("panic: boom"));
    assert_eq!(
        res.text(),
        format!(
            r#"{{"ok":false,"job":"p","run":"{}","status":"failed","durationMs":0,"error":"panic: boom"}}"#,
            runs[0].id
        )
    );
    assert_eq!(k.types(), ["failed"]);

    // A caller without the secret gets no error text, as for any failure.
    let open = k.cw.job("q", JobOptions::new()).unwrap().handler(
        |_, _| async {
            if T0 > 0 {
                panic!("private detail");
            }
            Ok::<_, std::io::Error>(())
        },
        HandlerOptions::new().no_secret(),
    );
    let res = open.handle(Request::new("GET", "/")).await;
    assert_eq!(res.status, 500);
    assert!(json(&res).get("error").is_none(), "the panic went to a caller who sent no secret");
}

#[tokio::test]
async fn run_fails_for_an_http_answer_of_400_or_more() {
    let k = Kit::new();
    let job = k.cw.job("fetch", JobOptions::new()).unwrap();
    let res = job.run(|_| async { Ok::<_, std::io::Error>(Response::new(502)) }).await.unwrap();
    assert_eq!(res.status, 502, "handed back");
    assert_eq!(k.runs("fetch").await[0].error.as_deref(), Some("HTTP 502 Bad Gateway"));
    k.advance(1000);
    let res = job
        .run_http(|_| async {
            Ok::<_, std::io::Error>(http::Response::builder().status(429).body(Full::new(Bytes::new())).unwrap())
        })
        .await
        .unwrap();
    assert_eq!(res.status(), 429);
    assert_eq!(k.runs("fetch").await[0].error.as_deref(), Some("HTTP 429 Too Many Requests"));
    k.advance(1000);
    job.run_http(|_| async { Ok::<_, std::io::Error>(http::Response::new(())) }).await.unwrap();
    assert_eq!(k.runs("fetch").await[0].status, RunStatus::Ok);
    k.advance(1000);
    let unknown = job.run(|_| async { Ok::<_, std::io::Error>(Response::new(599)) }).await.unwrap();
    assert_eq!(unknown.status, 599);
    assert_eq!(k.runs("fetch").await[0].error.as_deref(), Some("HTTP 599"), "a status HTTP names no reason for");
}

#[tokio::test]
async fn the_handler_as_a_tower_service_and_behind_a_real_server() {
    let secret = secret();
    let k = Kit::with(|b| b.cron_secret(secret.clone()));
    let job = k.cw.job("served", JobOptions::new()).unwrap();
    let h = job.handler(
        |j, mut req| async move {
            let current = cronwatch::current().expect("the job's context");
            assert_eq!(current.run_id(), j.run_id(), "current() is the run's context");
            let body = req.take_body().read(1024).await.unwrap_or_default();
            j.log(format!("{} {} {}", req.method(), req.target(), String::from_utf8_lossy(&body)));
            Ok::<_, std::io::Error>(())
        },
        HandlerOptions::new(),
    );
    let req = http::Request::post("/api/cron/served?x=1")
        .header("authorization", format!("Bearer {secret}"))
        .body(Full::new(Bytes::from_static(b"payload")))
        .unwrap();
    let res = h.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), 200);
    assert_eq!(k.runs("served").await[0].output.as_deref(), Some("POST /api/cron/served?x=1 payload"));

    let app = axum::Router::new().route_service("/api/cron/served", h);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await });
    let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
    let (mut sender, conn) = hyper::client::conn::http1::handshake(hyper_util::rt::TokioIo::new(stream)).await.unwrap();
    tokio::spawn(conn);
    k.advance(1000);
    let req = http::Request::post("/api/cron/served")
        .header("host", "app.test")
        .header("authorization", format!("Bearer {secret}"))
        .body(Full::new(Bytes::from_static(b"over the wire")))
        .unwrap();
    let res = sender.send_request(req).await.unwrap();
    assert_eq!(res.status(), 200);
    let body = res.into_body().collect().await.unwrap().to_bytes();
    let body = String::from_utf8_lossy(&body);
    assert!(body.starts_with(r#"{"ok":true,"job":"served","run":""#), "{body}");
    assert_eq!(k.runs("served").await[0].output.as_deref(), Some("POST /api/cron/served over the wire"));
    server.abort();
}
