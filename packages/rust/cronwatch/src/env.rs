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
    for name in VARIABLES {
        let value = std::env::var(name).unwrap_or_default().trim().to_lowercase();
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
