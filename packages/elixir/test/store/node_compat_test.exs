defmodule Cronwatch.Store.NodeCompatTest do
  @moduledoc """
  A Node process and an Elixir process sharing one SQLite file: the SDK's
  store (from the built packages/sdk/dist) and `Cronwatch.Store.Ecto` replay
  the same store calls (test/testdata/shared_store.json, the Ruby, Python, Go
  and Rust ports' fixture), and each must read what the other wrote exactly
  as it reads its own, down to the bytes and SQLite type of every column.
  Then the two take turns on one job's state version.

  Needs node on the PATH, the SDK built and its SQLite driver installed
  (`npm ci && npm run build` at the repository root); skipped, with the
  reason, without them.
  """
  use ExUnit.Case, async: true

  alias Cronwatch.JobState
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Store
  alias Cronwatch.Test.Repo

  @testdata Path.expand("../testdata", __DIR__)
  @script Path.join(@testdata, "node_store.mjs")
  @fixture Path.join(@testdata, "shared_store.json")
  @root Path.expand("../../../..", __DIR__)

  # Why the tests cannot run here, or nil when they can.
  missing =
    cond do
      System.find_executable("node") == nil -> "node is not on the PATH"
      not File.exists?(Path.join(@root, "packages/sdk/dist/sqlite.js")) -> "packages/sdk/dist is not built"
      not File.exists?(Path.join(@root, "node_modules/better-sqlite3")) -> "the SDK's SQLite driver is not installed"
      true -> nil
    end

  if missing do
    @moduletag skip: "Node compatibility: #{missing} (run `npm ci && npm run build` at the repository root)"
  end

  defp node(action, file, prefix, args) do
    {out, status} = System.cmd("node", [@script, action, file, prefix | args], stderr_to_stdout: true)
    assert status == 0, "node #{action}: #{out}"
    out
  end

  defp fixture, do: JS.parse!(File.read!(@fixture))

  defp store(file, prefix) do
    {mod, h} = Repo.store(file, prefix)
    :ok = mod.init(h)
    {mod, h}
  end

  defp must({:ok, v}), do: v
  defp must(:ok), do: :ok

  defp c(store, fun, args \\ []), do: store |> Store.call(fun, args) |> must()

  # Replays the fixture's store calls, as node_store.mjs `write` does.
  defp elixir_write(store, f) do
    pruned =
      Enum.flat_map(Object.get(f, "ops"), fn step ->
        field = &Object.get(step, &1)

        case field.("op") do
          "upsertJob" ->
            c(store, :upsert_job, [field.("definition"), field.("now")])
            []

          "insertRun" ->
            c(store, :insert_run, [must(Run.from_value(field.("run")))])
            []

          "updateRun" ->
            c(store, :update_run, [must(Run.from_value(field.("run")))])
            []

          "setState" ->
            c(store, :set_state, [must(JobState.from_value(field.("state")))])
            []

          "deleteJob" ->
            c(store, :delete_job, [field.("name")])
            []

          "prune" ->
            [c(store, :prune, [field.("before")])]
        end
      end)

    JS.stringify(Object.new([{"pruned", pruned}]))
  end

  defp stored_value(nil), do: nil

  defp stored_value(j) do
    Object.new([
      {"name", j.name},
      {"definition", j.definition},
      {"createdAt", j.created_at},
      {"updatedAt", j.updated_at}
    ])
  end

  defp run_value(nil), do: nil
  defp run_value(r), do: Run.to_value(r)
  defp runs_value(runs), do: Enum.map(runs, &Run.to_value/1)
  defp state_value(nil), do: nil
  defp state_value(s), do: JobState.to_value(s)

  # What node_store.mjs `read` prints, from the Elixir store, in the same key
  # order.
  defp elixir_read(store, f) do
    read = Object.get(f, "read")
    names = Object.get(read, "jobs")
    per = fn fun -> Object.new(Enum.map(names, &{&1, fun.(&1)})) end

    Object.new([
      {"jobs", Enum.map(c(store, :list_jobs), &stored_value/1)},
      {"job", per.(&stored_value(c(store, :get_job, [&1])))},
      {"runs", per.(&runs_value(c(store, :list_runs, [&1, 100])))},
      {"limited", per.(&runs_value(c(store, :list_runs, [&1, 1])))},
      {"last", per.(&run_value(c(store, :last_run, [&1])))},
      {"state", per.(&state_value(c(store, :get_state, [&1])))},
      {"running", runs_value(c(store, :running_runs))},
      {"run", Object.new(Enum.map(Object.get(read, "runs"), &{&1, run_value(c(store, :get_run, [&1]))}))}
    ])
    |> JS.stringify()
  end

  # Every row of the three tables with each value's SQLite type, the JSON
  # columns as the text the database holds.
  defp raw_rows(file, p) do
    pid = Repo.start(file)
    typed = fn columns -> Enum.map_join(columns, ", ", &"quote(#{&1}), typeof(#{&1})") end

    [
      "SELECT #{typed.(~w(name definition created_at updated_at))} FROM #{p}jobs ORDER BY created_at, name",
      "SELECT #{typed.(~w(rowid id job status started_at finished_at duration_ms error output metrics trigger))} " <>
        "FROM #{p}runs ORDER BY rowid",
      "SELECT #{typed.(~w(job state))} FROM #{p}state ORDER BY job"
    ]
    |> Enum.flat_map(fn q -> Enum.map(Repo.sql(pid, q).rows, &Enum.map_join(&1, " | ", fn v -> to_string(v) end)) end)
  end

  defp schema_of(file, p) do
    pid = Repo.start(file)

    Repo.sql(
      pid,
      "SELECT type || '|' || name || '|' || tbl_name || '|' || coalesce(sql, '') FROM sqlite_master " <>
        "WHERE name LIKE ? ORDER BY name",
      ["#{p}%"]
    ).rows
    |> Enum.map(fn [s] -> String.replace(s, p, "PREFIX_") end)
  end

  test "Elixir reads what Node wrote" do
    f = fixture()
    file = Path.join(Repo.tmp_dir(), "shared.db")
    assert node("write", file, "cw_", [@fixture]) == ~s({"pruned":[1]})
    s = store(file, "cw_")
    node_view = node("read", file, "cw_", [@fixture])
    refute node_view =~ "never stored", "an update of a run that is not there was stored"
    assert elixir_read(s, f) == node_view, "Elixir reads Node's rows differently"
  end

  test "Node reads what Elixir wrote, and the rows are the same" do
    f = fixture()
    dir = Repo.tmp_dir()
    {node_file, elixir_file} = {Path.join(dir, "node.db"), Path.join(dir, "elixir.db")}
    written = node("write", node_file, "cw_", [@fixture])
    s = store(elixir_file, "cw_")
    assert elixir_write(s, f) == written, "pruned"

    assert node("read", elixir_file, "cw_", [@fixture]) == node("read", node_file, "cw_", [@fixture]),
           "Node reads Elixir's rows differently from its own"

    {elixir_rows, node_rows} = {raw_rows(elixir_file, "cw_"), raw_rows(node_file, "cw_")}
    assert elixir_rows != []

    for {{e, n}, i} <- Enum.with_index(Enum.zip(elixir_rows, node_rows)) do
      assert e == n, "row #{i}"
    end

    assert length(elixir_rows) == length(node_rows), "rows"
  end

  test "the tables are the same whoever creates them" do
    file = Path.join(Repo.tmp_dir(), "both.db")
    node("write", file, "node_", [@fixture])
    store(file, "elixir_")
    {a, b} = {schema_of(file, "elixir_"), schema_of(file, "node_")}
    assert length(a) == 5, inspect(a)
    assert a == b, "schema"
  end

  test "Node and Elixir take turns on one job's state version" do
    file = Path.join(Repo.tmp_dir(), "versions.db")
    s = store(file, "cw_")

    v = fn version, failures, job ->
      must(
        JobState.from_json(
          ~s({"job":"#{job}","open":{},"consecutiveFailures":#{failures},"silencedUntil":null,) <>
            ~s("lastAlertAt":null,"version":#{version}})
        )
      )
    end

    node_cas = fn state, expected ->
      o = JS.parse!(node("cas", file, "cw_", [JobState.to_json(state), Integer.to_string(expected)]))
      {Object.get(o, "written"), JS.stringify(Object.get(o, "state"))}
    end

    assert c(s, :compare_and_set_state, [v.(1, 1, "v"), 0]), "Elixir writes the first version"
    refute elem(node_cas.(v.(1, 9, "v"), 0), 0), "Node's write from before it is refused"
    {written, state} = node_cas.(v.(2, 2, "v"), 1)
    assert written and state =~ ~s("version":2), "Node's fresh write"
    refute c(s, :compare_and_set_state, [v.(2, 7, "v"), 1]), "Elixir's stale write is refused"
    assert c(s, :compare_and_set_state, [v.(3, 3, "v"), 2]), "Elixir writes the next version"
    {written, state} = node_cas.(v.(3, 0, "v"), 2)
    refute written, "Node's stale write is refused"
    assert state == JobState.to_json(c(s, :get_state, ["v"])), "Node reads Elixir's version"

    # State written before versions existed counts as 0 for both.
    old = ~s({"job":"old","open":{},"consecutiveFailures":4,"silencedUntil":null,"lastAlertAt":null})
    c(s, :set_state, [must(JobState.from_json(old))])
    assert elem(node_cas.(v.(1, 5, "old"), 0), 0), "Node writes over state without a version"
    assert c(s, :get_state, ["old"]).version == 1
  end

  # Pending, for the client: a Node client and an Elixir client take turns on
  # one file (the Elixir client runs a job Node declared and checks every
  # job; then `node_store.mjs run` runs every-5 from Node, and each reads the
  # other's run and state), as Rust's node_carries_on_from_rust_and_rust_from_node.
end
