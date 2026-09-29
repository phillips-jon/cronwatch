//! The dashboard and its JSON API, framework-free: [`Routes::handle`] and
//! [`Handler::handle`](crate::Handler::handle) take a plain [`Request`] and
//! answer a plain [`Response`], as the SDK's routes take a fetch `Request`.
//! Everything a framework adds is an adapter over those two functions: the
//! `tower` feature makes both a `tower::Service` (for hyper, axum, tonic and
//! `lambda_http`), and the `axum` feature finds where they are mounted.
//!
//! A framework this crate has no adapter for builds a [`Request`] from its
//! own (the method, the request target as sent, the headers, the body,
//! whether it came over TLS) and writes the [`Response`] back.

mod html;
mod origin;
mod pwa;
mod request;
mod routes;
mod text;
mod timeline;

#[cfg(feature = "tower")]
mod adapter;

use std::borrow::Cow;
use std::fmt;
use std::future::Future;

use crate::store::{BoxError, BoxFuture};

pub use routes::{DEFAULT_BASE_PATH, Routes, RoutesOptions};

#[cfg(feature = "tower")]
pub(crate) use adapter::tower_answer;
pub(crate) use text::{constant_time_eq, latin1};

/// The most of a request body the dashboard reads: its forms and JSON are a
/// few bytes. A body past it is answered 413; the SDK leaves this to the
/// server in front of it.
pub const MAX_BODY: usize = 1 << 20;

/// A request, as a server hands it over: the method, the request target as
/// sent (so a `%2F` in a job name stays one), the headers as bytes, the body
/// and whether it came over TLS.
///
/// ```
/// use cronwatch::web::Request;
///
/// let request = Request::new("POST", "/cronwatch/api/check")
///     .with_header("host", "app.example.com")
///     .with_header("authorization", "Bearer tok")
///     .with_tls(true);
/// assert_eq!(request.method(), "POST");
/// ```
pub struct Request {
    pub(crate) method: String,
    pub(crate) target: String,
    pub(crate) headers: Vec<(String, Vec<u8>)>,
    pub(crate) body: Body,
    pub(crate) tls: bool,
    pub(crate) mount: Option<String>,
}

/// Header values and the query are left out: a request can carry the
/// dashboard's token in either (`?token=`, `Authorization`, the cookie).
impl fmt::Debug for Request {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let path = match self.target.split_once('?') {
            Some((path, _)) => format!("{path}?..."),
            None => self.target.clone(),
        };
        f.debug_struct("Request")
            .field("method", &self.method)
            .field("target", &path)
            .field("headers", &self.headers.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>())
            .field("tls", &self.tls)
            .finish_non_exhaustive()
    }
}

impl Request {
    /// A request with no headers and no body. `target` is the request target
    /// as sent: the path and query (`/cronwatch/api/jobs?runs=5`), or the
    /// absolute form a proxy is sent.
    pub fn new(method: impl Into<String>, target: impl Into<String>) -> Request {
        Request {
            method: method.into(),
            target: target.into(),
            headers: Vec::new(),
            body: Body::empty(),
            tls: false,
            mount: None,
        }
    }

    /// Adds a header. A name sent more than once is read as fetch's
    /// `Headers.get` reads it: the values joined with `, ` (a cookie's with
    /// `; `). `Host` gives the request's origin.
    pub fn with_header(mut self, name: impl Into<String>, value: impl AsRef<[u8]>) -> Request {
        self.headers.push((name.into().to_ascii_lowercase(), value.as_ref().to_vec()));
        self
    }

    /// Sets the body.
    pub fn with_body(mut self, body: impl Into<Body>) -> Request {
        self.body = body.into();
        self
    }

    /// Whether the request came over TLS, which makes its origin https.
    pub fn with_tls(mut self, tls: bool) -> Request {
        self.tls = tls;
        self
    }

    /// Where the dashboard is mounted, for an adapter that knows (the `axum`
    /// feature reads it from the router). [`RoutesOptions::base_path`] wins
    /// over it.
    pub fn with_mount(mut self, base: impl Into<String>) -> Request {
        self.mount = Some(base.into());
        self
    }

    /// The method.
    pub fn method(&self) -> &str {
        &self.method
    }

    /// The request target as sent.
    pub fn target(&self) -> &str {
        &self.target
    }

    /// A header as fetch's `Headers.get` gives it, or `None`.
    pub fn header(&self, name: &str) -> Option<Cow<'_, [u8]>> {
        request::header(self, name)
    }

    /// Every header, in the order given, names lowercase.
    pub fn headers(&self) -> impl Iterator<Item = (&str, &[u8])> {
        self.headers.iter().map(|(n, v)| (n.as_str(), v.as_slice()))
    }

    /// Whether the request came over TLS.
    pub fn is_tls(&self) -> bool {
        self.tls
    }

    /// Takes the body, leaving an empty one.
    pub fn take_body(&mut self) -> Body {
        std::mem::replace(&mut self.body, Body::empty())
    }
}

type ReadBody = Box<dyn FnOnce(usize) -> BoxFuture<'static, Result<Vec<u8>, BoxError>> + Send>;

/// A request body: bytes already read, or a body read only when a route
/// wants it (the `tower` adapter's), so a request refused for want of the
/// token is never read.
#[derive(Default)]
pub struct Body(BodyInner);

#[derive(Default)]
enum BodyInner {
    #[default]
    Empty,
    Bytes(Vec<u8>),
    Lazy {
        length: Option<u64>,
        // In a mutex, so a request is Sync and a future holding one is Send.
        read: std::sync::Mutex<Option<ReadBody>>,
    },
}

impl fmt::Debug for Body {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.0 {
            BodyInner::Empty => f.write_str("Body(empty)"),
            BodyInner::Bytes(b) => write!(f, "Body({} bytes)", b.len()),
            BodyInner::Lazy { length, .. } => write!(f, "Body(unread, length {length:?})"),
        }
    }
}

/// Why a body could not be read.
#[derive(Debug)]
pub enum BodyError {
    /// The body is longer than the limit it was read with.
    TooLarge,
    /// The body could not be read to its end: the client went away, a read
    /// deadline passed.
    Failed(BoxError),
}

impl fmt::Display for BodyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BodyError::TooLarge => f.write_str("the request body is too large"),
            BodyError::Failed(e) => write!(f, "the request body could not be read: {e}"),
        }
    }
}

impl std::error::Error for BodyError {}

impl Body {
    /// No body.
    pub fn empty() -> Body {
        Body(BodyInner::Empty)
    }

    /// A body read only when it is wanted: `read(limit)` reads it, and may
    /// stop once more than `limit` bytes have arrived. `length` is its
    /// `Content-Length`, when known, so a body past a limit is refused
    /// without reading it.
    pub fn lazy<F, Fut>(length: Option<u64>, read: F) -> Body
    where
        F: FnOnce(usize) -> Fut + Send + 'static,
        Fut: Future<Output = Result<Vec<u8>, BoxError>> + Send + 'static,
    {
        let read: ReadBody = Box::new(move |limit| Box::pin(read(limit)));
        Body(BodyInner::Lazy { length, read: std::sync::Mutex::new(Some(read)) })
    }

    /// Its length, when known.
    pub fn length(&self) -> Option<u64> {
        match &self.0 {
            BodyInner::Empty => Some(0),
            BodyInner::Bytes(b) => Some(b.len() as u64),
            BodyInner::Lazy { length, .. } => *length,
        }
    }

    /// Reads the body, refusing one longer than `limit` bytes.
    pub async fn read(self, limit: usize) -> Result<Vec<u8>, BodyError> {
        if self.length().is_some_and(|n| n > limit as u64) {
            return Err(BodyError::TooLarge);
        }
        let data = match self.0 {
            BodyInner::Empty => Vec::new(),
            BodyInner::Bytes(b) => b,
            BodyInner::Lazy { read, .. } => {
                let read = read.into_inner().unwrap_or_else(std::sync::PoisonError::into_inner);
                match read {
                    Some(read) => read(limit).await.map_err(BodyError::Failed)?,
                    None => Vec::new(),
                }
            }
        };
        if data.len() > limit {
            return Err(BodyError::TooLarge);
        }
        Ok(data)
    }
}

impl From<Vec<u8>> for Body {
    fn from(b: Vec<u8>) -> Body {
        Body(BodyInner::Bytes(b))
    }
}

impl From<&[u8]> for Body {
    fn from(b: &[u8]) -> Body {
        Body(BodyInner::Bytes(b.to_vec()))
    }
}

impl From<String> for Body {
    fn from(s: String) -> Body {
        Body(BodyInner::Bytes(s.into_bytes()))
    }
}

impl From<&str> for Body {
    fn from(s: &str) -> Body {
        Body(BodyInner::Bytes(s.as_bytes().to_vec()))
    }
}

/// An answer: a status, headers in order (names lowercase, as fetch and
/// HTTP/2 write them) and a body. The dashboard's never carry a
/// `Content-Length`; the server in front adds it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, Vec<u8>)>,
    pub body: Vec<u8>,
}

impl Response {
    /// An answer with this status, no headers and no body.
    pub fn new(status: u16) -> Response {
        Response { status, headers: Vec::new(), body: Vec::new() }
    }

    /// Adds a header.
    pub fn with_header(mut self, name: impl Into<String>, value: impl AsRef<[u8]>) -> Response {
        self.headers.push((name.into().to_ascii_lowercase(), value.as_ref().to_vec()));
        self
    }

    /// Sets the body.
    pub fn with_body(mut self, body: impl Into<Vec<u8>>) -> Response {
        self.body = body.into();
        self
    }

    /// The first value of a header, or `None`.
    pub fn header(&self, name: &str) -> Option<&[u8]> {
        self.headers.iter().find(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_slice())
    }

    /// The first value of a header as text, or `None` when it is absent or
    /// not UTF-8.
    pub fn header_str(&self, name: &str) -> Option<&str> {
        self.header(name).and_then(|v| std::str::from_utf8(v).ok())
    }

    /// The body as text, with anything not UTF-8 replaced.
    pub fn text(&self) -> Cow<'_, str> {
        String::from_utf8_lossy(&self.body)
    }
}

/// The reason phrase HTTP gives a status, or `""` for one it names none.
pub(crate) fn reason_phrase(status: u16) -> &'static str {
    match status {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        407 => "Proxy Authentication Required",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        418 => "I'm a teapot",
        421 => "Misdirected Request",
        422 => "Unprocessable Content",
        423 => "Locked",
        424 => "Failed Dependency",
        425 => "Too Early",
        426 => "Upgrade Required",
        428 => "Precondition Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        451 => "Unavailable For Legal Reasons",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        506 => "Variant Also Negotiates",
        507 => "Insufficient Storage",
        508 => "Loop Detected",
        510 => "Not Extended",
        511 => "Network Authentication Required",
        _ => "",
    }
}

/// The error an HTTP answer of 400 or more fails a run with, as the SDK
/// fails one for a fetch `Response`: `HTTP <status> <reason>`.
pub(crate) fn http_failure_text(status: u16) -> Option<String> {
    if status < 400 {
        return None;
    }
    let reason = reason_phrase(status);
    Some(if reason.is_empty() { format!("HTTP {status}") } else { format!("HTTP {status} {reason}") })
}

/// The status of a value a job returned when it is an HTTP answer: a
/// [`Response`], or with the `tower` feature an `http::Response` of a body
/// the adapter knows.
pub(crate) fn status_of(value: &dyn std::any::Any) -> Option<u16> {
    if let Some(r) = value.downcast_ref::<Response>() {
        return Some(r.status);
    }
    #[cfg(feature = "tower")]
    if let Some(status) = adapter::http_status_of(value) {
        return Some(status);
    }
    None
}
