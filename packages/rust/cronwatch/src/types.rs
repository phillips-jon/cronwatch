//! Everything public about a job, a run and an alert. Each type writes the
//! SDK's JSON (`to_json`): the same field names, in the same order, with
//! numbers as JavaScript prints them, so a Rust process and a Node, Ruby,
//! Python, PHP or Go process can share one store and `@cronwatch/mcp` reads
//! any of them.

use std::fmt;

use crate::js::{self, Object, Value};

macro_rules! string_enum {
    ($(#[$doc:meta])* $name:ident { $($(#[$vdoc:meta])* $variant:ident = $text:literal),* $(,)? }) => {
        $(#[$doc])*
        ///
        /// A value another writer stored that this release does not know is
        /// kept as `Other`, so it is written back as it was.
        #[derive(Clone, Debug, PartialEq, Eq, Hash)]
        #[non_exhaustive]
        pub enum $name {
            $($(#[$vdoc])* $variant,)*
            /// A value this release does not know.
            Other(String),
        }

        impl $name {
            /// The value as the SDK writes it.
            pub fn as_str(&self) -> &str {
                match self {
                    $($name::$variant => $text,)*
                    $name::Other(s) => s,
                }
            }

            /// The value the SDK's text names.
            pub fn parse(text: &str) -> Self {
                match text {
                    $($text => $name::$variant,)*
                    other => $name::Other(other.to_string()),
                }
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(self.as_str())
            }
        }

        impl From<&str> for $name {
            fn from(text: &str) -> Self {
                $name::parse(text)
            }
        }
    };
}

string_enum!(
    /// Where a run stands.
    RunStatus {
        Running = "running",
        Ok = "ok",
        Failed = "failed",
        Timeout = "timeout",
    }
);

string_enum!(
    /// Something wrong with a job that opens once, alerts, and closes with a
    /// recovery. In the SDK's order.
    Condition {
        Missed = "missed",
        Failed = "failed",
        Stuck = "stuck",
        Slow = "slow",
        OverBudget = "over_budget",
    }
);

string_enum!(
    /// A condition opening, or `recovered`.
    AlertType {
        Missed = "missed",
        Failed = "failed",
        Stuck = "stuck",
        Slow = "slow",
        OverBudget = "over_budget",
        Recovered = "recovered",
    }
);

string_enum!(
    /// How a job looks at a glance.
    JobHealth {
        Healthy = "healthy",
        Late = "late",
        Failing = "failing",
        Stuck = "stuck",
        Silenced = "silenced",
        NeverRan = "never_ran",
    }
);

impl AlertType {
    /// The alert a condition opening sends.
    pub fn of(condition: &Condition) -> AlertType {
        AlertType::parse(condition.as_str())
    }
}

/// Why stored JSON could not be read as one of these types.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsonError(pub(crate) String);

impl fmt::Display for JsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for JsonError {}

impl From<js::ParseError> for JsonError {
    fn from(e: js::ParseError) -> Self {
        JsonError(e.to_string())
    }
}

/// A run's numbers in JavaScript's key order: names that are array indices
/// (`"10"`, `"200"`) first in ascending order, then the rest in the order
/// they were first reported. Budgets use the same type.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Metrics(Vec<(String, f64)>);

impl Metrics {
    /// No metrics.
    pub fn new() -> Self {
        Self::default()
    }

    /// The value reported for `name`.
    pub fn get(&self, name: &str) -> Option<f64> {
        self.0.iter().find(|e| e.0 == name).map(|e| e.1)
    }

    /// Reports a value for `name`: a later value replaces an earlier one in
    /// its place, and a new name takes its place in JavaScript's order.
    pub fn set(&mut self, name: impl Into<String>, value: f64) {
        let name = name.into();
        if let Some(e) = self.0.iter_mut().find(|e| e.0 == name) {
            e.1 = value;
            return;
        }
        let at = match js::array_index(&name) {
            Some(n) => {
                self.0.iter().position(|(k, _)| js::array_index(k).is_none_or(|m| m > n)).unwrap_or(self.0.len())
            }
            None => self.0.len(),
        };
        self.0.insert(at, (name, value));
    }

    /// The names and values, in order.
    pub fn iter(&self) -> impl Iterator<Item = (&str, f64)> {
        self.0.iter().map(|e| (e.0.as_str(), e.1))
    }

    /// How many there are.
    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// Whether there are none.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// `{...self, ...over}`.
    pub(crate) fn merged(&self, over: &Metrics) -> Metrics {
        let mut out = self.clone();
        for (k, v) in over.iter() {
            out.set(k, v);
        }
        out
    }

    /// The metrics as a JSON object.
    pub fn to_value(&self) -> Value {
        let mut o = Object::new();
        for (k, v) in self.iter() {
            o.set(k, v);
        }
        Value::Object(o)
    }

    /// The SDK's JSON.
    pub fn to_json(&self) -> String {
        self.to_value().to_json()
    }

    /// The metrics as a store writes them: names without U+0000, which
    /// Postgres refuses, read back as JSON would read them.
    pub fn without_nul(&self) -> Metrics {
        if !self.0.iter().any(|(k, _)| k.contains('\0')) {
            return self.clone();
        }
        let mut out = Metrics::new();
        for (k, v) in self.iter() {
            out.set(crate::output::strip_nul(k), v);
        }
        out
    }

    /// Reads a JSON object of numbers.
    pub fn from_json(text: &str) -> Result<Metrics, JsonError> {
        Metrics::from_value(&js::parse(text)?)
    }

    /// Reads a JSON object of numbers; `null` is none.
    pub fn from_value(v: &Value) -> Result<Metrics, JsonError> {
        let o = match v {
            Value::Object(o) => o,
            Value::Null => return Ok(Metrics::new()),
            other => return Err(JsonError(format!("metrics must be an object, not {}", other.kind()))),
        };
        let mut out = Metrics::new();
        for (k, x) in o.iter() {
            match x {
                Value::Number(n) => out.set(k, *n),
                other => {
                    return Err(JsonError(format!("metric {} must be a number, not {}", js::quote(k), other.kind())));
                }
            }
        }
        Ok(out)
    }

    /// A stored row's metrics as the SDK reads them: the numbers of an
    /// object, whatever else it holds, and none for anything else.
    pub(crate) fn lenient(v: &Value) -> Metrics {
        let mut out = Metrics::new();
        if let Value::Object(o) = v {
            for (k, x) in o.iter() {
                if let Value::Number(n) = x {
                    out.set(k, *n);
                }
            }
        }
        out
    }
}

impl<K: Into<String>> FromIterator<(K, f64)> for Metrics {
    fn from_iter<I: IntoIterator<Item = (K, f64)>>(iter: I) -> Self {
        let mut m = Metrics::new();
        for (k, v) in iter {
            m.set(k, v);
        }
        m
    }
}

/// The longest duration written: 2^53 - 1, the largest integer JavaScript
/// holds exactly, which every port and store reads back unchanged.
pub const MAX_DURATION_MS: i64 = 9_007_199_254_740_991;

/// How long a run took, from `started_at` to `finished_at`: 0 when it
/// started later, and never more than [`MAX_DURATION_MS`]. A foreign row's
/// start near a 64-bit limit must not make a duration no store can write.
pub fn run_duration(started_at: i64, finished_at: i64) -> i64 {
    finished_at.saturating_sub(started_at).clamp(0, MAX_DURATION_MS)
}

/// The version a stored state's `version` value counts as for
/// [`Store::compare_and_set_state`](crate::Store::compare_and_set_state):
/// a JSON number that is a whole number from 0 to 2^53 - 1, else 0 (absent,
/// or a foreign row's `1.5`, `"x"` or `-1`). The SQL stores read it the same
/// way, so such a row is written over by the next update instead of refusing
/// every compare-and-set of its job for good.
pub fn state_version(version: Option<&Value>) -> i64 {
    version.and_then(whole_version).unwrap_or(0)
}

fn whole_version(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) if n.fract() == 0.0 && (0.0..=MAX_DURATION_MS as f64).contains(n) => Some(*n as i64),
        _ => None,
    }
}

/// One execution of a job, as a store keeps it. Times are epoch milliseconds.
#[derive(Clone, Debug, PartialEq)]
pub struct Run {
    pub id: String,
    pub job: String,
    pub status: RunStatus,
    pub started_at: i64,
    pub finished_at: Option<i64>,
    pub duration_ms: Option<i64>,
    pub error: Option<String>,
    /// Lines logged, or the string the job returned. Capped at 16 KB.
    pub output: Option<String>,
    pub metrics: Metrics,
    /// What started the run: `run`, `handler`, `start` or a value of yours.
    pub trigger: String,
}

impl Run {
    /// The run as the SDK writes it.
    pub fn to_value(&self) -> Value {
        Value::Object(
            Object::new()
                .with("id", self.id.as_str())
                .with("job", self.job.as_str())
                .with("status", self.status.as_str())
                .with("startedAt", self.started_at)
                .with("finishedAt", self.finished_at)
                .with("durationMs", self.duration_ms)
                .with("error", self.error.clone())
                .with("output", self.output.clone())
                .with("metrics", self.metrics.to_value())
                .with("trigger", self.trigger.as_str()),
        )
    }

    /// The SDK's JSON.
    pub fn to_json(&self) -> String {
        self.to_value().to_json()
    }

    /// The run as a store writes it: its trigger, output, error and metric
    /// names without U+0000, which Postgres refuses (a refused write would
    /// lose the whole run). Its id and job are identifiers, kept as given;
    /// the client never makes one with a NUL.
    pub fn without_nul(&self) -> Run {
        let strip = crate::output::strip_nul;
        Run {
            error: self.error.as_deref().map(strip),
            output: self.output.as_deref().map(strip),
            metrics: self.metrics.without_nul(),
            trigger: strip(&self.trigger),
            ..self.clone()
        }
    }

    /// Reads the SDK's JSON.
    pub fn from_json(text: &str) -> Result<Run, JsonError> {
        Run::from_value(&js::parse(text)?)
    }

    /// Reads the SDK's JSON value.
    pub fn from_value(v: &Value) -> Result<Run, JsonError> {
        let Value::Object(o) = v else {
            return Err(JsonError(format!("a run must be an object, not {}", v.kind())));
        };
        Ok(Run {
            id: str_of(o, "id"),
            job: str_of(o, "job"),
            status: RunStatus::parse(&str_of(o, "status")),
            started_at: int_of(o, "startedAt"),
            finished_at: nullable_int(o, "finishedAt"),
            duration_ms: nullable_int(o, "durationMs"),
            error: nullable_str(o, "error"),
            output: nullable_str(o, "output"),
            metrics: Metrics::from_value(o.get("metrics").unwrap_or(&Value::Null))?,
            trigger: str_of(o, "trigger"),
        })
    }
}

/// A job's definition as a store holds it: the SDK's JSON object, its fields
/// in the order they were given (defaults, then the job's options, then
/// `name`), `expect` described in words. Fields a newer writer added are
/// kept.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Definition(pub(crate) Object);

impl Definition {
    /// A definition holding these fields.
    pub fn from_object(o: Object) -> Definition {
        Definition(o)
    }

    /// The job's name.
    pub fn name(&self) -> &str {
        self.str("name")
    }

    /// The cron expression or `every <duration>`, or `""`.
    pub fn schedule(&self) -> &str {
        self.str("schedule")
    }

    /// The IANA zone the schedule is read in, or `""`.
    pub fn timezone(&self) -> &str {
        self.str("timezone")
    }

    /// The job's description, or `""`.
    pub fn description(&self) -> &str {
        self.str("description")
    }

    /// Describes the expect rule (`contains "done"`), or `""`.
    pub fn expect(&self) -> &str {
        self.str("expect")
    }

    /// The job's tags.
    pub fn tags(&self) -> Vec<String> {
        match self.0.get("tags") {
            Some(Value::Array(list)) => list.iter().filter_map(|t| t.as_str().map(str::to_string)).collect(),
            _ => Vec::new(),
        }
    }

    /// A field as JSON reads it.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.0.get(key)
    }

    /// The fields present, in order.
    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.0.keys()
    }

    /// The definition as a JSON object.
    pub fn as_object(&self) -> &Object {
        &self.0
    }

    fn str(&self, key: &str) -> &str {
        self.0.get(key).and_then(Value::as_str).unwrap_or("")
    }

    /// The SDK's JSON.
    pub fn to_json(&self) -> String {
        self.0.to_json()
    }

    /// The definition's JSON as a store writes it: every key and string
    /// without U+0000, which Postgres refuses.
    pub fn to_json_without_nul(&self) -> String {
        crate::output::strip_json_nul(&self.to_json())
    }

    /// The definition as a store holds it (see [`to_json_without_nul`](Self::to_json_without_nul)).
    pub fn without_nul(&self) -> Definition {
        let text = self.to_json();
        if !text.contains("\\u0000") {
            return self.clone();
        }
        Definition::from_json(&crate::output::strip_json_nul(&text)).unwrap_or_else(|_| self.clone())
    }

    /// Reads a JSON object.
    pub fn from_json(text: &str) -> Result<Definition, JsonError> {
        match js::parse(text)? {
            Value::Object(o) => Ok(Definition(o)),
            v => Err(JsonError(format!("a definition must be an object, not {}", v.kind()))),
        }
    }
}

/// A job as a store knows it.
#[derive(Clone, Debug, PartialEq)]
pub struct StoredJob {
    pub name: String,
    pub definition: Definition,
    pub created_at: i64,
    pub updated_at: i64,
}

/// A condition that is open, and when it opened.
#[derive(Clone, Debug, PartialEq)]
pub struct OpenCondition {
    pub condition: Condition,
    pub since: i64,
}

/// What the checks remember about a job between runs.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct JobState {
    pub job: String,
    /// Conditions currently open, in the order they opened.
    pub open: Vec<OpenCondition>,
    pub consecutive_failures: i64,
    pub silenced_until: Option<i64>,
    /// When an alert last reached at least one channel.
    pub last_alert_at: Option<i64>,
    /// Conditions that alerted and have since closed, waiting for the
    /// recovered alert the next successful run sends. `None` is a state
    /// written before the field existed (absent from the JSON).
    pub pending_recovery: Option<Vec<Condition>>,
    /// Alerts no channel accepted, each retried once per check. `None` is
    /// absent.
    pub undelivered: Option<Vec<Alert>>,
    /// Goes up by one on every write (see `Store::compare_and_set_state`).
    /// `None` is a state written before versions, which counts as 0.
    pub version: Option<i64>,
    /// Keys after the known ones, in stored order: `version` and any a newer
    /// writer added, so a state is written back as the SDK's spread would
    /// write it.
    pub(crate) tail: Vec<(String, Value)>,
}

const STATE_KEYS: [&str; 7] =
    ["job", "open", "consecutiveFailures", "silencedUntil", "lastAlertAt", "pendingRecovery", "undelivered"];

impl JobState {
    /// A new state for a job: nothing open, no failures.
    pub fn new(job: impl Into<String>) -> JobState {
        JobState { job: job.into(), pending_recovery: Some(Vec::new()), ..Default::default() }
    }

    /// When `condition` opened, if it is open.
    pub fn open_at(&self, condition: &Condition) -> Option<i64> {
        self.open.iter().find(|o| &o.condition == condition).map(|o| o.since)
    }

    /// The version this state counts as: see [`state_version`]. A version
    /// set out of that range counts as 0 too.
    pub fn counted_version(&self) -> i64 {
        self.version.filter(|v| (0..=MAX_DURATION_MS).contains(v)).unwrap_or(0)
    }

    /// The state as the SDK writes it.
    pub fn to_value(&self) -> Value {
        let mut open = Object::new();
        for c in &self.open {
            open.set(c.condition.as_str(), c.since);
        }
        let mut o = Object::new()
            .with("job", self.job.as_str())
            .with("open", open)
            .with("consecutiveFailures", self.consecutive_failures)
            .with("silencedUntil", self.silenced_until)
            .with("lastAlertAt", self.last_alert_at);
        if let Some(list) = &self.pending_recovery {
            o.set("pendingRecovery", list.iter().map(|c| Value::from(c.as_str())).collect::<Vec<_>>());
        }
        if let Some(list) = &self.undelivered {
            o.set("undelivered", list.iter().map(Alert::to_value).collect::<Vec<_>>());
        }
        let mut wrote_version = false;
        for (k, v) in &self.tail {
            if k == "version" {
                if let Some(version) = self.version {
                    o.set("version", version);
                    wrote_version = true;
                }
                continue;
            }
            o.set(k.as_str(), v.clone());
        }
        if let (Some(version), false) = (self.version, wrote_version) {
            o.set("version", version);
        }
        Value::Object(o)
    }

    /// The SDK's JSON.
    pub fn to_json(&self) -> String {
        self.to_value().to_json()
    }

    /// The state's JSON as a store writes it: every key and string without
    /// U+0000, which Postgres refuses.
    pub fn to_json_without_nul(&self) -> String {
        crate::output::strip_json_nul(&self.to_json())
    }

    /// The state as a store holds it (see [`to_json_without_nul`](Self::to_json_without_nul)).
    pub fn without_nul(&self) -> JobState {
        let text = self.to_json();
        if !text.contains("\\u0000") {
            return self.clone();
        }
        JobState::from_json(&crate::output::strip_json_nul(&text)).unwrap_or_else(|_| self.clone())
    }

    /// Reads the SDK's JSON.
    pub fn from_json(text: &str) -> Result<JobState, JsonError> {
        JobState::from_value(&js::parse(text)?)
    }

    /// Reads the SDK's JSON value.
    pub fn from_value(v: &Value) -> Result<JobState, JsonError> {
        let Value::Object(o) = v else {
            return Err(JsonError(format!("a job state must be an object, not {}", v.kind())));
        };
        let mut s = JobState { job: str_of(o, "job"), ..Default::default() };
        if let Some(Value::Object(open)) = o.get("open") {
            for (k, at) in open.iter() {
                s.open.push(OpenCondition { condition: Condition::parse(k), since: to_int(at) });
            }
        }
        s.consecutive_failures = int_of(o, "consecutiveFailures");
        s.silenced_until = nullable_int(o, "silencedUntil");
        s.last_alert_at = nullable_int(o, "lastAlertAt");
        if let Some(Value::Array(list)) = o.get("pendingRecovery") {
            s.pending_recovery = Some(list.iter().filter_map(|c| c.as_str().map(Condition::parse)).collect());
        }
        if let Some(Value::Array(list)) = o.get("undelivered") {
            // An entry that is not an alert is dropped rather than fail
            // every read of the state: it could never be delivered.
            s.undelivered = Some(list.iter().filter_map(|a| Alert::from_value(a).ok()).collect());
        }
        for (k, v) in o.iter() {
            if STATE_KEYS.contains(&k) {
                continue;
            }
            if k == "version" {
                // A version that is not a whole number (1.5, "x") reads as
                // none; one out of range is kept, so the state writes back
                // as it was read. Either counts as 0 (counted_version).
                s.version = match v {
                    Value::Number(n) if n.fract() == 0.0 => Some(js::to_i64(*n)),
                    _ => None,
                };
            }
            s.tail.push((k.to_string(), v.clone()));
        }
        Ok(s)
    }
}

/// One metric over its ceiling or its baseline.
#[derive(Clone, Debug, PartialEq)]
pub struct BudgetBreach {
    pub metric: String,
    pub value: f64,
    pub limit: f64,
    /// `budget`, or how the baseline was worked out.
    pub basis: String,
}

impl BudgetBreach {
    fn to_value(&self) -> Value {
        Value::Object(
            Object::new()
                .with("metric", self.metric.as_str())
                .with("value", self.value)
                .with("limit", self.limit)
                .with("basis", self.basis.as_str()),
        )
    }
}

/// What an alert carries beyond its title and message.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum AlertDetails {
    /// Which run was missed.
    Missed { due_at: i64, deadline: f64, grace_ms: f64, last_run_at: Option<i64> },
    /// The failures behind a failed or stuck alert.
    Failure { consecutive_failures: i64, threshold: i64 },
    /// How slow a run was; `basis` is `maxDuration`, or how the baseline was
    /// worked out.
    Slow { duration_ms: i64, threshold_ms: f64, basis: String },
    /// The metrics over their limits.
    OverBudget { breaches: Vec<BudgetBreach> },
    /// The conditions that closed. Reason `unscheduled` closes missed alone
    /// because the job no longer has a schedule; `since` is when missed
    /// opened.
    Recovered { after: Vec<Condition>, reason: Option<String>, since: Option<i64> },
}

impl AlertDetails {
    pub(crate) fn to_value(&self) -> Value {
        let o = match self {
            AlertDetails::Missed { due_at, deadline, grace_ms, last_run_at } => Object::new()
                .with("dueAt", *due_at)
                .with("deadline", *deadline)
                .with("graceMs", *grace_ms)
                .with("lastRunAt", *last_run_at),
            AlertDetails::Failure { consecutive_failures, threshold } => {
                Object::new().with("consecutiveFailures", *consecutive_failures).with("threshold", *threshold)
            }
            AlertDetails::Slow { duration_ms, threshold_ms, basis } => Object::new()
                .with("durationMs", *duration_ms)
                .with("thresholdMs", *threshold_ms)
                .with("basis", basis.as_str()),
            AlertDetails::OverBudget { breaches } => {
                Object::new().with("breaches", breaches.iter().map(BudgetBreach::to_value).collect::<Vec<_>>())
            }
            AlertDetails::Recovered { after, reason, since } => {
                let mut o =
                    Object::new().with("after", after.iter().map(|c| Value::from(c.as_str())).collect::<Vec<_>>());
                if let Some(reason) = reason.as_deref().filter(|r| !r.is_empty()) {
                    o.set("reason", reason);
                }
                if let Some(since) = since {
                    o.set("since", *since);
                }
                o
            }
        };
        Value::Object(o)
    }

    pub(crate) fn from_value(t: &AlertType, o: &Object) -> AlertDetails {
        match t {
            AlertType::Missed => AlertDetails::Missed {
                due_at: int_of(o, "dueAt"),
                deadline: float_of(o, "deadline"),
                grace_ms: float_of(o, "graceMs"),
                last_run_at: nullable_int(o, "lastRunAt"),
            },
            AlertType::Slow => AlertDetails::Slow {
                duration_ms: int_of(o, "durationMs"),
                threshold_ms: float_of(o, "thresholdMs"),
                basis: str_of(o, "basis"),
            },
            AlertType::OverBudget => {
                let empty = Object::new();
                let breaches = match o.get("breaches") {
                    Some(Value::Array(list)) => list
                        .iter()
                        .map(|b| {
                            let bo = b.as_object().unwrap_or(&empty);
                            BudgetBreach {
                                metric: str_of(bo, "metric"),
                                value: float_of(bo, "value"),
                                limit: float_of(bo, "limit"),
                                basis: str_of(bo, "basis"),
                            }
                        })
                        .collect(),
                    _ => Vec::new(),
                };
                AlertDetails::OverBudget { breaches }
            }
            AlertType::Recovered => AlertDetails::Recovered {
                after: match o.get("after") {
                    Some(Value::Array(list)) => list.iter().filter_map(|c| c.as_str().map(Condition::parse)).collect(),
                    _ => Vec::new(),
                },
                reason: o.get("reason").and_then(Value::as_str).map(str::to_string),
                since: nullable_int(o, "since"),
            },
            _ => AlertDetails::Failure {
                consecutive_failures: int_of(o, "consecutiveFailures"),
                threshold: int_of(o, "threshold"),
            },
        }
    }
}

/// A condition opening or closing, with the text every channel shows.
#[derive(Clone, Debug, PartialEq)]
pub struct Alert {
    pub alert_type: AlertType,
    /// The run behind the alert, when there is one.
    pub run: Option<Run>,
    pub details: AlertDetails,
    pub job: String,
    /// The job's definition when the alert was made.
    pub definition: Definition,
    /// One line, suitable as a notification title.
    pub title: String,
    /// A few lines of plain text with the specifics.
    pub message: String,
    /// A short diagnosis from the triage function, when one is configured.
    /// `None` with `triage_tried` set means triage was tried and gave
    /// nothing; it is not tried again for this alert.
    pub triage: Option<String>,
    pub triage_tried: bool,
    pub at: i64,
}

impl Alert {
    /// The alert as the SDK writes it.
    pub fn to_value(&self) -> Value {
        let mut o = Object::new()
            .with("type", self.alert_type.as_str())
            .with("run", self.run.as_ref().map_or(Value::Null, Run::to_value))
            .with("details", self.details.to_value())
            .with("job", self.job.as_str())
            .with("definition", self.definition.0.clone())
            .with("title", self.title.as_str())
            .with("message", self.message.as_str())
            .with("at", self.at);
        if self.triage_tried || self.triage.is_some() {
            o.set("triage", self.triage.clone());
        }
        Value::Object(o)
    }

    /// The SDK's JSON.
    pub fn to_json(&self) -> String {
        self.to_value().to_json()
    }

    /// Reads the SDK's JSON.
    pub fn from_json(text: &str) -> Result<Alert, JsonError> {
        Alert::from_value(&js::parse(text)?)
    }

    /// Reads the SDK's JSON value.
    pub fn from_value(v: &Value) -> Result<Alert, JsonError> {
        let Value::Object(o) = v else {
            return Err(JsonError(format!("an alert must be an object, not {}", v.kind())));
        };
        let alert_type = AlertType::parse(&str_of(o, "type"));
        // A queued alert's run keeps the metrics that are numbers, as a
        // stored run row does, so one another writer stored otherwise
        // cannot fail every read of the job's state.
        let run = match o.get("run") {
            None | Some(Value::Null) => None,
            Some(Value::Object(r)) => {
                let mut r = r.clone();
                let metrics = Metrics::lenient(r.get("metrics").unwrap_or(&Value::Null));
                r.set("metrics", metrics.to_value());
                Some(Run::from_value(&Value::Object(r))?)
            }
            Some(r) => Some(Run::from_value(r)?),
        };
        let empty = Object::new();
        let details =
            AlertDetails::from_value(&alert_type, o.get("details").and_then(Value::as_object).unwrap_or(&empty));
        Ok(Alert {
            run,
            details,
            job: str_of(o, "job"),
            definition: Definition(o.get("definition").and_then(Value::as_object).cloned().unwrap_or_default()),
            title: str_of(o, "title"),
            message: str_of(o, "message"),
            triage_tried: o.has("triage"),
            triage: nullable_str(o, "triage"),
            at: int_of(o, "at"),
            alert_type,
        })
    }
}

/// A job's last twenty runs of any status; the percentiles are over the
/// successful ones among them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Stats {
    pub runs: i64,
    pub ok_rate: f64,
    pub p50_ms: Option<i64>,
    pub p95_ms: Option<i64>,
}

/// A job and its health, as the dashboard shows it.
#[derive(Clone, Debug, PartialEq)]
pub struct JobSummary {
    pub name: String,
    pub definition: Definition,
    pub health: JobHealth,
    pub open: Vec<Condition>,
    pub last_run: Option<Run>,
    /// When the schedule says the next run is due. `None` without a schedule.
    pub next_expected_at: Option<i64>,
    pub consecutive_failures: i64,
    pub silenced_until: Option<i64>,
    pub stats: Stats,
}

impl JobSummary {
    /// The summary as the SDK writes it.
    pub fn to_value(&self) -> Value {
        let stats = Object::new()
            .with("runs", self.stats.runs)
            .with("okRate", self.stats.ok_rate)
            .with("p50Ms", self.stats.p50_ms)
            .with("p95Ms", self.stats.p95_ms);
        Value::Object(
            Object::new()
                .with("name", self.name.as_str())
                .with("definition", self.definition.0.clone())
                .with("health", self.health.as_str())
                .with("open", self.open.iter().map(|c| Value::from(c.as_str())).collect::<Vec<_>>())
                .with("lastRun", self.last_run.as_ref().map_or(Value::Null, Run::to_value))
                .with("nextExpectedAt", self.next_expected_at)
                .with("consecutiveFailures", self.consecutive_failures)
                .with("silencedUntil", self.silenced_until)
                .with("stats", stats),
        )
    }

    /// The SDK's JSON.
    pub fn to_json(&self) -> String {
        self.to_value().to_json()
    }
}

/// What a check found and sent.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CheckResult {
    pub checked_at: i64,
    pub jobs: Vec<JobSummary>,
    pub alerts: Vec<Alert>,
    pub pruned: i64,
}

impl CheckResult {
    /// The result as the SDK writes it.
    pub fn to_value(&self) -> Value {
        Value::Object(
            Object::new()
                .with("checkedAt", self.checked_at)
                .with("jobs", self.jobs.iter().map(JobSummary::to_value).collect::<Vec<_>>())
                .with("alerts", self.alerts.iter().map(Alert::to_value).collect::<Vec<_>>())
                .with("pruned", self.pruned),
        )
    }

    /// The SDK's JSON.
    pub fn to_json(&self) -> String {
        self.to_value().to_json()
    }
}

// ---- JSON helpers

pub(crate) fn str_of(o: &Object, key: &str) -> String {
    o.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

pub(crate) fn to_float(v: &Value) -> f64 {
    v.as_f64().unwrap_or(f64::NAN)
}

pub(crate) fn to_int(v: &Value) -> i64 {
    js::to_i64(to_float(v))
}

pub(crate) fn float_of(o: &Object, key: &str) -> f64 {
    o.get(key).map_or(f64::NAN, to_float)
}

pub(crate) fn int_of(o: &Object, key: &str) -> i64 {
    o.get(key).map_or(0, to_int)
}

pub(crate) fn nullable_int(o: &Object, key: &str) -> Option<i64> {
    o.get(key).and_then(Value::as_f64).map(js::to_i64)
}

pub(crate) fn nullable_str(o: &Object, key: &str) -> Option<String> {
    o.get(key).and_then(Value::as_str).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_duration_is_held_between_0_and_2_to_the_53_minus_1() {
        assert_eq!(run_duration(1000, 2500), 1500);
        assert_eq!(run_duration(i64::MIN, 1_767_605_400_000), MAX_DURATION_MS);
        assert_eq!(run_duration(i64::MAX, 1_767_605_400_000), 0);
        assert_eq!(run_duration(i64::MIN, i64::MAX), MAX_DURATION_MS);
        assert_eq!(run_duration(i64::MAX, i64::MIN), 0);
    }

    #[test]
    fn a_foreign_version_that_is_not_a_whole_number_counts_as_0() {
        for (text, want) in
            [("1.5", None), (r#""x""#, None), ("true", None), ("-1", Some(-1)), ("2.0", Some(2)), ("1e3", Some(1000))]
        {
            let s = JobState::from_json(&format!(r#"{{"job":"j","version":{text}}}"#)).unwrap();
            assert_eq!(s.version, want, "{text}");
            assert_eq!(s.counted_version(), want.filter(|v| *v >= 0).unwrap_or(0), "{text}");
        }
        let set = JobState { version: Some(-3), ..JobState::new("j") };
        assert_eq!(set.counted_version(), 0);
        let set = JobState { version: Some(MAX_DURATION_MS + 1), ..JobState::new("j") };
        assert_eq!(set.counted_version(), 0);
    }

    #[tokio::test]
    async fn the_memory_store_counts_a_foreign_version_as_0() {
        use crate::Store;
        let store = crate::MemoryStore::new();
        store.set_state(&JobState::from_json(r#"{"job":"j","version":1.5}"#).unwrap()).await.unwrap();
        let next = JobState { version: Some(1), ..JobState::new("j") };
        assert!(!store.compare_and_set_state(&next, 1).await.unwrap());
        assert!(store.compare_and_set_state(&next, 0).await.unwrap());
    }

    #[test]
    fn a_state_round_trips_with_unknown_keys_in_place() {
        let text = r#"{"job":"a","open":{"missed":5},"consecutiveFailures":2,"silencedUntil":null,"lastAlertAt":7,"pendingRecovery":["failed"],"version":3,"extra":{"x":1}}"#;
        let s = JobState::from_json(text).unwrap();
        assert_eq!(s.version, Some(3));
        assert_eq!(s.open_at(&Condition::Missed), Some(5));
        assert_eq!(s.to_json(), text);
    }

    #[test]
    fn a_queued_alert_of_another_shape_does_not_fail_the_state() {
        // The audit: a metric that is not a number, or an entry that is not
        // an alert, failed every read of the job's state.
        let text = r#"{"job":"k","version":1,"undelivered":[{"type":"failed","job":"k","run":{"id":"x","metrics":{"a":null,"b":2}}},7]}"#;
        let s = JobState::from_json(text).unwrap();
        let queued = s.undelivered.unwrap();
        assert_eq!(queued.len(), 1);
        assert_eq!(queued[0].run.as_ref().unwrap().metrics.to_json(), r#"{"b":2}"#);
    }

    #[test]
    fn metrics_keep_javascripts_order() {
        let mut m = Metrics::new();
        m.set("rows", 1.0);
        m.set("10", 2.0);
        m.set("2", 3.0);
        m.set("rows", 4.0);
        assert_eq!(m.to_json(), r#"{"2":3,"10":2,"rows":4}"#);
    }
}
