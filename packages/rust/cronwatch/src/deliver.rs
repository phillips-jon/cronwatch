//! Sending alerts: channels, triage, and the queue of alerts no channel
//! accepted, retried once per check (client.ts dispatch, retryUndelivered,
//! recordDelivery, deliver, addTriage).

use std::fmt;
use std::future::Future;
use std::io::Write;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::client::Client;
use crate::error::Error;
use crate::evaluate::{
    Evaluation, MAX_UNDELIVERED, SEND_LEASE_MS, hold_alerts, is_silenced, normalize_state, record_sent, stale_alert,
};
use crate::format::compose_alert;
use crate::panics::panic_text;
use crate::store::{BoxError, BoxFuture};
use crate::types::{Alert, AlertType, Definition, JobState, Run};

/// Alerts written with the state that opened their conditions, and how many
/// older ones the queue let go.
pub(crate) type Held = (Vec<Alert>, usize);

/// How long one channel may take to send one alert.
pub(crate) const CHANNEL_TIMEOUT: Duration = Duration::from_secs(15);
/// How long triage may take for one alert.
pub(crate) const TRIAGE_TIMEOUT: Duration = Duration::from_secs(25);
/// Wall-clock time one check spends retrying undelivered alerts, across every
/// job. Once it is spent the rest wait for the next check.
pub(crate) const RETRY_BUDGET: Duration = Duration::from_secs(20);

/// Where alerts go.
///
/// A send runs in a task of its own and is dropped after 15 seconds, which
/// cancels it at its next await. A channel that blocks its thread
/// (synchronous I/O inside `send`) cannot be cancelled that way and holds a
/// worker thread until it returns: do such work in
/// `tokio::task::spawn_blocking`.
pub trait Channel: Send + Sync + 'static {
    /// Names the channel in errors (`alert channel <name>`).
    fn name(&self) -> &str;
    /// Resolves once the alert went out (to at least one recipient), or with
    /// an error when it went nowhere.
    fn send<'a>(&'a self, alert: &'a Alert, cx: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>>;
}

/// What the client hands a channel with each alert.
#[derive(Clone, Default)]
pub struct ChannelContext {
    report: Option<Arc<dyn Fn(String) + Send + Sync>>,
}

impl fmt::Debug for ChannelContext {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ChannelContext").finish_non_exhaustive()
    }
}

impl ChannelContext {
    /// A channel context that reports to `report`, for sending to a channel
    /// outside a client (a test, say).
    pub fn new(report: impl Fn(String) + Send + Sync + 'static) -> Self {
        ChannelContext { report: Some(Arc::new(report)) }
    }

    /// Reports a problem that did not stop the alert going out, such as one
    /// of several recipients refusing it. It goes to the client's error
    /// handler; the default context writes it to standard error, as the SDK
    /// does for a channel called without one.
    pub fn report_error(&self, err: impl fmt::Display) {
        match &self.report {
            Some(report) => report(err.to_string()),
            None => eprintln!("[cronwatch] alert channel: {err}"),
        }
    }
}

struct FnChannel<F> {
    name: String,
    send: F,
}

impl<F, Fut> Channel for FnChannel<F>
where
    F: Fn(Alert) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<(), BoxError>> + Send + 'static,
{
    fn name(&self) -> &str {
        &self.name
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin((self.send)(alert.clone()))
    }
}

/// A function as a channel (the SDK's `custom()`).
pub fn channel_fn<F, Fut>(name: impl Into<String>, send: F) -> Arc<dyn Channel>
where
    F: Fn(Alert) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<(), BoxError>> + Send + 'static,
{
    Arc::new(FnChannel { name: name.into(), send })
}

/// The default channel: it writes each alert to standard error, and
/// recoveries to standard output.
#[derive(Clone, Copy, Debug, Default)]
pub struct Console;

impl Channel for Console {
    fn name(&self) -> &str {
        "console"
    }

    fn send<'a>(&'a self, alert: &'a Alert, _: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        let mut line = format!("[cronwatch] {}\n{}", alert.title, alert.message);
        if let Some(triage) = alert.triage.as_deref().filter(|t| !t.is_empty()) {
            line.push_str("\nTriage: ");
            line.push_str(triage);
        }
        line.push('\n');
        let result = if alert.alert_type == AlertType::Recovered {
            std::io::stdout().lock().write_all(line.as_bytes())
        } else {
            std::io::stderr().lock().write_all(line.as_bytes())
        };
        Box::pin(std::future::ready(result.map_err(BoxError::from)))
    }
}

/// What a triage function is given.
#[derive(Clone, Debug)]
#[non_exhaustive]
pub struct TriageContext {
    pub alert: Alert,
    /// The job's five newest runs.
    pub recent_runs: Vec<Run>,
}

impl TriageContext {
    /// `alert` and its job's newest runs, for a test of a triage of the
    /// app's own.
    pub fn new(alert: Alert, recent_runs: Vec<Run>) -> TriageContext {
        TriageContext { alert, recent_runs }
    }
}

/// Diagnoses an alert in a few sentences, or answers `""` for no diagnosis.
/// The client stops waiting after 25 seconds, dropping the future.
pub trait Triage: Send + Sync + 'static {
    fn triage(&self, cx: TriageContext) -> BoxFuture<'static, Result<String, BoxError>>;
}

struct FnTriage<F>(F);

impl<F, Fut> Triage for FnTriage<F>
where
    F: Fn(TriageContext) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<String, BoxError>> + Send + 'static,
{
    fn triage(&self, cx: TriageContext) -> BoxFuture<'static, Result<String, BoxError>> {
        Box::pin((self.0)(cx))
    }
}

/// A function as triage.
pub fn triage_fn<F, Fut>(triage: F) -> Arc<dyn Triage>
where
    F: Fn(TriageContext) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<String, BoxError>> + Send + 'static,
{
    Arc::new(FnTriage(triage))
}

/// Where runs this process does not wrap come from, such as pg_cron's jobs.
/// A check syncs each one first, so what it records is evaluated in the same
/// check.
pub trait Source: Send + Sync + 'static {
    fn name(&self) -> &str;
    /// Declares the jobs and records their new runs (with
    /// [`Client::job`] and [`Client::record_run`]), returning the alerts
    /// recording them sent.
    fn sync<'a>(&'a self, host: &'a Client) -> BoxFuture<'a, Result<Vec<Alert>, BoxError>>;
}

impl Client {
    /// An evaluation as it is written: its drafts composed into alerts and
    /// held in the same state (`hold_alerts`), so the write that opens a
    /// condition also keeps its alerts, and a process that stops before
    /// sending them does not lose them. Called inside `update_state`, so it
    /// only computes.
    pub(crate) fn outbox(&self, settled: Evaluation, def: &Definition, now: i64) -> (JobState, Held) {
        let alerts: Vec<Alert> = settled.alerts.into_iter().map(|d| compose_alert(d, def, now)).collect();
        let until = self.now().saturating_add(SEND_LEASE_MS);
        let (state, dropped) = hold_alerts(&settled.state, &alerts, until, self.inner.defer_delivery);
        (state, (alerts, dropped))
    }

    /// Triages and sends each alert the outbox holds (see `outbox`). The
    /// state, with the alerts in it, was saved before this, so a slow channel
    /// holds up nothing else; afterwards only the delivery fields are written
    /// back, onto a fresh read of the state, and the alerts leave `sending`.
    /// Triage is made here, never stored with the held alert: the write that
    /// opens a condition cannot wait for it, and a retry triages an alert
    /// that has none. With `Deliver::AtCheck` the alerts were queued for a
    /// check elsewhere instead. Returns the alerts, triaged.
    pub(crate) async fn dispatch(&self, name: &str, alerts: Vec<Alert>, now: i64) -> Vec<Alert> {
        if alerts.is_empty() || self.inner.defer_delivery {
            return alerts;
        }
        let (mut delivered, mut failed, mut sent) = (Vec::new(), Vec::new(), Vec::new());
        for mut alert in alerts {
            if self.inner.triage.is_some() && alert.alert_type != AlertType::Recovered {
                self.add_triage(&mut alert, TRIAGE_TIMEOUT).await;
            }
            if self.deliver(&alert).await {
                delivered.push(alert.clone());
            } else {
                failed.push(alert.clone());
            }
            sent.push(alert);
        }
        self.record_delivery(name, &delivered, &failed, &[], now).await;
        sent
    }

    /// Reports alerts let go because a job's queue was full.
    pub(crate) fn report_dropped(&self, name: &str, dropped: usize) {
        if dropped == 0 {
            return;
        }
        let plural = if dropped == 1 { "" } else { "s" };
        self.report(
            Error::Other(format!(
                "{dropped} undelivered alert{plural} for {name} dropped: only the newest {MAX_UNDELIVERED} are kept for retry"
            )),
            &format!("alert queue for {name}"),
        );
    }

    /// Sends the alerts no channel accepted last time, once each, oldest
    /// first. `state` is the job's state as this check left it: an alert that
    /// no longer describes it (`stale_alert`) is dropped instead. Retries
    /// across a check share `RETRY_BUDGET` of wall-clock time; once it is
    /// spent the rest stay queued for the next check.
    pub(crate) async fn retry_undelivered(
        &self,
        name: &str,
        state: &JobState,
        now: i64,
        spent: &mut Duration,
    ) -> Vec<Alert> {
        let pending = state.undelivered.clone().unwrap_or_default();
        if pending.is_empty() || is_silenced(state, now) || self.inner.defer_delivery {
            return Vec::new();
        }
        let dropped: Vec<Alert> = pending.iter().filter(|a| stale_alert(a, state)).cloned().collect();
        let (mut delivered, mut failed) = (Vec::new(), Vec::new());
        for a in pending.iter().filter(|a| !stale_alert(a, state)) {
            let Some(left) = RETRY_BUDGET.checked_sub(*spent).filter(|l| !l.is_zero()) else {
                break;
            };
            let started = Instant::now();
            let mut alert = a.clone();
            // An alert queued by a process that delivers at check time was
            // never triaged. One that was tried is not tried again.
            if self.inner.triage.is_some() && alert.alert_type != AlertType::Recovered && !alert.triage_tried {
                self.add_triage(&mut alert, TRIAGE_TIMEOUT.min(left)).await;
            }
            if self.deliver(&alert).await {
                delivered.push(alert);
            } else {
                failed.push(alert);
            }
            *spent += started.elapsed();
        }
        self.record_delivery(name, &delivered, &failed, &dropped, now).await;
        delivered
    }

    /// Marks delivered alerts done, drops stale ones, and keeps failed ones
    /// for the next check, taking them all out of `sending` (`record_sent`).
    /// A failed alert replaces its stored copy, so a triage made on this
    /// attempt is kept. `last_alert_at` moves only on a delivery. When this
    /// write fails, alerts still in `sending` are retried once their lease
    /// runs out.
    async fn record_delivery(&self, name: &str, delivered: &[Alert], failed: &[Alert], dropped: &[Alert], now: i64) {
        let result = self
            .update_state(name, async { Ok(()) }, |previous, _| {
                Ok(record_sent(&normalize_state(Some(&previous), name), delivered, failed, dropped, now))
            })
            .await;
        match result {
            Err(err) => self.report(err, &format!("recording alert delivery for {name}")),
            Ok((_, trimmed)) => self.report_dropped(name, trimmed),
        }
    }

    /// Sends to every channel at once. True when at least one accepted it,
    /// or there are none.
    pub(crate) async fn deliver(&self, alert: &Alert) -> bool {
        if self.inner.alerts.is_empty() {
            return true;
        }
        let sends: Vec<_> = self.inner.alerts.iter().map(|ch| self.send_one(ch.clone(), alert.clone())).collect();
        let mut ok = false;
        for send in sends {
            if send.await {
                ok = true;
            }
        }
        ok
    }

    /// Starts one alert's send to one channel, in a task of its own, within
    /// `CHANNEL_TIMEOUT`; a send past its time is dropped. The returned future
    /// says whether it went out.
    fn send_one(&self, ch: Arc<dyn Channel>, alert: Alert) -> impl Future<Output = bool> + Send + 'static {
        let client = self.clone();
        let where_ = format!("alert channel {}", ch.name());
        let report_where = where_.clone();
        let report_client = self.clone();
        let cx = ChannelContext::new(move |err| report_client.report(Error::Other(err), &report_where));
        let task = self.inner.handle.spawn(async move {
            tokio::time::timeout(CHANNEL_TIMEOUT, async move { ch.send(&alert, &cx).await }).await
        });
        async move {
            match task.await {
                Ok(Ok(Ok(()))) => true,
                Ok(Ok(Err(err))) => {
                    client.report(Error::Other(err.to_string()), &where_);
                    false
                }
                Ok(Err(_)) => {
                    client.report(Error::Other(format!("timed out after {}ms", CHANNEL_TIMEOUT.as_millis())), &where_);
                    false
                }
                Err(join) => {
                    let text = if join.is_panic() { panic_text(&*join.into_panic()) } else { "cancelled".into() };
                    client.report(Error::Other(format!("panicked: {text}")), &where_);
                    false
                }
            }
        }
    }

    /// Sets the alert's triage to the diagnosis, or to none, so it is tried
    /// once per alert.
    async fn add_triage(&self, alert: &mut Alert, timeout: Duration) {
        let where_ = format!("triage for {}", alert.job);
        alert.triage_tried = true;
        alert.triage = None;
        let Some(triage) = self.inner.triage.clone() else {
            return;
        };
        let recent = match self.inner.store.list_runs(&alert.job, 5).await {
            Ok(runs) => runs,
            Err(err) => {
                self.report(Error::store(err), &where_);
                return;
            }
        };
        let cx = TriageContext { alert: alert.clone(), recent_runs: recent };
        let task = self.inner.handle.spawn(async move { tokio::time::timeout(timeout, triage.triage(cx)).await });
        match task.await {
            Ok(Ok(Ok(text))) => {
                if !text.is_empty() {
                    alert.triage = Some(text);
                }
            }
            Ok(Ok(Err(err))) => self.report(Error::Other(err.to_string()), &where_),
            Ok(Err(_)) => {
                self.report(Error::Other(format!("timed out after {}ms", timeout.as_millis())), &where_);
            }
            Err(join) => {
                let text = if join.is_panic() { panic_text(&*join.into_panic()) } else { "cancelled".into() };
                self.report(Error::Other(format!("panicked: {text}")), &where_);
            }
        }
    }
}
