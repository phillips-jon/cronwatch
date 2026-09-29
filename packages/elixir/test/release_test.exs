defmodule Cronwatch.ReleaseTest do
  @moduledoc "Cronwatch.Release.check/2 and mix cronwatch.check: one check from a crontab line."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Cronwatch.Release
  alias Cronwatch.Store.Ecto, as: EctoStore
  alias Cronwatch.Test.Repo
  alias Cronwatch.Test.Stores
  alias Mix.Tasks.Cronwatch.Check, as: CheckTask

  setup do
    path = Path.join(Repo.tmp_dir(), "cronwatch.db")
    Application.put_env(:cronwatch, Repo, database: path, pool_size: 1, log: false)

    Application.put_env(:cronwatch, :release_test_cw,
      store: {EctoStore, repo: Repo},
      alerts: [],
      check_every: "1m",
      jobs: [{"nightly-report", schedule: "0 2 * * *", timezone: "UTC", grace: "15m"}]
    )

    on_exit(fn ->
      Application.delete_env(:cronwatch, :release_test_cw)
      Application.delete_env(:cronwatch, Repo)
    end)

    %{path: path}
  end

  test "a check starts the repo and the instance, checks once and stops them", %{path: path} do
    out = capture_io(fn -> assert {:ok, _} = Release.check(:release_test_cw, halt: false) end)
    assert out == "cronwatch: checked 1 job, sent 0 alerts\n"
    assert Process.whereis(Repo) == nil, "the repo it started is stopped"
    assert :persistent_term.get({Cronwatch, :release_test_cw}, nil) == nil, "the instance is stopped"

    # The job's declaration reached the file, for the processes that run it.
    pid = Repo.start(path)
    %{rows: [[definition]]} = Repo.sql(pid, "SELECT definition FROM cronwatch_jobs WHERE name = 'nightly-report'")
    assert definition =~ ~s("schedule":"0 2 * * *")

    # Again, as the next crontab line would.
    assert capture_io(fn -> Release.check(:release_test_cw, otp_app: :cronwatch, halt: false) end) ==
             "cronwatch: checked 1 job, sent 0 alerts\n"
  end

  test "a missing configuration is a failure, written to standard error" do
    err =
      capture_io(:stderr, fn ->
        assert {:error, %Cronwatch.Error{}} = Release.check(:nothing_configured, halt: false)
      end)

    assert err =~ "cronwatch: the check failed: no configuration for :nothing_configured"
  end

  test "config: gives the options themselves" do
    out = capture_io(fn -> Release.check(:release_given, config: [alerts: []], halt: false) end)
    assert out == "cronwatch: checked 0 jobs, sent 0 alerts\n"
  end

  test "an instance already running is checked as it is, left running, and never halts the node" do
    {store, hooks} = Stores.hooked(Stores.memory())
    start_supervised!({Cronwatch, name: :release_running, store: store, alerts: []})
    out = capture_io(fn -> assert {:ok, _} = Release.check(:release_running) end)
    assert out == "cronwatch: checked 0 jobs, sent 0 alerts\n"
    assert :persistent_term.get({Cronwatch, :release_running}, nil) != nil, "the app's instance is left running"

    # A failure is answered, not halted on: halting would stop the live app.
    for fun <- [:list_jobs, :running_runs], do: Stores.hook(hooks, fun, fn _, _ -> {:error, :down} end)
    err = capture_io(:stderr, fn -> assert {:error, _} = Release.check(:release_running) end)
    assert err =~ "cronwatch: the check failed"
  end

  test "a store without a repo, or with one that is not a repo, is a failure answered, not raised" do
    for store <- [{EctoStore, []}, {EctoStore, repo: String}] do
      capture_io(:stderr, fn ->
        assert {:error, %Cronwatch.Error{}} = Release.check(:release_bad_repo, config: [store: store], halt: false)
      end)
    end
  end

  test "mix cronwatch.check runs the check for an instance named on the command line" do
    Mix.Task.reenable("cronwatch.check")
    out = capture_io(fn -> CheckTask.run([":release_test_cw", "--otp-app", "cronwatch"]) end)
    assert out == "cronwatch: checked 1 job, sent 0 alerts\n"

    Mix.Task.reenable("cronwatch.check")

    capture_io(:stderr, fn ->
      assert catch_exit(CheckTask.run([":nothing_configured"])) == {:shutdown, 1}
    end)
  end
end
