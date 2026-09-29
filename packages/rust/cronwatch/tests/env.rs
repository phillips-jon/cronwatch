//! What depends on the environment: the dashboard locked without a token
//! outside development, the development token and its sign-in line, and a
//! job handler with no secret. Each case runs in a child process of this
//! test binary with the variables it needs (the environment is the
//! process's, and Rust 2024 makes changing it in a running process unsafe),
//! and the parent reads what the child printed, as the sign-in line goes to
//! standard output.

mod common;

use std::process::Command;

use cronwatch::web::{Request, Response, Routes, RoutesOptions};
use cronwatch::{Client, HandlerOptions, JobOptions};

/// Runs the ignored test `name` in a child process with only these of
/// CronWatch's variables set, and answers what it printed.
fn child(name: &str, vars: &[(&str, &str)]) -> String {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command.args(["--exact", name, "--include-ignored", "--nocapture", "--test-threads=1"]);
    for var in ["CRONWATCH_ENV", "APP_ENV", "RUST_ENV", "CRONWATCH_TOKEN", "CRON_SECRET"] {
        command.env_remove(var);
    }
    command.envs(vars.iter().copied()).env("CRONWATCH_CHILD", "1");
    let out = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(out.status.success(), "{name} failed:\n{stdout}\n{}", String::from_utf8_lossy(&out.stderr));
    assert!(stdout.contains("test result: ok. 1 passed"), "{name} did not run:\n{stdout}");
    stdout
}

/// Whether this is the child a parent started, rather than a plain run of
/// the ignored tests.
fn in_child() -> bool {
    std::env::var("CRONWATCH_CHILD").is_ok()
}

/// The lines the routes printed (the first follows the harness's
/// `test name ... ` on its line).
fn announced(stdout: &str) -> Vec<&str> {
    stdout.lines().filter_map(|l| l.find("[cronwatch]").map(|i| &l[i..])).collect()
}

async fn serve(routes: &Routes, method: &str, url: &str, headers: &[(&str, &str)]) -> Response {
    let tls = url.starts_with("https://");
    let rest = url.trim_start_matches("http://").trim_start_matches("https://");
    let (host, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let mut req =
        Request::new(method, if path.is_empty() { "/" } else { path }).with_header("host", host).with_tls(tls);
    for (k, v) in headers {
        req = req.with_header(*k, v);
    }
    routes.handle(req).await
}

fn client() -> Client {
    Client::builder().no_cron_secret().build().unwrap()
}

#[test]
fn routes_are_locked_without_a_token_outside_development() {
    for env in ["", "production", "staging", "prod"] {
        child("child_locked", &[("CRONWATCH_ENV", env)]);
    }
}

#[tokio::test]
#[ignore = "run by routes_are_locked_without_a_token_outside_development, in an environment of its own"]
async fn child_locked() {
    if !in_child() {
        return;
    }
    let routes = client().routes(RoutesOptions::new()).unwrap();
    assert_eq!(routes.token(), None);
    let api = serve(&routes, "GET", "http://localhost/cronwatch/api/jobs", &[]).await;
    assert_eq!(api.status, 503);
    assert_eq!(api.text(), r#"{"ok":false,"error":"CRONWATCH_TOKEN is not set"}"#);
    let page = serve(&routes, "GET", "http://localhost/cronwatch", &[]).await;
    assert_eq!(page.status, 503);
    assert!(page.text().contains("CronWatch routes are locked"));
    assert!(page.text().contains("RoutesOptions::no_token()"));
    // The app shell is public even so.
    for path in ["/manifest.webmanifest", "/sw.js", "/app.js", "/offline", "/icons/icon.svg"] {
        assert_eq!(
            serve(&routes, "GET", &format!("http://localhost/cronwatch{path}"), &[]).await.status,
            200,
            "{path}"
        );
    }
}

#[test]
fn a_development_token_is_printed_once_and_required() {
    for var in ["CRONWATCH_ENV", "APP_ENV", "RUST_ENV"] {
        let out = child("child_development_token", &[(var, "test")]);
        let lines = announced(&out);
        assert_eq!(lines.len(), 2, "{var}: {out}");
        let intro = "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: ";
        let first = lines[0].strip_prefix(intro).unwrap_or_else(|| panic!("the sign-in line: {}", lines[0]));
        let token = first.strip_prefix("http://localhost:3000/cronwatch/?token=").expect("a loopback link");
        assert_eq!(token.len(), 43, "base64url of 32 bytes: {token}");
        assert!(token.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_'));
        assert!(out.contains(&format!("\nTOKEN {token}\n")), "Routes::token is the one printed");
        let second = lines[1].strip_prefix(intro).unwrap();
        assert!(second.starts_with("/?token="), "a root mount's line: {second}");
        assert!(
            second.ends_with(" on this server (the first request's host is not local, so the link leaves it out)"),
            "{second}"
        );
        assert!(!second.contains(token), "each routes value makes its own token");
    }
}

#[tokio::test]
#[ignore = "run by a_development_token_is_printed_once_and_required, in an environment of its own"]
async fn child_development_token() {
    if !in_child() {
        return;
    }
    let cw = client();
    let routes = cw.routes(RoutesOptions::new().base_path("/cronwatch/")).unwrap();
    for (url, headers) in [
        ("http://localhost:3000/cronwatch/api/jobs", &[][..]),
        ("http://localhost:3000/cronwatch/api/jobs", &[("x-forwarded-for", "127.0.0.1")]),
        ("http://127.0.0.1:3000/cronwatch/", &[]),
        ("http://192.168.1.20:3000/cronwatch/api/jobs", &[]),
        ("http://[::1]:3000/cronwatch/api/jobs", &[("x-real-ip", "127.0.0.1")]),
    ] {
        assert_eq!(serve(&routes, "GET", url, headers).await.status, 401, "{url}");
    }
    let token = routes.token().expect("a token").to_string();
    println!("TOKEN {token}");
    let page = serve(&routes, "GET", "http://localhost:3000/cronwatch/", &[]).await;
    assert!(page.text().contains("sign-in link is in the server log"));
    let api = serve(&routes, "GET", "http://localhost:3000/cronwatch/api/jobs", &[]).await;
    assert!(api.text().contains("in the server log"));
    let sign_in = serve(&routes, "GET", &format!("http://localhost:3000/cronwatch/?token={token}"), &[]).await;
    assert_eq!(sign_in.status, 303);
    assert_eq!(sign_in.header_str("location"), Some("/cronwatch/"));
    let cookie = sign_in.header_str("set-cookie").unwrap().split(';').next().unwrap().to_string();
    assert_eq!(serve(&routes, "GET", "http://localhost:3000/cronwatch/", &[("cookie", &cookie)]).await.status, 200);
    let bearer = format!("Bearer {token}");
    assert_eq!(
        serve(&routes, "GET", "http://localhost:3000/cronwatch/api/jobs", &[("authorization", &bearer)]).await.status,
        200
    );

    let other = cw.routes(RoutesOptions::new().base_path("/")).unwrap();
    serve(&other, "GET", "https://dev.example:8443/api/jobs", &[]).await;
}

#[test]
fn an_empty_token_is_unset_and_no_token_opens() {
    child("child_empty_token", &[("CRONWATCH_ENV", "production")]);
    let out = child("child_open_in_development", &[("CRONWATCH_ENV", "development")]);
    assert!(announced(&out).is_empty(), "no token made: {out}");
    let out =
        child("child_configured_in_development", &[("CRONWATCH_ENV", "development"), ("CRONWATCH_TOKEN", "envtok")]);
    assert!(announced(&out).is_empty(), "nothing printed: {out}");
}

#[tokio::test]
#[ignore = "run by an_empty_token_is_unset_and_no_token_opens, in an environment of its own"]
async fn child_empty_token() {
    if !in_child() {
        return;
    }
    let cw = client();
    let jobs = |options: RoutesOptions| {
        let routes = cw.routes(options).unwrap();
        async move { serve(&routes, "GET", "http://app.test/cronwatch/api/jobs", &[]).await.status }
    };
    assert_eq!(jobs(RoutesOptions::new()).await, 503, "unset");
    assert_eq!(jobs(RoutesOptions::new().token("")).await, 503, "empty");
    assert_eq!(jobs(RoutesOptions::new().no_token()).await, 200, "open");
}

#[tokio::test]
#[ignore = "run by an_empty_token_is_unset_and_no_token_opens, in an environment of its own"]
async fn child_open_in_development() {
    if !in_child() {
        return;
    }
    let routes = client().routes(RoutesOptions::new().no_token()).unwrap();
    assert_eq!(serve(&routes, "GET", "http://app.test/cronwatch/api/jobs", &[]).await.status, 200);
}

#[tokio::test]
#[ignore = "run by an_empty_token_is_unset_and_no_token_opens, in an environment of its own"]
async fn child_configured_in_development() {
    if !in_child() {
        return;
    }
    let cw = client();
    let routes = cw.routes(RoutesOptions::new()).unwrap();
    assert_eq!(serve(&routes, "GET", "http://app.test/cronwatch/api/jobs", &[]).await.status, 401);
    let routes = cw.routes(RoutesOptions::new().token("")).unwrap();
    let res = serve(&routes, "GET", "http://app.test/cronwatch/api/jobs", &[("authorization", "Bearer envtok")]).await;
    assert_eq!(res.status, 200, "the environment's token");
}

#[test]
fn the_sign_in_line_shows_the_host_only_when_configured_or_loopback() {
    let out = child("child_sign_in_lines", &[("CRONWATCH_ENV", "development")]);
    let intro =
        "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: ";
    let hostless = " on this server (the first request's host is not local, so the link leaves it out)";
    let expected = [
        ("https://app.example.com/cronwatch", ""),
        ("https://app.example.com/cronwatch", ""),
        ("http://localhost:3000/cronwatch", ""),
        ("http://app.localhost:3000/cronwatch", ""),
        ("http://127.0.0.1:3000/cronwatch", ""),
        ("http://127.8.9.10/cronwatch", ""),
        ("http://[::1]:3000/cronwatch", ""),
        ("http://localhost:5173/cronwatch", ""),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
        ("", hostless),
        ("/cronwatch", hostless),
        ("/cronwatch", hostless),
    ];
    let lines = announced(&out);
    assert_eq!(lines.len(), expected.len(), "{out}");
    for (line, (link, tail)) in lines.iter().zip(expected) {
        let token = line.split("token=").nth(1).unwrap().split(' ').next().unwrap();
        assert_eq!(token.len(), 43, "{line}");
        assert_eq!(*line, format!("{intro}{link}/?token={token}{tail}"));
    }
}

#[tokio::test]
#[ignore = "run by the_sign_in_line_shows_the_host_only_when_configured_or_loopback, in an environment of its own"]
async fn child_sign_in_lines() {
    if !in_child() {
        return;
    }
    let internal = "http://10.0.0.5:8080";
    let cw = client();
    let spoofed = [("x-forwarded-proto", "https"), ("x-forwarded-host", "attacker.example")];
    type Headers<'a> = &'a [(&'a str, &'a str)];
    let cases: Vec<(RoutesOptions, String, Headers)> = vec![
        (RoutesOptions::new().origin("https://app.example.com"), format!("{internal}/cronwatch/"), &[]),
        (
            RoutesOptions::new().origin("https://app.example.com").trust_proxy(),
            format!("{internal}/cronwatch/"),
            &spoofed,
        ),
        (RoutesOptions::new(), "http://localhost:3000/cronwatch/".into(), &[]),
        (RoutesOptions::new(), "http://app.localhost:3000/cronwatch/".into(), &[]),
        (RoutesOptions::new(), "http://127.0.0.1:3000/cronwatch/".into(), &[]),
        (RoutesOptions::new(), "http://127.8.9.10/cronwatch/".into(), &[]),
        (RoutesOptions::new(), "http://[::1]:3000/cronwatch/".into(), &[]),
        (
            RoutesOptions::new().trust_proxy(),
            format!("{internal}/cronwatch/"),
            &[("x-forwarded-host", "localhost:5173")],
        ),
        (RoutesOptions::new(), format!("{internal}/cronwatch/"), &[]),
        (RoutesOptions::new(), "https://app.example.com/cronwatch/".into(), &[]),
        (RoutesOptions::new().trust_proxy(), "http://localhost:3000/cronwatch/".into(), &spoofed),
        (RoutesOptions::new(), "http://localhost.example/cronwatch/".into(), &[]),
        (RoutesOptions::new(), "http://128.0.0.1/cronwatch/".into(), &[]),
        (RoutesOptions::new().base_path("/"), "http://attacker.example/".into(), &[]),
    ];
    for (options, url, headers) in cases {
        let routes = cw.routes(options).unwrap();
        serve(&routes, "GET", &url, headers).await;
        // Printed once per routes value, however many requests it answers.
        serve(&routes, "GET", &url, headers).await;
    }
    // A Host header that is not a host is not loopback, however it ends
    // (the audit): the link leaves it out.
    for host in ["evil.example/.localhost", "localhost:1@evil.example"] {
        let routes = cw.routes(RoutesOptions::new()).unwrap();
        routes.handle(Request::new("GET", "/cronwatch/").with_header("host", host)).await;
    }
}

#[test]
fn a_handler_without_a_secret_fails_closed_outside_development() {
    child("child_handler_closed", &[]);
    child("child_handler_development", &[("APP_ENV", "local")]);
}

#[tokio::test]
#[ignore = "run by a_handler_without_a_secret_fails_closed_outside_development, in an environment of its own"]
async fn child_handler_closed() {
    if !in_child() {
        return;
    }
    let k = common::Kit::with(|b| b.cron_secret(""));
    let ran = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = ran.clone();
    let h = k.cw.job("closed", JobOptions::new()).unwrap().handler(
        move |_, _| {
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            async { Ok::<_, std::io::Error>(()) }
        },
        HandlerOptions::new(),
    );
    let res = h.handle(Request::new("GET", "/")).await;
    assert_eq!(res.status, 503);
    assert!(res.text().contains("CRON_SECRET is not set"), "{}", res.text());
    assert_eq!(res.header_str("content-type"), Some("application/json; charset=utf-8"));
    h.handle(Request::new("GET", "/")).await;
    assert_eq!(ran.load(std::sync::atomic::Ordering::SeqCst), 0, "ran");
    assert_eq!(k.wheres(), ["handler"], "reported once");
    assert!(k.messages()[0].contains("HandlerOptions::no_secret()"));

    // Opting out runs the job, and does not show the error to the caller.
    let open = k.cw.job("open", JobOptions::new()).unwrap().handler(
        |_, _| async { Err::<(), _>(std::io::Error::other("private detail")) },
        HandlerOptions::new().no_secret(),
    );
    let failed = open.handle(Request::new("GET", "/")).await;
    assert_eq!(failed.status, 500);
    assert!(!failed.text().contains("error"), "the error went to a caller who sent no secret: {}", failed.text());

    // A client made with no_cron_secret lets anyone in.
    let anyone = common::Kit::new();
    let h = anyone
        .cw
        .job("any", JobOptions::new())
        .unwrap()
        .handler(|_, _| async { Ok::<_, std::io::Error>(()) }, HandlerOptions::new());
    assert_eq!(h.handle(Request::new("GET", "/")).await.status, 200);
}

#[tokio::test]
#[ignore = "run by a_handler_without_a_secret_fails_closed_outside_development, in an environment of its own"]
async fn child_handler_development() {
    if !in_child() {
        return;
    }
    let k = common::Kit::with(|b| b.cron_secret(""));
    let h =
        k.cw.job("dev", JobOptions::new())
            .unwrap()
            .handler(|_, _| async { Ok::<_, std::io::Error>(()) }, HandlerOptions::new());
    assert_eq!(h.handle(Request::new("GET", "/")).await.status, 200, "development lets it run");
    assert!(k.wheres().is_empty());
}
