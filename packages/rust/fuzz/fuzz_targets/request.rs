//! A request to the dashboard or a job's handler, as anyone can send one:
//! the method, the target, the headers (`Host`, `Origin`, the forwarded
//! ones, the cookie, the bearer), the body, over TLS or not, and where an
//! adapter found the mount. The routes answer a panic with a 500 and report
//! it, so a report of one fails the target. The Host and origin readers
//! are also run on their own.
#![no_main]

use std::sync::OnceLock;

use cronwatch::web::{Request, Routes, RoutesOptions};
use cronwatch::{Client, Handler, HandlerOptions, JobOptions};
use libfuzzer_sys::arbitrary::{self, Arbitrary};
use libfuzzer_sys::fuzz_target;

const TOKEN: &str = "fuzz-token-0123456789";
const SECRET: &str = "fuzz-secret-0123456789";

struct State {
    runtime: tokio::runtime::Runtime,
    routes: Vec<Routes>,
    handler: Handler,
    cookie: String,
}

fn state() -> &'static State {
    static STATE: OnceLock<State> = OnceLock::new();
    STATE.get_or_init(|| {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
        let entered = runtime.enter();
        let cw = Client::builder()
            .alert(cronwatch::channel_fn("quiet", |_| async { Ok(()) }))
            .on_error(|err, where_| {
                let text = err.to_string();
                if text.contains("panic") {
                    panic!("{where_}: {text}");
                }
            })
            .build()
            .unwrap();
        let nightly = cw.job("nightly", JobOptions::new().schedule("0 2 * * *").timezone("UTC").grace("15m")).unwrap();
        let flaky = cw.job("flaky:job", JobOptions::new().schedule("every 5m").expect("done")).unwrap();
        runtime.block_on(async {
            let _ = nightly
                .run(|job| async move {
                    job.log("Report written");
                    Ok::<_, std::io::Error>(())
                })
                .await;
            let _ = flaky.run(|_| async { Err::<(), _>(std::io::Error::other("boom")) }).await;
        });
        let routes = vec![
            cw.routes(RoutesOptions::new().token(TOKEN)).unwrap(),
            cw.routes(RoutesOptions::new().token(TOKEN).trust_proxy()).unwrap(),
            cw.routes(RoutesOptions::new().token(TOKEN).origin("https://app.example.com")).unwrap(),
            cw.routes(RoutesOptions::new().token(TOKEN).base_path("/admin/cw/")).unwrap(),
            cw.routes(RoutesOptions::new().no_token()).unwrap(),
        ];
        let handler = nightly.handler(
            |job, _request| async move {
                job.log("handled");
                Ok::<_, std::io::Error>("done")
            },
            HandlerOptions::new().secret(SECRET),
        );
        // The cookie a sign-in sets, so the fuzzer starts inside.
        let signed_in = runtime.block_on(routes[0].handle(Request::new("GET", format!("/cronwatch/?token={TOKEN}"))));
        let cookie = signed_in.header_str("set-cookie").unwrap_or("").split(';').next().unwrap_or("").to_string();
        drop(entered);
        State { runtime, routes, handler, cookie }
    })
}

const METHODS: [&str; 7] = ["GET", "POST", "HEAD", "DELETE", "PUT", "OPTIONS", "get"];

const PATHS: [&str; 14] = [
    "/cronwatch",
    "/cronwatch/",
    "/cronwatch/jobs/nightly",
    "/cronwatch/jobs/flaky%3Ajob",
    "/cronwatch/jobs/nightly/silence",
    "/cronwatch/check",
    "/cronwatch/api/jobs",
    "/cronwatch/api/jobs/nightly",
    "/cronwatch/api/jobs/nightly/silence",
    "/cronwatch/api/check",
    "/cronwatch/offline",
    "/cronwatch/manifest.webmanifest",
    "/cronwatch/sw.js",
    "/admin/cw/api/jobs",
];

const HEADERS: [&str; 14] = [
    "host",
    "origin",
    "referer",
    "cookie",
    "authorization",
    "content-type",
    "content-length",
    "x-forwarded-host",
    "x-forwarded-proto",
    "forwarded",
    "sec-fetch-site",
    "accept",
    "if-none-match",
    "x-requested-with",
];

#[derive(Arbitrary, Debug)]
enum Name<'a> {
    Known(u8),
    Own(&'a str),
}

#[derive(Arbitrary, Debug)]
struct Input<'a> {
    to: u8,
    method: u8,
    own_method: Option<&'a str>,
    path: u8,
    target: &'a str,
    headers: Vec<(Name<'a>, &'a [u8])>,
    auth: u8,
    body: &'a [u8],
    tls: bool,
    mount: Option<&'a str>,
    host: &'a [u8],
    origin: &'a str,
}

fuzz_target!(|input: Input<'_>| {
    cronwatch::fuzz::origin(input.host, input.tls, input.origin);

    let s = state();
    let method = input.own_method.unwrap_or(METHODS[input.method as usize % METHODS.len()]);
    let target = match input.path as usize {
        i if i < PATHS.len() => format!("{}{}", PATHS[i], input.target),
        _ => input.target.to_string(),
    };
    let mut req = Request::new(method, target).with_tls(input.tls).with_header("host", input.host);
    for (name, value) in input.headers.iter().take(12) {
        let name = match name {
            Name::Known(i) => HEADERS[*i as usize % HEADERS.len()],
            Name::Own(own) => own,
        };
        req = req.with_header(name, value);
    }
    req = match input.auth % 4 {
        1 => req.with_header("authorization", format!("Bearer {TOKEN}")),
        2 => req.with_header("cookie", &s.cookie),
        3 => req.with_header("authorization", format!("Bearer {SECRET}")),
        _ => req,
    };
    if let Some(mount) = input.mount {
        req = req.with_mount(mount);
    }
    let req = req.with_body(input.body);
    let to = input.to as usize % (s.routes.len() + 1);
    let answer = match s.routes.get(to) {
        Some(routes) => s.runtime.block_on(routes.handle(req)),
        None => s.runtime.block_on(s.handler.handle(req)),
    };
    assert!((100..600).contains(&answer.status), "status {}", answer.status);
});
