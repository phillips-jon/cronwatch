//! `Job::handler`: the SDK's fetch-style job handler (client.ts
//! `handler()`), for a platform cron that calls a URL (Vercel's crons,
//! Cloud Scheduler, EventBridge through API Gateway, a crontab line running
//! curl). Framework-free like the dashboard: [`Handler::handle`] takes a
//! [`web::Request`](crate::web::Request) and answers a
//! [`web::Response`](crate::web::Response), and the `tower` feature makes
//! it a `tower::Service`. Each request carrying the cron secret runs the
//! function as a recorded run and is answered with how it went.

use std::any::Any;
use std::fmt;
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use crate::env::environment;
use crate::error::Error;
use crate::js::Object;
use crate::run::{Job, JobContext, Outcome, http_failure};
use crate::store::BoxFuture;
use crate::types::{Run, RunStatus};
use crate::web::{Request, Response, constant_time_eq, latin1};

/// How [`Job::handler`] checks its requests: the SDK's `HandlerOptions`,
/// with Rust's three ways for the secret.
#[derive(Clone, Debug, Default)]
pub struct HandlerOptions {
    secret: Option<Option<String>>,
}

impl HandlerOptions {
    /// The defaults: the client's cron secret (`CRON_SECRET`).
    pub fn new() -> Self {
        Self::default()
    }

    /// The secret the handler's requests must carry, as
    /// `Authorization: Bearer <secret>`, in place of the client's cron
    /// secret. `""` counts as unset.
    pub fn secret(mut self, secret: impl Into<String>) -> Self {
        self.secret = Some(Some(secret.into()));
        self
    }

    /// Lets anyone run the job through the handler (the SDK's
    /// `secret: null`), for one behind the app's own auth, or a function
    /// only its platform can invoke (an EventBridge Scheduler invoking a
    /// Lambda directly sends no bearer).
    pub fn no_secret(mut self) -> Self {
        self.secret = Some(None);
        self
    }
}

type Runner = Box<dyn Fn(Request) -> BoxFuture<'static, (Run, Option<Response>)> + Send + Sync>;

/// A job as an HTTP handler, made by [`Job::handler`]. Cheap to clone.
#[derive(Clone)]
pub struct Handler {
    inner: Arc<HandlerInner>,
}

struct HandlerInner {
    job: Job,
    secret: String,
    opted_out: bool,
    run: Runner,
}

impl fmt::Debug for Handler {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Handler").field("job", &self.inner.job.name()).finish_non_exhaustive()
    }
}

impl Job {
    /// The job as an HTTP handler, the SDK's `job.handler()`. A request must
    /// send `Authorization: Bearer <secret>` (compared in constant time): the
    /// options' secret, else the client's cron secret. With no secret at all
    /// it answers 503 and reports it once to the error handler as `handler`,
    /// unless the environment is development or
    /// [`HandlerOptions::no_secret`] (or the client's `no_cron_secret`) lets
    /// anyone in; a wrong or missing bearer is 401.
    ///
    /// Each request it lets in runs `f` as a run with the trigger `handler`,
    /// answered with `{"ok","job","run","status","durationMs"}`, 200 when the
    /// run was ok and 500 when it failed, with the error's first line as
    /// `error` for a caller who sent the secret. A function that returns an
    /// HTTP answer (a [`web::Response`](crate::web::Response), or with the
    /// `tower` feature an `http::Response` whose body is `Full<Bytes>`,
    /// `String`, `Vec<u8>`, `Bytes`, `&'static str`, `()` or `Empty<Bytes>`)
    /// is answered with it, and a status of 400 or more fails the run with
    /// `HTTP <status> <reason>`. A panic in `f` is a failed run answered 500,
    /// as the SDK answers a throw. A `String` returned is the run's output
    /// when nothing was logged.
    ///
    /// A request whose future is dropped while `f` runs (its caller went
    /// away, a server's deadline) drops `f`'s future too, and the run is
    /// recorded as failed, as for any run.
    pub fn handler<F, Fut, T, E>(&self, f: F, options: HandlerOptions) -> Handler
    where
        F: Fn(JobContext, Request) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<T, E>> + Send + 'static,
        T: Send + 'static,
        E: fmt::Display + Send + 'static,
    {
        let client = &self.client;
        let (secret, opted_out) = match options.secret {
            Some(None) => (String::new(), true),
            Some(Some(own)) if !own.is_empty() => (own, false),
            _ => (client.cron_secret().unwrap_or("").to_string(), client.inner.secret_opt_out),
        };
        let job = self.clone();
        let f = Arc::new(f);
        let run: Runner = Box::new(move |req: Request| {
            let (job, f) = (job.clone(), f.clone());
            Box::pin(async move {
                let done = job
                    .client
                    .execute_run(job.def.clone(), "handler".into(), move |jc| f(jc, req), http_failure::<T>)
                    .await;
                let answer = match done.outcome {
                    Outcome::Value(v) => answer_of(Box::new(v)).await,
                    _ => None,
                };
                (done.run, answer)
            })
        });
        Handler { inner: Arc::new(HandlerInner { job: self.clone(), secret, opted_out, run }) }
    }
}

/// A value a job's function returned, as the answer when it is one.
async fn answer_of(value: Box<dyn Any + Send>) -> Option<Response> {
    let value = match value.downcast::<Response>() {
        Ok(r) => return Some(*r),
        Err(v) => v,
    };
    #[cfg(feature = "tower")]
    return crate::web::tower_answer(value).await;
    #[cfg(not(feature = "tower"))]
    {
        let _ = value;
        None
    }
}

/// The SDK's `json()`: the body, with its type and `no-store`.
fn json(body: Object, status: u16) -> Response {
    Response::new(status)
        .with_header("content-type", "application/json; charset=utf-8")
        .with_header("cache-control", "no-store")
        .with_body(body.to_json())
}

impl Handler {
    /// Answers one request. See [`Job::handler`].
    pub async fn handle(&self, req: Request) -> Response {
        let h = &self.inner;
        let client = &h.job.client;
        if h.secret.is_empty() && !h.opted_out && environment() != "development" {
            if !client.inner.warned_no_secret.swap(true, Ordering::SeqCst) {
                client.report(
                    Error::Other(
                        "handler refused a request because no CRON_SECRET is set; pass HandlerOptions::no_secret() to allow unauthenticated requests"
                            .into(),
                    ),
                    "handler",
                );
            }
            return json(
                Object::new().with("ok", false).with(
                    "error",
                    "CRON_SECRET is not set, so this job will not run for an unauthenticated request. Set it, or pass HandlerOptions::no_secret() to handler to allow anyone.",
                ),
                503,
            );
        }
        if !h.secret.is_empty() {
            let sent = req.header("authorization").map(|v| latin1(&v)).unwrap_or_default();
            if !constant_time_eq(&sent, &format!("Bearer {}", h.secret)) {
                return json(Object::new().with("ok", false).with("error", "Unauthorized"), 401);
            }
        }
        let (run, answer) = (h.run)(req).await;
        if let Some(answer) = answer {
            return answer;
        }
        let mut body = Object::new()
            .with("ok", run.status == RunStatus::Ok)
            .with("job", h.job.name())
            .with("run", run.id.as_str())
            .with("status", run.status.as_str())
            .with("durationMs", run.duration_ms);
        // Error text only goes to a caller who proved they hold the secret.
        if let Some(error) = run.error.as_deref().filter(|e| !h.secret.is_empty() && !e.is_empty()) {
            body.set("error", error.split('\n').next().unwrap_or(""));
        }
        json(body, if run.status == RunStatus::Ok { 200 } else { 500 })
    }

    /// The job this handler runs.
    pub fn job(&self) -> &Job {
        &self.inner.job
    }
}
