//! AWS Lambda through `lambda_http`, with no code of the crate's own: a
//! job's handler and the dashboard are tower services, so
//! `lambda_http::run(handler)` and `lambda_http::run(routes)` serve them.
//! The function runs in a child process of this test binary (the runtime
//! reads its configuration from the environment) against a fake Lambda
//! runtime API this test serves, which hands it an API Gateway HTTP API
//! event and receives its answer, as Lambda would.

mod common;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::{Path, State};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use cronwatch::js::{self, Object, Value};
use cronwatch::web::RoutesOptions;
use cronwatch::{Client, HandlerOptions, JobOptions};
use tokio::sync::Notify;

const SECRET: &str = "lambda-test-secret";

#[derive(Default)]
struct Runtime {
    events: Mutex<VecDeque<String>>,
    answers: Mutex<Vec<String>>,
    answered: Notify,
}

async fn next(State(rt): State<Arc<Runtime>>) -> axum::response::Response {
    let event = rt.events.lock().unwrap().pop_front();
    let Some(event) = event else {
        // Nothing more to run: the function waits, as it would on Lambda.
        std::future::pending::<()>().await;
        unreachable!();
    };
    (
        [
            ("lambda-runtime-aws-request-id", "req-1"),
            ("lambda-runtime-deadline-ms", "4102444800000"),
            ("lambda-runtime-invoked-function-arn", "arn:aws:lambda:us-east-1:123456789012:function:cronwatch-test"),
            ("content-type", "application/json"),
        ],
        event,
    )
        .into_response()
}

async fn answer(State(rt): State<Arc<Runtime>>, Path(_id): Path<String>, body: String) -> &'static str {
    rt.answers.lock().unwrap().push(body);
    rt.answered.notify_one();
    "{}"
}

async fn failed(State(rt): State<Arc<Runtime>>, Path(_id): Path<String>, body: String) -> &'static str {
    rt.answers.lock().unwrap().push(format!("error: {body}"));
    rt.answered.notify_one();
    "{}"
}

/// An API Gateway HTTP API (payload 2.0) event.
fn event(method: &str, path: &str, query: &str, authorization: &str) -> String {
    let host = "abc123.execute-api.us-east-1.amazonaws.com";
    format!(
        r#"{{"version":"2.0","routeKey":"$default","rawPath":"{path}","rawQueryString":"{query}","headers":{{"host":"{host}","authorization":"{authorization}","x-forwarded-proto":"https","user-agent":"curl/8"}},"requestContext":{{"accountId":"123456789012","apiId":"abc123","domainName":"{host}","domainPrefix":"abc123","http":{{"method":"{method}","path":"{path}","protocol":"HTTP/1.1","sourceIp":"203.0.113.1","userAgent":"curl/8"}},"requestId":"r1","routeKey":"$default","stage":"$default","time":"05/Jan/2026:09:30:00 +0000","timeEpoch":1767605400000}},"isBase64Encoded":false}}"#
    )
}

/// Serves `event` to a function running `service` in a child process, and
/// answers what the function sent back.
async fn invoke(service: &str, event: String) -> Object {
    let rt = Arc::new(Runtime::default());
    rt.events.lock().unwrap().push_back(event);
    let app = axum::Router::new()
        .route("/2018-06-01/runtime/invocation/next", get(next))
        .route("/2018-06-01/runtime/invocation/{id}/response", post(answer))
        .route("/2018-06-01/runtime/invocation/{id}/error", post(failed))
        .with_state(rt.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await });

    let mut child = tokio::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "child_lambda", "--include-ignored", "--nocapture", "--test-threads=1"])
        .env("CRONWATCH_CHILD", service)
        .env("AWS_LAMBDA_RUNTIME_API", addr.to_string())
        .env("AWS_LAMBDA_FUNCTION_NAME", "cronwatch-test")
        .env("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "128")
        .env("AWS_LAMBDA_FUNCTION_VERSION", "1")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let answered = tokio::time::timeout(Duration::from_secs(60), rt.answered.notified()).await;
    let _ = child.kill().await;
    server.abort();
    answered.expect("the function never answered");
    let text = rt.answers.lock().unwrap()[0].clone();
    match js::parse(&text) {
        Ok(Value::Object(o)) => o,
        _ => panic!("the function's answer: {text}"),
    }
}

fn get_str<'a>(o: &'a Object, key: &str) -> &'a str {
    o.get(key).and_then(Value::as_str).unwrap_or_else(|| panic!("no {key} in {}", o.to_json()))
}

fn body_of(answer: &Object) -> Object {
    match js::parse(get_str(answer, "body")) {
        Ok(Value::Object(o)) => o,
        _ => panic!("the body: {}", answer.to_json()),
    }
}

#[tokio::test]
async fn a_job_handler_runs_on_lambda_through_lambda_http() {
    let answer = invoke("handler", event("POST", "/api/cron/nightly", "", &format!("Bearer {SECRET}"))).await;
    assert_eq!(answer.get("statusCode").and_then(Value::as_f64), Some(200.0), "{}", answer.to_json());
    let headers = answer.get("headers").and_then(Value::as_object).unwrap();
    assert_eq!(get_str(headers, "content-type"), "application/json; charset=utf-8");
    let body = body_of(&answer);
    assert_eq!(body.get("ok").and_then(Value::as_bool), Some(true), "{}", body.to_json());
    assert_eq!(get_str(&body, "job"), "nightly");
    assert_eq!(get_str(&body, "status"), "ok");

    let refused = invoke("handler", event("POST", "/api/cron/nightly", "", "Bearer wrong")).await;
    assert_eq!(refused.get("statusCode").and_then(Value::as_f64), Some(401.0));
    assert_eq!(get_str(&refused, "body"), r#"{"ok":false,"error":"Unauthorized"}"#);
}

#[tokio::test]
async fn the_dashboard_answers_on_lambda_through_lambda_http() {
    let answer = invoke("routes", event("GET", "/cronwatch/api/jobs", "runs=5", "Bearer tok")).await;
    assert_eq!(answer.get("statusCode").and_then(Value::as_f64), Some(200.0), "{}", answer.to_json());
    let body = body_of(&answer);
    let jobs = body.get("jobs").and_then(Value::as_array).unwrap();
    assert_eq!(jobs.len(), 1);
    assert_eq!(get_str(jobs[0].as_object().unwrap(), "name"), "nightly");

    let page = invoke("routes", event("GET", "/cronwatch/", "", "Bearer tok")).await;
    assert_eq!(page.get("statusCode").and_then(Value::as_f64), Some(200.0));
    assert!(get_str(&page, "body").contains(r#"<h2>Jobs</h2>"#));
}

/// The function: a job's handler or the dashboard, served by
/// `lambda_http::run` and nothing else.
#[tokio::test]
#[ignore = "run by the Lambda tests, as the function, in an environment of its own"]
async fn child_lambda() {
    let Ok(service) = std::env::var("CRONWATCH_CHILD") else {
        return;
    };
    let cw = Client::builder().cron_secret(SECRET).build().unwrap();
    let nightly = cw.job("nightly", JobOptions::new().schedule("0 2 * * *")).unwrap();
    match service.as_str() {
        "handler" => {
            let handler = nightly.handler(
                |job, request| async move {
                    job.log(format!("{} {}", request.method(), request.target()));
                    Ok::<_, std::io::Error>(())
                },
                HandlerOptions::new(),
            );
            lambda_http::run(handler).await.unwrap();
        }
        _ => {
            nightly.run(|_| async { Ok::<_, std::io::Error>(()) }).await.unwrap();
            lambda_http::run(cw.routes(RoutesOptions::new().token("tok")).unwrap()).await.unwrap();
        }
    }
}
