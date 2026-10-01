//! The channels' hardening, as the SDK's channels-hardening.test.ts and the
//! other ports' tests have it, against real local servers where it matters:
//! redirects refused, one deadline, bodies capped, only the origin in an
//! error, URLs and headers checked, credentials trimmed and cut out of quoted
//! answers, TLS verified, Twilio's partial delivery and lone surrogates.

use std::io::Write as _;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use url::Url;

use super::post::{self, error_body, fetch};
use super::*;
use crate::client::Client;
use crate::deliver::{Channel, ChannelContext};
use crate::js::{self, Value};
use crate::options::JobOptions;
use crate::store::{BoxError, BoxFuture};
use crate::types::Alert;

/// The channels fixture's first alert, a failure.
fn sample() -> Alert {
    let f = crate::conformance::fixture("channels");
    Alert::from_value(crate::conformance::field(crate::conformance::objects(&f, "alerts")[0], "alert")).unwrap()
}

/// A request a server was sent.
#[derive(Clone, Debug)]
struct Seen {
    headers: Vec<(String, String)>,
}

/// How a server answers.
enum Reply {
    Answer(u16, Vec<(&'static str, String)>, Vec<u8>),
    /// Takes the request and never answers.
    Hang,
    /// Answers 500, then a byte every 50 ms for five seconds.
    Drip,
}

type Handler = Arc<dyn Fn(&Seen) -> Reply + Send + Sync>;

/// A local HTTP/1.1 server answering with `handler`, over TLS when
/// `tls` is given.
struct Server {
    url: String,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl Server {
    async fn start(handler: impl Fn(&Seen) -> Reply + Send + Sync + 'static) -> Server {
        Server::start_with(Arc::new(handler), None).await
    }

    async fn start_with(handler: Handler, tls: Option<tokio_rustls::TlsAcceptor>) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        let scheme = if tls.is_some() { "https" } else { "http" };
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let (handler, log, tls) = (handler.clone(), log.clone(), tls.clone());
                tokio::spawn(async move {
                    match tls {
                        Some(tls) => {
                            if let Ok(stream) = tls.accept(stream).await {
                                serve(stream, handler, log).await;
                            }
                        }
                        None => serve(stream, handler, log).await,
                    }
                });
            }
        });
        Server { url: format!("{scheme}://127.0.0.1:{port}"), seen }
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

async fn serve<S: AsyncRead + AsyncWrite + Unpin>(mut stream: S, handler: Handler, log: Arc<Mutex<Vec<Seen>>>) {
    let mut data = Vec::new();
    let mut buf = [0u8; 8192];
    let head_end = loop {
        match stream.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => data.extend_from_slice(&buf[..n]),
        }
        if let Some(i) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
    };
    let head = String::from_utf8_lossy(&data[..head_end]).to_string();
    let headers: Vec<(String, String)> = head
        .lines()
        .skip(1)
        .filter_map(|l| l.split_once(':'))
        .map(|(n, v)| (n.trim().to_ascii_lowercase(), v.trim().to_string()))
        .collect();
    let length = headers.iter().find(|(n, _)| n == "content-length").and_then(|(_, v)| v.parse().ok()).unwrap_or(0);
    while data.len() < head_end + length {
        match stream.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => data.extend_from_slice(&buf[..n]),
        }
    }
    let seen = Seen { headers };
    log.lock().unwrap().push(seen.clone());
    match handler(&seen) {
        Reply::Answer(status, extra, body) => {
            let mut out = format!("HTTP/1.1 {status} X\r\ncontent-length: {}\r\nconnection: close\r\n", body.len());
            for (n, v) in extra {
                out.push_str(&format!("{n}: {v}\r\n"));
            }
            out.push_str("\r\n");
            let _ = stream.write_all(out.as_bytes()).await;
            let _ = stream.write_all(&body).await;
            let _ = stream.flush().await;
        }
        Reply::Hang => tokio::time::sleep(Duration::from_secs(60)).await,
        Reply::Drip => {
            let _ = stream.write_all(b"HTTP/1.1 500 X\r\ntransfer-encoding: chunked\r\n\r\n").await;
            for _ in 0..100 {
                if stream.write_all(b"1\r\nx\r\n").await.is_err() || stream.flush().await.is_err() {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

/// A transport that sends every request to a local server instead, as the
/// SDK's test points fetch at one.
struct Rewrite {
    to: Url,
    inner: ReqwestTransport,
}

fn to(server: &Server) -> Option<Arc<dyn Transport>> {
    Some(Arc::new(Rewrite { to: Url::parse(&server.url).unwrap(), inner: ReqwestTransport::new().unwrap() }))
}

impl Transport for Rewrite {
    fn post(&self, mut request: Request) -> BoxFuture<'_, Result<Response, BoxError>> {
        let mut u = Url::parse(&request.url).unwrap();
        u.set_scheme(self.to.scheme()).unwrap();
        u.set_host(self.to.host_str()).unwrap();
        u.set_port(self.to.port()).unwrap();
        request.url = u.to_string();
        self.inner.post(request)
    }
}

type Answer = Arc<dyn Fn(&str) -> (u16, String) + Send + Sync>;

/// Keeps each request and answers each as `answer` says for its body.
struct Recorder {
    taken: Mutex<Vec<Request>>,
    answer: Mutex<Answer>,
}

impl Recorder {
    fn new(status: u16, body: &str) -> Arc<Recorder> {
        let body = body.to_string();
        Arc::new(Recorder {
            taken: Mutex::new(Vec::new()),
            answer: Mutex::new(Arc::new(move |_| (status, body.clone()))),
        })
    }

    fn taken(&self) -> Vec<Request> {
        self.taken.lock().unwrap().clone()
    }

    fn header(&self, i: usize, name: &str) -> String {
        self.taken()[i].headers.iter().find(|(n, _)| n == name).map(|(_, v)| v.clone()).unwrap_or_default()
    }
}

impl Transport for Recorder {
    fn post(&self, request: Request) -> BoxFuture<'_, Result<Response, BoxError>> {
        let answer = self.answer.lock().unwrap().clone();
        let (status, body) = answer(&String::from_utf8_lossy(&request.body));
        self.taken.lock().unwrap().push(request);
        Box::pin(std::future::ready(Ok(Response::new(status, body))))
    }
}

fn some(t: &Arc<Recorder>) -> Option<Arc<dyn Transport>> {
    Some(t.clone())
}

fn email() -> EmailOptions {
    EmailOptions { from: "a@b.c".into(), to: vec!["d@e.f".into()], ..Default::default() }
}

/// One of each channel, posting through `transport`.
fn every(transport: Option<Arc<dyn Transport>>, webhook_url: &str) -> Vec<Arc<dyn Channel>> {
    let t = || transport.clone();
    let s = |v: &str| v.to_string();
    vec![
        datadog(DatadogOptions { api_key: s("dd-secret-key-123"), transport: t(), ..Default::default() }),
        resend(ResendOptions { api_key: s("re_secret"), email: email(), transport: t() }),
        postmark(PostmarkOptions {
            server_token: s("pm-secret"),
            email: email(),
            transport: t(),
            ..Default::default()
        }),
        sendgrid(SendgridOptions { api_key: s("SG.secret"), email: email(), transport: t(), ..Default::default() }),
        mailgun(MailgunOptions {
            api_key: s("key-secret"),
            domain: s("mg.example.com"),
            email: email(),
            transport: t(),
            ..Default::default()
        }),
        ses(SesOptions {
            region: s("us-east-1"),
            access_key_id: s("AKIDEXAMPLE"),
            secret_access_key: s("sekret-sekret"),
            email: email(),
            transport: t(),
            ..Default::default()
        }),
        twilio(TwilioOptions {
            account_sid: s("AC1"),
            auth_token: s("tw-secret"),
            from: s("+1"),
            to: vec![s("+2")],
            transport: t(),
            ..Default::default()
        }),
        sentry(SentryOptions { dsn: s("https://pubkey@o1.ingest.sentry.io/42"), transport: t(), ..Default::default() }),
        honeybadger(HoneybadgerOptions { api_key: s("hb-secret"), transport: t(), ..Default::default() }),
        rollbar(RollbarOptions { access_token: s("rb-secret"), transport: t(), ..Default::default() }),
        bugsnag(BugsnagOptions { api_key: s("bs-secret"), transport: t(), ..Default::default() }),
        newrelic(NewRelicOptions { account_id: s("1"), api_key: s("nr-secret"), transport: t(), ..Default::default() }),
        webhook(WebhookOptions {
            url: webhook_url.into(),
            headers: vec![(s("authorization"), s("Bearer wh-secret"))],
            secret: s("s"),
            transport: t(),
        }),
        slack(SlackOptions { webhook_url: webhook_url.into(), transport: t(), ..Default::default() }),
        discord(DiscordOptions { webhook_url: webhook_url.into(), transport: t(), ..Default::default() }),
    ]
    .into_iter()
    .map(Result::unwrap)
    .collect()
}

fn quiet() -> ChannelContext {
    ChannelContext::new(|_| {})
}

#[tokio::test(flavor = "multi_thread")]
async fn every_channel_refuses_to_follow_a_redirect() {
    let evil = Server::start(|_| Reply::Answer(202, vec![], vec![])).await;
    let target = format!("{}/steal", evil.url);
    let provider = Server::start(move |_| Reply::Answer(307, vec![("location", target.clone())], vec![])).await;
    let channels = every(to(&provider), &format!("{}/in", provider.url));
    assert_eq!(channels.len(), 15);
    for ch in channels {
        let err = ch.send(&sample(), &quiet()).await.err().map(|e| e.to_string()).unwrap_or_default();
        assert!(err.contains("answered 307"), "{} followed the redirect or failed otherwise: {err}", ch.name());
    }
    assert!(evil.seen().is_empty(), "the other origin was reached");
    // The credentials went to the provider, and no further.
    let seen = provider.seen();
    assert_eq!(seen.len(), 15);
    assert!(seen.iter().any(|s| s.headers.contains(&("authorization".into(), "Bearer wh-secret".into()))));
}

#[tokio::test(flavor = "multi_thread")]
async fn one_deadline_for_the_whole_request() {
    assert_eq!(post::TIMEOUT, Duration::from_secs(10));
    let hang = Server::start(|_| Reply::Hang).await;
    let t = ReqwestTransport::new().unwrap();
    let started = std::time::Instant::now();
    let err = fetch(&t, Duration::from_millis(300), &format!("{}/T/B/secret", hang.url), &[], b"{}".to_vec())
        .await
        .unwrap_err();
    assert!(err.is::<TimedOut>());
    assert_eq!(err.to_string(), "The operation was aborted due to timeout");
    assert!(started.elapsed() < Duration::from_secs(3), "took {:?}", started.elapsed());

    // An answer whose body is still arriving at the deadline is the answer with no body.
    let drip = Server::start(|_| Reply::Drip).await;
    let answer = fetch(&t, Duration::from_millis(300), &drip.url, &[], b"{}".to_vec()).await.unwrap();
    assert_eq!((answer.status, answer.body.as_str()), (500, ""));
    let refused = post::refused("Rollbar", "https://api.rollbar.com/api/1/item/", &answer, &[]);
    assert_eq!(refused.to_string(), "Rollbar https://api.rollbar.com answered 500");
}

/// A channel's own deadline, on tokio's paused clock: a server that never
/// answers fails the send after ten seconds, however long it holds on.
#[tokio::test(start_paused = true)]
async fn a_channel_stops_waiting_at_ten_seconds() {
    let hang = Server::start(|_| Reply::Hang).await;
    let ch = slack(SlackOptions { webhook_url: format!("{}/T/B/secret", hang.url), ..Default::default() }).unwrap();
    let started = tokio::time::Instant::now();
    let err = ch.send(&sample(), &quiet()).await.unwrap_err();
    assert_eq!(err.to_string(), "The operation was aborted due to timeout");
    assert!(started.elapsed() <= Duration::from_secs(10));
}

#[tokio::test(flavor = "multi_thread")]
async fn an_answer_is_read_to_one_mebibyte_at_most() {
    // 64 MiB of zeros, gzipped: the transport decodes it, and only the first MiB is read.
    let mut z = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    let chunk = vec![0u8; 1 << 20];
    for _ in 0..64 {
        z.write_all(&chunk).unwrap();
    }
    let zipped = z.finish().unwrap();
    let bomb =
        Server::start(move |_| Reply::Answer(500, vec![("content-encoding", "gzip".into())], zipped.clone())).await;
    let answer = fetch(&ReqwestTransport::new().unwrap(), post::TIMEOUT, &bomb.url, &[], b"{}".to_vec()).await.unwrap();
    assert_eq!((answer.status, answer.body.len()), (500, post::MAX_BODY));
    let rb = rollbar(RollbarOptions { access_token: "rb-secret".into(), transport: to(&bomb), ..Default::default() })
        .unwrap();
    let err = rb.send(&sample(), &quiet()).await.unwrap_err().to_string();
    assert!(js::len16(&err) <= "Rollbar https://api.rollbar.com answered 500: ".len() + 200, "{err}");
}

#[tokio::test]
async fn a_url_that_cannot_be_posted_to_is_refused_without_quoting_it() {
    let rec = Recorder::new(200, "");
    let secret_path = ["services", "T0", "B0", &format!("not{}secret", "areal")].join("/");
    let cases = [
        (format!("hooks.example.com/{secret_path}"), "this URL"),
        (format!("ftp://hooks.example.com/{secret_path}"), "ftp:"),
        (format!("https://user:pw@hooks.example.com/{secret_path}"), "this URL"),
        (format!("https://hooks.example.com:99999/{secret_path}"), "this URL"),
        // Fetch reads it as a URL with a scheme and refuses the scheme.
        ("javascript:alert(1)".to_string(), "javascript:"),
    ];
    for (raw, shown) in &cases {
        let channels = [
            slack(SlackOptions { webhook_url: raw.clone(), transport: some(&rec), ..Default::default() }),
            discord(DiscordOptions { webhook_url: raw.clone(), transport: some(&rec), ..Default::default() }),
            webhook(WebhookOptions { url: raw.clone(), transport: some(&rec), ..Default::default() }),
        ];
        for ch in channels.into_iter().map(Result::unwrap) {
            let err = ch.send(&sample(), &quiet()).await.unwrap_err().to_string();
            assert_eq!(err, format!("only http and https URLs can be posted to, not {shown}"), "{} {raw:?}", ch.name());
        }
    }
    assert!(rec.taken().is_empty(), "something was sent");
    // A stray newline or space around a pasted URL, or a tab inside it, is
    // dropped, as fetch drops it; a space inside is encoded, as fetch
    // encodes it.
    for (raw, posted) in [
        (format!("  https://hooks.exa\tmple.com/{secret_path}\n"), format!("https://hooks.example.com/{secret_path}")),
        (format!("https://hooks.example.com/{secret_path} x"), format!("https://hooks.example.com/{secret_path}%20x")),
    ] {
        let ch = slack(SlackOptions { webhook_url: raw, transport: some(&rec), ..Default::default() }).unwrap();
        ch.send(&sample(), &quiet()).await.unwrap();
        assert_eq!(rec.taken().last().unwrap().url, posted);
    }
    for (raw, want) in [
        (format!("https://hooks.example.com/{secret_path}\n"), "https://hooks.example.com"),
        ("HTTPS://Hooks.Example.com:443/x".into(), "https://hooks.example.com"),
        ("http://hooks.example.com:8080/x".into(), "http://hooks.example.com:8080"),
        ("not a url".into(), "(invalid URL)"),
    ] {
        assert_eq!(post::origin(&raw), want, "{raw:?}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_error_names_only_the_origin() {
    // Nothing listens on port 1: the transport's own error is kept, the URL's path is not.
    let secret = format!("not{}secret", "areal");
    let ch = webhook(WebhookOptions {
        url: format!("http://127.0.0.1:1/hooks/{secret}?token={secret}"),
        ..Default::default()
    })
    .unwrap();
    let err = ch.send(&sample(), &quiet()).await.unwrap_err().to_string();
    assert!(!err.contains(&secret) && err.starts_with("http://127.0.0.1:1: "), "{err}");
    let refuse = Server::start(|_| Reply::Answer(403, vec![], vec![])).await;
    let ch =
        webhook(WebhookOptions { url: format!("{}/services/{secret}?key={secret}", refuse.url), ..Default::default() })
            .unwrap();
    let err = ch.send(&sample(), &quiet()).await.unwrap_err().to_string();
    assert_eq!(err, format!("Webhook {} answered 403", refuse.url));
}

/// An app's transport that fails the way a wrapper around a client of its
/// own does: with its own text quoting the URL, whole or decoded.
struct Quoting;

impl Transport for Quoting {
    fn post(&self, request: Request) -> BoxFuture<'_, Result<Response, BoxError>> {
        let decoded = post::percent_decode(Url::parse(&request.url).unwrap().path());
        let text = format!("giving up on {} ({decoded}) after 3 tries", request.url);
        Box::pin(std::future::ready(Err(text.into())))
    }
}

#[tokio::test]
async fn an_error_names_only_the_origin_whatever_the_transport_quotes() {
    let secret = format!("not{}secret", "areal");
    let ch = webhook(WebhookOptions {
        url: format!("https://hooks.example.com/services/{secret}%20x?token={secret}"),
        transport: Some(Arc::new(Quoting)),
        ..Default::default()
    })
    .unwrap();
    let err = ch.send(&sample(), &quiet()).await.unwrap_err().to_string();
    assert!(
        !err.contains(&secret) && !err.contains("/services") && err.starts_with("https://hooks.example.com: "),
        "{err}"
    );
}

/// An app's transport that panics.
struct Panicking;

impl Transport for Panicking {
    fn post(&self, _: Request) -> BoxFuture<'_, Result<Response, BoxError>> {
        panic!("transport broke")
    }
}

#[tokio::test]
async fn a_panic_while_texting_is_a_failure_not_a_crash() {
    let sms = twilio(TwilioOptions {
        account_sid: "AC1".into(),
        auth_token: "tok".into(),
        from: "+15551112222".into(),
        to: vec!["+15553334444".into(), "+15553335555".into()],
        transport: Some(Arc::new(Panicking)),
        ..Default::default()
    })
    .unwrap();
    let err = sms.send(&sample(), &quiet()).await.unwrap_err().to_string();
    assert_eq!(err, "panicked: transport broke (2 of 2 numbers failed)");
}

#[tokio::test(flavor = "multi_thread")]
async fn tls_is_verified() {
    use tokio_rustls::rustls::{self, pki_types};
    let made = rcgen::generate_simple_self_signed(vec!["localhost".into(), "127.0.0.1".into()]).unwrap();
    let key = pki_types::PrivateKeyDer::Pkcs8(pki_types::PrivatePkcs8KeyDer::from(made.key_pair.serialize_der()));
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::aws_lc_rs::default_provider()))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![made.cert.der().clone()], key)
        .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let server = Server::start_with(Arc::new(|_: &Seen| Reply::Answer(200, vec![], vec![])), Some(acceptor)).await;
    assert!(server.url.starts_with("https://"));
    let ch = slack(SlackOptions { webhook_url: format!("{}/T/B/secret", server.url), ..Default::default() }).unwrap();
    let err = ch.send(&sample(), &quiet()).await.unwrap_err().to_string();
    assert!(err.to_lowercase().contains("certificate"), "a certificate no one trusts was accepted: {err}");
    assert!(!err.contains("/T/B/secret"), "{err}");
    assert!(server.seen().is_empty());
}

#[tokio::test]
async fn headers_are_checked_and_credentials_trimmed() {
    let rec = Recorder::new(200, "{}");
    for value in ["Bearer a\r\nX-Evil: 1", "Bearer a\nb", "a\0b"] {
        let ch = webhook(WebhookOptions {
            url: "https://hooks.example.com/in".into(),
            headers: vec![("authorization".into(), value.into())],
            transport: some(&rec),
            ..Default::default()
        })
        .unwrap();
        let err = ch.send(&sample(), &quiet()).await.unwrap_err().to_string();
        assert_eq!(err, "the authorization header's value may not contain a line break", "{value:?}");
    }
    let ch = webhook(WebhookOptions {
        url: "https://hooks.example.com/in".into(),
        headers: vec![("bad name".into(), "x".into())],
        transport: some(&rec),
        ..Default::default()
    })
    .unwrap();
    let err = ch.send(&sample(), &quiet()).await.unwrap_err().to_string();
    assert!(err.starts_with("a header name must be a token"), "{err}");
    assert!(rec.taken().is_empty(), "a request with a bad header was sent");

    let s = |v: &str| v.to_string();
    let t = || some(&rec);
    let channels: Vec<Arc<dyn Channel>> = [
        resend(ResendOptions { api_key: s(" re_secret\n"), email: email(), transport: t() }),
        postmark(PostmarkOptions {
            server_token: s("\tpm-secret "),
            email: email(),
            transport: t(),
            ..Default::default()
        }),
        sendgrid(SendgridOptions { api_key: s("SG.secret\n"), email: email(), transport: t(), ..Default::default() }),
        mailgun(MailgunOptions {
            api_key: s(" key-secret "),
            domain: s("mg.example.com"),
            email: email(),
            transport: t(),
            ..Default::default()
        }),
        datadog(DatadogOptions { api_key: s("dd-secret\n"), transport: t(), ..Default::default() }),
        honeybadger(HoneybadgerOptions { api_key: s(" hb-secret"), transport: t(), ..Default::default() }),
        rollbar(RollbarOptions { access_token: s("rb-secret \n"), transport: t(), ..Default::default() }),
        bugsnag(BugsnagOptions { api_key: s("bs-secret\n"), transport: t(), ..Default::default() }),
        newrelic(NewRelicOptions {
            account_id: s("1"),
            api_key: s(" nr-secret"),
            transport: t(),
            ..Default::default()
        }),
        sentry(SentryOptions {
            dsn: s(" https://pubkey@o1.ingest.sentry.io/42\n"),
            transport: t(),
            ..Default::default()
        }),
        twilio(TwilioOptions {
            account_sid: s(" AC1 "),
            auth_token: s("tok\n"),
            from: s("+1"),
            to: vec![s("+2")],
            transport: t(),
            ..Default::default()
        }),
        ses(SesOptions {
            region: s("us-east-1"),
            access_key_id: s(" AKIDEXAMPLE"),
            secret_access_key: s("sekret\n"),
            email: email(),
            transport: t(),
            ..Default::default()
        }),
        webhook(WebhookOptions {
            url: s("https://hooks.example.com/in"),
            headers: vec![(s("authorization"), s(" Bearer wh-secret\n"))],
            transport: t(),
            ..Default::default()
        }),
    ]
    .into_iter()
    .map(Result::unwrap)
    .collect();
    for ch in &channels {
        ch.send(&sample(), &quiet()).await.unwrap_or_else(|e| panic!("{}: {e}", ch.name()));
    }
    let got = rec.taken();
    for r in &got {
        for (name, v) in &r.headers {
            assert_eq!(v, v.trim(), "{name} has spaces around it");
        }
    }
    assert_eq!(rec.header(0, "authorization"), "Bearer re_secret");
    assert_eq!(rec.header(1, "x-postmark-server-token"), "pm-secret");
    assert_eq!(rec.header(4, "dd-api-key"), "dd-secret");
    assert!(String::from_utf8_lossy(&got[7].body).contains(r#""apiKey":"bs-secret""#));
    assert_eq!(got[10].url, "https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json");
    assert_eq!(rec.header(10, "authorization"), "Basic QUMxOnRvaw==");
    assert!(rec.header(11, "authorization").starts_with("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"));
    assert_eq!(rec.header(12, "authorization"), "Bearer wh-secret");
    let err = resend(ResendOptions { api_key: s("  "), email: email(), transport: None }).err().unwrap();
    assert_eq!(err.to_string(), "alerts::resend needs an api_key");
}

#[tokio::test]
async fn a_secret_that_straddles_the_cut_is_still_cut_out() {
    let key = ["key", "0123456789abcdef", "0123456789abcdef"].join("-")[..36].to_string();
    let rec = Recorder::new(401, &format!("{}invalid key {key}", "x".repeat(180)));
    let ch = mailgun(MailgunOptions {
        api_key: key.clone(),
        domain: "mg.example.com".into(),
        email: email(),
        transport: some(&rec),
        ..Default::default()
    })
    .unwrap();
    let err = ch.send(&sample(), &quiet()).await.unwrap_err().to_string();
    for i in 0..=key.len() - 6 {
        assert!(!err.contains(&key[i..i + 6]), "a piece of the key survives: {err}");
    }
    assert!(err.ends_with(&format!(": {}invalid key [redacte", "x".repeat(180))), "{err}");
    assert_eq!(error_body(&format!("{}\u{1F600}tail", "a".repeat(199)), &[]), "a".repeat(199));
    let cut = error_body(&format!("{}sekret{}", "y".repeat(10), "z".repeat(300)), &["sekret"]);
    assert!(cut.starts_with(&format!("{}[redacted]", "y".repeat(10))), "{cut}");
}

#[tokio::test]
async fn twilio_texts_every_number_at_once_and_reports_the_refusals() {
    let sent = Arc::new(Mutex::new(Vec::<String>::new()));
    let log = sent.clone();
    let rec = Recorder::new(201, "{}");
    *rec.answer.lock().unwrap() = Arc::new(move |body: &str| {
        let to = url::form_urlencoded::parse(body.as_bytes()).find(|(k, _)| k == "To").map(|(_, v)| v.into_owned());
        if to.as_deref() == Some("+15550000000") {
            return (400, r#"{"code":21211,"message":"Invalid To"}"#.to_string());
        }
        log.lock().unwrap().push(to.unwrap_or_default());
        (201, "{}".to_string())
    });
    let sms = twilio(TwilioOptions {
        account_sid: "AC1".into(),
        auth_token: "tok".into(),
        from: "+15551112222".into(),
        to: vec!["+15553334444".into(), "+15550000000".into()],
        transport: some(&rec),
        ..Default::default()
    })
    .unwrap();
    let clock = Arc::new(AtomicI64::new(1767225600000));
    let now = clock.clone();
    let errors = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = errors.clone();
    let cw = Client::builder()
        .clock(move || now.load(Ordering::SeqCst))
        .no_cron_secret()
        .on_error(move |e, where_| sink.lock().unwrap().push(format!("{where_}: {e}")))
        .alert(sms)
        .build()
        .unwrap();
    cw.job("nightly", JobOptions::new().schedule("0 * * * *")).unwrap();
    cw.check().await.unwrap();
    for _ in 0..6 {
        clock.fetch_add(70 * 60_000, Ordering::SeqCst);
        cw.check().await.unwrap();
    }
    assert_eq!(*sent.lock().unwrap(), vec!["+15553334444"], "one SMS for one open missed condition, never resent");
    let errors = errors.lock().unwrap().clone();
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(
        errors[0].starts_with("alert channel twilio: Twilio https://api.twilio.com answered 400: ")
            && errors[0].contains("Invalid To")
            && errors[0].ends_with(" (to ********0000; 1 of 2 numbers took the alert)"),
        "{errors:?}"
    );
    // Every number refusing it is a failure, retried at the next check.
    let rec = Recorder::new(500, "no");
    let sms = twilio(TwilioOptions {
        account_sid: "AC1".into(),
        auth_token: "tok".into(),
        from: "+1".into(),
        to: vec!["+2".into(), "+3".into()],
        transport: some(&rec),
        ..Default::default()
    })
    .unwrap();
    let err = sms.send(&sample(), &quiet()).await.unwrap_err().to_string();
    assert!(err.ends_with("(2 of 2 numbers failed)"), "{err}");
}

#[test]
fn sms_bodies_stay_inside_twilio_limits() {
    use super::twilio::{sms_body, sms_segments};
    let mut long = sample();
    long.title = "j failed".into();
    long.message = "x".repeat(3000);
    assert!(js::len16(&sms_body(&long, "", 12.0)) <= 1530, "segments capped at 10");
    assert!(js::len16(&sms_body(&long, "", f64::NAN)) <= 459, "not a number is the default 3");
    for (text, want) in [
        ("a".repeat(160), 1),
        ("a".repeat(161), 2),
        (format!("{}{{{}", "a".repeat(152), "a".repeat(152)), 3),
        ("\u{1F600}".repeat(35), 1),
        (format!("{}\u{1F600}{}", "a".repeat(66), "a".repeat(66)), 3),
    ] {
        assert_eq!(sms_segments(&text), want, "{} units", js::len16(&text));
    }
    let mut packed = sample();
    packed.title = "t".into();
    packed.message = format!("{}{{", "a".repeat(152)).repeat(3);
    assert!(sms_segments(&sms_body(&packed, "", 3.0)) <= 3);
    let mut short = sample();
    short.message = "m".into();
    assert!(js::len16(&sms_body(&short, &format!("https://example.com/{}", "p".repeat(2000)), 10.0)) <= 1600);
}

#[tokio::test]
async fn a_json_body_cut_through_a_surrogate_pair_keeps_the_lone_half() {
    let rec = Recorder::new(200, "");
    let mut a = sample();
    a.message = format!("{}\u{1F600} and on", "a".repeat(2899));
    a.triage = Some(format!("{}\u{1F600}", "b".repeat(2989)));
    let ch = slack(SlackOptions {
        webhook_url: "https://hooks.slack.example/T/B/secret".into(),
        transport: some(&rec),
        ..Default::default()
    })
    .unwrap();
    ch.send(&a, &quiet()).await.unwrap();
    let body = String::from_utf8(rec.taken()[0].body.clone()).unwrap();
    assert!(body.contains(&format!("{}\\ud83d```", "a".repeat(2899))), "{}", &body[body.len() - 80..]);
    assert!(body.contains(&format!("{}\\ud83d\"", "b".repeat(2989))));
    assert!(matches!(crate::js::parse(&body), Ok(Value::Object(_))));

    // Discord's description holds 4096 units, so the message and the triage
    // are cut at their own caps in two sends.
    let rec = Recorder::new(204, "");
    let ch = discord(DiscordOptions {
        webhook_url: "https://discord.example/api/webhooks/1/x".into(),
        transport: some(&rec),
        ..Default::default()
    })
    .unwrap();
    a.message = format!("{}\u{1F600}", "c".repeat(3799));
    a.triage = None;
    ch.send(&a, &quiet()).await.unwrap();
    a.message = "m".into();
    a.triage = Some(format!("{}\u{1F600}", "d".repeat(999)));
    ch.send(&a, &quiet()).await.unwrap();
    let taken = rec.taken();
    let body = String::from_utf8(taken[0].body.clone()).unwrap();
    assert!(body.contains(&format!("{}\\ud83d\\n```", "c".repeat(3799))), "{body}");
    let body = String::from_utf8(taken[1].body.clone()).unwrap();
    assert!(body.contains(&format!("{}\\ud83d\"", "d".repeat(999))));
}

#[test]
fn channels_need_their_options() {
    let s = |v: &str| v.to_string();
    let err = |r: Result<Arc<dyn Channel>, crate::Error>| r.err().map(|e| e.to_string()).unwrap_or_default();
    let cases = [
        ("alerts::slack needs a webhook_url", err(slack(SlackOptions::default()))),
        ("alerts::discord needs a webhook_url", err(discord(DiscordOptions::default()))),
        ("alerts::webhook needs a url", err(webhook(WebhookOptions::default()))),
        (
            "alerts::postmark needs a from address",
            err(postmark(PostmarkOptions {
                server_token: s("x"),
                email: EmailOptions { to: vec![s("d@e.f")], ..Default::default() },
                ..Default::default()
            })),
        ),
        (
            "alerts::sendgrid needs at least one to address",
            err(sendgrid(SendgridOptions {
                api_key: s("x"),
                email: EmailOptions { from: s("a@b.c"), to: vec![s(" "), s("")], ..Default::default() },
                ..Default::default()
            })),
        ),
        (
            "alerts::mailgun needs a domain",
            err(mailgun(MailgunOptions { api_key: s("x"), email: email(), ..Default::default() })),
        ),
        (
            "alerts::ses needs a region like us-east-1",
            err(ses(SesOptions { region: s("US East"), email: email(), ..Default::default() })),
        ),
        (
            "alerts::ses needs an access_key_id and secret_access_key",
            err(ses(SesOptions {
                region: s("us-east-1"),
                access_key_id: s("x"),
                email: email(),
                ..Default::default()
            })),
        ),
        (
            "alerts::twilio needs an auth_token, or an api_key_sid and api_key_secret",
            err(twilio(TwilioOptions {
                account_sid: s("AC1"),
                api_key_sid: s("SK1"),
                auth_token: s("x"),
                ..Default::default()
            })),
        ),
        (
            "alerts::twilio needs a from number or a messaging_service_sid",
            err(twilio(TwilioOptions { account_sid: s("AC1"), auth_token: s("x"), ..Default::default() })),
        ),
        (
            "alerts::twilio needs at least one to number",
            err(twilio(TwilioOptions {
                account_sid: s("AC1"),
                auth_token: s("x"),
                from: s("+1"),
                ..Default::default()
            })),
        ),
        (
            "alerts::sentry needs a dsn like https://<key>@<host>/<project>",
            err(sentry(SentryOptions { dsn: s("https://o1.ingest.sentry.io/42"), ..Default::default() })),
        ),
        (
            "alerts::newrelic needs a numeric account_id",
            err(newrelic(NewRelicOptions { api_key: s("x"), account_id: s("12a"), ..Default::default() })),
        ),
        (
            "alerts::honeybadger needs an api_key",
            err(honeybadger(HoneybadgerOptions { api_key: s("\n"), ..Default::default() })),
        ),
        ("alerts::bugsnag needs an api_key", err(bugsnag(BugsnagOptions::default()))),
        ("alerts::rollbar needs an access_token", err(rollbar(RollbarOptions::default()))),
    ];
    for (want, got) in cases {
        assert_eq!(got, want);
    }
}

#[test]
fn email_content() {
    let mut a = sample();
    a.title = "line one\r\nline two <b>".into();
    a.triage = Some("check the \"db\"".into());
    let options = EmailOptions {
        from: "a@b.c".into(),
        subject_prefix: "[prod]".into(),
        link: Some(Arc::new(|_: &Alert| "javascript:alert(1)".to_string())),
        ..Default::default()
    };
    let m = super::email::compose_email(&a, &options, &["d@e.f".to_string()]);
    assert_eq!(m.subject, "[prod] line one line two <b>");
    assert!(!m.html.contains("javascript:") && !m.text.contains("javascript:"));
    assert!(m.html.contains("line two &lt;b&gt;") && m.html.contains("check the &quot;db&quot;"));
}

#[test]
fn the_webhook_signature_is_hmac_sha256() {
    // RFC 4231's second case.
    assert_eq!(
        signature("Jefe", "what do ya want for nothing?"),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
    );
    // The vector every port's docs give for `signature`.
    assert_eq!(
        crate::alerts::signature("key", "The quick brown fox jumps over the lazy dog"),
        "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
    );
}
