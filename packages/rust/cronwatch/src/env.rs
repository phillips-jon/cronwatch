//! The environment, read in one place.

/// The variables that name the environment, first set wins. The SDK reads
/// `NODE_ENV`; Rust has no one convention, so CronWatch's own variable comes
/// first, then `APP_ENV` (as the PHP and Go ports read it) and `RUST_ENV`
/// (the Go port's `GO_ENV`).
const VARIABLES: [&str; 3] = ["CRONWATCH_ENV", "APP_ENV", "RUST_ENV"];

/// The environment's name, lowercased, or `""` when no variable names one.
/// `development`, `dev`, `local`, `test` and `testing` count as
/// `development` and `prod` as `production`, as in the PHP and Go ports. A
/// debug build is not development: `cfg!(debug_assertions)` says how the
/// code was compiled, not where it runs.
pub(crate) fn environment() -> String {
    environment_from(|name| std::env::var(name).ok())
}

/// [`environment`] over variables `read` gives. The first whose value,
/// trimmed as `String.prototype.trim` trims, is not empty wins: a value of
/// only spaces counts as unset, and the next variable is read, as in every
/// port.
fn environment_from(read: impl Fn(&str) -> Option<String>) -> String {
    for name in VARIABLES {
        let value = crate::js::trim(&read(name).unwrap_or_default()).to_lowercase();
        if value.is_empty() {
            continue;
        }
        return match value.as_str() {
            "prod" => "production".into(),
            "dev" | "local" | "test" | "testing" => "development".into(),
            _ => value,
        };
    }
    String::new()
}

/// Claude triage's API key and base URL, from the variables the official
/// Anthropic client reads: `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL`,
/// `""` when unset.
#[cfg(feature = "triage")]
pub(crate) fn anthropic() -> (String, String) {
    let read = |name: &str| std::env::var(name).unwrap_or_default();
    (read("ANTHROPIC_API_KEY"), read("ANTHROPIC_BASE_URL"))
}

#[cfg(test)]
mod tests {
    use super::environment_from;

    /// The SDK's cases (packages/sdk/test/env.test.ts, plan D8), with
    /// `RUST_ENV` in `NODE_ENV`'s place.
    #[test]
    fn the_environment_is_read_as_every_port_reads_it() {
        let cases: [(&str, &str, &str, &str); 12] = [
            ("", "", "", ""),
            ("", "", "development", "development"),
            ("", "", "test", "development"),
            ("", "", "production", "production"),
            ("", "local", "production", "development"),
            ("production", "dev", "development", "production"),
            ("staging", "", "development", "staging"),
            ("  PROD ", "", "", "production"),
            ("", "Testing", "", "development"),
            ("", "DEV", "", "development"),
            ("", "   ", "production", "production"),
            (" \t", "", "", ""),
        ];
        for (cronwatch, app, own, want) in cases {
            let got = environment_from(|name| {
                let v = match name {
                    "CRONWATCH_ENV" => cronwatch,
                    "APP_ENV" => app,
                    "RUST_ENV" => own,
                    _ => "",
                };
                (!v.is_empty() || name == "CRONWATCH_ENV").then(|| v.to_string())
            });
            assert_eq!(got, want, "CRONWATCH_ENV={cronwatch:?} APP_ENV={app:?} RUST_ENV={own:?}");
        }
    }

    /// Each value is trimmed as `String.prototype.trim` trims it: U+FEFF
    /// alone counts as unset, and U+0085, which JavaScript keeps, does not.
    #[test]
    fn the_environment_is_trimmed_as_javascript_trims() {
        let read = |first: &'static str| {
            move |name: &str| match name {
                "CRONWATCH_ENV" => Some(first.to_string()),
                "APP_ENV" => Some("production".to_string()),
                _ => None,
            }
        };
        assert_eq!(environment_from(read("\u{feff}")), "production");
        assert_eq!(environment_from(read("\u{feff}dev\u{3000}")), "development");
        assert_eq!(environment_from(read("\u{85}")), "\u{85}");
    }
}
