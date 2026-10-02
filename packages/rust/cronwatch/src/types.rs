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
        UnderFloor = "under_floor",
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
        UnderFloor = "under_floor",
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

/// Why text is not JSON (with `JSON.parse`'s wording and the byte
/// position), or why stored JSON could not be read as one of these types:
/// what [`js::parse`](crate::js::parse) and every `from_json` answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsonError(pub(crate) String);

impl fmt::Display for JsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for JsonError {}

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

/// The failures in a row a stored state's `consecutiveFailures` value counts
/// as, as the SDK's `failureCount` reads it: a JSON number that is a whole
/// number, held at [`MAX_DURATION_MS`] (2^53 - 1), and 0 when it is negative,
/// not a whole number, or not a number. A foreign row's count at a 64-bit
/// limit stays at the top instead of wrapping negative on the next failure.
pub(crate) fn failure_count(count: Option<&Value>) -> i64 {
    match count {
        Some(Value::Number(n)) if n.fract() == 0.0 && *n > 0.0 => n.min(MAX_DURATION_MS as f64) as i64,
        _ => 0,
    }
}

/// One execution of a job, as a store keeps it. Times are epoch milliseconds.
///
/// `#[non_exhaustive]`, so a release can add a field: a store of the app's
/// own makes one with [`Run::new`] and sets the rest, or reads one with
/// [`Run::from_json`].
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
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
    /// A run of `job` with this id, status and start, and nothing else: not
    /// finished, no error, output or metrics, trigger `run`. Set the other
    /// fields on what it returns.
    pub fn new(id: impl Into<String>, job: impl Into<String>, status: RunStatus, started_at: i64) -> Run {
        Run {
            id: id.into(),
            job: job.into(),
            status,
            started_at,
            finished_at: None,
            duration_ms: None,
            error: None,
            output: None,
            metrics: Metrics::new(),
            trigger: "run".into(),
        }
    }

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

/// A job as a store knows it. `#[non_exhaustive]`: a store makes one with
/// [`StoredJob::new`].
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub struct StoredJob {
    pub name: String,
    pub definition: Definition,
    pub created_at: i64,
    pub updated_at: i64,
    /// The stored definition was not a JSON object (see [`StoredJob::read`]).
    pub(crate) unreadable: bool,
}

impl StoredJob {
    /// The job `definition` names, first stored at `created_at` and last
    /// declared at `updated_at`.
    pub fn new(definition: Definition, created_at: i64, updated_at: i64) -> StoredJob {
        StoredJob { name: definition.name().to_string(), definition, created_at, updated_at, unreadable: false }
    }

    /// The job named `name` as a store read its row, with its definition as
    /// the JSON text the row holds, leniently, so a foreign, hand-edited or
    /// damaged row affects only its own job. A definition that does not
    /// parse, or is not a JSON object, becomes `{"name": <name>}` and the job
    /// is not readable ([`is_readable`](Self::is_readable)): the client
    /// reports it and shows it as failing, without evaluating it. `tags` is
    /// kept only when it is a list of strings; every other field is kept as
    /// stored.
    pub fn read(name: impl Into<String>, definition: &str, created_at: i64, updated_at: i64) -> StoredJob {
        let name = name.into();
        let (definition, unreadable) = match js::parse(definition) {
            Ok(Value::Object(o)) => (Definition(o), false),
            _ => (Definition(Object::new().with("name", name.as_str())), true),
        };
        StoredJob { name, definition, created_at, updated_at, unreadable }.read_leniently()
    }

    /// Whether the job's stored definition was a JSON object. One that was
    /// not ([`read`](Self::read)) is reported by a check and shown as
    /// failing.
    pub fn is_readable(&self) -> bool {
        !self.unreadable
    }

    /// The job as the client reads it (the SDK's `readStoredJob`): `tags`
    /// that is not a list of strings is left out.
    pub(crate) fn read_leniently(mut self) -> StoredJob {
        let odd = |v: &Value| !matches!(v, Value::Array(list) if list.iter().all(|t| t.as_str().is_some()));
        if self.definition.0.get("tags").is_some_and(odd) {
            self.definition.0.remove("tags");
        }
        self
    }
}

/// A condition that is open, and when it opened.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub struct OpenCondition {
    pub condition: Condition,
    pub since: i64,
}

impl OpenCondition {
    /// `condition`, open since `since`.
    pub fn new(condition: Condition, since: i64) -> OpenCondition {
        OpenCondition { condition, since }
    }
}

/// What the checks remember about a job between runs. Made with
/// [`JobState::new`] or read with [`JobState::from_json`].
#[derive(Clone, Debug, Default, PartialEq)]
#[non_exhaustive]
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
    /// The outbox: alerts written with the state that opened their
    /// condition, while the process that wrote them sends them. Each leaves
    /// once that process records how the send went; one still here after its
    /// `until` (the process stopped part way) goes to `undelivered` at the
    /// next check. `None` when empty, and in state written before the field
    /// existed: it is never written as `[]`.
    pub sending: Option<Vec<SendingAlert>>,
    /// The metrics under their floor at the job's last successful run.
    /// `None` when none, and in state written before the field existed: it
    /// is never written as `[]`.
    pub under_floor: Option<Vec<String>>,
    /// Goes up by one on every write (see `Store::compare_and_set_state`).
    /// `None` is a state written before versions, which counts as 0.
    pub version: Option<i64>,
    /// Keys after the known ones, in stored order: `version` and any a newer
    /// writer added, so a state is written back as the SDK's spread would
    /// write it.
    pub(crate) tail: Vec<(String, Value)>,
}

const STATE_KEYS: [&str; 9] = [
    "job",
    "open",
    "consecutiveFailures",
    "silencedUntil",
    "lastAlertAt",
    "pendingRecovery",
    "undelivered",
    "sending",
    "underFloor",
];

/// An alert in [`JobState::sending`]. Read leniently, as the SDK's
/// `releaseSending` treats an entry: one with no numeric `until` has run out,
/// and one with no alert (or one that is not an alert) is dropped when it
/// has, so a malformed entry never makes the whole state unreadable. Until
/// then it is written back as it was read.
#[derive(Clone, Debug, Default, PartialEq)]
#[non_exhaustive]
pub struct SendingAlert {
    /// When the sender's lease runs out, in epoch milliseconds.
    pub until: Option<i64>,
    /// The alert as composed, never with a triage.
    pub alert: Option<Alert>,
    /// What a stored entry holds that `until` and `alert` do not: written
    /// back as read, as the SDK carries an entry along unchanged until the
    /// next check lets it go.
    kept: KeptEntry,
}

/// The parts of a stored `sending` entry the port does not read.
#[derive(Clone, Debug, Default, PartialEq)]
struct KeptEntry {
    /// The entry as stored, when it is not an object.
    whole: Option<Value>,
    /// The entry's keys in the order read, each with its stored value when
    /// the port does not read it (a key it does not know, an `until` that
    /// is not a number, an `alert` that does not read as one) and `None`
    /// when `until` or `alert` holds it.
    keys: Vec<(String, Option<Value>)>,
}

impl SendingAlert {
    /// `alert`, held by its sender until `until`.
    pub fn new(until: Option<i64>, alert: Option<Alert>) -> SendingAlert {
        SendingAlert { until, alert, kept: KeptEntry::default() }
    }

    /// The entry as the SDK writes it: one read from a store as it was
    /// read, with `until` and `alert` as they are now.
    pub fn to_value(&self) -> Value {
        if let (Some(whole), None, None) = (&self.kept.whole, self.until, &self.alert) {
            return whole.clone();
        }
        let until = || self.until.map(Value::from);
        let alert = || self.alert.as_ref().map(Alert::to_value);
        let mut o = Object::new();
        for (k, stored) in &self.kept.keys {
            let now = match k.as_str() {
                "until" => until(),
                "alert" => alert(),
                _ => None,
            };
            if let Some(v) = now.or_else(|| stored.clone()) {
                o.set(k.as_str(), v);
            }
        }
        for (k, v) in [("until", until()), ("alert", alert())] {
            if let (Some(v), false) = (v, o.has(k)) {
                o.set(k, v);
            }
        }
        Value::Object(o)
    }

    fn from_value(v: &Value) -> SendingAlert {
        let Value::Object(o) = v else {
            return SendingAlert { kept: KeptEntry { whole: Some(v.clone()), keys: Vec::new() }, ..Default::default() };
        };
        let until = nullable_int(o, "until");
        let alert = o.get("alert").and_then(|a| Alert::from_value(a).ok());
        let mut keys: Vec<(String, Option<Value>)> = o
            .iter()
            .map(|(k, v)| {
                let held = match k {
                    "until" => until.is_some(),
                    "alert" => alert.is_some(),
                    _ => false,
                };
                (k.to_string(), (!held).then(|| v.clone()))
            })
            .collect();
        // An entry as the SDK writes it keeps nothing, so it equals one made
        // with `new`.
        let written = [until.is_some().then_some("until"), alert.is_some().then_some("alert")];
        if keys.iter().all(|(_, v)| v.is_none())
            && keys.iter().map(|(k, _)| k.as_str()).eq(written.into_iter().flatten())
        {
            keys.clear();
        }
        SendingAlert { until, alert, kept: KeptEntry { whole: None, keys } }
    }
}

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
        // Last, where the SDK's normalizeState puts it; never as [].
        if let Some(list) = self.sending.as_ref().filter(|l| !l.is_empty()) {
            o.set("sending", list.iter().map(SendingAlert::to_value).collect::<Vec<_>>());
        }
        if let Some(list) = self.under_floor.as_ref().filter(|l| !l.is_empty()) {
            o.set("underFloor", list.iter().map(|m| Value::from(m.as_str())).collect::<Vec<_>>());
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

    /// Reads the SDK's JSON value, leniently, as the SDK's `normalizeState`
    /// reads a stored state, so a foreign, hand-edited or damaged one affects
    /// only its own job: an `open` entry whose time is not a number is not
    /// open, a `silencedUntil` or `lastAlertAt` that is not a number is
    /// none, and `pendingRecovery` and `undelivered` keep only their entries
    /// of the right shape. Only a value that is not an object is an error
    /// (a store reads such a state as none).
    pub fn from_value(v: &Value) -> Result<JobState, JsonError> {
        let Value::Object(o) = v else {
            return Err(JsonError(format!("a job state must be an object, not {}", v.kind())));
        };
        let mut s = JobState { job: str_of(o, "job"), ..Default::default() };
        if let Some(Value::Object(open)) = o.get("open") {
            // Only the entries whose time is a number: another (a foreign or
            // damaged row's) is not an open condition.
            for (k, at) in open.iter() {
                if let Value::Number(n) = at {
                    s.open.push(OpenCondition { condition: Condition::parse(k), since: js::to_i64(*n) });
                }
            }
        }
        s.consecutive_failures = failure_count(o.get("consecutiveFailures"));
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
        if let Some(Value::Array(list)) = o.get("sending") {
            // Kept only when it holds an entry, as normalizeState keeps it.
            if !list.is_empty() {
                s.sending = Some(list.iter().map(SendingAlert::from_value).collect());
            }
        }
        if let Some(Value::Array(list)) = o.get("underFloor") {
            // Only its strings, and absent when it has none.
            let metrics: Vec<String> = list.iter().filter_map(|m| m.as_str().map(str::to_string)).collect();
            s.under_floor = (!metrics.is_empty()).then_some(metrics);
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

/// One metric over its ceiling or its baseline, or under its floor.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub struct BudgetBreach {
    pub metric: String,
    pub value: f64,
    pub limit: f64,
    /// `budget` or `floor`, or how the baseline was worked out.
    pub basis: String,
}

impl BudgetBreach {
    /// `metric` at `value`, over `limit`; `basis` is `budget`, or how the
    /// baseline was worked out.
    pub fn new(metric: impl Into<String>, value: f64, limit: f64, basis: impl Into<String>) -> BudgetBreach {
        BudgetBreach { metric: metric.into(), value, limit, basis: basis.into() }
    }

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

/// What an alert carries beyond its title and message. Each variant is
/// `#[non_exhaustive]`, so a release can add a field to one: match with
/// `..`, and make one with its constructor ([`AlertDetails::failure`] and
/// the others).
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum AlertDetails {
    /// Which run was missed.
    #[non_exhaustive]
    Missed { due_at: i64, deadline: f64, grace_ms: f64, last_run_at: Option<i64> },
    /// The failures behind a failed or stuck alert.
    #[non_exhaustive]
    Failure { consecutive_failures: i64, threshold: i64 },
    /// How slow a run was; `basis` is `maxDuration`, or how the baseline was
    /// worked out.
    #[non_exhaustive]
    Slow { duration_ms: i64, threshold_ms: f64, basis: String },
    /// The metrics over their limits.
    #[non_exhaustive]
    OverBudget { breaches: Vec<BudgetBreach> },
    /// The metrics under their floors. `limit` is the floor, or for a
    /// metric without one the lowest of the earlier runs it was judged
    /// against.
    #[non_exhaustive]
    UnderFloor { breaches: Vec<BudgetBreach> },
    /// The conditions that closed. Reason `unscheduled` closes missed alone
    /// because the job no longer has a schedule; `since` is when missed
    /// opened.
    #[non_exhaustive]
    Recovered { after: Vec<Condition>, reason: Option<String>, since: Option<i64> },
}

impl AlertDetails {
    /// [`AlertDetails::Missed`].
    pub fn missed(due_at: i64, deadline: f64, grace_ms: f64, last_run_at: Option<i64>) -> AlertDetails {
        AlertDetails::Missed { due_at, deadline, grace_ms, last_run_at }
    }

    /// [`AlertDetails::Failure`].
    pub fn failure(consecutive_failures: i64, threshold: i64) -> AlertDetails {
        AlertDetails::Failure { consecutive_failures, threshold }
    }

    /// [`AlertDetails::Slow`].
    pub fn slow(duration_ms: i64, threshold_ms: f64, basis: impl Into<String>) -> AlertDetails {
        AlertDetails::Slow { duration_ms, threshold_ms, basis: basis.into() }
    }

    /// [`AlertDetails::OverBudget`].
    pub fn over_budget(breaches: Vec<BudgetBreach>) -> AlertDetails {
        AlertDetails::OverBudget { breaches }
    }

    /// [`AlertDetails::UnderFloor`].
    pub fn under_floor(breaches: Vec<BudgetBreach>) -> AlertDetails {
        AlertDetails::UnderFloor { breaches }
    }

    /// [`AlertDetails::Recovered`].
    pub fn recovered(after: Vec<Condition>, reason: Option<String>, since: Option<i64>) -> AlertDetails {
        AlertDetails::Recovered { after, reason, since }
    }

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
            AlertDetails::OverBudget { breaches } | AlertDetails::UnderFloor { breaches } => {
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
            AlertType::OverBudget | AlertType::UnderFloor => {
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
                if *t == AlertType::UnderFloor {
                    AlertDetails::UnderFloor { breaches }
                } else {
                    AlertDetails::OverBudget { breaches }
                }
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
/// `#[non_exhaustive]`: the client makes alerts; a test of a channel of the
/// app's own makes one with [`Alert::new`] or reads one with
/// [`Alert::from_json`].
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
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
    /// What a stored alert holds that the fields above do not, written back
    /// as it was read.
    pub(crate) kept: KeptFields,
}

/// The parts of a stored alert the port does not read, kept so that a
/// field a newer release adds survives every write of the queue and goes
/// out with a retry, as the SDK keeps the JSON it read.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct KeptFields {
    /// Top-level keys the port does not know, in the order read.
    top: Vec<(String, Value)>,
    /// Keys of `details` its variant does not hold, in the order read.
    details: Vec<(String, Value)>,
    /// The details as stored, for an alert of a type the port does not know,
    /// and for a recovery whose details do not say what it recovers from.
    raw_details: Option<Value>,
    /// `at` as stored when it is not a number (`Some(None)` when absent),
    /// written back as it was read.
    raw_at: Option<Option<Value>>,
    /// Read from a foreign or damaged row in a shape no retry can judge: a
    /// recovery whose `details.after` is not a list of strings, or an alert
    /// whose `at` is not a number. Such an alert is stale (`stale_alert`).
    pub(crate) unjudgeable: bool,
}

const ALERT_KEYS: [&str; 9] = ["type", "run", "details", "job", "definition", "title", "message", "at", "triage"];

/// The details keys each known type's variant holds; `None` for a type the
/// port does not know, whose details are kept whole.
fn detail_keys(t: &AlertType) -> Option<&'static [&'static str]> {
    match t {
        AlertType::Missed => Some(&["dueAt", "deadline", "graceMs", "lastRunAt"]),
        AlertType::Failed | AlertType::Stuck => Some(&["consecutiveFailures", "threshold"]),
        AlertType::Slow => Some(&["durationMs", "thresholdMs", "basis"]),
        AlertType::OverBudget | AlertType::UnderFloor => Some(&["breaches"]),
        AlertType::Recovered => Some(&["after", "reason", "since"]),
        AlertType::Other(_) => None,
    }
}

impl Alert {
    /// An alert of `alert_type` for `job` at `at`, with these details and
    /// nothing else: no run, an empty definition, title and message, no
    /// triage. Set the other fields on what it returns.
    pub fn new(alert_type: AlertType, job: impl Into<String>, details: AlertDetails, at: i64) -> Alert {
        Alert {
            alert_type,
            run: None,
            details,
            job: job.into(),
            definition: Definition::default(),
            title: String::new(),
            message: String::new(),
            triage: None,
            triage_tried: false,
            at,
            kept: KeptFields::default(),
        }
    }

    /// The alert as the SDK writes it.
    pub fn to_value(&self) -> Value {
        let mut o = Object::new()
            .with("type", self.alert_type.as_str())
            .with("run", self.run.as_ref().map_or(Value::Null, Run::to_value))
            .with("details", self.details_value())
            .with("job", self.job.as_str())
            .with("definition", self.definition.0.clone())
            .with("title", self.title.as_str())
            .with("message", self.message.as_str());
        match &self.kept.raw_at {
            None => o.set("at", self.at),
            Some(Some(raw)) => o.set("at", raw.clone()),
            Some(None) => {}
        }
        // A field a newer release added goes before the triage, which the
        // SDK spreads onto an alert last.
        for (k, v) in &self.kept.top {
            o.set(k.as_str(), v.clone());
        }
        if self.triage_tried || self.triage.is_some() {
            o.set("triage", self.triage.clone());
        }
        Value::Object(o)
    }

    /// The SDK's JSON.
    pub fn to_json(&self) -> String {
        self.to_value().to_json()
    }

    /// The details as written: those of a type the port does not know as
    /// they were read, and a known type's with the keys its variant does not
    /// hold after its own.
    fn details_value(&self) -> Value {
        if let (AlertType::Other(_) | AlertType::Recovered, Some(raw)) = (&self.alert_type, &self.kept.raw_details) {
            return raw.clone();
        }
        let mut details = self.details.to_value();
        if let Value::Object(o) = &mut details {
            for (k, v) in &self.kept.details {
                if !o.has(k) {
                    o.set(k.as_str(), v.clone());
                }
            }
        }
        details
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
        let stored_details = o.get("details");
        let details_object = stored_details.and_then(Value::as_object);
        let details = AlertDetails::from_value(&alert_type, details_object.unwrap_or(&empty));
        let mut kept = KeptFields::default();
        match detail_keys(&alert_type) {
            None => kept.raw_details = stored_details.cloned(),
            Some(known) => {
                if let Some(d) = details_object {
                    kept.details =
                        d.iter().filter(|(k, _)| !known.contains(k)).map(|(k, v)| (k.to_string(), v.clone())).collect();
                }
            }
        }
        kept.top = o.iter().filter(|(k, _)| !ALERT_KEYS.contains(k)).map(|(k, v)| (k.to_string(), v.clone())).collect();
        // From a foreign or damaged row: a recovery that does not say what it
        // recovers from, with a list of strings, and an alert with no
        // numeric time, cannot be judged, and are stale. Each is written
        // back as it was read until a retry drops it.
        if alert_type == AlertType::Recovered {
            let after = details_object.and_then(|d| d.get("after"));
            let judged = matches!(after, Some(Value::Array(list)) if list.iter().all(|c| c.as_str().is_some()));
            if !judged {
                kept.unjudgeable = true;
                kept.raw_details = stored_details.cloned();
                kept.details.clear();
            }
        }
        match o.get("at") {
            Some(Value::Number(_)) => {}
            other => {
                kept.unjudgeable = true;
                kept.raw_at = Some(other.cloned());
            }
        }
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
            kept,
        })
    }
}

/// A job's last twenty runs of any status; the percentiles are over the
/// successful ones among them.
#[derive(Clone, Debug, Default, PartialEq)]
#[non_exhaustive]
pub struct Stats {
    pub runs: i64,
    pub ok_rate: f64,
    pub p50_ms: Option<i64>,
    pub p95_ms: Option<i64>,
}

/// A job and its health, as the dashboard shows it.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
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
#[non_exhaustive]
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

    #[test]
    fn failures_in_a_row_set_past_the_limit_are_held_there_and_never_wrap() {
        let failed = Run::from_value(
            &js::parse(r#"{"id":"f","job":"j","status":"failed","startedAt":1,"finishedAt":2,"durationMs":1}"#)
                .unwrap(),
        )
        .unwrap();
        let def = Definition::from_object(Object::new().with("name", "j").with("failuresBeforeAlert", 3));
        for (set, want) in [(i64::MAX, MAX_DURATION_MS), (MAX_DURATION_MS, MAX_DURATION_MS), (i64::MIN, 1), (-1, 1)] {
            let state = JobState { consecutive_failures: set, ..JobState::new("j") };
            let next = crate::evaluate::on_run_finish(&def, &failed, &state, &[], 2).unwrap().state;
            assert_eq!(next.consecutive_failures, want, "{set}");
        }
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

    /// A queued alert keeps every field a newer writer gave it, at its top
    /// level and in its details, as the SDK keeps the JSON it read.
    #[test]
    fn a_queued_alert_keeps_the_fields_it_does_not_know() {
        let known = r#"{"type":"failed","run":null,"details":{"consecutiveFailures":1,"threshold":1,"futureDetail":[1]},"job":"k","definition":{"a":1},"title":"t","message":"m","at":5,"futureAlertField":{"x":"y"},"triage":null}"#;
        let unknown = r#"{"type":"future","run":null,"details":{"a_b":1,"x":"y"},"job":"k","definition":{},"title":"t","message":"m","at":6,"futureAlertField":2}"#;
        let shapeless =
            r#"{"type":"future","run":null,"details":[1],"job":"k","definition":{},"title":"t","message":"m","at":7}"#;
        for text in [known, unknown, shapeless] {
            assert_eq!(Alert::from_json(text).unwrap().to_json(), text);
        }
        let state = format!(
            r#"{{"job":"k","open":{{}},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"pendingRecovery":[],"undelivered":[{known},{unknown}]}}"#
        );
        assert_eq!(JobState::from_json(&state).unwrap().to_json(), state);
        // A triage set on a retry goes where the SDK's spread puts it.
        let mut a = Alert::from_json(unknown).unwrap();
        a.triage = Some("look".into());
        assert_eq!(a.to_json(), unknown.replace(r#""futureAlertField":2"#, r#""futureAlertField":2,"triage":"look""#));
    }

    /// A `sending` entry is written back as it was read: a malformed one
    /// (not an object, an `until` that is not a number, an alert that does
    /// not read) and the keys of one the port does not know, until the next
    /// check lets it go.
    #[test]
    fn a_sending_entry_is_written_back_as_it_was_read() {
        let alert = r#"{"type":"failed","run":null,"details":{"consecutiveFailures":1,"threshold":1},"job":"k","definition":{},"title":"t","message":"m","at":5}"#;
        let sending = format!(
            r#"["x",null,{{"until":"x","alert":{alert}}},{{"until":9,"alert":{{"run":"bad"}}}},{{"until":9,"alert":{alert},"futureEntryKey":1}},{{"until":9}}]"#
        );
        let state = format!(
            r#"{{"job":"k","open":{{}},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"pendingRecovery":[],"undelivered":[],"sending":{sending}}}"#
        );
        let s = JobState::from_json(&state).unwrap();
        let entries = s.sending.as_ref().unwrap();
        assert_eq!(entries.len(), 6);
        assert_eq!((entries[2].until, entries[2].alert.is_some()), (None, true));
        assert_eq!((entries[3].until, entries[3].alert.is_some()), (Some(9), false));
        // One as the SDK writes it equals one made with `new`.
        assert_eq!(entries[5], SendingAlert::new(Some(9), None));
        assert_eq!(s.to_json(), state);
    }

    /// A queued alert a retry cannot judge (a recovery that does not say
    /// what it recovers from, an alert with no numeric time) is stale, and
    /// written back as it was read until the retry drops it; a state's open
    /// entry whose time is not a number is not open (the second review).
    #[test]
    fn an_alert_no_retry_can_judge_is_stale_and_written_back_as_read() {
        let state = JobState::from_json(r#"{"job":"j","open":{"failed":5,"slow":"x","stuck":null}}"#).unwrap();
        assert_eq!(state.open, vec![OpenCondition::new(Condition::Failed, 5)]);
        for text in [
            r#"{"type":"recovered","run":null,"details":{},"job":"j","definition":{},"title":"","message":"","at":5}"#,
            r#"{"type":"recovered","run":null,"details":"x","job":"j","definition":{},"title":"","message":"","at":5}"#,
            r#"{"type":"recovered","run":null,"details":{"after":["failed",1]},"job":"j","definition":{},"title":"","message":"","at":5}"#,
            r#"{"type":"failed","run":null,"details":{"consecutiveFailures":1,"threshold":1},"job":"j","definition":{},"title":"","message":"","at":"x"}"#,
            r#"{"type":"failed","run":null,"details":{"consecutiveFailures":1,"threshold":1},"job":"j","definition":{},"title":"","message":""}"#,
        ] {
            let alert = Alert::from_json(text).unwrap();
            assert!(crate::evaluate::stale_alert(&alert, &state), "{text}");
            assert_eq!(alert.to_json(), text);
        }
        let judged = r#"{"type":"failed","run":null,"details":{"consecutiveFailures":1,"threshold":1},"job":"j","definition":{},"title":"","message":"","at":5}"#;
        assert!(!crate::evaluate::stale_alert(&Alert::from_json(judged).unwrap(), &state));
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
