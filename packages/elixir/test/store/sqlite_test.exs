defmodule Cronwatch.Store.SQLiteTest do
  alias Cronwatch.Test.Conformance
  alias Cronwatch.Test.Repo

  use Cronwatch.StoreCase,
    async: true,
    store: fn -> Repo.store(Path.join(Repo.tmp_dir(), "store.db")) end,
    fixture: File.read!(Path.join(Conformance.dir(), "store.json"))

  alias Cronwatch.JobState
  alias Cronwatch.JS
  alias Cronwatch.Store
  alias Cronwatch.Store.Ecto, as: EctoStore
  alias Cronwatch.Store.SQL
  alias Cronwatch.StoreCase
  alias Cronwatch.Test.ForeignRows
  alias Cronwatch.Test.Repo

  defp file, do: Path.join(Repo.tmp_dir(), "t.db")

  test "prefixes follow the SDK's rule" do
    assert SQL.table_prefix("cw_") == {:ok, "cw_"}
    assert SQL.table_prefix("_x9") == {:ok, "_x9"}

    assert SQL.table_prefix("Monitoring_") ==
             {:error,
              ~s(cronwatch: invalid table prefix "Monitoring_". Use lowercase letters, digits and underscores, ) <>
                "not starting with a digit, at most 47 characters."}

    assert {:error, _} = SQL.table_prefix("9x")
    assert {:error, _} = SQL.table_prefix("")
    assert {:error, _} = SQL.table_prefix(String.duplicate("a", 48))
    assert {:ok, _} = SQL.table_prefix(String.duplicate("a", 47))
    assert {:error, _} = EctoStore.new(repo: Repo, prefix: "Bad")
  end

  test "the schema is sql.ts's text, cut into five statements" do
    s = SQL.schema(:sqlite, "cw_")
    assert length(s) == 5
    assert Enum.at(s, 0) =~ ~r/\A\n    CREATE TABLE IF NOT EXISTS cw_jobs \(\n      name TEXT PRIMARY KEY,/
    assert Enum.at(s, 1) =~ "metrics TEXT NOT NULL DEFAULT '{}'"
    pg = SQL.schema(:postgres, "cw_")

    assert String.starts_with?(
             Enum.at(pg, 1),
             "\n    CREATE TABLE IF NOT EXISTS cw_runs (\n      seq BIGSERIAL,\n      id TEXT PRIMARY KEY,"
           )

    q = SQL.statements(:postgres, "cw_")

    assert q.cas_update ==
             "UPDATE cw_state SET state = $1::text::jsonb WHERE job = $2 AND " <>
               "CASE WHEN jsonb_typeof(state->'version') <> 'number' THEN 0 " <>
               "WHEN (state->>'version')::numeric % 1 = 0 AND (state->>'version')::numeric BETWEEN 0 AND 9007199254740991 " <>
               "THEN (state->>'version')::numeric::bigint ELSE 0 END = $3"

    assert SQL.statements(:sqlite, "cw_").cas_update ==
             "UPDATE cw_state SET state = ? WHERE job = ? AND " <>
               "CASE WHEN json_type(state, '$.version') NOT IN ('integer', 'real') THEN 0 " <>
               "WHEN json_extract(state, '$.version') = CAST(json_extract(state, '$.version') AS INTEGER) " <>
               "AND json_extract(state, '$.version') BETWEEN 0 AND 9007199254740991 " <>
               "THEN CAST(json_extract(state, '$.version') AS INTEGER) ELSE 0 END = ?"

    assert String.ends_with?(SQL.update_run_if(:postgres, "cw_", 2), "WHERE id = $7 AND status IN ($8, $9)")

    assert SQL.statements(:sqlite, "cw_").list_runs ==
             "SELECT * FROM cw_runs WHERE job = ? ORDER BY started_at DESC, rowid DESC LIMIT ?"
  end

  use ForeignRows, store: fn -> Repo.store(file()) end

  test "stores with different prefixes share one file" do
    path = file()
    pid = Repo.start(path)
    {:ok, a} = EctoStore.new(repo: Repo, prefix: "one_", dynamic_repo: pid)
    {:ok, b} = EctoStore.new(repo: Repo, prefix: "two_", dynamic_repo: pid)
    for h <- [a, b], do: :ok = EctoStore.init(h)
    :ok = EctoStore.upsert_job(a, JS.parse!(~s({"name":"x"})), 1)
    assert {:ok, [_]} = EctoStore.list_jobs(a)
    assert {:ok, []} = EctoStore.list_jobs(b)
    names = Repo.sql(pid, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").rows
    assert names == [["one_jobs"], ["one_runs"], ["one_state"], ["two_jobs"], ["two_runs"], ["two_state"]]
  end

  test "an in-memory database needs a pool of one" do
    Application.put_env(:cronwatch, Cronwatch.Test.Repo, database: ":memory:", pool_size: 4)
    on_exit(fn -> Application.delete_env(:cronwatch, Cronwatch.Test.Repo) end)
    assert {:error, message} = EctoStore.new(repo: Repo)
    assert message =~ "pool_size: 1"
    assert {:error, _} = EctoStore.new(repo: nil)
    assert {:error, _} = EctoStore.new(repo: String)
  end

  test "create_statements gives an app's migration the tables" do
    assert EctoStore.create_statements(repo: Repo, prefix: "cw_") == SQL.schema(:sqlite, "cw_")
  end

  test "a write inside the app's transaction survives its rollback" do
    path = file()
    # Two connections: the app's transaction holds one, and the store's
    # write runs on the other. SQLite has one writer at a time, so the
    # store writes before the app's transaction takes the write lock.
    pid = Repo.start(path, pool_size: 2)
    {:ok, h} = EctoStore.new(repo: Repo, dynamic_repo: pid)
    :ok = EctoStore.init(h)
    Repo.put_dynamic_repo(pid)

    {:error, :rolled_back} =
      Repo.transaction(fn ->
        :ok = EctoStore.insert_run(h, StoreCase.test_run("kept", "j", "running", 1))
        Repo.query!("CREATE TABLE app_rows (x INTEGER)")
        Repo.rollback(:rolled_back)
      end)

    assert {:ok, %{id: "kept"}} = EctoStore.get_run(h, "kept")
    assert Repo.sql(pid, "SELECT name FROM sqlite_master WHERE name = 'app_rows'").rows == []
  end

  test "rows of another shape are read as the SDK reads them" do
    path = file()
    pid = Repo.start(path)
    {:ok, h} = EctoStore.new(repo: Repo, dynamic_repo: pid)
    :ok = EctoStore.init(h)
    store = {EctoStore, h}

    # Metrics that are not all numbers keep the ones that are; a time stored
    # as text or real is read as a number; text that is not UTF-8 reads
    # with U+FFFD; a definition that is not an object is an empty one.
    Repo.sql(
      pid,
      "INSERT INTO cronwatch_runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger) " <>
        "VALUES ('odd', 'j', 'ok', '1500', 1600.9, NULL, NULL, ?, '{\"a\":null,\"b\":2,\"c\":\"x\"}', 'run')",
      [<<"bad ", 0xFF, " byte">>]
    )

    Repo.sql(pid, "INSERT INTO cronwatch_jobs VALUES ('j', '[1,2]', 5, 6)")
    Repo.sql(pid, "INSERT INTO cronwatch_runs (id, job, status, started_at) VALUES ('big', 'j', 'running', 1e30)")

    {:ok, run} = Store.call(store, :get_run, ["odd"])
    assert JS.stringify(run.metrics) == ~s({"b":2})
    assert run.started_at == 1500
    assert run.finished_at == 1600
    assert run.output == "bad � byte"
    {:ok, [job]} = Store.call(store, :list_jobs, [])
    assert JS.stringify(job.definition) == "{}"
    {:ok, big} = Store.call(store, :get_run, ["big"])
    assert big.started_at == 9_223_372_036_854_775_807

    # A queued alert that is not an alert, or whose run's metrics are not all
    # numbers, does not fail the state's read.
    Repo.sql(pid, "INSERT INTO cronwatch_state VALUES ('j', ?)", [
      ~s({"job":"j","version":1,"undelivered":[{"type":"failed","job":"j","run":{"id":"x","metrics":{"a":null,"b":2}}},7]})
    ])

    {:ok, %JobState{undelivered: [alert]}} = Store.call(store, :get_state, ["j"])
    assert JS.stringify(alert.run.metrics) == ~s({"b":2})
  end
end
