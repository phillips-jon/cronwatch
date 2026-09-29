import Config

# Read when the release starts, so each crontab line can point it at the
# file: $CRONWATCH_DB, else ./cronwatch.db.
config :crontab_example, CrontabExample.Repo,
  database: System.get_env("CRONWATCH_DB", "cronwatch.db"),
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5000

# The instance both lines start: the job is declared here, so the check
# knows its schedule even before its first run.
config :crontab_example, CrontabExample.Cronwatch,
  store: {Cronwatch.Store.Ecto, repo: CrontabExample.Repo},
  jobs: [
    {"nightly-report", schedule: "0 2 * * *", timezone: "UTC", grace: "15m", timeout: "30m", expect: "Report written"}
  ]
