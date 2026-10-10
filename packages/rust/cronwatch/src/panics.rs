//! Panics as failed runs: the message always, and the panicking thread's
//! frames only when the app opted in with [`capture_panic_frames`].

use std::any::Any;
use std::backtrace::Backtrace;
use std::cell::RefCell;
use std::sync::Once;

/// A panic's payload as text: the `&str` or `String` a `panic!` carries, or
/// `Box<dyn Any>` for anything else, as the standard library's hook prints
/// it.
pub(crate) fn panic_text(payload: &(dyn Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "Box<dyn Any>".to_string()
    }
}

thread_local! {
    /// The frames of this thread's last panic, while the hook is installed.
    static FRAMES: RefCell<Option<Vec<String>>> = const { RefCell::new(None) };
}

static INSTALL: Once = Once::new();

/// Records the stack frames of a panic in a job's function with its run, up
/// to five, innermost first, as `    at function (file:line)` lines under
/// `panic: <message>`, as a JavaScript stack reads. Off by default: the
/// standard library hands a panic's backtrace to its hook alone, so this
/// installs a hook, chained to the one already set, that keeps the
/// panicking thread's backtrace for the run. Capturing a backtrace costs
/// time on every panic in the process, which is why it is opt-in. Calling
/// it again does nothing.
pub fn capture_panic_frames() {
    INSTALL.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let frames = frames_of(&Backtrace::force_capture().to_string());
            FRAMES.with(|f| *f.borrow_mut() = Some(frames));
            previous(info);
        }));
    });
}

/// The frames the hook kept for this thread's last panic, taken, or none.
pub(crate) fn take_frames() -> Vec<String> {
    FRAMES.with(|f| f.borrow_mut().take()).unwrap_or_default()
}

/// The frames of a backtrace's text that are the app's: the panic machinery
/// (`std`, `core`, `alloc`, the hook, and this crate's own) left out, at most
/// five, each `function (file:line)`.
fn frames_of(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut lines = text.lines().peekable();
    while let Some(line) = lines.next() {
        // "  12: path::to::function" then, when known, "             at src/x.rs:3:5".
        let Some((index, function)) = line.trim_start().split_once(": ") else {
            continue;
        };
        if !index.bytes().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let at = match lines.peek() {
            Some(next) if next.trim_start().starts_with("at ") => {
                let location = next.trim_start()["at ".len()..].to_string();
                lines.next();
                // file:line:column, written file:line as a JavaScript frame is.
                match location.rsplit_once(':') {
                    Some((file_line, column)) if column.bytes().all(|c| c.is_ascii_digit()) => file_line.to_string(),
                    _ => location,
                }
            }
            _ => String::new(),
        };
        let skipped = ["std::", "core::", "alloc::", "__rust", "rust_begin_unwind", "cronwatch::", "<cronwatch::"];
        if skipped.iter().any(|p| function.starts_with(p)) || function.contains("{{closure}}") && at.is_empty() {
            continue;
        }
        out.push(if at.is_empty() { function.to_string() } else { format!("{function} ({at})") });
        if out.len() == 5 {
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payloads_read_as_text() {
        assert_eq!(panic_text(&"boom"), "boom");
        assert_eq!(panic_text(&String::from("boom 2")), "boom 2");
        assert_eq!(panic_text(&5), "Box<dyn Any>");
    }

    #[test]
    fn frames_leave_out_the_panic_machinery() {
        let text = "   0: std::backtrace::Backtrace::force_capture\n             at /rustc/x/library/std/src/backtrace.rs:312:13\n   1: cronwatch::panics::capture_panic_frames::{{closure}}\n   2: app::jobs::nightly\n             at src/jobs.rs:10:5\n   3: app::main\n             at src/main.rs:3:1\n";
        assert_eq!(frames_of(text), vec!["app::jobs::nightly (src/jobs.rs:10)", "app::main (src/main.rs:3)"]);
    }
}
