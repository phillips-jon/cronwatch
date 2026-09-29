//! The two crontab lines, run as two processes would run them, on one
//! SQLite file.

use std::process::Command;

fn crontab(command: &str, db: &std::path::Path) -> (bool, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_crontab")).arg(command).env("CRONWATCH_DB", db).output().unwrap();
    (out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned())
}

#[test]
fn a_report_then_a_check() {
    let dir = std::env::temp_dir().join(format!("cronwatch-crontab-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("cronwatch.db");
    assert_eq!(crontab("check", &db), (true, "cronwatch: checked 1 job, sent 0 alerts\n".into()), "before any run");
    assert_eq!(crontab("report", &db), (true, String::new()));
    assert_eq!(crontab("check", &db), (true, "cronwatch: checked 1 job, sent 0 alerts\n".into()), "after the run");
    assert!(!crontab("nope", &db).0, "an unknown command ran");
    let _ = std::fs::remove_dir_all(&dir);
}
