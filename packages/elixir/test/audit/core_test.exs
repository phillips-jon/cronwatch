defmodule Cronwatch.Audit.CoreTest do
  @moduledoc """
  The core pass of the audit before the first release: each test holds one
  finding fixed (DESIGN.md, Phases, 5).
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Cronwatch.Test.More

  alias Cronwatch.Run.Exec
  alias Cronwatch.Runs
  alias Cronwatch.Store.Ecto, as: EctoStore
  alias Cronwatch.Test.Repo

  defp only_run(cw, job) do
    [run] = Cronwatch.runs!(job, 50, instance: cw)
    run
  end

  defp lines_rows(cw), do: :ets.info(Runs.table(cw, :lines), :size)

  # A pid on another node, as a Task started from there holds in `$callers`.
  defp remote_pid do
    node = "other@host"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node)>> <> node <> <<1::32, 0::32, 1::32>>)
  end

  test "an isolated run whose caller is killed is recorded when its function ends" do
    %{cw: cw} = make()
    test = self()
    gate = switch(:closed)

    caller =
      spawn(fn ->
        Cronwatch.run(
          "orphan",
          fn j ->
            Cronwatch.log(j, "working")
            send(test, :running)
            eventually(fn -> get(gate) == :open end)
            "finished"
          end,
          isolate: true,
          instance: cw
        )
      end)

    assert_receive :running
    Process.exit(caller, :kill)
    put(gate, :open)
    eventually(fn -> only_run(cw, "orphan").status == "ok" end)
    assert only_run(cw, "orphan").output == "working"
    eventually(fn -> lines_rows(cw) == 0 end)
  end

  test "an isolated run with kill_at_timeout and a timeout past the BEAM's longest wait runs" do
    %{cw: cw} = make()
    Cronwatch.job!("long", timeout: "60d", instance: cw)
    assert Cronwatch.run("long", fn _ -> :done end, isolate: true, kill_at_timeout: true, instance: cw) == :done
    assert only_run(cw, "long").status == "ok"
  end

  test "current/0 in a process whose callers include one on another node is nil, not a raise" do
    parent = self()

    spawn(fn ->
      Process.put(:"$callers", [remote_pid()])
      send(parent, {:current, Cronwatch.current(), Cronwatch.log("x")})
    end)

    assert_receive {:current, nil, :ok}
  end

  test "a finished handle leaves nothing behind in the instance's tables" do
    %{cw: cw} = make()
    Cronwatch.job!("h", instance: cw)

    for _ <- 1..20 do
      {:ok, h} = Cronwatch.start("h", instance: cw)
      Cronwatch.log(h, "line")
      assert %Cronwatch.Run{status: "ok"} = Cronwatch.finish(h)
      refute Cronwatch.active?(h)
      assert Cronwatch.finish(h) == nil
    end

    assert :ets.info(Runs.table(cw, :handles), :size) == 0
    assert lines_rows(cw) == 0
    assert :sys.get_state(Runs.server(cw)).owners == %{}
  end

  test "a recording that fails hands the caller's recorded: function nil and leaves no lines" do
    broken = :atomics.new(1, [])

    clock = fn ->
      if :atomics.get(broken, 1) == 1, do: raise("clock gone"), else: 1_700_000_000_000
    end

    %{cw: cw, errors: errors} = make(clock: clock)
    job = Cronwatch.job!("rec", instance: cw)
    me = self()

    assert Exec.run(
             job,
             fn j ->
               Cronwatch.log(j, "x")
               :atomics.put(broken, 1, 1)
               :ok
             end,
             recorded: &send(me, {:recorded, &1})
           ) == :ok

    assert_receive {:recorded, nil}
    assert "recording rec" in wheres(errors)
    assert lines_rows(cw) == 0
  end

  test "a stuck run from a foreign row with a start near the limit is marked, its duration held in range" do
    path = Path.join(Repo.tmp_dir(), "far.db")
    pid = Repo.start(path)
    %{cw: cw, errors: errors} = make(store: {EctoStore, repo: Repo, dynamic_repo: pid})
    Cronwatch.job!("far", timeout: "1m", instance: cw)
    {:ok, _} = Cronwatch.check(instance: cw)

    Repo.sql(pid, "INSERT INTO cronwatch_runs (id, job, status, started_at) VALUES ('old', 'far', 'running', -1e30)")
    {:ok, _} = Cronwatch.check(instance: cw)

    run = only_run(cw, "far")
    assert run.status == "timeout"
    assert run.duration_ms == 9_223_372_036_854_775_807
    assert Enum.reject(wheres(errors), &(&1 =~ "alert")) == []
  end

  test "an instance's config never prints its cron secret" do
    {:ok, config} = Cronwatch.Config.new(cron_secret: "s3cret-handler-token")
    refute inspect(config) =~ "s3cret-handler-token"
    assert inspect(config) =~ "Cronwatch.Config"
  end

  test "an option given the wrong way is refused without quoting it" do
    url = "https://hooks.slack.com/services/T0/B0/s3cret-webhook"

    for opts <- [
          [alerts: [url]],
          [alerts: url],
          [store: url],
          [integrations: url],
          [integrations: [url]],
          [redact: url],
          [cron_secret: ~c"s3cret-webhook"]
        ] do
      assert {:error, %Cronwatch.Error{message: message}} = Cronwatch.Config.new(opts)
      refute message =~ "s3cret", message
    end

    assert {:error, %Cronwatch.Error{message: "Cronwatch: not an alert channel: a string"}} =
             Cronwatch.Config.new(alerts: [url])
  end

  defmodule ExitingSource do
    @moduledoc false
    def name(_opts), do: throw(:no_name)
    def sync(_opts, _instance), do: exit(:timeout)
  end

  test "a source that exits is that source's failure, and the jobs are still checked" do
    %{cw: cw, errors: errors} = make(sources: [{ExitingSource, []}])
    Cronwatch.job!("checked", instance: cw)
    assert {:ok, %Cronwatch.CheckResult{jobs: [%{name: "checked"}]}} = Cronwatch.check(instance: cw)
    assert wheres(errors) == ["source Cronwatch.Audit.CoreTest.ExitingSource"]
  end

  test "a number too large for a double is refused as a timeout or a metric, as JavaScript reads it as Infinity" do
    %{cw: cw} = make()

    assert {:error, %Cronwatch.Error{message: message}} = Cronwatch.job("huge", timeout: 10 ** 400, instance: cw)
    assert message =~ "must be a non-negative number of milliseconds"

    assert_raise Cronwatch.Error, ~s(metric "x" must be a finite number), fn ->
      Cronwatch.run("m", fn j -> Cronwatch.metric(j, "x", 10 ** 400) end, instance: cw)
    end

    # The instance is still up.
    assert Cronwatch.run("m", fn _ -> :ok end, instance: cw) == :ok
  end
end
