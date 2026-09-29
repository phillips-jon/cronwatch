defmodule Cronwatch.ReleaseTest do
  @moduledoc "Cronwatch.Release.check/2 and mix cronwatch.check: one check from a crontab line."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Cronwatch.Release
  alias Cronwatch.Store.Ecto, as: EctoStore
  alias Cronwatch.Test.Repo
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
