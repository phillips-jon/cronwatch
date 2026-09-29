//! The one POST the alert channels and Claude triage make, as the SDK makes
//! it with fetch (`alerts/shared.ts`): the URL read as fetch reads it, only
//! http and https, headers checked as fetch checks them, one ten second
//! deadline for the whole request, a redirect refused rather than followed,
//! at most 1 MiB of an answer read, and an error that names only the URL's
//! origin, with every secret the caller holds cut out of a quoted answer
//! before it is cut to 200 characters.
//!
//! The request goes out through a [`Transport`], so an app can send it its
//! own way (a proxy, a custom root, a test's recorder); the deadline and the
//! answer's cap are this module's, whatever the transport.

use std::fmt;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use url::Url;

use crate::js;
use crate::store::{BoxError, BoxFuture};

/// How long one request may take, connecting, sending and reading the
/// answer, as the SDK's `AbortSignal.timeout(10_000)`.
pub const TIMEOUT: Duration = Duration::from_secs(10);

/// How much of an answer is read. A channel quotes 200 characters of a
/// refusal, and a compressed answer from a broken or hostile endpoint could
/// otherwise decode to far more than a process has.
pub const MAX_BODY: usize = 1 << 20;

/// How much of an answer's body goes into an error.
pub(crate) const ERROR_BODY_MAX: usize = 200;

/// One POST, as a [`Transport`] is asked to send it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    /// An http or https URL, as the WHATWG URL parser (and so fetch) writes
    /// it. Its path or query may be a credential: never quote it.
    pub url: String,
    /// The headers in the order they are sent, names as the SDK writes them
    /// (lowercase), values without the spaces and line breaks around them.
    pub headers: Vec<(String, String)>,
    /// The body: UTF-8 (JSON, a form, a Sentry envelope).
    pub body: Vec<u8>,
}

/// An answer: its status, and its body as it arrives.
pub struct Response {
    pub status: u16,
    pub body: Box<dyn ResponseBody>,
}

impl Response {
    /// An answer whose whole body is at hand.
    pub fn new(status: u16, body: impl Into<Vec<u8>>) -> Response {
        Response { status, body: Box::new(Whole(Some(body.into()))) }
    }
}

impl fmt::Debug for Response {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Response").field("status", &self.status).finish_non_exhaustive()
    }
}

/// An answer's body, read a chunk at a time, so no more of it than
/// [`MAX_BODY`] is ever read and the deadline holds while it arrives.
pub trait ResponseBody: Send {
    /// The next chunk, or `None` at the end.
    fn chunk(&mut self) -> BoxFuture<'_, Result<Option<Vec<u8>>, BoxError>>;
}

struct Whole(Option<Vec<u8>>);

impl ResponseBody for Whole {
    fn chunk(&mut self) -> BoxFuture<'_, Result<Option<Vec<u8>>, BoxError>> {
        Box::pin(std::future::ready(Ok(self.0.take())))
    }
}

/// Sends one POST and answers its status and body, whatever the status. A
/// transport must not follow redirects: a 3xx is an answer like any other,
/// and the channel fails on it, so credential headers never go where it
/// points. [`ReqwestTransport`] is the default.
///
/// The deadline and the answer's cap are enforced around the transport, so a
/// transport need not enforce them itself; its errors are rewritten so they
/// name only the URL's origin.
pub trait Transport: Send + Sync + 'static {
    fn post(&self, request: Request) -> BoxFuture<'_, Result<Response, BoxError>>;
}

/// The default transport: reqwest on rustls with the platform's roots (TLS
/// is always verified), HTTP/1.1, gzip answers decoded, and redirects
/// refused.
#[derive(Clone, Debug)]
pub struct ReqwestTransport {
    client: reqwest::Client,
}

impl ReqwestTransport {
    /// The default: a client that never follows a redirect, and keeps no
    /// idle connections. Alerts are rare, and a pooled connection belongs to
    /// the tokio runtime that opened it, so one shared transport would fail
    /// in an app with more than one runtime (the blocking client's and its
    /// own, say).
    pub fn new() -> Result<ReqwestTransport, BoxError> {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .pool_max_idle_per_host(0)
            .build()
            .map_err(|e| BoxError::from(e.without_url()))?;
        Ok(ReqwestTransport { client })
    }

    /// Sends with an app's own client (a proxy, a custom root). Build it with
    /// `redirect(reqwest::redirect::Policy::none())`: reqwest decides about
    /// redirects inside the client, so one that follows them sends the
    /// channel's credential headers wherever a redirect points.
    pub fn with_client(client: reqwest::Client) -> ReqwestTransport {
        ReqwestTransport { client }
    }
}

struct ReqwestBody(reqwest::Response);

impl ResponseBody for ReqwestBody {
    fn chunk(&mut self) -> BoxFuture<'_, Result<Option<Vec<u8>>, BoxError>> {
        Box::pin(async move {
            match self.0.chunk().await {
                Ok(chunk) => Ok(chunk.map(|b| b.to_vec())),
                Err(e) => Err(error_chain(&e.without_url()).into()),
            }
        })
    }
}

impl Transport for ReqwestTransport {
    fn post(&self, request: Request) -> BoxFuture<'_, Result<Response, BoxError>> {
        Box::pin(async move {
            let mut headers = reqwest::header::HeaderMap::new();
            for (name, value) in &request.headers {
                let name = reqwest::header::HeaderName::from_bytes(name.as_bytes())
                    .map_err(|_| format!("the {name} header's name cannot be sent"))?;
                let value = reqwest::header::HeaderValue::from_bytes(value.as_bytes())
                    .map_err(|_| format!("the {name} header's value cannot be sent"))?;
                headers.append(name, value);
            }
            let sent = self.client.post(request.url.as_str()).headers(headers).body(request.body).send().await;
            match sent {
                Ok(response) => {
                    Ok(Response { status: response.status().as_u16(), body: Box::new(ReqwestBody(response)) })
                }
                Err(e) => Err(error_chain(&e.without_url()).into()),
            }
        })
    }
}

/// An error and its sources as one line, so the reason a request had no
/// answer (a refused connection, a certificate) is not lost behind
/// reqwest's "error sending request".
fn error_chain(err: &dyn std::error::Error) -> String {
    let mut text = err.to_string();
    let mut source = err.source();
    while let Some(e) = source {
        let s = e.to_string();
        if !text.contains(&s) {
            text.push_str(": ");
            text.push_str(&s);
        }
        source = e.source();
    }
    text
}

/// The shared default transport, made once.
pub(crate) fn transport(given: &Option<Arc<dyn Transport>>) -> Result<Arc<dyn Transport>, BoxError> {
    if let Some(t) = given {
        return Ok(t.clone());
    }
    static DEFAULT: OnceLock<Result<Arc<dyn Transport>, String>> = OnceLock::new();
    DEFAULT
        .get_or_init(|| ReqwestTransport::new().map(|t| Arc::new(t) as Arc<dyn Transport>).map_err(|e| e.to_string()))
        .clone()
        .map_err(BoxError::from)
}

/// Fetch's error for a request past its deadline.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TimedOut;

impl fmt::Display for TimedOut {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("The operation was aborted due to timeout")
    }
}

impl std::error::Error for TimedOut {}

/// An error of this module's, with its message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PostError(pub(crate) String);

impl fmt::Display for PostError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PostError {}

pub(crate) fn fail(message: impl Into<String>) -> BoxError {
    Box::new(PostError(message.into()))
}

/// An answer: its status and as much of its body as was read, as
/// `response.text()` reads it (UTF-8, U+FFFD for bytes that are not, no byte
/// order mark). A body the deadline cut short is `""`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Answer {
    pub(crate) status: u16,
    pub(crate) body: String,
}

impl Answer {
    /// `response.ok`: a 2xx status.
    pub(crate) fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

/// The URL as fetch reads it, once it is one a channel can post to: http or
/// https with a host. Refused without quoting it, since a webhook URL's path
/// is its credential: "not ftp:" for another scheme, "not this URL" for
/// anything else (no URL at all, or one with a user name and password, which
/// fetch refuses to send).
pub(crate) fn postable(raw: &str) -> Result<Url, BoxError> {
    let refused = || fail("only http and https URLs can be posted to, not this URL");
    let url = Url::parse(raw).map_err(|_| refused())?;
    match url.scheme() {
        "http" | "https" => {}
        other => return Err(fail(format!("only http and https URLs can be posted to, not {other}:"))),
    }
    if !url.username().is_empty() || url.password().is_some() || url.host_str().is_none_or(str::is_empty) {
        return Err(refused());
    }
    Ok(url)
}

/// `new URL(url).origin`: the scheme, host and port only, a port that is the
/// scheme's own left out. A URL's path or query can hold a credential, so an
/// error names only this.
pub fn origin(raw: &str) -> String {
    match Url::parse(raw) {
        Ok(url) => url.origin().ascii_serialization(),
        Err(_) => "(invalid URL)".to_string(),
    }
}

/// Whether a header name is an HTTP token (RFC 9110).
fn token(name: &str) -> bool {
    !name.is_empty() && name.bytes().all(|c| c.is_ascii_alphanumeric() || b"!#$%&'*+.^_`|~-".contains(&c))
}

/// The headers as a request sends them: each name a token, each value
/// without the spaces, tabs and line breaks around it, as fetch sends it. A
/// name that is not a token, or a value with a line break or NUL inside, is
/// refused, as fetch refuses them, so no header can add another; the error
/// names the header, never its value, which may be a credential.
pub(crate) fn headers(list: &[(&str, String)]) -> Result<Vec<(String, String)>, BoxError> {
    let mut out = Vec::with_capacity(list.len());
    for (name, value) in list {
        if !token(name) {
            return Err(fail("a header name must be a token (letters, digits and !#$%&'*+.^_`|~-)"));
        }
        let value = value.trim_matches([' ', '\t', '\r', '\n']);
        if value.contains(['\r', '\n', '\0']) {
            return Err(fail(format!("the {name} header's value may not contain a line break")));
        }
        out.push((name.to_string(), value.to_string()));
    }
    Ok(out)
}

/// Bytes as `response.text()` reads them.
pub(crate) fn text(data: &[u8]) -> String {
    let s = String::from_utf8_lossy(data);
    s.strip_prefix('\u{feff}').unwrap_or(&s).to_string()
}

/// Posts `body` to `raw_url` through `transport` within `within`, and answers
/// whatever the status. An error is a request that could not be made or had
/// no answer: the URL or a header refused, [`TimedOut`] past the deadline, or
/// the transport's own error, naming no more of the URL than its origin.
pub(crate) async fn fetch(
    transport: &dyn Transport,
    within: Duration,
    raw_url: &str,
    list: &[(&str, String)],
    body: Vec<u8>,
) -> Result<Answer, BoxError> {
    let url = postable(raw_url)?;
    let headers = headers(list)?;
    let deadline = tokio::time::Instant::now() + within;
    let request = Request { url: url.as_str().to_string(), headers, body };
    let response = match tokio::time::timeout_at(deadline, transport.post(request)).await {
        Err(_) => return Err(Box::new(TimedOut)),
        Ok(Err(e)) => return Err(without_url(&e.to_string(), raw_url, &url)),
        Ok(Ok(response)) => response,
    };
    let status = response.status;
    let mut body = response.body;
    let mut data = Vec::new();
    loop {
        match tokio::time::timeout_at(deadline, body.chunk()).await {
            Ok(Ok(Some(chunk))) => {
                let room = MAX_BODY - data.len();
                data.extend_from_slice(&chunk[..chunk.len().min(room)]);
                if data.len() >= MAX_BODY {
                    break;
                }
            }
            Ok(Ok(None)) => break,
            // A body the deadline cut short, or one that could not be read, is
            // treated as the SDK treats a body it could not read.
            _ => return Ok(Answer { status, body: String::new() }),
        }
    }
    Ok(Answer { status, body: text(&data) })
}

/// A transport's error as `<origin>: <text>`, with every spelling of the URL
/// in its text written as the origin, and the path and query cut out.
fn without_url(text: &str, raw: &str, url: &Url) -> BoxError {
    let origin = url.origin().ascii_serialization();
    let mut out = text.to_string();
    let with_slash = format!("{origin}/");
    for s in [raw.trim(), url.as_str()] {
        if !s.is_empty() && s != origin && s != with_slash {
            out = out.replace(s, &origin);
        }
    }
    let path = url.path();
    let query = url.query().unwrap_or("");
    let request_uri = if query.is_empty() { path.to_string() } else { format!("{path}?{query}") };
    let decoded = percent_decode(path);
    for s in [request_uri.as_str(), path, decoded.as_str(), query] {
        if s.len() > 1 {
            out = out.replace(s, "");
        }
    }
    fail(format!("{origin}: {out}"))
}

/// `%XX` decoded, lossily, for finding a decoded path in an error's text.
pub(crate) fn percent_decode(text: &str) -> String {
    let b = text.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push((h << 4) | l);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(c: u8) -> Option<u8> {
    (c as char).to_digit(16).map(|d| d as u8)
}

/// At most `max` UTF-16 code units of text, never half a surrogate pair
/// (shared.ts's cut).
pub(crate) fn cut(text: &str, max: usize) -> String {
    if js::len16(text) <= max {
        return text.to_string();
    }
    let mut n = 0;
    let mut end = 0;
    for (i, c) in text.char_indices() {
        if n + c.len_utf16() > max {
            break;
        }
        n += c.len_utf16();
        end = i + c.len_utf8();
    }
    text[..end].to_string()
}

/// The start of an error body: every secret of four or more characters cut
/// out of a prefix long enough to hold one that starts inside the first 200
/// characters, and only then cut to that length, so no part of a secret
/// survives at the edge.
pub(crate) fn error_body(text: &str, secrets: &[&str]) -> String {
    let kept: Vec<&str> = secrets.iter().copied().filter(|s| js::len16(s) >= 4).collect();
    let longest = kept.iter().map(|s| js::len16(s)).max().unwrap_or(0);
    let mut head = cut(text, ERROR_BODY_MAX + longest);
    for s in kept {
        head = head.replace(s, "[redacted]");
    }
    cut(&head, ERROR_BODY_MAX)
}

/// The error for an answer outside 2xx: `<provider> <origin> answered
/// <status>: <body>`, the body's secrets cut out.
pub(crate) fn refused(provider: &str, raw_url: &str, answer: &Answer, secrets: &[&str]) -> BoxError {
    let mut text = format!("{provider} {} answered {}", origin(raw_url), answer.status);
    if !answer.body.is_empty() {
        text.push_str(": ");
        text.push_str(&error_body(&answer.body, secrets));
    }
    fail(text)
}

/// [`fetch`] within [`TIMEOUT`] that fails on an answer outside 2xx.
#[cfg(feature = "alerts")]
pub(crate) async fn post(
    transport: &dyn Transport,
    provider: &str,
    raw_url: &str,
    list: &[(&str, String)],
    body: Vec<u8>,
    secrets: &[&str],
) -> Result<Answer, BoxError> {
    let answer = fetch(transport, TIMEOUT, raw_url, list, body).await?;
    if !answer.ok() {
        return Err(refused(provider, raw_url, &answer, secrets));
    }
    Ok(answer)
}
