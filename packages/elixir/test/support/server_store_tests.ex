defmodule Cronwatch.Test.ServerStoreTests do
  @moduledoc """
  The store's tests on a database server, used once per server:
  `use Cronwatch.Test.ServerStoreTests, kind: :pg`. They skip, saying why,
  when the server's variable is unset (see `Cronwatch.Test.Servers`).

  Each module gets `Cronwatch.StoreCase` (the contract, the `store.json`
  replay, the finish-once scenarios over several instances on one database
  and a client end to end) and the Rust port's server tests that every
  dialect shares: a client recording and checking, a run surviving the app's
  rollback, and rows of another shape. The dialects' own tests are in
  `test/store/servers_test.exs`.
  """

  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)
    # Worked out here rather than in the test, where Elixir 1.18's type
    # checker warns that comparing the one kind with the others is always
    # false.
    dialect = if kind in [:pg, :pgcron], do: :postgres, else: :mysql

    quote do
      # The tag is set before StoreCase's tests are registered, which read
      # the module's tags as each is defined.
      use ExUnit.Case, async: true

      alias Cronwatch.JS
      alias Cronwatch.Store.Ecto, as: EctoStore
      alias Cronwatch.StoreCase
      alias Cronwatch.Test.Capture
      alias Cronwatch.Test.Client
      alias Cronwatch.Test.Clock
      alias Cronwatch.Test.Conformance
      alias Cronwatch.Test.ForeignRows
      alias Cronwatch.Test.Servers
      alias Cronwatch.Test.Stores

      @moduletag Servers.skip_unless(unquote(kind))

      use Cronwatch.StoreCase,
        async: true,
        store: fn -> Servers.store(unquote(kind)) end,
        fixture: File.read!(Path.join(Conformance.dir(), "store.json"))

      @kind unquote(kind)

      use ForeignRows, store: fn -> Servers.store(@kind) end

      test "the store names its dialect" do
        {EctoStore, h} = Servers.store(@kind)
        assert h.dialect == unquote(dialect)
      end

      # A client from end to end: jobs declared, runs that succeed and fail,
      # a check that finds a stuck run and a missed one, the alerts sent, and
      # the state's version moving on every write.
      test "a client records and checks" do
        {EctoStore, h} = store = Servers.store(@kind)
        %{cw: cw, clock: c, alerts: alerts, errors: errors} = Client.make(store: Stores.option(store))
        nightly = Cronwatch.job!("nightly", schedule: "every 5m", grace: "1m", timeout: "2m", instance: cw)
        Cronwatch.job!("hourly", schedule: "every 1h", grace: "1m", instance: cw)

        Cronwatch.run(nightly, fn j ->
          Cronwatch.log(j, "rows: 12")
          Cronwatch.metric(j, "rows", 12)
        end)

        Clock.advance(c, Clock.min())
        assert {:error, "boom"} = Cronwatch.run(nightly, fn _ -> {:error, "boom"} end)
        {:ok, st} = EctoStore.get_state(h, "nightly")
        assert st.consecutive_failures == 1
        before = st.version
        assert before >= 2

        Clock.advance(c, Clock.min())
        {:ok, handle} = Cronwatch.start(nightly)
        Cronwatch.log(handle, "started")
        Cronwatch.flush(handle)
        # Past nightly's timeout, then past hourly's hour and grace.
        Clock.advance(c, 3 * Clock.min())
        first = Cronwatch.check!(instance: cw)
        Clock.advance(c, 61 * Clock.min())
        second = Cronwatch.check!(instance: cw)

        types = Capture.types(alerts)
        for want <- ~w(failed missed stuck), do: assert(want in types, "no #{want} among #{inspect(types)}")
        runs = Cronwatch.runs!("nightly", 10, instance: cw)
        assert Enum.map(runs, & &1.status) == ["timeout", "failed", "ok"]
        assert Enum.at(runs, 0).output == "started"
        assert Enum.at(runs, 2).output == "rows: 12"
        assert JS.stringify(Enum.at(runs, 2).metrics) == ~s({"rows":12})
        {:ok, st} = EctoStore.get_state(h, "nightly")
        assert st.version > before, "the version did not move"
        assert {length(first.jobs), length(second.jobs)} == {2, 2}
        assert Agent.get(errors, & &1) == []

        # Another process reads it all back.
        {:ok, other} = EctoStore.new(repo: h.repo, prefix: h.prefix, dynamic_repo: h.dynamic_repo)
        %{cw: two} = Client.make(store: Stores.option({EctoStore, other}), clock_ref: c)
        summary = Cronwatch.job_summary!("nightly", instance: two)
        assert summary.consecutive_failures == 2, "the failure and the stuck run"
        assert length(Cronwatch.runs!("nightly", 10, instance: two)) == 3
      end

      # A run recorded while the app has a transaction open survives the
      # app's rollback: the store's statements run on a connection of their
      # own, never inside the app's transaction.
      test "a run survives the app's rollback" do
        {EctoStore, h} = store = Servers.store(@kind)
        %{cw: cw} = Client.make(store: Stores.option(store))
        repo = h.repo
        orders = "#{h.prefix}orders"
        Servers.sql(repo, h.dynamic_repo, "CREATE TABLE #{orders} (id INT PRIMARY KEY)")
        on_exit(fn -> drop_table(@kind, orders) end)
        previous = repo.put_dynamic_repo(h.dynamic_repo)

        try do
          {:error, :rolled_back} =
            repo.transaction(fn ->
              repo.query!("INSERT INTO #{orders} VALUES (1)")
              assert Cronwatch.run("import", fn _ -> "imported" end, instance: cw) == "imported"
              repo.rollback(:rolled_back)
            end)
        after
          repo.put_dynamic_repo(previous)
        end

        assert %{rows: [[0]]} = Servers.sql(repo, h.dynamic_repo, "SELECT COUNT(*) FROM #{orders}")
        assert [run] = Cronwatch.runs!("import", 10, instance: cw), "the run was lost with the app's rollback"
        assert run.output == "imported"
      end

      # A row another writer (or a hand edit) left in a shape of its own,
      # valid JSON but not what the SDK writes, is read as the SDK reads it
      # rather than failing every read it is part of.
      test "a row of another shape does not blind the checks" do
        {EctoStore, h} = store = Servers.store(@kind)
        p = h.prefix
        :ok = EctoStore.init(h)
        :ok = EctoStore.insert_run(h, StoreCase.test_run("good", "a", "running", 1))
        :ok = EctoStore.upsert_job(h, JS.parse!(~s({"name":"a","schedule":"0 * * * *"})), 1)

        Servers.sql(
          h.repo,
          h.dynamic_repo,
          "INSERT INTO #{p}runs (id, job, status, started_at, metrics) " <>
            ~s[VALUES ('bad', 'b', 'running', 2, '{"rows":"12","n":3}')]
        )

        Servers.sql(
          h.repo,
          h.dynamic_repo,
          "INSERT INTO #{p}jobs (name, definition, created_at, updated_at) VALUES ('b', '[]', 1, 1)"
        )

        {:ok, running} = EctoStore.running_runs(h)
        assert length(running) == 2
        bad = Enum.find(running, &(&1.id == "bad"))
        assert JS.stringify(bad.metrics) == ~s({"n":3}), "the numbers are kept"
        assert {:ok, [_, _]} = EctoStore.list_jobs(h)
        %{cw: cw} = Client.make(store: Stores.option(store))
        assert {:ok, _} = Cronwatch.check(instance: cw)
      end

      defp drop_table(kind, table) do
        repo = Servers.repo(kind)
        {:ok, pid} = repo.start_link(name: nil, url: Servers.url(kind), pool_size: 1, log: false)

        try do
          Servers.sql(repo, pid, "DROP TABLE IF EXISTS #{table}")
        after
          Supervisor.stop(pid)
        end
      end
    end
  end
end
