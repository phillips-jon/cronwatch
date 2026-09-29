defmodule CrontabExampleTest do
  @moduledoc "The two crontab lines, run through the built release as two nodes would run them, on one SQLite file."
  use ExUnit.Case

  setup_all do
    dir = Path.join(System.tmp_dir!(), "cronwatch-crontab-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    release = Path.join(dir, "release")

    {out, status} =
      System.cmd("mix", ["release", "--overwrite", "--path", release, "--quiet"],
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("mix release failed:\n" <> out)
    %{bin: Path.join([release, "bin", "crontab_example"]), db: Path.join(dir, "cronwatch.db")}
  end

  defp eval(%{bin: bin, db: db}, code) do
    System.cmd(bin, ["eval", code], env: [{"CRONWATCH_DB", db}], stderr_to_stdout: true)
  end

  test "a check, the report, and a check again", ctx do
    check = "Cronwatch.Release.check(CrontabExample.Cronwatch)"
    assert eval(ctx, check) == {"cronwatch: checked 1 job, sent 0 alerts\n", 0}
    assert eval(ctx, "CrontabExample.report()") == {"", 0}
    assert eval(ctx, check) == {"cronwatch: checked 1 job, sent 0 alerts\n", 0}
    assert {_, 1} = eval(ctx, "Cronwatch.Release.check(CrontabExample.Unconfigured)")
  end
end
