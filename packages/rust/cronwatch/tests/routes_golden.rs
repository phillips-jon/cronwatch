//! Replays packages/ruby/test/web/golden.json, the SDK routes' answers to a
//! fixed seed (written by golden.mjs), against `Client::routes` seeded the
//! same way, and compares status, headers and body byte for byte, three
//! ways: straight into `Routes::handle`, through the tower service, and
//! through a real hyper server with the dashboard nested in an axum
//! `Router`, its base path found from the mount. Run ids are random on
//! both sides, so each becomes `<id:N>` in order of first appearance. The
//! gem and the Python, PHP and Go ports replay the same file.

mod common;

use std::collections::HashMap;

use bytes::Bytes;
use common::{HOUR, Kit, MIN, T0};
use cronwatch::js::{self, Value};
use cronwatch::web::{Request, RoutesOptions};
use cronwatch::{Client, JobOptions};
use http_body_util::{BodyExt, Full};
use hyper_util::rt::TokioIo;
use tower::ServiceExt;

const DAY: i64 = 24 * HOUR;

struct Capture {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: Option<String>,
    status: u16,
    response_headers: Vec<(String, String)>,
    response_body: String,
}

fn text(v: &Value) -> String {
    v.as_str().unwrap_or_default().to_string()
}

fn pairs(v: Option<&Value>) -> Vec<(String, String)> {
    v.and_then(Value::as_object).map_or_else(Vec::new, |o| o.iter().map(|(k, v)| (k.to_string(), text(v))).collect())
}

fn read_golden() -> Vec<Capture> {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../ruby/test/web/golden.json");
    let data = std::fs::read_to_string(path).expect("golden.json");
    let golden = js::parse(&data).expect("golden.json is JSON");
    let golden = golden.as_object().expect("an object");
    assert_eq!(golden.get("t0").and_then(Value::as_f64), Some(T0 as f64), "golden.json's t0");
    let captures: Vec<Capture> = golden
        .get("captures")
        .and_then(Value::as_array)
        .expect("captures")
        .iter()
        .map(|c| {
            let c = c.as_object().expect("a capture");
            Capture {
                method: text(c.get("method").unwrap()),
                path: text(c.get("path").unwrap()),
                headers: pairs(c.get("headers")),
                body: c.get("body").and_then(Value::as_str).map(str::to_string),
                status: c.get("status").and_then(Value::as_f64).unwrap() as u16,
                response_headers: pairs(c.get("responseHeaders")),
                // GET /api names the library, its language and its version,
                // which differ from port to port: the fixture holds
                // placeholders, and this port puts in its own.
                response_body: text(c.get("responseBody").unwrap())
                    .replace("\"<library>\"", "\"cronwatch\"")
                    .replace("\"<language>\"", "\"rust\"")
                    .replace("\"<version>\"", &format!("\"{}\"", cronwatch::VERSION))
                    .replace("><library> <version></a>", &format!(">cronwatch {}</a>", cronwatch::VERSION)),
            }
        })
        .collect();
    assert_eq!(captures.len(), 82, "golden.json's captures");
    captures
}

/// The seed in golden.mjs, step for step.
async fn seed() -> Kit {
    let k = Kit::new();
    let nightly =
        k.cw.job(
            "nightly-report",
            JobOptions::new()
                .schedule("0 2 * * *")
                .timezone("UTC")
                .grace("15m")
                .max_duration("10m")
                .budget("cost", 2.0)
                .floor("rows", 40.0)
                .expect("Report written")
                .failures_before_alert(2)
                .description("Builds the <b>PDF</b>")
                .tags(["reports", "<t>"]),
        )
        .unwrap();
    let durations = [2000, 2500, 90_000, 3100, 1800];
    for (i, d) in durations.into_iter().enumerate() {
        k.set(T0 - (5 - i as i64) * DAY - 7 * HOUR - 30 * MIN);
        let _ = nightly
            .run(|job| {
                let first = if i == 3 { "Wrote nothing" } else { "Report written:" };
                job.log(format!("{first} report-{i}.pdf"));
                job.metric("cost", if i == 4 { 2.5 } else { 1.2 }).unwrap();
                job.metric("rows", 40.0 + i as f64).unwrap();
                job.metric("2", 0.123456).unwrap();
                k.advance(d);
                async { Ok::<_, std::io::Error>(()) }
            })
            .await;
    }
    // Five runs that wrote rows, then one that wrote none: under its floor.
    let importer = k.cw.job("import", JobOptions::new().schedule("0 * * * *")).unwrap();
    for i in 0..6 {
        k.set(T0 - (6 - i) * HOUR - 30 * MIN);
        let _ = importer
            .run(|job| {
                job.metric("rows", if i == 5 { 0.0 } else { 120.0 + i as f64 }).unwrap();
                k.advance(800);
                async { Ok::<_, std::io::Error>(()) }
            })
            .await;
    }
    let broken = k.cw.job("broken", JobOptions::new().expect("done")).unwrap();
    k.set(T0 - 2 * HOUR);
    let _ = broken
        .run(|job| {
            job.log("half way <script>alert(1)</script>");
            k.advance(450);
            async { Ok::<_, std::io::Error>(()) }
        })
        .await;
    let sync = k.cw.job("sync-users", JobOptions::new().schedule("*/15 * * * *").grace(60_000).timeout("5m")).unwrap();
    k.set(T0 - 3 * HOUR);
    let _ = sync
        .run(|_| {
            k.advance(12_345);
            async { Ok::<_, std::io::Error>(()) }
        })
        .await;
    k.cw.job("never-ran", JobOptions::new().schedule("0 * * * *")).unwrap();
    // A run as a foreign or damaged row could hold it: started before the
    // year 1, so the pages write it in words rather than as a date.
    let far_back = k.cw.job("far-back", JobOptions::new().timeout("5m").expect("far")).unwrap();
    k.set(-62_135_596_800_001);
    let _ = far_back
        .run(|_| {
            k.advance(1000);
            async { Ok::<_, std::io::Error>(()) }
        })
        .await;
    // Cron jobs whose last run is as far off: counted from the first
    // millisecond of the year 1, the first is due then (and is missed at
    // the check); after 9999 the other is never due again.
    for (name, start) in [("far-cron-back", -62_135_596_800_001), ("far-cron-ahead", 253_402_300_800_000)] {
        let job = k.cw.job(name, JobOptions::new().schedule("0 2 * * *").timezone("UTC").grace("10m")).unwrap();
        k.set(start);
        job.run(|_| {
            k.advance(1000);
            async { Ok::<_, std::io::Error>(()) }
        })
        .await
        .unwrap();
    }
    k.set(T0);
    k
}

/// Puts the id of the Nth newest run of a job where the path says
/// `{run:JOB:N}`.
async fn resolve(cw: &Client, path: &str) -> String {
    let Some(start) = path.find("{run:") else {
        return path.to_string();
    };
    let end = start + path[start..].find('}').unwrap();
    let (job, n) = path[start + 5..end].split_once(':').unwrap();
    let runs = cw.runs(job, 50).await.unwrap();
    format!("{}{}{}", &path[..start], runs[n.parse::<usize>().unwrap()].id, &path[end + 1..])
}

/// Numbers run ids in order of first appearance, as golden.mjs does.
#[derive(Default)]
struct Ids(HashMap<String, String>);

fn is_uuid(b: &[u8]) -> bool {
    b.len() == 36
        && b.iter().enumerate().all(|(i, &c)| {
            if [8, 13, 18, 23].contains(&i) { c == b'-' } else { c.is_ascii_digit() || (b'a'..=b'f').contains(&c) }
        })
}

impl Ids {
    fn replace(&mut self, text: &str) -> String {
        let bytes = text.as_bytes();
        let mut out = String::with_capacity(text.len());
        let mut i = 0;
        while i < bytes.len() {
            if i + 36 <= bytes.len() && text.is_char_boundary(i + 36) && is_uuid(&bytes[i..i + 36]) {
                let id = &text[i..i + 36];
                let n = self.0.len();
                out.push_str(self.0.entry(id.to_string()).or_insert_with(|| format!("<id:{n}>")));
                i += 36;
                continue;
            }
            let c = text[i..].chars().next().unwrap();
            out.push(c);
            i += c.len_utf8();
        }
        out
    }
}

fn base64(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Checks one answer against its capture. `ignored` names headers the
/// server in front adds (the SDK leaves Content-Length to it).
fn compare(c: &Capture, status: u16, headers: Vec<(String, Vec<u8>)>, body: &[u8], ids: &mut Ids, ignored: &[&str]) {
    let label = format!("{} {}", c.method, c.path);
    let mut got: Vec<(String, String)> = Vec::new();
    for (name, value) in headers {
        let name = name.to_ascii_lowercase();
        if name == "content-length" || ignored.contains(&name.as_str()) {
            continue;
        }
        let value = String::from_utf8(value).expect("a header in UTF-8");
        match got.iter_mut().find(|(n, _)| *n == name) {
            Some(existing) => existing.1 = format!("{}, {value}", existing.1),
            None => got.push((name, value)),
        }
    }
    let content_type = got.iter().find(|(n, _)| n == "content-type").map(|(_, v)| v.as_str());
    let text = if content_type == Some("image/png") {
        format!("base64:{}", base64(body))
    } else {
        ids.replace(std::str::from_utf8(body).expect("a body in UTF-8"))
    };
    assert_eq!(status, c.status, "{label}: status");
    let mut want = c.response_headers.clone();
    want.sort();
    got.sort();
    assert_eq!(got, want, "{label}: headers");
    if text != c.response_body {
        let at = text
            .bytes()
            .zip(c.response_body.bytes())
            .position(|(a, b)| a != b)
            .unwrap_or(text.len().min(c.response_body.len()));
        let from = at.saturating_sub(120);
        panic!(
            "{label}: the body differs at byte {at}:\n got {:?}\nwant {:?}",
            text.get(from..(at + 200).min(text.len())).unwrap_or(""),
            c.response_body.get(from..(at + 200).min(c.response_body.len())).unwrap_or("")
        );
    }
}

#[tokio::test]
async fn routes_match_the_sdk_golden_straight_into_handle() {
    let captures = read_golden();
    let k = seed().await;
    let routes = k.cw.routes(RoutesOptions::new().token("tok").base_path("/cronwatch")).unwrap();
    let mut ids = Ids::default();
    for c in &captures {
        let mut req = Request::new(c.method.as_str(), resolve(&k.cw, &c.path).await).with_header("host", "app.test");
        for (name, value) in &c.headers {
            req = req.with_header(name.as_str(), value);
        }
        if let Some(body) = &c.body {
            req = req.with_body(body.as_str());
        }
        let res = routes.handle(req).await;
        compare(c, res.status, res.headers, &res.body, &mut ids, &[]);
    }
    // As golden.mjs: nothing in the seed or the requests reports an error,
    // however far off a run's start is.
    assert_eq!(k.messages(), Vec::<String>::new());
}

fn http_request(c: &Capture, path: &str) -> http::Request<Full<Bytes>> {
    let mut req = http::Request::builder().method(c.method.as_str()).uri(path).header("host", "app.test");
    for (name, value) in &c.headers {
        req = req.header(name.as_str(), value.as_str());
    }
    req.body(Full::new(Bytes::from(c.body.clone().unwrap_or_default()))).unwrap()
}

fn header_list(headers: &http::HeaderMap) -> Vec<(String, Vec<u8>)> {
    headers.iter().map(|(n, v)| (n.as_str().to_string(), v.as_bytes().to_vec())).collect()
}

#[tokio::test]
async fn routes_match_the_sdk_golden_through_the_tower_service() {
    let captures = read_golden();
    let k = seed().await;
    let routes = k.cw.routes(RoutesOptions::new().token("tok")).unwrap();
    let mut ids = Ids::default();
    for c in &captures {
        let path = resolve(&k.cw, &c.path).await;
        let res = routes.clone().oneshot(http_request(c, &path)).await.unwrap();
        let (parts, body) = res.into_parts();
        let body = body.collect().await.unwrap().to_bytes();
        compare(c, parts.status.as_u16(), header_list(&parts.headers), &body, &mut ids, &[]);
    }
}

#[tokio::test]
async fn routes_match_the_sdk_golden_through_a_server_nested_in_axum() {
    let captures = read_golden();
    let k = seed().await;
    // No base path: it is found from where axum nests the dashboard.
    let routes = k.cw.routes(RoutesOptions::new().token("tok")).unwrap();
    let app = axum::Router::new().nest_service("/cronwatch", routes);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await });
    let mut ids = Ids::default();
    for c in &captures {
        let path = resolve(&k.cw, &c.path).await;
        let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
        let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(stream)).await.unwrap();
        tokio::spawn(conn);
        let res = sender.send_request(http_request(c, &path)).await.unwrap();
        let (parts, body) = res.into_parts();
        let body = body.collect().await.unwrap().to_bytes();
        compare(c, parts.status.as_u16(), header_list(&parts.headers), &body, &mut ids, &["date"]);
    }
    server.abort();
}
