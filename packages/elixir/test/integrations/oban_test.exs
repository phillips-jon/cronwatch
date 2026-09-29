defmodule Cronwatch.Test.Workers.Nightly do
  @moduledoc "Fails its first two attempts, logs through current/0, and succeeds on the third."
  use Oban.Worker, queue: :default, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt}) do
    Cronwatch.log("attempt #{attempt}")
    Cronwatch.metric("rows", attempt * 10)
    if attempt < 3, do: {:error, "database busy"}, else: :ok
  end

  @impl Oban.Worker
  def backoff(_job), do: 0
end

defmodule Cronwatch.Test.Workers.Snoozer do
  @moduledoc "Snoozes."
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(_job), do: {:snooze, 1}
end

defmodule Cronwatch.Test.Workers.Canceller do
  @moduledoc "Gives up on its job."
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(_job), do: {:cancel, "the invoice was deleted"}
end

defmodule Cronwatch.Test.Workers.Raiser do
  @moduledoc "Raises."
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(_job), do: raise("the report broke")
end

defmodule Cronwatch.Test.Workers.Email do
  @moduledoc "A worker outside the crontab."
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(_job), do: :ok
end

defmodule Cronwatch.Test.Workers.Slow do
  @moduledoc "Sleeps past its timeout."
  use Oban.Worker, queue: :slow, max_attempts: 1

  @impl Oban.Worker
  def perform(_job), do: Process.sleep(:infinity)

  @impl Oban.Worker
  def timeout(_job), do: 100
end

defmodule Cronwatch.ObanTest do
  @moduledoc "Cronwatch.Oban: Oban on SQLite (the Lite engine) always, and on Postgres when CRONWATCH_TEST_PG is set."
  use ExUnit.Case, async: false

  import Cronwatch.Test.Client

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Oban.CheckWorker
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Oban, as: TestOban
  alias Cronwatch.Test.Stores
  alias Cronwatch.Test.Workers

  @moduletag timeout: 120_000

  # Oban reads a crontab's zones through the app's time zone database; the
  # tests use tz's, as an app would configure it. CronWatch itself never
  # sets it.
  setup_all do
    previous = Calendar.get_time_zone_database()
    Calendar.put_time_zone_database(Tz.TimeZoneDatabase)
    on_exit(fn -> Calendar.put_time_zone_database(previous) end)
  end

  # A cron job as the plugin inserts it.
  defp cron_job(worker, expr \\ "0 2 * * *") do
    worker.new(%{}, meta: %{cron: true, cron_expr: expr, cron_tz: "Etc/UTC"})
  end

  defp drain(oban, queue \\ :default) do
    Oban.drain_queue(oban, queue: queue, with_recursion: true, with_scheduled: true)
  end

  defp stored(cw, name) do
    case Cronwatch.Config.get(cw) |> Cronwatch.Core.store!(:get_job, [name]) do
      nil -> nil
      %{definition: d} -> JS.stringify(d)
    end
  end

  defp runs(cw, name), do: Cronwatch.runs!(name, 50, instance: cw) |> Enum.reverse()

  for engine <- Cronwatch.Test.Oban.engines() do
    describe "on #{engine}" do
      @describetag engine: engine

      test "the crontab's jobs are declared, each schedule checked against Oban's reading", %{engine: engine} do
        oban =
          TestOban.start(engine,
            plugins: [
              {Oban.Plugins.Cron,
               timezone: "Europe/London",
               crontab: [
                 {"0 2 * * *", Workers.Nightly},
                 {"@hourly", Workers.Email},
                 {"0 0 1 * MON", Workers.Canceller},
                 {"* * * * *", Cronwatch.Oban.CheckWorker}
               ]}
            ]
          )

        %{cw: cw, errors: errors} =
          make(
            alerts: [],
            integrations: [
              {Cronwatch.Oban,
               oban: oban, app: "billing", defaults: [grace: "5m"], workers: [{Workers.Nightly, timeout: "1h"}]}
            ]
          )

        Cronwatch.Oban.settle(instance: cw, oban: oban)

        assert stored(cw, "Cronwatch.Test.Workers.Nightly") ==
                 ~s({"grace":"5m","schedule":"0 2 * * *","timezone":"Europe/London","timeout":"1h","tags":["oban","oban:billing"],"name":"Cronwatch.Test.Workers.Nightly"})

        assert stored(cw, "Cronwatch.Test.Workers.Email") ==
                 ~s({"grace":"5m","schedule":"0 * * * *","timezone":"Europe/London","tags":["oban","oban:billing"],"name":"Cronwatch.Test.Workers.Email"})

        assert stored(cw, "Cronwatch.Test.Workers.Canceller") ==
                 ~s({"grace":"5m","tags":["oban","oban:billing"],"name":"Cronwatch.Test.Workers.Canceller"})

        assert stored(cw, "Cronwatch.Oban.CheckWorker") == nil, "the check is never a job"

        assert [{"declaring Oban crontab entry for Cronwatch.Test.Workers.Canceller", message}] =
                 Enum.zip(wheres(errors), messages(errors))

        assert message =~
                 ~s(cronwatch: Oban crontab entry for Cronwatch.Test.Workers.Canceller is "0 0 1 * MON" in Europe/London)

        assert message =~ "Oban runs it next at"
      end

      test "each attempt is a run: two failures, then a success", %{engine: engine} do
        oban = TestOban.start(engine)

        %{cw: cw, alerts: alerts} =
          make(integrations: [{Cronwatch.Oban, oban: oban, workers: [{Workers.Nightly, failures_before_alert: 1}]}])

        {:ok, job} = Oban.insert(oban, cron_job(Workers.Nightly))
        drain(oban)

        list = runs(cw, "Cronwatch.Test.Workers.Nightly")
        assert Enum.map(list, & &1.id) == for(n <- 1..3, do: "oban:#{job.id}:#{n}")
        assert Enum.map(list, & &1.status) == ["failed", "failed", "ok"]
        assert Enum.map(list, & &1.trigger) == ["oban", "oban", "oban"]

        assert hd(list).error =~
                 ~s(Oban.PerformError: Cronwatch.Test.Workers.Nightly failed with {:error, "database busy"})

        assert List.last(list).output == "attempt 3"
        assert JS.stringify(List.last(list).metrics) == ~s({"rows":30})
        assert Capture.types(alerts) == ["failed", "recovered"]
      end

      test "a snooze gives the run back and a cancel fails it", %{engine: engine} do
        oban = TestOban.start(engine)

        %{cw: cw, alerts: alerts, errors: errors} =
          make(integrations: [{Cronwatch.Oban, oban: oban, workers: [Workers.Snoozer, Workers.Canceller]}])

        {:ok, _} = Oban.insert(oban, Workers.Snoozer.new(%{}))
        Oban.drain_queue(oban, queue: :default)
        assert runs(cw, "Cronwatch.Test.Workers.Snoozer") == [], "the snooze is not a run"

        {:ok, _} = Oban.insert(oban, Workers.Canceller.new(%{}))
        # Not staged again: the snoozed job would snooze again for good.
        Oban.drain_queue(oban, queue: :default)
        [run] = runs(cw, "Cronwatch.Test.Workers.Canceller")
        assert run.status == "failed"
        assert run.error =~ ~s(failed with {:cancel, "the invoice was deleted"})
        assert Capture.types(alerts) == ["failed"]
        assert messages(errors) == []
      end

      test "a raise fails the run with the exception", %{engine: engine} do
        oban = TestOban.start(engine)
        %{cw: cw} = make(alerts: [], integrations: [{Cronwatch.Oban, oban: oban, workers: [Workers.Raiser]}])
        {:ok, _} = Oban.insert(oban, Workers.Raiser.new(%{}))
        drain(oban)
        [run] = runs(cw, "Cronwatch.Test.Workers.Raiser")
        assert run.status == "failed"
        assert run.error =~ ~r/\ARuntimeError: the report broke\n    at Cronwatch.Test.Workers.Raiser.perform\/1/
      end

      test "other workers are watched only when named", %{engine: engine} do
        oban = TestOban.start(engine)
        %{cw: cw} = make(alerts: [], integrations: [{Cronwatch.Oban, oban: oban}])
        {:ok, _} = Oban.insert(oban, Workers.Email.new(%{}))
        {:ok, _} = Oban.insert(oban, cron_job(Workers.Raiser))
        drain(oban)
        assert Cronwatch.jobs!(instance: cw) |> Enum.map(& &1.name) == ["Cronwatch.Test.Workers.Raiser"]
      end

      test "a job killed at its timeout is a failed run at once", %{engine: engine} do
        oban = TestOban.start(engine, queues: [slow: 1], stage_interval: 50)
        %{cw: cw} = make(alerts: [], integrations: [{Cronwatch.Oban, oban: oban, workers: [Workers.Slow]}])
        {:ok, _} = Oban.insert(oban, Workers.Slow.new(%{}))

        [run] =
          eventually(
            fn ->
              case runs(cw, "Cronwatch.Test.Workers.Slow") do
                [%{status: "failed"}] = list -> list
                _ -> nil
              end
            end,
            500
          )

        assert run.error =~ "Oban.TimeoutError"
      end

      test "an attempt its node never finished is closed when Lifeline's rescue runs again", %{engine: engine} do
        oban = TestOban.start(engine)
        %{cw: cw} = make(alerts: [], integrations: [{Cronwatch.Oban, oban: oban}])
        {:ok, job} = Oban.insert(oban, cron_job(Workers.Email))
        cw_job = Cronwatch.job!("Cronwatch.Test.Workers.Email", instance: cw)

        # The first attempt's run, left running by a node that died.
        task = Task.async(fn -> Cronwatch.start(cw_job, id: "oban:#{job.id}:1", trigger: "oban") end)
        {:ok, _} = Task.await(task)
        repo = Oban.config(oban).repo
        repo.query!("UPDATE oban_jobs SET attempt = 1 WHERE id = #{job.id}", [])

        drain(oban)
        [first, second] = runs(cw, "Cronwatch.Test.Workers.Email")

        assert {first.id, first.status, first.error} ==
                 {"oban:#{job.id}:1", "failed", "Oban rescued the job after its node stopped"}

        assert {second.id, second.status} == {"oban:#{job.id}:2", "ok"}
      end

      test "the check worker syncs and checks, and is never a job", %{engine: engine} do
        oban = TestOban.start(engine, plugins: [{Oban.Plugins.Cron, crontab: [{"0 2 * * *", Workers.Nightly}]}])
        %{cw: earlier} = make(alerts: [])

        store = Cronwatch.Config.get(earlier).store

        Cronwatch.job!("Gone.Worker",
          schedule: "0 3 * * *",
          tags: ["oban", "oban:billing"],
          instance: earlier
        )

        Cronwatch.check!(instance: earlier)

        %{cw: cw} =
          make(
            store: Stores.option(store),
            alerts: [],
            integrations: [{Cronwatch.Oban, oban: oban, app: "billing"}]
          )

        {:ok, _} = Oban.insert(oban, CheckWorker.new(%{instance: inspect(cw)}))
        assert %{success: 1} = drain(oban)

        assert stored(cw, "Gone.Worker") ==
                 ~s|{"description":"A scheduled task (no longer scheduled)","tags":["oban","oban:billing"],"name":"Gone.Worker"}|

        assert stored(cw, "Cronwatch.Test.Workers.Nightly") =~ ~s("schedule":"0 2 * * *")
        assert stored(cw, "Cronwatch.Oban.CheckWorker") == nil
        refute Object.has_key?(JS.parse!(stored(cw, "Gone.Worker")), "schedule")
      end
    end
  end

  test "an integration Oban does not provide is refused when the instance starts" do
    assert {:error, %Cronwatch.Error{message: message}} =
             Cronwatch.start_link(name: :cw_refused, integrations: [{Cronwatch.Missing, []}])

    assert message =~ "Cronwatch.Missing is not available"
  end

  describe "Oban's reading" do
    test "matches a day of the month and a day of the week both, and croner either" do
      {:error, message} = Cronwatch.Oban.convert("0 0 1 * MON", "Etc/UTC", "x", JS.date_utc(2026, 8, 1))
      assert message =~ ~s(x is "0 0 1 * MON" in Etc/UTC, but after a run at)
    end

    test "reads its nicknames, and a schedule it runs as CronWatch expects passes" do
      now = JS.date_utc(2026, 8, 1)
      assert Cronwatch.Oban.convert("@daily", "Etc/UTC", "x", now) == {:ok, "0 0 * * *"}
      assert Cronwatch.Oban.convert("*/15 9-17 * * 1-5", "America/New_York", "x", now) == {:ok, "*/15 9-17 * * 1-5"}
      assert Cronwatch.Oban.convert("30 3 * * *", "Europe/London", "x", now) == {:ok, "30 3 * * *"}
    end

    test "a time the clock change skips is named" do
      {:error, message} = Cronwatch.Oban.convert("30 2 * * *", "America/New_York", "x", JS.date_utc(2026, 8, 1))
      assert message =~ "does not exist in America/New_York"
    end

    test "@reboot and what Oban cannot read are refused" do
      assert {:error, m} = Cronwatch.Oban.convert("@reboot", "Etc/UTC", "x", 0)
      assert m =~ "not a schedule"
      assert {:error, m} = Cronwatch.Oban.convert("61 * * * *", "Etc/UTC", "x", 0)
      assert m =~ "Oban cannot read"
    end
  end
end
