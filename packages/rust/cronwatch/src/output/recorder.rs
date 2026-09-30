use std::collections::VecDeque;
use std::sync::Mutex;

use super::OUTPUT_CAP;
use crate::js;

/// How much logged text a recorder holds, in code units, before it drops
/// lines from the front. `redact_and_cap` trims exactly at the end, so this only
/// bounds memory: well past the cap, so the kept tail is whole.
const WINDOW: usize = 64 * 1024;

/// `createRecorder` in `job.ts`: the lines a run logs and the numbers it
/// reports. It is safe to share, since a job may log from tasks of its own.
#[derive(Debug, Default)]
pub(crate) struct Recorder {
    inner: Mutex<Inner>,
}

#[derive(Debug, Default)]
struct Inner {
    /// The lines kept and their lengths in code units; the front is dropped
    /// once the total passes `WINDOW`.
    lines: VecDeque<(String, usize)>,
    size: usize,
    /// The first lines logged, until they reach `OUTPUT_CAP`, kept for
    /// expect even after the window has dropped them.
    head: Vec<String>,
    head_size: usize,
    dropped: bool,
    metrics: js::Object,
}

impl Recorder {
    /// An empty recorder.
    pub(crate) fn new() -> Recorder {
        Recorder::default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Appends a line.
    pub(crate) fn log(&self, line: impl Into<String>) {
        let line = line.into();
        let n = js::len16(&line);
        let mut r = self.lock();
        if r.head_size < OUTPUT_CAP {
            r.head.push(line.clone());
            r.head_size += n + 1;
        }
        r.lines.push_back((line, n));
        r.size += n + 1;
        // Drop from the front once well past the cap; redact_and_cap trims
        // exactly at the end.
        while r.size > WINDOW && r.lines.len() > 1 {
            let (_, len) = r.lines.pop_front().expect("more than one line");
            r.size -= len + 1;
            r.dropped = true;
        }
    }

    /// The lines still held (past 64 KB the oldest are let go), joined and
    /// not yet capped: the client redacts them first, then caps them
    /// (`redact_and_cap`). `None` when nothing was logged.
    pub(crate) fn output(&self) -> Option<String> {
        let r = self.lock();
        if r.lines.is_empty() {
            return None;
        }
        Some(join(&r.lines))
    }

    /// What an expect rule is checked against: everything logged, or when
    /// that ran long, the first 16 KB and the last 16 KB. The stored output
    /// keeps only the tail, so a "done" line printed early would otherwise
    /// be lost. `None` when nothing was logged.
    pub(crate) fn expect_text(&self) -> Option<String> {
        let r = self.lock();
        if r.lines.is_empty() {
            return None;
        }
        let all = join(&r.lines);
        if !r.dropped && js::len16(&all) <= 2 * OUTPUT_CAP {
            return Some(all);
        }
        Some(format!("{}\n{}", js::head16(&r.head.join("\n"), OUTPUT_CAP), js::tail16(&all, OUTPUT_CAP)))
    }

    /// Reports a number for the run; a later value for the same name
    /// replaces an earlier one.
    pub(crate) fn metric(&self, name: &str, value: f64) -> Result<(), String> {
        if !value.is_finite() {
            return Err(format!("metric \"{name}\" must be a finite number"));
        }
        self.lock().metrics.set(name, value);
        Ok(())
    }

    /// A copy of the numbers reported, in JavaScript's key order.
    pub(crate) fn metrics(&self) -> js::Object {
        self.lock().metrics.clone()
    }
}

fn join(lines: &VecDeque<(String, usize)>) -> String {
    let mut out = String::new();
    for (i, (line, _)) in lines.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        out.push_str(line);
    }
    out
}
