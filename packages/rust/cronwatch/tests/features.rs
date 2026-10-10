//! The `regex` and `serde` features.

#[cfg(feature = "regex")]
#[tokio::test]
async fn expect_match_takes_a_regex() {
    use cronwatch::{Client, JobOptions, RunStatus};

    let cw = Client::builder().alerts([]).build().unwrap();
    let pattern = regex::Regex::new(r"(?i)done in \d+s/ok").unwrap();
    let job = cw.job("rx", JobOptions::new().expect_match(pattern)).unwrap();
    assert_eq!(job.definition().expect(), r"matches /(?i)done in \d+s\/ok/");
    job.run(|_| async { Ok::<_, std::io::Error>("Done in 12s/ok") }).await.unwrap();
    job.run(|_| async { Ok::<_, std::io::Error>("nothing") }).await.unwrap();
    let runs = cw.runs("rx", 5).await.unwrap();
    assert_eq!(runs[1].status, RunStatus::Ok);
    assert_eq!(runs[0].status, RunStatus::Failed);
    assert_eq!(runs[0].error.as_deref(), Some(r"Output did not match /(?i)done in \d+s\/ok/"));
}

#[cfg(feature = "serde")]
#[test]
fn the_public_types_serialize_as_the_sdk_writes_them() {
    use cronwatch::{Definition, JobState, Metrics, Run, RunStatus};

    let text = r#"{"id":"r1","job":"nightly","status":"failed","startedAt":1767605400000,"finishedAt":1767605401500,"durationMs":1500,"error":"Error: disk full","output":"a\nb","metrics":{"rows":3,"cost":1.25},"trigger":"run"}"#;
    let run = Run::from_json(text).unwrap();
    assert_eq!(serde_json::to_string(&run).unwrap(), text, "the SDK's fields, order, and numbers");
    let back: Run = serde_json::from_str(text).unwrap();
    assert_eq!(back, run);
    assert_eq!(serde_json::to_string(&RunStatus::Failed).unwrap(), r#""failed""#);
    assert_eq!(serde_json::from_str::<RunStatus>(r#""someday""#).unwrap(), RunStatus::parse("someday"));

    let def = r#"{"schedule":"0 2 * * *","budget":{"cost":2},"tags":["a"],"name":"nightly"}"#;
    let parsed: Definition = serde_json::from_str(def).unwrap();
    assert_eq!(parsed.to_json(), def);
    assert_eq!(serde_json::to_string(&parsed).unwrap(), def);

    let state =
        r#"{"job":"a","open":{"missed":5},"consecutiveFailures":2,"silencedUntil":null,"version":3,"extra":{"x":1}}"#;
    let s: JobState = serde_json::from_str(state).unwrap();
    assert_eq!(serde_json::to_string(&s).unwrap(), s.to_json());
    assert!(serde_json::from_str::<Metrics>(r#"{"a":"text"}"#).is_err(), "metrics are numbers");
}
