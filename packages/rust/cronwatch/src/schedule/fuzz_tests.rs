//! The croner port against croner itself: thousands of generated cron
//! expressions (valid and not, nicknames, names, ranges, steps, lists, L, W,
//! LW, #, ?, +, six and seven fields, in zones with and without daylight
//! saving, from times around the clock changes) answered by the SDK in Node
//! (tests/testdata/schedule_fuzz.mjs, which imports packages/sdk/dist) and
//! by this module, which must agree on every error message and every fire
//! time. Seeded, so a failure repeats; the generator is the Go, Python and
//! PHP ports', over a random source of its own.

use std::path::Path;
use std::process::Command;

use super::*;
use crate::js::{Object, Value, date_utc, iso_string, parse as parse_json, stringify};

const ZONES: [&str; 9] = [
    "",
    "UTC",
    "America/New_York",
    "Europe/London",
    "Australia/Lord_Howe",
    "America/Santiago",
    "Asia/Kolkata",
    "Pacific/Chatham",
    "Europe/Berlin",
];
const MONTHS: [&str; 12] = ["jan", "FEB", "Mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const DAYS: [&str; 7] = ["sun", "MON", "Tue", "wed", "thu", "fri", "sat"];
const NICKNAMES: [&str; 10] =
    ["@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly", "@HOURLY", "@reboot", "@every"];

/// SplitMix64: small, seeded and the same on every platform.
struct Fuzzer(u64);

impl Fuzzer {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn chance(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn between(&mut self, lo: i64, hi: i64) -> i64 {
        lo + (self.next() % (hi - lo + 1) as u64) as i64
    }

    fn pick<T: Clone>(&mut self, items: &[T]) -> T {
        items[self.next() as usize % items.len()].clone()
    }

    /// One cron field: mostly valid, sometimes out of range or malformed.
    fn field(&mut self, low: i64, high: i64, names: &[&str]) -> String {
        let size = high - low + 1;
        let kind = self.chance();
        if kind < 0.3 {
            return "*".into();
        }
        if kind < 0.45 {
            return self.value(low, high, names);
        }
        if kind < 0.6 {
            let (mut a, mut b) = self.pair(low, high);
            if self.chance() < 0.05 {
                (a, b) = (b + 1, a);
            }
            return format!("{a}-{b}");
        }
        if kind < 0.75 {
            return format!("*/{}", self.pick(&[1, 2, 3, 5, 7, 10, 15, 30, size, size + 1, 0]));
        }
        if kind < 0.85 {
            let (a, b) = self.pair(low, high);
            let step = self.between(1, (size / 2).max(1));
            return format!("{a}-{b}/{step}");
        }
        if kind < 0.97 {
            let n = self.between(2, 4);
            return (0..n).map(|_| self.value(low, high, names)).collect::<Vec<_>>().join(",");
        }
        self.pick(&["?", "x", "", "5/15", "/5", "1-", "-1"]).to_string()
    }

    fn value(&mut self, low: i64, high: i64, names: &[&str]) -> String {
        if !names.is_empty() && self.chance() < 0.3 {
            return self.pick(names).to_string();
        }
        if self.chance() < 0.05 {
            return self.pick(&[high + 1, low - 1, 99]).to_string();
        }
        self.between(low, high).to_string()
    }

    fn pair(&mut self, low: i64, high: i64) -> (i64, i64) {
        let (a, b) = (self.between(low, high), self.between(low, high));
        if a > b { (b, a) } else { (a, b) }
    }

    fn day_of_month(&mut self) -> String {
        let kind = self.chance();
        if kind < 0.1 {
            return self.pick(&["L", "LW", "15W", "1W", "31W", "5L", "L,15"]).to_string();
        }
        if kind < 0.2 {
            return "?".into();
        }
        self.field(1, 31, &[])
    }

    fn day_of_week(&mut self) -> String {
        let kind = self.chance();
        if kind < 0.1 {
            let (a, b) = (self.between(0, 7), self.between(0, 6));
            return format!("{a}#{b}");
        }
        if kind < 0.18 {
            return format!("{}L", self.between(0, 6));
        }
        if kind < 0.24 {
            return format!("+{}", self.field(0, 7, &DAYS));
        }
        if kind < 0.3 {
            let (a, b) = (self.pick(&DAYS), self.pick(&DAYS));
            return format!("{a}-{b}");
        }
        self.field(0, 7, &DAYS)
    }

    fn expression(&mut self) -> String {
        if self.chance() < 0.05 {
            return self.pick(&NICKNAMES).to_string();
        }
        let mut parts = vec![
            self.field(0, 59, &[]),
            self.field(0, 23, &[]),
            self.day_of_month(),
            self.field(1, 12, &MONTHS),
            self.day_of_week(),
        ];
        if self.chance() < 0.25 {
            parts.insert(0, self.field(0, 59, &[]));
        }
        if self.chance() < 0.02 {
            parts.push("*".into());
        }
        parts.join(" ")
    }
}

struct Case {
    schedule: String,
    timezone: String,
    from: i64,
    count: i64,
}

fn fuzz_cases(seed: u64, count: usize) -> Vec<Case> {
    let mut f = Fuzzer(seed);
    // Around the nights clocks change in the zones above, and ordinary days.
    let starts = [
        date_utc(2026, 2, 8, 6, 30, 0, 0),
        date_utc(2026, 10, 1, 5, 10, 0, 0),
        date_utc(2026, 2, 29, 0, 45, 0, 0),
        date_utc(2026, 9, 25, 0, 50, 0, 0),
        date_utc(2026, 9, 3, 15, 20, 0, 0),
        date_utc(2026, 3, 4, 14, 55, 0, 0),
        date_utc(2026, 0, 5, 9, 30, 0, 0),
        date_utc(2027, 1, 27, 23, 59, 59, 0),
        date_utc(2028, 1, 28, 12, 0, 0, 0),
    ];
    (0..count)
        .map(|_| {
            let from =
                f.pick(&starts) + f.between(-3, 3) * 3_600_000 + f.between(0, 3_599) * 1000 + f.pick(&[0, 0, 500, 999]);
            let schedule = f.expression();
            let count = f.between(1, 6);
            let timezone = f.pick(&ZONES).to_string();
            Case { schedule, timezone, from, count }
        })
        .collect()
}

/// This port's answer, as the helper writes the SDK's: `{error}` or `{fires}`.
fn answer(c: &Case) -> Object {
    let p = match parse(&c.schedule, &c.timezone) {
        Ok(p) => p,
        Err(e) => return Object::new().with("error", e),
    };
    let mut fires = Vec::new();
    let mut at = c.from;
    for _ in 0..c.count {
        match next_fire(&p, at, None) {
            Some(next) => {
                fires.push(Value::from(next));
                at = next;
            }
            None => {
                fires.push(Value::Null);
                break;
            }
        }
    }
    Object::new().with("fires", fires)
}

fn show(a: &Object) -> String {
    if let Some(e) = a.get("error") {
        return format!("error {}", e.as_str().unwrap_or(""));
    }
    let fires = a.get("fires").and_then(Value::as_array).cloned().unwrap_or_default();
    let parts: Vec<String> =
        fires.iter().map(|t| t.as_f64().map_or_else(|| "null".to_string(), |t| iso_string(t as i64))).collect();
    format!("[{}]", parts.join(" "))
}

#[test]
fn the_port_agrees_with_croner() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let helper = root.join("../cronwatch/tests/testdata/schedule_fuzz.mjs");
    if !root.join("../../sdk/dist/index.js").exists() {
        eprintln!("croner parity: skipped, packages/sdk/dist is not built (npm run build --workspace packages/sdk)");
        return;
    }
    if Command::new("node").arg("--version").output().is_err() {
        eprintln!("croner parity: skipped, node is not installed");
        return;
    }
    for seed in [1u64, 2, 3] {
        let generated = fuzz_cases(seed, 1000);
        let input: Vec<Value> = generated
            .iter()
            .map(|c| {
                let zone = if c.timezone.is_empty() { Value::Null } else { Value::from(c.timezone.as_str()) };
                Value::Object(
                    Object::new()
                        .with("schedule", c.schedule.as_str())
                        .with("timezone", zone)
                        .with("from", c.from)
                        .with("count", c.count),
                )
            })
            .collect();
        let file = std::env::temp_dir().join(format!("cronwatch-schedule-fuzz-{}-{seed}.json", std::process::id()));
        std::fs::write(&file, stringify(&Value::Array(input))).unwrap();
        let out = Command::new("node").arg(&helper).arg(&file).env("TZ", "UTC").output().unwrap();
        let _ = std::fs::remove_file(&file);
        assert!(out.status.success(), "node: {}", String::from_utf8_lossy(&out.stderr));
        let expected = parse_json(&String::from_utf8(out.stdout).unwrap()).unwrap();
        let expected = expected.as_array().unwrap();

        let mut differences = Vec::new();
        let (mut valid, mut refused, mut threw) = (0, 0, 0);
        for (c, want) in generated.iter().zip(expected) {
            let want = want.as_object().unwrap();
            let got = answer(c);
            if want.has("error") {
                refused += 1;
            } else {
                valid += 1;
            }
            if let Some(throws) = want.get("throws") {
                threw += 1;
                // croner walks by recursion, a year at a time, so a date no
                // month has (February 30) runs out of stack before the year
                // 3000. The port walks in a loop and finds nothing: the
                // schedule never fires.
                let mut prefix = want.get("fires").and_then(Value::as_array).cloned().unwrap_or_default();
                prefix.push(Value::Null);
                let fires = got.get("fires").and_then(Value::as_array).cloned().unwrap_or_default();
                if fires.len() < prefix.len() || fires[..prefix.len()] != prefix[..] {
                    differences.push(format!(
                        "{} in {:?} from {}\n    croner threw {} after {}\n    rust {}",
                        c.schedule,
                        c.timezone,
                        c.from,
                        throws.as_str().unwrap_or(""),
                        show(want),
                        show(&got)
                    ));
                }
                continue;
            }
            if stringify(&Value::Object(want.clone())) != stringify(&Value::Object(got.clone())) {
                differences.push(format!(
                    "{} in {:?} from {}\n    croner {}\n    rust   {}",
                    c.schedule,
                    c.timezone,
                    c.from,
                    show(want),
                    show(&got)
                ));
            }
        }
        differences.sort();
        assert!(
            differences.is_empty(),
            "seed {seed}: {} of {} differ:\n{}",
            differences.len(),
            generated.len(),
            differences[..differences.len().min(10)].join("\n")
        );
        assert!(
            valid >= 300,
            "seed {seed}: only {valid} generated expressions were valid; the walk needs more exercise"
        );
        eprintln!(
            "seed {seed}: {} cases: {valid} valid ({threw} where croner ran out of stack), {refused} refused with croner's message",
            generated.len()
        );
    }
}
