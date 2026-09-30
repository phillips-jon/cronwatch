defmodule Cronwatch.Test.QScheduler do
  @moduledoc "The Quantum scheduler the tests start, one test at a time."
  use Quantum, otp_app: :cronwatch
end

defmodule Cronwatch.Test.QJobs do
  @moduledoc "Quantum jobs' tasks."

  def report do
    Cronwatch.log("Report written")
    Cronwatch.metric("rows", 12)
    :ok
  end

  def broken, do: raise("the report broke")
  def refused, do: {:error, :no_disk}
  def nightly, do: :ok
end

defmodule Cronwatch.QuantumTest do
  @moduledoc "Cronwatch.Quantum, against a real Quantum scheduler."
  use ExUnit.Case, async: false

  import Cronwatch.Test.Client
  import ExUnit.CaptureLog
  import Crontab.CronExpression

  alias Cronwatch.JS
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.QJobs
  alias Cronwatch.Test.QScheduler
  alias Cronwatch.Test.Stores

  # Quantum reads a job's zone through the app's time zone database; the
  # tests use tz's, as an app would configure it.
  setup_all do
    previous = Calendar.get_time_zone_database()
    Calendar.put_time_zone_database(Tz.TimeZoneDatabase)
    on_exit(fn -> Calendar.put_time_zone_database(previous) end)
  end

  # Schedules that do not fire while the tests run: runs come from run_job.
  defp start_scheduler(jobs) do
    start_supervised!({QScheduler, jobs: jobs, debug_logging: false})
  end

  defp stored(cw, name) do
    case Cronwatch.Config.get(cw) |> Cronwatch.Core.store!(:get_job, [name]) do
      nil -> nil
      %{definition: d} -> JS.stringify(d)
    end
  end

  defp integration(opts \\ []), do: {Cronwatch.Quantum, Keyword.merge([scheduler: QScheduler, app: "billing"], opts)}

  test "the scheduler's jobs are declared, each schedule checked against Quantum's reading" do
    start_scheduler(
      nightly_report: [schedule: "0 2 1 7 *", timezone: "Europe/London", task: {QJobs, :report, []}],
      odd: [schedule: "0 0 1 7 MON", task: {QJobs, :nightly, []}],
      paused: [schedule: "0 3 1 7 *", task: {QJobs, :nightly, []}, state: :inactive],
      ticks: [schedule: ~e[*/30 * * 1 7 *]e, task: {QJobs, :nightly, []}]
    )

    QScheduler.add_job(
      QScheduler.new_job()
      |> Quantum.Job.set_schedule(~e[0 4 1 7 *])
      |> Quantum.Job.set_task({QJobs, :nightly, []})
    )

    QScheduler.add_job(
      QScheduler.new_job()
      |> Quantum.Job.set_schedule(~e[0 5 1 7 *])
      |> Quantum.Job.set_task(fn -> :ok end)
    )

    %{cw: cw, errors: errors} =
      make(alerts: [], integrations: [integration(defaults: [grace: "5m"], jobs: [nightly_report: [timeout: "1h"]])])

    Cronwatch.Quantum.settle(instance: cw, scheduler: QScheduler)

    assert stored(cw, "nightly_report") ==
             ~s({"grace":"5m","schedule":"0 2 1 7 *","timezone":"Europe/London","timeout":"1h","tags":["quantum","quantum:billing"],"name":"nightly_report"})

    assert stored(cw, "ticks") ==
             ~s({"grace":"5m","schedule":"*/30 * * 1 7 *","timezone":"UTC","tags":["quantum","quantum:billing"],"name":"ticks"})

    assert stored(cw, "Cronwatch.Test.QJobs.nightly") =~ ~s("schedule":"0 4 1 7 *")
    assert stored(cw, "odd") == ~s({"grace":"5m","tags":["quantum","quantum:billing"],"name":"odd"})
    assert stored(cw, "paused") == nil

    found = Enum.zip(wheres(errors), messages(errors))
    assert {"declaring Quantum job odd", odd} = Enum.find(found, &(elem(&1, 0) == "declaring Quantum job odd"))
    assert odd =~ ~s(cronwatch: Quantum job odd is "0 0 1 7 1" in UTC, but after a run at)
    assert {"declaring a Quantum job", anon} = Enum.find(found, &(elem(&1, 0) == "declaring a Quantum job"))
    assert anon =~ "anonymous function"
  end

  test "each run is a run, with its logs, failures and errors" do
    start_scheduler(
      report: [schedule: "0 2 1 7 *", task: {QJobs, :report, []}],
      broken: [schedule: "0 2 1 7 *", task: {QJobs, :broken, []}],
      refused: [schedule: "0 2 1 7 *", task: {QJobs, :refused, []}]
    )

    %{cw: cw, alerts: alerts} = make(integrations: [integration()])
    Cronwatch.Quantum.settle(instance: cw, scheduler: QScheduler)

    QScheduler.run_job(:report)
    [run] = eventually(fn -> match_runs(cw, "report") end)
    assert {run.status, run.trigger, run.output} == {"ok", "quantum", "Report written"}
    assert JS.stringify(run.metrics) == ~s({"rows":12})

    capture_log(fn ->
      QScheduler.run_job(:broken)
      [broken] = eventually(fn -> match_runs(cw, "broken") end)
      assert broken.status == "failed"
      assert broken.error =~ ~r/\ARuntimeError: the report broke\n    at Cronwatch.Test.QJobs.broken\/0/
    end)

    QScheduler.run_job(:refused)
    [refused] = eventually(fn -> match_runs(cw, "refused") end)
    assert {refused.status, refused.error} == {"failed", ":no_disk"}
    assert Enum.sort(Capture.types(alerts)) == ["failed", "failed"]
  end

  defp match_runs(cw, name) do
    case Cronwatch.runs!(name, 5, instance: cw) do
      [%{status: status}] = list when status != "running" -> list
      _ -> nil
    end
  end

  test "a job deleted is declared again without its schedule, and one added is declared" do
    start_scheduler(nightly: [schedule: "0 2 1 7 *", task: {QJobs, :nightly, []}])
    %{cw: cw} = make(alerts: [], integrations: [integration()])
    Cronwatch.Quantum.settle(instance: cw, scheduler: QScheduler)
    assert stored(cw, "nightly") =~ ~s("schedule":"0 2 1 7 *")

    QScheduler.delete_job(:nightly)

    eventually(fn ->
      Cronwatch.Quantum.settle(instance: cw, scheduler: QScheduler)
      stored(cw, "nightly") =~ "no longer scheduled"
    end)

    QScheduler.add_job(
      QScheduler.new_job()
      |> Quantum.Job.set_name(:later)
      |> Quantum.Job.set_schedule(~e[0 6 1 7 *])
      |> Quantum.Job.set_task({QJobs, :nightly, []})
    )

    eventually(fn ->
      Cronwatch.Quantum.settle(instance: cw, scheduler: QScheduler)
      (stored(cw, "later") || "") =~ ~s("schedule":"0 6 1 7 *")
    end)
  end

  test "a job named by a module finds its options under that name" do
    start_scheduler([{Cronwatch.Test.QJobs, [schedule: "0 2 1 7 *", task: {QJobs, :nightly, []}]}])

    %{cw: cw} =
      make(alerts: [], integrations: [integration(jobs: [{Cronwatch.Test.QJobs, [timeout: "1h"]}])])

    Cronwatch.Quantum.settle(instance: cw, scheduler: QScheduler)
    assert stored(cw, "Cronwatch.Test.QJobs") =~ ~s("timeout":"1h")
  end

  test "an integration killed before it could detach is replaced by its restart" do
    start_scheduler(report: [schedule: "0 2 1 7 *", task: {QJobs, :report, []}])
    %{cw: cw, errors: errors} = make(alerts: [], integrations: [integration()])
    server = Cronwatch.Quantum.server(cw, QScheduler)
    old = Process.whereis(server)
    Process.exit(old, :kill)
    eventually(fn -> (pid = Process.whereis(server)) && pid != old end)
    Cronwatch.Quantum.settle(instance: cw, scheduler: QScheduler)

    QScheduler.run_job(:report)
    [run] = eventually(fn -> match_runs(cw, "report") end)
    assert run.status == "ok"
    assert messages(errors) == []
  end

  test "a job forgotten while Quantum still runs it comes back with its schedule" do
    start_scheduler(nightly: [schedule: "0 2 1 7 *", task: {QJobs, :nightly, []}])
    %{cw: cw} = make(alerts: [], integrations: [integration()])
    Cronwatch.Quantum.settle(instance: cw, scheduler: QScheduler)
    scheduled = stored(cw, "nightly")
    assert scheduled =~ ~s("schedule":"0 2 1 7 *")

    # The dashboard's Forget, then a run and a check with its sync.
    Cronwatch.forget!("nightly", instance: cw)
    QScheduler.run_job(:nightly)
    eventually(fn -> match_runs(cw, "nightly") end)
    assert {:ok, _} = Cronwatch.Quantum.check(instance: cw, scheduler: QScheduler)
    assert stored(cw, "nightly") == scheduled
    assert {:ok, _} = Cronwatch.Quantum.check(instance: cw, scheduler: QScheduler)
    assert stored(cw, "nightly") == scheduled
  end

  test "check/1 syncs and checks, and is never a job" do
    %{cw: earlier} = make(alerts: [])
    store = Cronwatch.Config.get(earlier).store
    Cronwatch.job!("gone", schedule: "0 3 * * *", tags: ["quantum", "quantum:billing"], instance: earlier)
    Cronwatch.check!(instance: earlier)

    start_scheduler(
      nightly: [schedule: "0 2 1 7 *", task: {QJobs, :nightly, []}],
      check: [schedule: "0 2 1 7 *", task: {Cronwatch.Quantum, :check, [[scheduler: QScheduler]]}]
    )

    %{cw: cw} = make(store: Stores.option(store), alerts: [], integrations: [integration()])
    assert {:ok, _} = Cronwatch.Quantum.check(instance: cw, scheduler: QScheduler)

    assert stored(cw, "gone") ==
             ~s|{"description":"A scheduled task (no longer scheduled)","tags":["quantum","quantum:billing"],"name":"gone"}|

    assert stored(cw, "check") == nil, "the check is never a job"
  end

  describe "Quantum's reading" do
    test "a schedule Quantum runs as CronWatch expects passes" do
      now = JS.date_utc(2026, 8, 1)

      assert Cronwatch.Quantum.convert(~e[*/15 9-17 * * 1-5], "America/New_York", "x", now) ==
               {:ok, "*/15 9-17 * * 1-5", "America/New_York"}

      assert Cronwatch.Quantum.convert(~e[0 2 * * *], :utc, "x", now) == {:ok, "0 2 * * *", "UTC"}
    end

    test "a time the clock change skips, or repeats, is named" do
      now = JS.date_utc(2026, 8, 1)
      assert {:error, m} = Cronwatch.Quantum.convert(~e[30 2 * * *], "America/New_York", "x", now)
      assert m =~ "does not exist in America/New_York"
      # Quantum runs neither 01:30 of the night clocks go back, where CronWatch expects the first.
      assert {:error, m} = Cronwatch.Quantum.convert(~e[30 1 * * *], "America/New_York", "x", now)
      assert m =~ "Quantum runs it next at"
    end

    test "@reboot and years are refused" do
      assert {:error, m} = Cronwatch.Quantum.convert(~e[@reboot], :utc, "x", 0)
      assert m =~ "not a schedule"
      assert {:error, m} = Cronwatch.Quantum.convert(~e[0 2 * * * 2030], :utc, "x", 0)
      assert m =~ "names years"
    end
  end
end
