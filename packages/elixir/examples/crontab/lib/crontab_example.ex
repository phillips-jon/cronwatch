defmodule CrontabExample.Repo do
  @moduledoc "The app's repo, on a SQLite file."
  use Ecto.Repo, otp_app: :crontab_example, adapter: Ecto.Adapters.SQLite3
end

defmodule CrontabExample do
  @moduledoc """
  A job a crontab runs, watched by CronWatch, and the check a second line of
  the same crontab runs, both through the release:

      # m  h  dom mon dow  command
      0    2  *   *   *    /app/bin/crontab_example eval "CrontabExample.report()"
      */5  *  *   *   *    /app/bin/crontab_example eval "Cronwatch.Release.check(CrontabExample.Cronwatch)"

  Each line starts a node of its own, so the runs and the job's state live
  in a database both reach: a SQLite file here (`$CRONWATCH_DB`, else
  `./cronwatch.db`), or the app's Postgres or MySQL through its Ecto repo.
  `report/0` records its run as it ends and exits non-zero when it fails,
  as cron expects; the check finds the report missed when 02:00 passes
  without one (after the grace), a run that started and never ended stuck
  after its timeout, sends the alerts, and prints what it did.

  An app that stays up (a Phoenix app, a worker) checks in itself instead,
  with `check_every:` in its instance's options, or with Oban's
  `Cronwatch.Oban.CheckWorker`.
  """

  alias CrontabExample.Repo

  @doc "The nightly report, as a recorded run."
  def report do
    {:ok, _} = Application.ensure_all_started([:cronwatch, :ecto_sqlite3])
    {:ok, _} = Repo.start_link()
    config = Application.fetch_env!(:crontab_example, CrontabExample.Cronwatch)
    {:ok, _} = Cronwatch.start_link([name: CrontabExample.Cronwatch] ++ config)

    # Alerts go to the console (Logger) unless channels are given.
    result =
      Cronwatch.run(
        "nightly-report",
        fn job ->
          Cronwatch.log(job, "Report written: 42 rows")
          Cronwatch.metric(job, "rows", 42)
          :ok
        end,
        instance: CrontabExample.Cronwatch
      )

    # A failed run exits non-zero, so cron mails it.
    if result != :ok, do: System.halt(1)
    :ok
  end
end
