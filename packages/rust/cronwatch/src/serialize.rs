//! Expect rules and how a definition is stored (serialize.ts).

use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

use crate::js::{self, Object};
use crate::types::Definition;

/// A pattern a job's output must match somewhere, for
/// [`JobOptions::expect_match`](crate::JobOptions::expect_match). The
/// definition stores it as `matches <source>`, so `source` should read as
/// JavaScript writes a `RegExp`: `/done in \d+s/i`.
pub trait Matcher: Send + Sync {
    /// Whether the pattern matches somewhere in the text.
    fn is_match(&self, text: &str) -> bool;
    /// The pattern as JavaScript writes a `RegExp`, `/source/flags`.
    fn source(&self) -> String;
}

/// A job's expect option: what a successful run's output must satisfy, and
/// how the rule is described in the stored definition.
#[derive(Clone)]
pub(crate) enum ExpectRule {
    /// The output must contain the text.
    Contains(String),
    /// A pattern must match somewhere in the output.
    Matches(Arc<dyn Matcher>),
    /// A function must return true for the output.
    Func(Arc<dyn Fn(&str) -> bool + Send + Sync>),
}

impl fmt::Debug for ExpectRule {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.describe())
    }
}

impl ExpectRule {
    /// `None` when the output passes, or why it does not.
    pub(crate) fn check(&self, output: &str) -> Option<String> {
        match self {
            ExpectRule::Contains(text) => {
                (!output.contains(text.as_str())).then(|| format!("Output did not contain {}", js::quote(text)))
            }
            ExpectRule::Matches(m) => (!m.is_match(output)).then(|| format!("Output did not match {}", m.source())),
            ExpectRule::Func(f) => match catch_unwind(AssertUnwindSafe(|| f(output))) {
                Ok(true) => None,
                Ok(false) => Some("Output did not pass the expect() check".into()),
                Err(panic) => Some(format!("Output check threw: {}", crate::panics::panic_text(&*panic))),
            },
        }
    }

    /// The stored definition's `expect`.
    pub(crate) fn describe(&self) -> String {
        match self {
            ExpectRule::Contains(text) => format!("contains {}", js::quote(text)),
            ExpectRule::Matches(m) => format!("matches {}", m.source()),
            ExpectRule::Func(_) => "custom function".into(),
        }
    }
}

/// A definition as a store can hold it (serialize.ts `toStored`): the fields
/// as given, less `expect`, which goes last as a description.
pub(crate) fn to_stored(fields: &Object, rule: Option<&ExpectRule>) -> Definition {
    let mut out = Object::new();
    for (k, v) in fields.iter() {
        if k != "expect" {
            out.set(k, v.clone());
        }
    }
    if let Some(rule) = rule {
        out.set("expect", rule.describe());
    }
    Definition(out)
}

/// serialize.ts `checkExpectation`: `None` when there is no rule or the
/// output satisfies it, otherwise why not.
pub(crate) fn check_expectation(rule: Option<&ExpectRule>, output: Option<&str>) -> Option<String> {
    rule?.check(output.unwrap_or(""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rules_check_and_describe_as_the_sdk_does() {
        let contains = ExpectRule::Contains("done \"ok\"".into());
        assert_eq!(contains.describe(), r#"contains "done \"ok\"""#);
        assert_eq!(contains.check("done \"ok\" now"), None);
        assert_eq!(contains.check("nope").as_deref(), Some(r#"Output did not contain "done \"ok\"""#));
        let func = ExpectRule::Func(Arc::new(|out: &str| out.len() > 3));
        assert_eq!(func.describe(), "custom function");
        assert_eq!(func.check("ab").as_deref(), Some("Output did not pass the expect() check"));
        let panics = ExpectRule::Func(Arc::new(|_: &str| panic!("bad check")));
        assert_eq!(panics.check("x").as_deref(), Some("Output check threw: bad check"));
        assert_eq!(check_expectation(None, None), None);
        assert_eq!(check_expectation(Some(&contains), None).as_deref(), Some(r#"Output did not contain "done \"ok\"""#));
    }
}
