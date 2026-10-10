//! The dashboard and its small JSON API (routes/index.ts), carried over
//! from the Go port's `routes.go`: the same URLs, JSON, status codes,
//! headers, cookie, redirects, cross-site rule, and token rules as the SDK's
//! routes, so `@cronwatch/mcp` works against a Rust app as it does against
//! a Node one.

use std::collections::HashMap;
use std::fmt;
use std::io::Write;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use sha2::{Digest, Sha256};

use crate::JobWithRuns;
use crate::client::Client;
use crate::env::environment;
use crate::error::Error;
use crate::evaluate::js_number;
use crate::js::{self, Object, Value};
use crate::panics::panic_text;
use crate::run::CatchUnwind;
use crate::schedule::parse_duration;
use crate::types::{JobSummary, Run};

use super::html::{dashboard_page, job_page, message_page};
use super::origin::{bare_origin, configured_origin, is_loopback_origin, request_origin};
use super::pwa::{ShellAsset, static_asset};
use super::request::{
    body_field, form_encode, header, normalize_path, param, parse_form, read_limited, request_target, safe_decode,
    strip_base,
};
use super::text::{constant_time_eq, latin1};
use super::timeline::{BOARD_BEHIND_MS, BOARD_LANES, BOARD_RUNS, LaneInput, week_runs_limit};
use super::{Request, Response};

const TOKEN_COOKIE: &str = "cronwatch_token";
/// Runs a JSON job read lists by default, and at most.
const DEFAULT_RUNS: usize = 20;
const MAX_RUNS: f64 = 500.0;
/// Runs per job the board reads in one go: the table's sparkline, and most
/// jobs' lanes.
const BOARD_PAGE_RUNS: usize = 20;
const COOKIE_MAX_AGE: u32 = 60 * 60 * 24 * 30;
/// Where the dashboard is taken to be mounted when nothing else says: not
/// [`RoutesOptions::base_path`], not the `axum` feature's mount.
pub const DEFAULT_BASE_PATH: &str = "/cronwatch";

// 'self' only for what the app shell needs: app.js (which registers the
// service worker and the theme toggle), the manifest, the worker, and the icons.
// No inline script, and the pages work without any.
const PAGE_CSP: &str = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";
const ASSET_CSP: &str = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'";

/// On every answer. same-origin rather than no-referrer: under no-referrer
/// browsers send `Origin: null` on form posts, which the cross-site check
/// would refuse, and the forms redirect back to the page named by the
/// same-origin Referer.
const SECURITY_HEADERS: [(&str, &str); 3] =
    [("x-content-type-options", "nosniff"), ("referrer-policy", "same-origin"), ("x-robots-tag", "noindex")];

/// How [`Client::routes`] serves the dashboard: the SDK's `RoutesOptions`,
/// with Rust's three ways for the token.
#[derive(Clone, Default)]
pub struct RoutesOptions {
    token: Option<Option<String>>,
    base_path: Option<String>,
    origin: Option<String>,
    trust_proxy: bool,
}

/// Says whether a token is set, never the token.
impl fmt::Debug for RoutesOptions {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let token = match &self.token {
            None => "CRONWATCH_TOKEN",
            Some(None) => "none",
            Some(Some(_)) => "set",
        };
        f.debug_struct("RoutesOptions")
            .field("token", &token)
            .field("base_path", &self.base_path)
            .field("origin", &self.origin)
            .field("trust_proxy", &self.trust_proxy)
            .finish()
    }
}

impl RoutesOptions {
    /// The defaults: the token from `CRONWATCH_TOKEN`, mounted at
    /// `/cronwatch` (or where the `axum` feature finds it), the request's own
    /// origin.
    pub fn new() -> Self {
        Self::default()
    }

    /// The token the dashboard asks for. Send it as
    /// `Authorization: Bearer <token>`, or open the dashboard once with
    /// `?token=<token>`, or enter it in the sign-in page's form, and a
    /// cookie is set. Without it the token is `CRONWATCH_TOKEN`; an empty
    /// string, or one of only whitespace, given here or in the variable,
    /// counts as unset. With no token in development
    /// (`CRONWATCH_ENV`, `APP_ENV`, or `RUST_ENV` naming it), the routes make
    /// a random one and print a sign-in link to standard output on their
    /// first request; with no token otherwise they answer 503. `/api/check`
    /// also takes the client's cron secret as a bearer, so a platform cron
    /// can run checks without the token.
    pub fn token(mut self, token: impl Into<String>) -> Self {
        self.token = Some(Some(token.into()));
        self
    }

    /// Serves the dashboard to anyone, everywhere, for one behind the app's
    /// own auth (the SDK's `token: null`).
    pub fn no_token(mut self) -> Self {
        self.token = Some(None);
        self
    }

    /// Where the dashboard is mounted (`""` for the root), so its links
    /// resolve. Without it the base is where the `axum` feature finds the
    /// dashboard nested, else `/cronwatch`.
    pub fn base_path(mut self, path: impl Into<String>) -> Self {
        self.base_path = Some(path.into());
        self
    }

    /// The public origin the dashboard is served from, such as
    /// `https://app.example.com`, for an app behind a proxy whose requests
    /// carry an internal host or scheme. It stands in for the request's own
    /// origin in the cross-site check on writes, the sign-in cookie's
    /// `Secure` flag, the Referer the redirect back after a form follows, and
    /// the development sign-in line. Anything that is not an http or https
    /// URL is an error from [`Client::routes`]. It takes precedence over
    /// [`trust_proxy`](Self::trust_proxy).
    pub fn origin(mut self, origin: impl Into<String>) -> Self {
        self.origin = Some(origin.into());
        self
    }

    /// Takes the public origin from `X-Forwarded-Proto` and
    /// `X-Forwarded-Host` (the first value of each, the request's own scheme
    /// or host for whichever is missing) when a request carries either. Only
    /// for an app whose proxy sets or overwrites both headers: a client can
    /// send them too.
    pub fn trust_proxy(mut self) -> Self {
        self.trust_proxy = true;
        self
    }
}

/// The dashboard and its JSON API, made by [`Client::routes`]. Cheap to
/// clone. [`handle`](Self::handle) answers one request; with the `tower`
/// feature it is a `tower::Service` too.
#[derive(Clone)]
pub struct Routes {
    inner: Arc<RoutesInner>,
}

struct RoutesInner {
    client: Client,
    opted_out: bool,
    token: String,
    generated: bool,
    cookie: String,
    base: Option<String>,
    origin: Option<String>,
    trust_proxy: bool,
    announced: AtomicBool,
}

impl fmt::Debug for Routes {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Routes")
            .field("base", &self.inner.base)
            .field("origin", &self.inner.origin)
            .finish_non_exhaustive()
    }
}

impl Client {
    /// The dashboard and its JSON API, the SDK's `cw.routes()`. The error is
    /// for an [`origin`](RoutesOptions::origin) that is not an http or https
    /// URL.
    ///
    /// ```no_run
    /// # async fn example(cw: cronwatch::Client) -> Result<(), cronwatch::Error> {
    /// use cronwatch::web::{Request, RoutesOptions};
    ///
    /// let routes = cw.routes(RoutesOptions::new().token("a-long-random-token"))?;
    /// let answer = routes.handle(Request::new("GET", "/cronwatch/api/jobs").with_header("host", "app.example.com")).await;
    /// assert_eq!(answer.status, 401);
    /// # Ok(())
    /// # }
    /// ```
    pub fn routes(&self, options: RoutesOptions) -> Result<Routes, Error> {
        let origin = configured_origin(options.origin.as_deref().unwrap_or("")).map_err(Error::Invalid)?;
        let opted_out = options.token == Some(None);
        // A blank token (empty or only whitespace), given or read, counts as
        // unset; any other is used as it is, untrimmed.
        let configured = match options.token {
            Some(None) => String::new(),
            Some(Some(t)) if !crate::env::is_blank(&t) => t,
            _ => crate::env::secret_var("CRONWATCH_TOKEN").unwrap_or_default(),
        };
        // A handler cannot tell a local caller from a remote one (proxies,
        // tunnels, and a server listening on every interface all look alike),
        // so development gets a token too: made here, and shown only in the
        // log.
        let generated = configured.is_empty() && !opted_out && environment() == "development";
        let token = if generated { development_token() } else { configured };
        // Without the system's randomness no token was made, so there is
        // nothing to announce and the routes stay locked.
        let generated = generated && !token.is_empty();
        let cookie =
            if token.is_empty() { String::new() } else { hex(&Sha256::digest(format!("cronwatch-cookie:{token}"))) };
        Ok(Routes {
            inner: Arc::new(RoutesInner {
                client: self.clone(),
                opted_out,
                token,
                generated,
                cookie,
                base: options.base_path.map(|p| p.trim_end_matches('/').to_string()),
                origin,
                trust_proxy: options.trust_proxy,
                announced: AtomicBool::new(false),
            }),
        })
    }
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 15) as usize] as char);
    }
    out
}

/// 32 random bytes, base64url (43 characters).
fn development_token() -> String {
    let mut b = [0u8; 32];
    if getrandom::fill(&mut b).is_err() {
        // No system randomness: a token nobody can guess cannot be made, so
        // make one nobody can use either.
        return String::new();
    }
    base64url(&b)
}

fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        let chars = chunk.len() + 1;
        for i in 0..chars {
            out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    out
}

/// The line a development token is announced with, once, on the routes'
/// first request. `origin` is the configured origin when set, otherwise
/// that request's public origin when its host is loopback, and `None` for
/// any other host: the request's host is the client's to choose, so the
/// line then leaves it out rather than point the link, token and all,
/// somewhere else. `base` is the base path without a trailing slash.
fn development_sign_in_line(origin: Option<&str>, base: &str, token: &str) -> String {
    const INTRO: &str =
        "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: ";
    match origin {
        None => format!(
            "{INTRO}{base}/?token={token} on this server (the first request's host is not local, so the link leaves it out)"
        ),
        Some(origin) => format!("{INTRO}{origin}{base}/?token={token}"),
    }
}

fn with_security(mut headers: Vec<(String, Vec<u8>)>) -> Vec<(String, Vec<u8>)> {
    headers.extend(SECURITY_HEADERS.iter().map(|(k, v)| ((*k).to_string(), v.as_bytes().to_vec())));
    headers
}

fn pair(k: &str, v: impl AsRef<[u8]>) -> (String, Vec<u8>) {
    (k.to_string(), v.as_ref().to_vec())
}

/// A JSON answer with the security headers.
pub(crate) fn api(body: Object, status: u16) -> Response {
    api_with(body, status, Vec::new())
}

fn api_with(body: Object, status: u16, extra: Vec<(String, Vec<u8>)>) -> Response {
    let mut headers =
        with_security(vec![pair("content-type", "application/json; charset=utf-8"), pair("cache-control", "no-store")]);
    headers.extend(extra);
    Response { status, headers, body: body.to_json().into_bytes() }
}

fn error_body(message: &str) -> Object {
    Object::new().with("ok", false).with("error", message)
}

fn redirect(location: impl AsRef<[u8]>, extra: Vec<(String, Vec<u8>)>) -> Response {
    let mut headers = with_security(vec![pair("location", location), pair("cache-control", "no-store")]);
    headers.extend(extra);
    Response { status: 303, headers, body: Vec::new() }
}

fn html(body: String, status: u16, cache: &str) -> Response {
    let headers = with_security(vec![
        pair("content-type", "text/html; charset=utf-8"),
        pair("cache-control", cache),
        pair("content-security-policy", PAGE_CSP),
        pair("x-frame-options", "DENY"),
    ]);
    Response { status, headers, body: body.into_bytes() }
}

fn page(body: String, status: u16) -> Response {
    html(body, status, "no-store")
}

/// An app shell file. The worker may be scoped to the base (it is served
/// from there anyway); the SVGs get a CSP of their own.
fn shell(asset: ShellAsset, base: &str) -> Response {
    let mut headers = with_security(vec![pair("content-type", asset.content_type), pair("cache-control", asset.cache)]);
    if asset.content_type == "image/svg+xml" {
        headers.push(pair("content-security-policy", ASSET_CSP));
    }
    if asset.worker {
        headers.push(pair("service-worker-allowed", format!("{base}/")));
    }
    Response { status: 200, headers, body: asset.body.into_owned() }
}

fn too_large(wants_html: bool, base: &str) -> Response {
    if wants_html {
        return page(message_page("Not silenced", "The request was too large.", base, false), 413);
    }
    api(error_body("Request body too large"), 413)
}

/// The first entry of a comma-separated header, trimmed, or `None` when
/// there is none.
fn first_value(req: &Request, name: &str) -> Option<String> {
    let value = latin1(&header(req, name)?);
    let first = js::trim(value.split(',').next().unwrap_or("")).to_string();
    (!first.is_empty()).then_some(first)
}

/// The named cookie, decoded, or `None`; a malformed escape counts as no
/// cookie.
fn read_cookie(req: &Request, name: &str) -> Option<String> {
    let value = latin1(&header(req, "cookie")?);
    for part in value.split(';') {
        let pieces: Vec<&str> = js::trim(part).split('=').collect();
        if pieces[0] == name {
            return safe_decode(&pieces[1..].join("="));
        }
    }
    None
}

/// A browser attaches `Origin` or `Sec-Fetch-Site` to a cross-site form
/// post, and a page cannot forge either. Non-browser clients send neither.
fn cross_site(req: &Request, public_origin: &str) -> bool {
    if header(req, "origin").is_some_and(|o| *o != *public_origin.as_bytes()) {
        return true;
    }
    header(req, "sec-fetch-site").is_some_and(|s| *s != *b"same-origin" && *s != *b"none")
}

/// The token an `Authorization` header carries: what follows the scheme
/// when the scheme is `Bearer` (in any case) and one or more whitespace
/// characters follow it, else `None`. Any other scheme (a proxy's Basic
/// auth, say) is not a bearer at all, so the cookie and `?token=` are read
/// as if no header came.
fn bearer(req: &Request) -> Option<String> {
    let text = latin1(&header(req, "authorization")?);
    if text.len() > 6 && text.is_char_boundary(6) && text[..6].eq_ignore_ascii_case("bearer") {
        let rest = text[6..].trim_start_matches(js::is_space);
        if rest.len() < text.len() - 6 {
            return Some(rest.to_string());
        }
    }
    None
}

/// Where a sign-in through the form goes next: the page it was posted from
/// (the `Referer`) when that is on the public origin and its query has no
/// `token` parameter, else the dashboard.
fn sign_in_return(referer: &[u8], public_origin: &str, base: &str) -> Vec<u8> {
    let prefix = format!("{public_origin}/");
    if !referer.starts_with(prefix.as_bytes()) {
        return format!("{base}/").into_bytes();
    }
    // The URL parser drops tabs and newlines before it reads the query.
    let parsed: Vec<u8> = referer.iter().copied().filter(|c| !matches!(c, b'\t' | b'\n' | b'\r')).collect();
    let query = match parsed.iter().position(|&c| c == b'?') {
        Some(i) => {
            let rest = &parsed[i + 1..];
            &rest[..rest.iter().position(|&c| c == b'#').unwrap_or(rest.len())]
        }
        None => &[][..],
    };
    if parse_form(query).iter().any(|(name, _)| name == "token") {
        return format!("{base}/").into_bytes();
    }
    referer.to_vec()
}

/// What `GET <base>/api` says is serving it: the package as its registry
/// names it, and the language. Each port answers with its own.
const LIBRARY: &str = "cronwatch";
const LANGUAGE: &str = "rust";

/// The API's version, which goes up only with a change that is not
/// additive, in a major release.
const API_VERSION: i64 = 1;

/// A job's summary as JSON, what silence and unsilence answer: the same as
/// `GET <base>/api/jobs/:name`'s `job` after the change.
async fn summary_value(cw: &Client, name: &str) -> Result<Value, Error> {
    Ok(cw.job_summary(name).await?.map_or(Value::Null, |s| s.to_value()))
}

/// Absent means one hour; a number or numeric string is milliseconds. The
/// error is the SDK's for anything else.
fn silence_duration(value: Option<&str>) -> Result<f64, String> {
    let duration = match value {
        None => Value::from("1h"),
        Some(v) => {
            let text = js::trim(v);
            let numeric = {
                let (whole, fraction) = text.split_once('.').unwrap_or((text, ""));
                let digits = |s: &str| !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit());
                digits(whole) && (!text.contains('.') || digits(fraction))
            };
            if numeric { Value::Number(text.parse().unwrap_or(f64::NAN)) } else { Value::from(text) }
        }
    };
    parse_duration(&duration, "silence duration")
}

fn runs_limit(value: Option<&str>) -> usize {
    let n = match value {
        Some(v) if !js::trim(v).is_empty() => js_number(&Value::from(v)).trunc(),
        _ => f64::NAN,
    };
    if !n.is_finite() {
        return DEFAULT_RUNS;
    }
    n.clamp(1.0, MAX_RUNS) as usize
}

/// What a request says, read before anything is awaited.
struct Said {
    method: String,
    public_origin: String,
    query: Vec<(String, String)>,
    bearer: Option<String>,
    cookie: Option<String>,
    referer: Vec<u8>,
    content_type: String,
    cross_site: bool,
}

impl Routes {
    /// The configured base path, if any.
    #[cfg(feature = "axum")]
    pub(crate) fn inner_base(&self) -> Option<&str> {
        self.inner.base.as_deref()
    }

    /// The token the dashboard asks for (the generated one in development),
    /// or `None` when it is open or locked for want of one.
    pub fn token(&self) -> Option<&str> {
        (!self.inner.token.is_empty()).then_some(self.inner.token.as_str())
    }

    /// Where the dashboard is mounted for this request: the configured base
    /// path, else the mount an adapter found, else `/cronwatch`.
    fn base_path(&self, req: &Request) -> String {
        if let Some(base) = &self.inner.base {
            return base.clone();
        }
        match &req.mount {
            Some(mount) => mount.trim_end_matches('/').to_string(),
            None => DEFAULT_BASE_PATH.to_string(),
        }
    }

    /// The origin a browser sees: the configured one, the forwarded one
    /// under `trust_proxy`, else the request's own.
    fn public_origin(&self, req: &Request) -> String {
        if let Some(origin) = &self.inner.origin {
            return origin.clone();
        }
        let host = header(req, "host").map(|h| h.into_owned()).unwrap_or_default();
        let own = request_origin(req.tls, &host);
        if !self.inner.trust_proxy {
            return own;
        }
        let proto = first_value(req, "x-forwarded-proto").map(|p| p.to_lowercase());
        let forwarded_host = first_value(req, "x-forwarded-host");
        if proto.is_none() && forwarded_host.is_none() {
            return own;
        }
        if proto.as_deref().is_some_and(|p| p != "http" && p != "https") {
            return own;
        }
        let (own_scheme, own_host) = own.split_once("://").unwrap_or((&own, ""));
        let proto = proto.unwrap_or_else(|| own_scheme.to_string());
        let forwarded_host = forwarded_host.unwrap_or_else(|| own_host.to_string());
        bare_origin(&format!("{proto}://{forwarded_host}")).unwrap_or(own)
    }

    /// Answers one request as the SDK's routes answer it. A store failure
    /// (or a panic) is reported to the client's error handler as `routes`
    /// and answered 500. A request whose future is dropped (its client went
    /// away) is not answered and reports nothing.
    pub async fn handle(&self, mut req: Request) -> Response {
        let (raw, query) = request_target(&req.target);
        let base = self.base_path(&req);
        let pathname = normalize_path(&raw);
        let path = strip_base(&pathname, &base);
        let wants_html = !path.starts_with("/api");
        let outcome = CatchUnwind(Box::pin(self.serve(&mut req, &pathname, &path, &query, &base, wants_html))).await;
        let err = match outcome {
            Ok(Ok(answer)) => return answer,
            Ok(Err(err)) => err,
            Err(panic) => Error::Other(format!("panic: {}", panic_text(&*panic))),
        };
        self.inner.client.report(err, "routes");
        if wants_html {
            return page(
                message_page("Something went wrong", "The request failed and the error was reported.", &base, false),
                500,
            );
        }
        api(error_body("Internal error"), 500)
    }

    fn read(&self, req: &Request, raw_query: &str) -> Said {
        let public_origin = self.public_origin(req);
        Said {
            method: req.method.to_ascii_uppercase(),
            cross_site: cross_site(req, &public_origin),
            public_origin,
            query: parse_form(raw_query.as_bytes()),
            bearer: bearer(req),
            cookie: read_cookie(req, TOKEN_COOKIE),
            referer: header(req, "referer").map(|r| r.into_owned()).unwrap_or_default(),
            content_type: header(req, "content-type").map(|t| latin1(&t)).unwrap_or_default(),
        }
    }

    async fn serve(
        &self,
        req: &mut Request,
        pathname: &str,
        path: &str,
        raw_query: &str,
        base: &str,
        wants_html: bool,
    ) -> Result<Response, Error> {
        let rt = &self.inner;
        let cw = &rt.client;
        let said = self.read(req, raw_query);
        let method = said.method.as_str();

        if rt.generated && !rt.announced.swap(true, Ordering::SeqCst) {
            let shown = rt
                .origin
                .clone()
                .or_else(|| is_loopback_origin(&said.public_origin).then(|| said.public_origin.clone()));
            // Not println!, which panics when standard output is closed; the
            // SDK's console.info never throws.
            let line = development_sign_in_line(shown.as_deref(), base, &rt.token);
            let _ = writeln!(std::io::stdout().lock(), "{line}");
        }

        // The app shell: the manifest, icons, service worker, app.js, and the
        // offline page. Served to anyone, since a browser fetches some of it
        // without cookies and none of it says anything about the jobs.
        if method == "GET" || method == "HEAD" {
            if path == "/offline" {
                return Ok(html(
                    message_page(
                        "You are offline",
                        "CronWatch shows live data from your app, so it needs a connection.",
                        base,
                        false,
                    ),
                    200,
                    "no-cache",
                ));
            }
            if let Some(asset) = static_asset(path, base) {
                return Ok(shell(asset, base));
            }
        }

        // No token outside development: fail closed.
        if rt.token.is_empty() && !rt.opted_out {
            if wants_html {
                return Ok(page(
                    message_page(
                        "CronWatch routes are locked",
                        "Set CRONWATCH_TOKEN (or pass RoutesOptions::token to routes), or pass RoutesOptions::no_token() to serve them open behind your own auth.",
                        base,
                        false,
                    ),
                    503,
                ));
            }
            return Ok(api(error_body("CRONWATCH_TOKEN is not set"), 503));
        }

        if method != "GET" && method != "HEAD" && said.cross_site {
            if wants_html {
                return Ok(page(
                    message_page(
                        "Cross-site request refused",
                        "Changes can only be made from the dashboard itself.",
                        base,
                        false,
                    ),
                    403,
                ));
            }
            return Ok(api(error_body("Cross-site request refused"), 403));
        }

        let cookie_path = if base.is_empty() { "/" } else { base };
        let secure = if said.public_origin.starts_with("https:") { "; Secure" } else { "" };
        let sign_in_cookie = || {
            pair(
                "set-cookie",
                format!(
                    "{TOKEN_COOKIE}={}; Path={cookie_path}; HttpOnly; SameSite=Lax; Max-Age={COOKIE_MAX_AGE}{secure}",
                    rt.cookie
                ),
            )
        };
        let sign_in_page = || {
            let message = if rt.generated {
                "CRONWATCH_TOKEN is not set, so this development server made a token. The sign-in link is in the server log: open it once, or enter the token from it below, and this browser stays signed in."
            } else {
                "Enter your CRONWATCH_TOKEN and this browser stays signed in."
            };
            page(message_page("Sign in", message, base, true), 401)
        };

        // The sign-in form posts the token here, in the body, so it stays out
        // of the URL and every access log. Cross-site posts were refused
        // above.
        if !rt.token.is_empty() && method == "POST" && path == "/signin" {
            // A body past the cap carries no token.
            let data = read_limited(req.take_body()).await.unwrap_or_default();
            let sent = body_field(&said.content_type, &data, "token");
            if !sent.is_some_and(|t| constant_time_eq(&t, &rt.token)) {
                return Ok(sign_in_page());
            }
            return Ok(redirect(sign_in_return(&said.referer, &said.public_origin, base), vec![sign_in_cookie()]));
        }

        if !rt.token.is_empty() {
            // ?token= is only the sign-in that moves the token into a cookie.
            let query_token = if wants_html && method == "GET" { param(&said.query, "token") } else { None };
            let cron_secret_ok = path == "/api/check"
                && match (&said.bearer, cw.cron_secret()) {
                    (Some(b), Some(secret)) => constant_time_eq(b, secret),
                    _ => false,
                };
            let token_ok = match (&said.bearer, query_token, &said.cookie) {
                (Some(b), _, _) => constant_time_eq(b, &rt.token),
                (None, Some(q), _) => constant_time_eq(q, &rt.token),
                (None, None, Some(c)) => constant_time_eq(c, &rt.cookie),
                _ => false,
            };
            if !cron_secret_ok && !token_ok {
                if wants_html {
                    return Ok(sign_in_page());
                }
                if rt.generated {
                    return Ok(api(
                        error_body(
                            "Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log",
                        ),
                        401,
                    ));
                }
                return Ok(api(error_body("Unauthorized"), 401));
            }
            if query_token.is_some() {
                // Move the token from the URL into a cookie, so it is not
                // left in the browser's history. The request line that
                // carried it may still be in an access log, which is why the
                // sign-in form posts instead.
                let rest: Vec<String> = said
                    .query
                    .iter()
                    .filter(|(n, _)| n != "token")
                    .map(|(n, v)| format!("{}={}", form_encode(n), form_encode(v)))
                    .collect();
                let search = if rest.is_empty() { String::new() } else { format!("?{}", rest.join("&")) };
                return Ok(redirect(format!("{pathname}{search}"), vec![sign_in_cookie()]));
            }
        }

        let redirect_back = || {
            let prefix = format!("{}/", said.public_origin);
            if said.referer.starts_with(prefix.as_bytes()) {
                redirect(&said.referer, Vec::new())
            } else {
                redirect(format!("{base}/"), Vec::new())
            }
        };
        let mut parts: Vec<String> = Vec::new();
        for part in path.split('/').filter(|p| !p.is_empty()) {
            match safe_decode(part) {
                Some(decoded) => parts.push(decoded),
                None if wants_html => {
                    return Ok(page(message_page("Bad request", "The path is not valid.", base, false), 400));
                }
                None => return Ok(api(error_body("Bad path"), 400)),
            }
        }
        let parts: Vec<&str> = parts.iter().map(String::as_str).collect();

        // HTML
        match (method, parts.as_slice()) {
            ("GET", _) if path == "/" => {
                let entries = cw.jobs_with_runs(BOARD_PAGE_RUNS).await?;
                let now = cw.now();
                let runs_by_job: HashMap<String, Vec<Run>> =
                    entries.iter().map(|e| (e.job.name.clone(), e.runs.clone())).collect();
                let jobs: Vec<JobSummary> = entries.iter().map(|e| e.job.clone()).collect();
                let lanes = self.board_lanes(&entries, now).await?;
                return Ok(page(dashboard_page(&jobs, &runs_by_job, now, base, None, &lanes), 200));
            }
            ("GET", ["jobs", name]) => {
                let Some(job) = cw.job_summary(name).await? else {
                    return Ok(page(
                        message_page("No such job", &format!("{name} is not in the store."), base, false),
                        404,
                    ));
                };
                let now = cw.now();
                // Enough runs to draw the job's week; the page lists the newest fifty.
                let limit = week_runs_limit(&job, now);
                let runs = cw.runs(&job.name, limit).await?;
                return Ok(page(job_page(&job, &runs, now, base, runs.len() < limit), 200));
            }
            ("POST", _) if path == "/check" => {
                cw.check().await?;
                return Ok(redirect_back());
            }
            ("POST", ["jobs", name, action]) => {
                if *action == "forget" {
                    cw.forget(name).await?;
                    return Ok(redirect(format!("{base}/"), Vec::new()));
                }
                if *action != "silence" && *action != "unsilence" {
                    return Ok(page(message_page("Not found", path, base, false), 404));
                }
                if cw.job_summary(name).await?.is_none() {
                    return Ok(page(
                        message_page("No such job", &format!("{name} is not in the store."), base, false),
                        404,
                    ));
                }
                if *action == "silence" {
                    let Ok(data) = read_limited(req.take_body()).await else {
                        return Ok(too_large(true, base));
                    };
                    let value = body_field(&said.content_type, &data, "for");
                    let ms = match silence_duration(value.as_deref()) {
                        Ok(ms) => ms,
                        Err(message) => return Ok(page(message_page("Not silenced", &message, base, false), 400)),
                    };
                    cw.silence_ms(name, ms).await?;
                } else {
                    cw.unsilence(name).await?;
                }
                return Ok(redirect_back());
            }
            _ => {}
        }

        // JSON API
        if let ["api", rest @ ..] = parts.as_slice() {
            return self.serve_api(req, method, rest, &said).await;
        }
        Ok(page(message_page("Not found", path, base, false), 404))
    }

    /// The board's timeline lanes, the first `BOARD_LANES` jobs. The runs
    /// already read for the table usually cover the last day; only a job
    /// whose twenty newest runs all fall inside it is read again, deeper.
    async fn board_lanes(&self, entries: &[JobWithRuns], now: i64) -> Result<Vec<LaneInput>, Error> {
        let from = now - BOARD_BEHIND_MS;
        let mut lanes = Vec::new();
        for e in entries.iter().take(BOARD_LANES) {
            let short = e.runs.len() >= BOARD_PAGE_RUNS && e.runs.last().is_some_and(|r| r.started_at > from);
            if !short {
                lanes.push(LaneInput { job: e.job.clone(), runs: e.runs.clone(), complete: true });
                continue;
            }
            let deeper = self.inner.client.runs(&e.job.name, BOARD_RUNS).await?;
            let complete = deeper.len() < BOARD_RUNS;
            lanes.push(LaneInput { job: e.job.clone(), runs: deeper, complete });
        }
        Ok(lanes)
    }

    async fn serve_api(&self, req: &mut Request, method: &str, rest: &[&str], said: &Said) -> Result<Response, Error> {
        let cw = &self.inner.client;
        let no_such_job = || api(error_body("No such job"), 404);
        match (method, rest) {
            // What is serving the API, so a client such as @cronwatch/mcp can tell.
            ("GET", []) => {
                let about = Object::new()
                    .with("ok", true)
                    .with("library", LIBRARY)
                    .with("language", LANGUAGE)
                    .with("version", crate::VERSION)
                    .with("api", API_VERSION);
                return Ok(api(about, 200));
            }
            ("GET", ["jobs"]) => {
                let jobs = cw.jobs().await?;
                let list: Vec<Value> = jobs.iter().map(JobSummary::to_value).collect();
                return Ok(api(Object::new().with("ok", true).with("jobs", list), 200));
            }
            ("GET", ["jobs", name]) => {
                let Some(job) = cw.job_summary(name).await? else {
                    return Ok(no_such_job());
                };
                let runs = cw.runs(name, runs_limit(param(&said.query, "runs"))).await?;
                let list: Vec<Value> = runs.iter().map(Run::to_value).collect();
                return Ok(api(Object::new().with("ok", true).with("job", job.to_value()).with("runs", list), 200));
            }
            ("DELETE", ["jobs", name]) => {
                if cw.job_summary(name).await?.is_none() {
                    return Ok(no_such_job());
                }
                cw.forget(name).await?;
                return Ok(api(Object::new().with("ok", true), 200));
            }
            ("POST", ["jobs", name, action]) => {
                if cw.job_summary(name).await?.is_none() {
                    return Ok(no_such_job());
                }
                match *action {
                    "silence" => {
                        let Ok(data) = read_limited(req.take_body()).await else {
                            return Ok(too_large(false, ""));
                        };
                        let value = body_field(&said.content_type, &data, "for")
                            .or_else(|| param(&said.query, "for").map(str::to_string));
                        let ms = match silence_duration(value.as_deref()) {
                            Ok(ms) => ms,
                            Err(message) => return Ok(api(error_body(&message), 400)),
                        };
                        cw.silence_ms(name, ms).await?;
                        return Ok(api(
                            Object::new().with("ok", true).with("job", summary_value(cw, name).await?),
                            200,
                        ));
                    }
                    "unsilence" => {
                        cw.unsilence(name).await?;
                        return Ok(api(
                            Object::new().with("ok", true).with("job", summary_value(cw, name).await?),
                            200,
                        ));
                    }
                    _ => {}
                }
            }
            (_, ["check"]) => {
                // A page cannot send an Authorization header cross-site, so a
                // GET may only run the check when it carries a bearer (token
                // or cron secret).
                if method == "GET" && said.bearer.is_none() {
                    return Ok(api_with(
                        error_body("Use POST, or GET with an Authorization bearer"),
                        405,
                        vec![pair("allow", "POST")],
                    ));
                }
                if method == "GET" || method == "POST" {
                    let result = cw.check().await?;
                    let mut body = Object::new().with("ok", true);
                    if let Value::Object(o) = result.to_value() {
                        for (k, v) in o.iter() {
                            body.set(k, v.clone());
                        }
                    }
                    return Ok(api(body, 200));
                }
            }
            ("GET", ["runs", id]) => {
                return Ok(match cw.get_run(id).await? {
                    Some(run) => api(Object::new().with("ok", true).with("run", run.to_value()), 200),
                    None => api(error_body("No such run"), 404),
                });
            }
            _ => {}
        }
        Ok(api(error_body("Not found"), 404))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64url_is_unpadded() {
        assert_eq!(base64url(b""), "");
        assert_eq!(base64url(b"f"), "Zg");
        assert_eq!(base64url(b"fo"), "Zm8");
        assert_eq!(base64url(b"foo"), "Zm9v");
        assert_eq!(base64url(&[0xfb, 0xff]), "-_8");
        assert_eq!(base64url(&[0u8; 32]).len(), 43);
    }

    #[test]
    fn silence_durations_and_run_limits() {
        assert_eq!(silence_duration(None), Ok(3_600_000.0));
        assert_eq!(silence_duration(Some(" 7200000 ")), Ok(7_200_000.0));
        assert_eq!(silence_duration(Some("1.5")), Ok(1.5));
        assert!(silence_duration(Some("1.")).is_err());
        assert!(silence_duration(Some("forever")).unwrap_err().contains("silence duration"));
        for (value, want) in
            [("0", 1), ("-5", 1), ("2.7", 2), ("abc", 20), ("", 20), ("1e9", 500), ("Infinity", 20), ("0x2", 2)]
        {
            assert_eq!(runs_limit(Some(value)), want, "{value}");
        }
        assert_eq!(runs_limit(None), 20);
    }

    #[test]
    fn the_sign_in_line() {
        assert_eq!(
            development_sign_in_line(Some("http://localhost:3000"), "/cronwatch", "t"),
            "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: http://localhost:3000/cronwatch/?token=t"
        );
        assert_eq!(
            development_sign_in_line(None, "", "t"),
            "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: /?token=t on this server (the first request's host is not local, so the link leaves it out)"
        );
    }
}
