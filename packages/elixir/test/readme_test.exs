defmodule MyApp.Repo do
  @moduledoc false
end

defmodule MyApp.Pager do
  @moduledoc false
  def page(_title, _message), do: :ok
end

defmodule MyApp.Reports do
  @moduledoc false
  def build, do: "/tmp/nightly-report.csv"
  def nightly(_job, _conn), do: :ok
end

defmodule Cronwatch.ReadmeTest do
  # Every Elixir example in README.md is compiled here, with warnings counted
  # as failures, and the ones that call the API are run against an instance,
  # so the README fails the suite when an example stops working. An example
  # is compiled as what its first line says it is: a module body (`def`), a
  # module (`defmodule`), a router's body (`scope`, `forward`), a keyword
  # list's items (`alerts:`), a config file's body (`config`), or else the
  # body of a function, which is also run when it is listed in @run.
  use ExUnit.Case, async: false

  @readme Path.expand("../README.md", __DIR__)
  @external_resource @readme

  # The examples run against a real instance, by their first line.
  @run [
    "Cronwatch.run(\"nightly-report\", fn job ->",
    "{:ok, result} = Cronwatch.check()",
    "{:ok, run} = Cronwatch.start(\"import\", id: \"batch-42\")   # records a running run"
  ]

  defp blocks do
    ~r/^```elixir\n(.*?)^```$/ms
    |> Regex.scan(File.read!(@readme), capture: :all_but_first)
    |> Enum.map(fn [code] -> code end)
  end

  defp first_code_line(code) do
    code |> String.split("\n") |> Enum.find(&(not String.starts_with?(&1, "#"))) |> String.trim()
  end

  defp kind(code) do
    line = first_code_line(code)

    cond do
      String.starts_with?(line, "defmodule ") -> :module
      String.starts_with?(line, "def ") -> :module_body
      String.starts_with?(line, ["scope ", "forward "]) -> :router
      String.starts_with?(line, "config ") -> :config
      Regex.match?(~r/^[a-z_]+: /, line) -> :keyword
      true -> :body
    end
  end

  # The store example reads the fixture when its module compiles, from the
  # path a reader's own checkout has it at.
  @fixture Path.expand("../../../conformance/store.json", __DIR__)

  defp source(code, name) do
    case kind(code) do
      :module -> String.replace(code, "path/to/conformance/store.json", @fixture)
      :module_body -> "defmodule #{name} do\n#{code}\nend\n"
      :router -> "defmodule #{name} do\nuse Phoenix.Router\n#{code}\nend\n"
      :config -> "defmodule #{name} do\ndef run do\nimport Config\n#{code}\nend\nend\n"
      :keyword -> "defmodule #{name} do\ndef run do\n[\n#{code}\n]\nend\nend\n"
      :body -> "defmodule #{name} do\ndef run do\n#{code}\nend\nend\n"
    end
  end

  # Compiles one example; the warnings it gives, but for a variable an
  # example binds to show what a call answers.
  defp compile(code, name) do
    {_, diagnostics} =
      Code.with_diagnostics(fn ->
        Code.compile_string(source(code, name), "README.md")
      end)

    Enum.reject(diagnostics, &(&1.message =~ ~r/variable "\w+" is unused/))
  end

  test "the README has the examples this test knows" do
    kinds = Enum.map(blocks(), &kind/1)
    assert length(kinds) >= 13
    assert :module in kinds and :router in kinds and :config in kinds and :keyword in kinds
    firsts = Enum.map(blocks(), &first_code_line/1)
    for line <- @run, do: assert(line in firsts, "README no longer has #{line}")
  end

  test "every example compiles without a warning" do
    for {code, i} <- Enum.with_index(blocks()) do
      name = Module.concat(__MODULE__, "Example#{i}")
      assert compile(code, name) == [], "README example #{i + 1} warns:\n#{code}"
    end
  end

  test "the examples that call the API run" do
    start_supervised!(
      {Cronwatch,
       alerts: [Cronwatch.Alerts.fun("pager", fn alert, _ctx -> MyApp.Pager.page(alert.title, alert.message) end)],
       jobs: [{"nightly-report", schedule: "0 2 * * *", timezone: "UTC", expect: "Report written", budget: [cost: 2]}]}
    )

    for {code, i} <- Enum.with_index(blocks()), first_code_line(code) in @run do
      name = Module.concat(__MODULE__, "Run#{i}")
      assert compile(code, name) == []
      name.run()
    end

    {:ok, runs} = Cronwatch.runs("nightly-report")
    assert [%{status: "ok", output: "Report written: /tmp/nightly-report.csv"}] = runs
    {:ok, runs} = Cronwatch.runs("import")
    assert [%{status: "ok", output: "fetched 1,200 rows"}] = runs
  end
end
