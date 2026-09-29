//! The `tower` feature: [`Routes`] and [`Handler`] as
//! `tower::Service<http::Request<B>>` for any `B: http_body::Body`,
//! answering `http::Response<Full<Bytes>>`. That is what hyper serves, what
//! axum mounts with `nest_service`, what tonic and most Rust HTTP stacks
//! accept, and what `lambda_http::run` takes, so AWS Lambda needs no code
//! of the crate's own. With the `axum` feature, a dashboard nested in an
//! axum `Router` finds its base path from the mount (axum's `NestedPath`
//! and `OriginalUri`), and [`Routes::into_router`] nests it.

use std::any::Any;
use std::convert::Infallible;
use std::task::{Context, Poll};

use bytes::{Buf, Bytes};
use http_body::Body as HttpBody;
use http_body_util::{BodyExt, Empty, Full};

use crate::handler::Handler;
use crate::store::{BoxError, BoxFuture};

use super::{Body, Request, Response, Routes};

/// An `http::Request` as the framework-free [`Request`]: the target as sent
/// (the original one, when axum nested the service), the headers as bytes,
/// `Host` from the URI's authority for HTTP/2, and a body read only when a
/// route wants it.
pub(crate) fn from_http<B>(req: http::Request<B>) -> Request
where
    B: HttpBody + Send + 'static,
    B::Data: Send,
    B::Error: Into<BoxError>,
{
    let (parts, body) = req.into_parts();
    #[cfg(feature = "axum")]
    let (target, mount) = match nested(&parts) {
        Some((target, mount)) => (target, Some(mount)),
        None => (target_of(&parts.uri), None),
    };
    #[cfg(not(feature = "axum"))]
    let (target, mount): (String, Option<String>) = (target_of(&parts.uri), None);
    let mut out = Request::new(parts.method.as_str(), target);
    out.mount = mount;
    out.tls = parts.uri.scheme() == Some(&http::uri::Scheme::HTTPS);
    for (name, value) in &parts.headers {
        out.headers.push((name.as_str().to_string(), value.as_bytes().to_vec()));
    }
    if !parts.headers.contains_key(http::header::HOST) {
        if let Some(authority) = parts.uri.authority() {
            out.headers.push(("host".into(), authority.as_str().as_bytes().to_vec()));
        }
    }
    let length = parts
        .headers
        .get(http::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok())
        .or_else(|| body.size_hint().exact());
    if length == Some(0) && body.is_end_stream() {
        return out;
    }
    out.body = Body::lazy(length, move |limit| read_body(body, limit));
    out
}

/// Reads a body to its end, or until more than `limit` bytes have arrived.
async fn read_body<B>(body: B, limit: usize) -> Result<Vec<u8>, BoxError>
where
    B: HttpBody,
    B::Error: Into<BoxError>,
{
    let mut body = std::pin::pin!(body);
    let mut out = Vec::new();
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(Into::into)?;
        let Ok(mut data) = frame.into_data() else {
            continue;
        };
        while data.has_remaining() {
            let chunk = data.chunk();
            out.extend_from_slice(chunk);
            let n = chunk.len();
            data.advance(n);
        }
        if out.len() > limit {
            break;
        }
    }
    Ok(out)
}

fn target_of(uri: &http::Uri) -> String {
    uri.path_and_query().map_or_else(|| "/".to_string(), |pq| pq.as_str().to_string())
}

/// For a service axum nested: the target the client sent, and where axum
/// mounted the service, which is the sent path less the path axum passed
/// on. `None` when the service was not nested.
#[cfg(feature = "axum")]
fn nested(parts: &http::request::Parts) -> Option<(String, String)> {
    parts.extensions.get::<axum::extract::NestedPath>()?;
    let original = &parts.extensions.get::<axum::extract::OriginalUri>()?.0;
    let full = original.path();
    let rest = parts.uri.path();
    let mount = if rest != full && full.ends_with(rest) {
        &full[..full.len() - rest.len()]
    } else if rest == "/" {
        full
    } else {
        return None;
    };
    Some((target_of(original), mount.trim_end_matches('/').to_string()))
}

/// A [`Response`] as an `http::Response`. A header value HTTP cannot carry
/// is left out.
pub(crate) fn to_http(res: Response) -> http::Response<Full<Bytes>> {
    let mut out = http::Response::new(Full::new(Bytes::from(res.body)));
    *out.status_mut() = http::StatusCode::from_u16(res.status).unwrap_or(http::StatusCode::INTERNAL_SERVER_ERROR);
    let headers = out.headers_mut();
    for (name, value) in res.headers {
        if let (Ok(name), Ok(value)) =
            (http::HeaderName::from_bytes(name.as_bytes()), http::HeaderValue::from_bytes(&value))
        {
            headers.append(name, value);
        }
    }
    out
}

macro_rules! each_body {
    ($m:ident) => {
        $m!(Full<Bytes>);
        $m!(String);
        $m!(Vec<u8>);
        $m!(Bytes);
        $m!(&'static str);
        $m!(());
        $m!(Empty<Bytes>);
    };
}

/// The status of an `http::Response` a job returned, for a body type the
/// adapter knows.
pub(crate) fn http_status_of(value: &dyn Any) -> Option<u16> {
    macro_rules! try_body {
        ($b:ty) => {
            if let Some(r) = value.downcast_ref::<http::Response<$b>>() {
                return Some(r.status().as_u16());
            }
        };
    }
    each_body!(try_body);
    None
}

/// An `http::Response` a job's handler returned, as its answer, for a body
/// type the adapter knows.
pub(crate) async fn tower_answer(value: Box<dyn Any + Send>) -> Option<Response> {
    async fn convert<B>(r: http::Response<B>) -> Response
    where
        B: HttpBody,
        B::Error: std::fmt::Debug,
    {
        let (parts, body) = r.into_parts();
        let body = match body.collect().await {
            Ok(collected) => collected.to_bytes().to_vec(),
            Err(_) => Vec::new(),
        };
        Response {
            status: parts.status.as_u16(),
            headers: parts
                .headers
                .iter()
                .filter(|(n, _)| *n != http::header::CONTENT_LENGTH && *n != http::header::TRANSFER_ENCODING)
                .map(|(n, v)| (n.as_str().to_string(), v.as_bytes().to_vec()))
                .collect(),
            body,
        }
    }
    let mut value = value;
    macro_rules! try_body {
        ($b:ty) => {
            value = match value.downcast::<http::Response<$b>>() {
                Ok(r) => return Some(convert(*r).await),
                Err(v) => v,
            };
        };
    }
    try_body!(Full<Bytes>);
    try_body!(Empty<Bytes>);
    macro_rules! try_plain {
        ($b:ty) => {
            value = match value.downcast::<http::Response<$b>>() {
                Ok(r) => return Some(convert(r.map(|b| Full::new(Bytes::from(b)))).await),
                Err(v) => v,
            };
        };
    }
    try_plain!(String);
    try_plain!(Bytes);
    try_plain!(Vec<u8>);
    try_plain!(&'static str);
    if let Ok(r) = value.downcast::<http::Response<()>>() {
        return Some(convert(r.map(|()| Empty::<Bytes>::new())).await);
    }
    None
}

impl<B> tower_service::Service<http::Request<B>> for Routes
where
    B: HttpBody + Send + 'static,
    B::Data: Send,
    B::Error: Into<BoxError>,
{
    type Response = http::Response<Full<Bytes>>;
    type Error = Infallible;
    type Future = BoxFuture<'static, Result<Self::Response, Infallible>>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), Infallible>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, req: http::Request<B>) -> Self::Future {
        let routes = self.clone();
        let req = from_http(req);
        Box::pin(async move { Ok(to_http(routes.handle(req).await)) })
    }
}

impl<B> tower_service::Service<http::Request<B>> for Handler
where
    B: HttpBody + Send + 'static,
    B::Data: Send,
    B::Error: Into<BoxError>,
{
    type Response = http::Response<Full<Bytes>>;
    type Error = Infallible;
    type Future = BoxFuture<'static, Result<Self::Response, Infallible>>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), Infallible>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, req: http::Request<B>) -> Self::Future {
        let handler = self.clone();
        let req = from_http(req);
        Box::pin(async move { Ok(to_http(handler.handle(req).await)) })
    }
}

#[cfg(feature = "axum")]
impl Routes {
    /// An axum `Router` with the dashboard nested at its base path (the
    /// configured one, else `/cronwatch`), to merge into the app's own:
    /// `app.merge(routes.into_router())`. Nesting it yourself works the same:
    /// `Router::new().nest_service("/ops/cron", routes)` finds `/ops/cron`
    /// from the mount.
    pub fn into_router<S>(self) -> axum::Router<S>
    where
        S: Clone + Send + Sync + 'static,
    {
        let base = self.inner_base().unwrap_or(super::routes::DEFAULT_BASE_PATH).to_string();
        if base.is_empty() {
            return axum::Router::new().fallback_service(self);
        }
        axum::Router::new().nest_service(&base, self)
    }
}
