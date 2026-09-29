//! Replays `conformance/output.json`, written by `scripts/conformance.mjs`
//! from the TypeScript SDK (the cap, every redaction case, error text and
//! what an expect rule sees), and the SDK's redaction tests that exercise
//! `redactSecrets` and the cap directly. Fake keys are built from pieces, so
//! no string here looks like a real credential to a scanner.

use std::time::{Duration, Instant};

use super::*;
use crate::js::{Object, Value};

fn load() -> Object {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../conformance/output.json");
    let text = std::fs::read_to_string(path).expect("conformance/output.json");
    match js::parse(&text).expect("valid JSON") {
        Value::Object(o) => o,
        _ => panic!("output.json is not an object"),
    }
}

fn list<'a>(o: &'a Object, key: &str) -> &'a Vec<Value> {
    o.get(key).and_then(Value::as_array).unwrap_or_else(|| panic!("no {key}"))
}

/// The fixture's recipe for long text: a string, or `{ parts: [[piece,
/// times], ...] }` joined.
fn expand(spec: &Value) -> String {
    if let Some(s) = spec.as_str() {
        return s.to_string();
    }
    let mut b = String::new();
    for p in list(spec.as_object().expect("a recipe"), "parts") {
        let pair = p.as_array().expect("a pair");
        b.push_str(&pair[0].as_str().expect("a piece").repeat(pair[1].as_f64().expect("a count") as usize));
    }
    b
}

/// The fixture's form of a result: the text when it is 400 code units or
/// fewer, else its length and the SHA-256 of its UTF-8.
fn digest(text: Option<&str>) -> Value {
    let Some(text) = text else { return Value::Null };
    let n = js::len16(text);
    if n <= 400 {
        return Object::new().with("text", text).into();
    }
    Object::new().with("length", n).with("sha256", sha256_hex(text.as_bytes())).into()
}

fn same(what: &str, got: &Value, want: &Value) {
    let (g, w) = (got.to_json(), want.to_json());
    assert!(g == w, "{what}:\n got {:.300}\nwant {:.300}", g, w);
}

#[test]
fn conformance_output_cap() {
    assert_eq!(load().get("outputCap").and_then(Value::as_f64), Some(OUTPUT_CAP as f64));
}

#[test]
fn conformance_redact() {
    let cases = list(&load(), "redact").clone();
    assert_eq!(cases.len(), 204, "redact cases");
    for (i, c) in cases.iter().enumerate() {
        let o = c.as_object().expect("a case");
        let input = expand(o.get("input").expect("input"));
        let got = redact_secrets(&input);
        same(
            &format!("redact case {i} {:?}", js::head16(&input, 60)),
            &digest(Some(&got)),
            o.get("result").expect("result"),
        );
    }
}

#[test]
fn conformance_error_message() {
    let cases = list(&load(), "errorMessage").clone();
    assert_eq!(cases.len(), 16, "errorMessage cases");
    for (i, c) in cases.iter().enumerate() {
        let o = c.as_object().expect("a case");
        let text = match o.get("value") {
            Some(v) => {
                let recipe = v.as_object().is_some_and(|vo| vo.has("parts"));
                if recipe { value_message(&Value::String(expand(v))) } else { value_message(v) }
            }
            None => {
                let frames: Vec<String> =
                    list(o, "frames").iter().map(|f| f.as_str().expect("a frame").to_string()).collect();
                let name = o.get("name").and_then(Value::as_str).expect("a name");
                error_message(name, &expand(o.get("message").expect("a message")), &frames)
            }
        };
        same(&format!("errorMessage case {i}"), &digest(Some(&text)), o.get("result").expect("result"));
    }
}

/// A recorder case's lines: plain strings, recipes, and `{ numbered, count,
/// width }` runs of numbered lines padded to a width.
fn lines(spec: &[Value]) -> Vec<String> {
    let mut out = Vec::new();
    for line in spec {
        if let Some(o) = line.as_object().filter(|o| o.has("numbered")) {
            let prefix = o.get("numbered").and_then(Value::as_str).expect("a prefix");
            let count = o.get("count").and_then(Value::as_f64).expect("a count") as usize;
            let width = o.get("width").and_then(Value::as_f64).expect("a width") as usize;
            for i in 0..count {
                let head = format!("{prefix}{i} ");
                let pad = width.saturating_sub(js::len16(&head));
                out.push(format!("{head}{}", "x".repeat(pad)));
            }
            continue;
        }
        out.push(expand(line));
    }
    out
}

#[test]
fn conformance_expect_text() {
    let cases = list(&load(), "expectText").clone();
    assert_eq!(cases.len(), 11, "expectText cases");
    for c in &cases {
        let o = c.as_object().expect("a case");
        let name = o.get("name").and_then(Value::as_str).expect("a name");
        let rec = Recorder::new();
        for line in lines(list(o, "lines")) {
            rec.log(line);
        }
        let text = rec.expect_text();
        same(&format!("{name}: expectText"), &digest(text.as_deref()), o.get("expectText").expect("expectText"));
        same(&format!("{name}: output"), &digest(rec.output().as_deref()), o.get("output").expect("output"));
        for ch in list(o, "checks") {
            let co = ch.as_object().expect("a check");
            let needle = co.get("expect").and_then(Value::as_str).expect("a needle");
            let result = match &text {
                Some(t) if t.contains(needle) => Value::Null,
                _ => Value::String(format!("Output did not contain {}", js::quote(needle))),
            };
            same(&format!("{name}: expect {needle}"), &result, co.get("result").expect("result"));
        }
    }
}

#[test]
fn redacts_what_the_sdk_tests_redact() {
    let smile = "\u{1F600}";
    let cases: Vec<(String, String)> = vec![
        ("DB_PASSWORD=hunter2 tokens: 1200".into(), "DB_PASSWORD=[redacted] tokens: 1200".into()),
        (
            "connect ECONNREFUSED postgres://app:s3cr3t@10.0.0.12:5432/db".into(),
            "connect ECONNREFUSED postgres://app:[redacted]@10.0.0.12:5432/db".into(),
        ),
        (format!("key AKIA{} and ghp_{}", "IOSFODNN7EXAMPLE", "a".repeat(36)), "key [redacted] and [redacted]".into()),
        ("Authorization: Bearer abcdefgh12345".into(), "Authorization: Bearer [redacted]".into()),
        ("max_tokens: 800".into(), "max_tokens: 800".into()),
        ("SLACK_TOKEN='xoxb-123'".into(), "SLACK_TOKEN='[redacted]'".into()),
        (r#"PASSWORD = "two words here""#.into(), r#"PASSWORD = "[redacted]""#.into()),
        (
            r#"{"client_secret": "abc def", "other": "x"}"#.into(),
            r#"{"client_secret": "[redacted]", "other": "x"}"#.into(),
        ),
        (r#"password="a" user="b""#.into(), r#"password="[redacted]" user="b""#.into()),
        (r#"password="unterminated"#.into(), "password=[redacted]".into()),
        (r#":password=>"hunter2""#.into(), r#":password=>"[redacted]""#.into()),
        ("{:api_key => 'abc', user: 1}".into(), "{:api_key => '[redacted]', user: 1}".into()),
        ("Authorization: Basic dXNlcjpwYXNz".into(), "Authorization: Basic [redacted]".into()),
        (
            r#"{"Authorization": "Token abc123", "x": 1}"#.into(),
            r#"{"Authorization": "Token [redacted]", "x": 1}"#.into(),
        ),
        (
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nIBAAK==\n-----END RSA PRIVATE KEY-----\nafter".into(),
            "[redacted]\nafter".into(),
        ),
        ("-----BEGIN PRIVATE KEY-----\nMIIE\nabc".into(), "[redacted]".into()),
        (format!("jwt eyJ{}.eyJzdWIiOiIxIn0.abc_def-123 done", "hbGciOiJIUzI1NiJ9"), "jwt [redacted] done".into()),
        (
            "https://hooks.slack.com/services/T0/B0/xyz ok".into(),
            "https://hooks.slack.com/services/[redacted] ok".into(),
        ),
        ("https://discord.com/api/webhooks/123/abc-def".into(), "https://discord.com/api/webhooks/[redacted]".into()),
        (format!("key AI{}{}A", "za", "Sy".repeat(17)), "key [redacted]".into()),
        (format!("wh{}{}", "sec_", "abcd1234".repeat(3)), "[redacted]".into()),
        ("postgres://user:p@ss@host/db".into(), "postgres://user:[redacted]@host/db".into()),
        // JavaScript's /i folds ASCII only: these are not secret names there.
        ("\u{17f}ecret=x".into(), "\u{17f}ecret=x".into()),
        ("api_\u{212a}ey=x".into(), "api_\u{212a}ey=x".into()),
        // An emoji is two code units to the bounded run, as in JavaScript.
        (format!("token={}", smile.repeat(3000)), format!("token=[redacted]{}", smile.repeat(952))),
        (format!("token=a{}", smile.repeat(3000)), format!("token=[redacted]\u{fffd}{}", smile.repeat(952))),
    ];
    for (input, want) in cases {
        assert_eq!(redact_secrets(&input), want, "redact_secrets({:.60?})", input);
    }
}

#[test]
fn adversarial_lines_redact_in_linear_time() {
    let mut shapes: Vec<String> = [
        "password",
        "token-",
        "secret_",
        "a-",
        "password_x-",
        "-token",
        "tokens-",
        "token\"  ",
        "token  =",
        "password=\"",
        "x=>",
        "=>",
        "authorization: ",
        "authorization: basic ",
        "Authorization-",
        "a://",
        "a://x:",
        "postgres://u:",
        "https://u:@@@",
        "@",
        ":",
        "Bearer ",
        "eyJ",
        "eyJa.",
        "eyJaaaa.aaaa",
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN A B C ",
        "-----BEGIN PRIVATE KEY----------",
        "hooks.slack.com/services/",
        "x.discord.com/api/webhooks/",
        "-",
        " ",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    shapes.push(format!("a://{}:", "b".repeat(250)));
    shapes.push(format!("a://b:{}", "c".repeat(250)));
    shapes.push(format!("eyJ{}.", "a".repeat(4090)));
    shapes.push(format!("-----BEGIN PRIVATE KEY-----{}", "a".repeat(100)));
    shapes.push(format!("AI{}", "za"));
    shapes.push(format!("wh{}", "sec_"));
    let mut worst = Duration::ZERO;
    let mut slowest = String::new();
    for shape in &shapes {
        let line: String = shape.repeat(16384 / shape.len() + 1)[..16384].to_string();
        let started = Instant::now();
        redact_secrets(&line);
        redact_secrets(&format!("{line}!"));
        let took = started.elapsed();
        if took > worst {
            worst = took;
            slowest = shape.clone();
        }
    }
    // An unoptimized build is several times slower than a release one.
    let limit = if cfg!(debug_assertions) { Duration::from_secs(20) } else { Duration::from_secs(1) };
    assert!(worst <= limit, "{:.30?} took {:?}", slowest, worst);
}

#[test]
fn a_megabyte_redacts_in_bounded_time() {
    let pieces = [
        "INFO processed 1200 rows in 3.2s tokens: 1200 max_tokens: 800\n".to_string(),
        "password=hunter2 user=bob url=postgres://app:pw@db.internal:5432/app\n".to_string(),
        format!("Authorization: Bearer abcdefgh12345 and eyJ{}.eyJzdWIi.sig\n", "hbGciOi"),
        format!("r\u{e9}sum\u{e9} \u{1F680} done, {}\n", "x".repeat(200)),
        format!("-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n", "QUJD".repeat(100)),
    ];
    let mut text = String::new();
    while text.len() < 1 << 20 {
        for p in &pieces {
            text.push_str(p);
        }
    }
    let started = Instant::now();
    let out = redact_secrets(&text);
    let took = started.elapsed();
    assert!(!out.contains("hunter2"), "a secret survived");
    let limit = if cfg!(debug_assertions) { Duration::from_secs(60) } else { Duration::from_secs(3) };
    assert!(took <= limit, "a megabyte took {took:?}");
}

#[test]
fn caps_output() {
    assert_eq!(cap_output("a\0b"), "ab");
    let long = "x".repeat(OUTPUT_CAP + 5);
    assert_eq!(cap_output(&long), format!("[earlier output trimmed]\n{}", "x".repeat(OUTPUT_CAP)));
}

#[test]
fn error_names_are_the_last_segment_of_the_type() {
    let cases = [
        ("std::io::error::Error", "Error"),
        ("my_app::jobs::ReportError", "ReportError"),
        ("my_app::Wrapper<my_app::Inner>", "Wrapper"),
        ("alloc::boxed::Box<dyn core::error::Error + core::marker::Send + core::marker::Sync>", "Error"),
        ("anyhow::Error", "Error"),
        ("alloc::string::String", "Error"),
        ("&str", "Error"),
        ("my_app::lower_case", "Error"),
    ];
    for (name, want) in cases {
        assert_eq!(error_name(name), want, "{name}");
    }
    assert_eq!(describe("ReportError", "no rows", &[]), "ReportError: no rows");
    assert_eq!(value_message(&Value::from(42)), "42");
    assert_eq!(value_message(&Value::Null), "null");
    assert_eq!(value_message(&Value::from("a\0b")), "ab");
}

#[test]
fn recorder_metrics_and_lines() {
    let r = Recorder::new();
    assert_eq!(r.metric("cost", f64::INFINITY), Err("metric \"cost\" must be a finite number".to_string()));
    for name in ["zeta", "200", "10"] {
        r.metric(name, 2.0).expect("a finite metric");
    }
    assert_eq!(r.metrics().keys().collect::<Vec<_>>(), ["10", "200", "zeta"]);
    assert!(r.output().is_none() && r.expect_text().is_none(), "nothing logged");
    r.log(format!("{} {} {}", "a", 1, "Error: e"));
    r.log("second");
    assert_eq!(r.output().as_deref(), Some("a 1 Error: e\nsecond"));
}

/// SHA-256, for the fixture's digests of long results (the tests only; the
/// crate takes RustCrypto's `sha2` in the phase that first needs a hash).
pub(crate) fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98,
        0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8,
        0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
        0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] =
        [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut msg = data.to_vec();
    let bits = (data.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([chunk[4 * i], chunk[4 * i + 1], chunk[4 * i + 2], chunk[4 * i + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().fold(String::new(), |mut out, x| {
        use std::fmt::Write;
        let _ = write!(out, "{x:08x}");
        out
    })
}

#[test]
fn sha256_is_sha256() {
    assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert_eq!(sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
}
