defmodule Cronwatch.Store.SQLDialectTest do
  @moduledoc "The Postgres and MySQL statements' text, which needs no server."
  use ExUnit.Case, async: true

  alias Cronwatch.Store.SQL

  test "Postgres's statements are sql.ts's, with the JSON casts" do
    q = SQL.statements(:postgres, "cw_")

    assert q.list_jobs ==
             ~s(SELECT name, definition::text AS definition, created_at, updated_at FROM cw_jobs ORDER BY name COLLATE "C")

    assert q.set_state =~ "VALUES ($1, $2::text::jsonb) ON CONFLICT (job)"
  end

  test "MySQL's dialect is the PHP, Go and Rust ports'" do
    s = SQL.schema(:mysql, "cw_")
    assert length(s) == 3

    assert Enum.at(s, 1) =~
             "metrics LONGTEXT NOT NULL DEFAULT ('{}'),\n      `trigger` VARCHAR(255) NOT NULL DEFAULT 'run',"

    assert String.ends_with?(Enum.at(s, 2), ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin")
    q = SQL.statements(:mysql, "cw_")
    assert q.insert_run =~ "metrics, `trigger`)"

    assert q.cas_from_zero ==
             "UPDATE cw_state SET state = ? WHERE job = ? AND " <>
               "CASE WHEN JSON_TYPE(JSON_EXTRACT(state, '$.version')) NOT IN " <>
               "('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 " <>
               "WHEN JSON_EXTRACT(state, '$.version') + 0 = FLOOR(JSON_EXTRACT(state, '$.version') + 0) " <>
               "AND JSON_EXTRACT(state, '$.version') + 0 BETWEEN 0 AND 9007199254740991 " <>
               "THEN CAST(JSON_EXTRACT(state, '$.version') + 0 AS SIGNED) ELSE 0 END = 0"

    assert String.ends_with?(SQL.update_run_if(:mysql, "cw_", 1), "status IN (?)")
  end
end

defmodule Cronwatch.Store.PostgresTest do
  @moduledoc "The store on Postgres, when CRONWATCH_TEST_PG is set: the shared server tests and stores.test.ts's own."
  use Cronwatch.Test.ServerStoreTests, kind: :pg

  alias Cronwatch.JobState

  defp column(h, text), do: Servers.sql(h.repo, h.dynamic_repo, text).rows |> Enum.map(&hd/1)

  defp state(text), do: elem(JobState.from_json(text), 1)

  test "the schema is the SDK's" do
    {EctoStore, h} = Servers.store(:pg)
    p = h.prefix
    :ok = EctoStore.init(h)
    assert :ok = EctoStore.init(h), "IF NOT EXISTS: a second init changes nothing"

    columns =
      column(
        h,
        "SELECT table_name || '.' || column_name || ' ' || data_type || ' ' || coalesce(column_default, '') " <>
          "FROM information_schema.columns WHERE table_name LIKE '#{p}%' ORDER BY table_name, ordinal_position"
      )

    runs =
      for c <- columns,
          String.starts_with?(c, "#{p}runs."),
          do: c |> String.trim_leading("#{p}runs.") |> String.split(" ") |> hd()

    assert runs == ~w(seq id job status started_at finished_at duration_ms error output metrics trigger)

    for want <- [
          "#{p}runs.seq bigint nextval(",
          "#{p}runs.started_at bigint ",
          "#{p}runs.metrics jsonb '{}'::jsonb",
          "#{p}runs.trigger text 'run'::text",
          "#{p}jobs.definition jsonb ",
          "#{p}state.state jsonb "
        ] do
      assert Enum.any?(columns, &String.starts_with?(&1, want)), "no #{want} among #{inspect(columns)}"
    end

    indexes = column(h, "SELECT indexname FROM pg_indexes WHERE indexname LIKE '#{p}%' ORDER BY indexname")
    assert indexes == Enum.map(~w(jobs_pkey runs_job_started runs_pkey runs_running state_pkey), &(p <> &1))
    [partial] = column(h, "SELECT indexdef FROM pg_indexes WHERE indexname = '#{p}runs_running'")
    assert String.ends_with?(partial, "WHERE (status = 'running'::text)")

    # Numbers come back as numbers, and JSONB as Postgres orders it: keys by
    # length, then bytes.
    run = %{
      StoreCase.test_run("r1", "nightly", "ok", Clock.t0())
      | finished_at: Clock.t0() + 1000,
        duration_ms: 1000,
        output: "tab\tand \"quotes\" 😀",
        metrics: JS.parse!(~s({"ratio":0.30000000000000004,"tiny":1e-7,"huge":1e21}))
    }

    :ok = EctoStore.insert_run(h, run)
    {:ok, read} = EctoStore.get_run(h, "r1")
    assert {read.started_at, read.duration_ms, read.output} == {Clock.t0(), 1000, run.output}
    assert JS.stringify(read.metrics) == ~s({"huge":1e+21,"tiny":1e-7,"ratio":0.30000000000000004})
    # Postgres keeps JSONB numbers as numeric, and writes them out in full.
    assert column(h, "SELECT metrics::text FROM #{p}runs WHERE id = 'r1'") ==
             [~s({"huge": 1000000000000000000000, "tiny": 0.0000001, "ratio": 0.30000000000000004})]

    :ok = EctoStore.upsert_job(h, JS.parse!(~s({"name":"a","schedule":"every 5m","tags":["x"]})), 1)
    {:ok, j} = EctoStore.get_job(h, "a")
    assert JS.Object.keys(j.definition) == ["name", "tags", "schedule"]

    # Runs started in one millisecond come back in insertion order (seq).
    for id <- ~w(t1 t2 t3), do: :ok = EctoStore.insert_run(h, StoreCase.test_run(id, "ties", "ok", 5))
    {:ok, ties} = EctoStore.list_runs(h, "ties", 10)
    assert Enum.map(ties, & &1.id) == ~w(t3 t2 t1)

    # Names sort by byte, whatever the database's collation.
    for name <- ["b", "B", "_c"], do: :ok = EctoStore.upsert_job(h, JS.parse!(~s({"name":"#{name}"})), 1)
    {:ok, jobs} = EctoStore.list_jobs(h)
    assert Enum.map(jobs, & &1.name) == ["B", "_c", "a", "b"]
  end

  test "NUL characters are still recorded" do
    store = Servers.store(:pg)
    %{cw: cw, errors: errors} = Client.make(store: Stores.option(store))

    assert {:error, "bad\0byte"} =
             Cronwatch.run(
               "nul",
               fn j ->
                 Cronwatch.log(j, "before\0after")
                 {:error, "bad\0byte"}
               end,
               instance: cw
             )

    [run] = Cronwatch.runs!("nul", 10, instance: cw)
    assert run.status == "failed"
    assert run.output == "beforeafter"
    assert run.error == "badbyte"
    {EctoStore, h} = store
    {:ok, st} = EctoStore.get_state(h, "nul")
    assert st.consecutive_failures == 1, "the state, with its alert, was written too"

    # So are a trigger, metric names and a definition's text.
    {:ok, _} =
      Cronwatch.job("nul2", description: "a\0b", tags: ["t\0"], budget: %{"c\0" => 5}, instance: cw)

    :ok = Cronwatch.run("nul2", fn j -> Cronwatch.metric(j, "ro\0ws", 2) end, trigger: "cr\0on", instance: cw)
    [second] = Cronwatch.runs!("nul2", 10, instance: cw)
    assert {second.status, second.trigger, JS.stringify(second.metrics)} == {"ok", "cron", ~s({"rows":2})}
    {:ok, job} = EctoStore.get_job(h, "nul2")
    assert JS.stringify(job.definition) == ~s({"name":"nul2","tags":["t"],"budget":{"c":5},"description":"ab"})
    assert Agent.get(errors, & &1) == []
  end

  test "two stores racing on one job's state: exactly one write wins" do
    p = Servers.prefix()
    {EctoStore, one} = Servers.store(:pg, p)
    {EctoStore, two} = Servers.store(:pg, p)
    :ok = EctoStore.init(one)
    :ok = EctoStore.init(two)

    st = fn version, n ->
      state(
        ~s({"job":"r","open":{},"consecutiveFailures":#{n},"silencedUntil":null,"lastAlertAt":null,"version":#{version}})
      )
    end

    for {what, a, b, expected} <- [
          {"exactly one insert wins", st.(1, 1), st.(1, 2), 0},
          {"exactly one update wins", st.(2, 3), st.(2, 4), 1}
        ] do
      ta = Task.async(fn -> EctoStore.compare_and_set_state(one, a, expected) end)
      tb = Task.async(fn -> EctoStore.compare_and_set_state(two, b, expected) end)
      {{:ok, ra}, {:ok, rb}} = {Task.await(ta), Task.await(tb)}
      assert ra != rb, what
    end

    assert {:ok, %JobState{version: 2}} = EctoStore.get_state(one, "r")
  end

  test "many stores init at once" do
    p = Servers.prefix()
    stores = for _ <- 1..8, do: elem(Servers.store(:pg, p), 1)
    results = stores |> Enum.map(&Task.async(fn -> EctoStore.init(&1) end)) |> Enum.map(&Task.await/1)
    assert Enum.all?(results, &(&1 == :ok)), inspect(results)
    :ok = EctoStore.upsert_job(hd(stores), JS.parse!(~s({"name":"a"})), 1)
    assert {:ok, %{created_at: 1}} = EctoStore.get_job(List.last(stores), "a")
  end
end

defmodule Cronwatch.Store.MySQLDialectTests do
  @moduledoc """
  MySQL's and MariaDB's own tests (the PHP port's MysqlStoreTest, as the Go
  and Rust ports have them), used once per server.
  """

  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)

    quote do
      use Cronwatch.Test.ServerStoreTests, kind: unquote(kind)

      alias Cronwatch.JobState
      alias Cronwatch.JS
      alias Cronwatch.Store.Ecto, as: EctoStore
      alias Cronwatch.StoreCase
      alias Cronwatch.Test.Servers

      defp column(h, text), do: Servers.sql(h.repo, h.dynamic_repo, text).rows |> Enum.map(&hd/1)

      defp state(text), do: elem(JobState.from_json(text), 1)

      test "the SDK's JSON is kept byte for byte" do
        {EctoStore, h} = Servers.store(@kind)
        p = h.prefix
        :ok = EctoStore.init(h)
        assert :ok = EctoStore.init(h), "IF NOT EXISTS: a second init changes nothing"

        columns =
          column(
            h,
            "SELECT CONCAT(TABLE_NAME, '.', COLUMN_NAME, ' ', DATA_TYPE, ' ', COALESCE(COLLATION_NAME, '')) " <>
              "FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE '#{p}%' " <>
              "ORDER BY TABLE_NAME, ORDINAL_POSITION"
          )

        for want <- [
              # text, never the JSON type, which rewrites what it holds
              "#{p}jobs.definition longtext utf8mb4_bin",
              "#{p}runs.metrics longtext utf8mb4_bin",
              "#{p}state.state longtext utf8mb4_bin",
              # names compare as bytes: "b" and "B" are two jobs
              "#{p}jobs.name varchar utf8mb4_bin"
            ] do
          assert want in columns, "no #{want} among #{inspect(columns)}"
        end

        runs =
          for c <- columns,
              String.starts_with?(c, "#{p}runs."),
              do: c |> String.trim_leading("#{p}runs.") |> String.split(" ") |> hd()

        assert runs == ~w(seq id job status started_at finished_at duration_ms error output metrics trigger)

        definition =
          JS.parse!(~s({"grace":"15m","schedule":"0 2 * * *","budget":{"cost":2},"tags":["café ☃ 😀"],"name":"nightly"}))

        :ok = EctoStore.upsert_job(h, definition, 1)

        run = %{
          StoreCase.test_run("r1", "nightly", "ok", 1)
          | finished_at: 2,
            duration_ms: 1,
            output: "tab\tand \"quotes\" 😀",
            metrics: JS.parse!(~s({"ratio":0.30000000000000004,"tiny":1e-7,"huge":1e21,"üml":7}))
        }

        :ok = EctoStore.insert_run(h, run)

        st =
          state(
            ~s({"job":"nightly","open":{"failed":5},"consecutiveFailures":1,"silencedUntil":null,"lastAlertAt":null,) <>
              ~s("pendingRecovery":["missed"],"undelivered":[],"version":3})
          )

        :ok = EctoStore.set_state(h, st)
        assert column(h, "SELECT definition FROM #{p}jobs") == [JS.stringify(definition)]

        assert column(h, "SELECT metrics FROM #{p}runs") ==
                 [~s({"ratio":0.30000000000000004,"tiny":1e-7,"huge":1e+21,"üml":7})]

        assert column(h, "SELECT state FROM #{p}state") == [JobState.to_json(st)]
        {:ok, read} = EctoStore.get_run(h, "r1")
        assert Cronwatch.Run.to_json(read) == Cronwatch.Run.to_json(run)
      end

      # MySQL answers how many rows an UPDATE changed, not how many it
      # matched, unless the connection asks for found rows (MyXQL's do).
      # Neither may make a conditional write that landed read as refused.
      test "conditional writes do not lean on how rows are counted" do
        {EctoStore, h} = Servers.store(@kind)
        :ok = EctoStore.init(h)

        v = fn job, version, failures ->
          state(
            ~s({"job":"#{job}","open":{},"consecutiveFailures":#{failures},"silencedUntil":null,) <>
              ~s("lastAlertAt":null,"version":#{version}})
          )
        end

        cas = fn what, st, expected, want ->
          assert EctoStore.compare_and_set_state(h, st, expected) == {:ok, want}, what
        end

        cas.("first", v.("j", 1, 0), 0, true)
        cas.("a write from a stale read is refused", v.("j", 1, 9), 0, false)
        cas.("another version", v.("j", 3, 0), 2, false)
        cas.("the version read", v.("j", 2, 1), 1, true)
        assert {:ok, %JobState{version: 2}} = EctoStore.get_state(h, "j")

        :ok =
          EctoStore.set_state(
            h,
            state(~s({"job":"old","open":{},"consecutiveFailures":3,"silencedUntil":null,"lastAlertAt":null}))
          )

        cas.("state written before versions counts as 0", v.("old", 1, 4), 0, true)
        zero = state(~s({"job":"zero","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null}))
        :ok = EctoStore.set_state(h, zero)
        cas.("a write of what version 0 already holds still wrote", zero, 0, true)
        # A write from version 0 whose insert landed but whose answer was
        # lost: the row holding exactly what was sent is the write's own.
        landed = v.("landed", 1, 0)
        :ok = EctoStore.set_state(h, landed)
        cas.("a landed write is counted as written", landed, 0, true)

        # A flush that writes what the row already holds still wrote.
        run = %{StoreCase.test_run("r", "j", "running", 1) | output: "same"}
        :ok = EctoStore.insert_run(h, run)
        assert EctoStore.update_run_if(h, run, ["running"]) == {:ok, true}
        assert EctoStore.update_run_if(h, run, ["timeout"]) == {:ok, false}
      end

      # MySQL's trigger column is VARCHAR(255): a longer trigger is cut to
      # fit rather than lose the whole run.
      test "a run with a long trigger is kept" do
        {EctoStore, h} = Servers.store(@kind)
        :ok = EctoStore.init(h)

        :ok =
          EctoStore.insert_run(h, %{StoreCase.test_run("r", "j", "running", 1) | trigger: String.duplicate("é", 300)})

        assert {:ok, %{trigger: trigger}} = EctoStore.get_run(h, "r")
        assert trigger == String.duplicate("é", 255)
      end
    end
  end
end

defmodule Cronwatch.Store.MySQLTest do
  @moduledoc "The store on MySQL, when CRONWATCH_TEST_MYSQL is set."
  use Cronwatch.Store.MySQLDialectTests, kind: :mysql
end

defmodule Cronwatch.Store.MariaDBTest do
  @moduledoc "The store on MariaDB, when CRONWATCH_TEST_MARIADB is set."
  use Cronwatch.Store.MySQLDialectTests, kind: :mariadb
end
