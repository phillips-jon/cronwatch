if Code.ensure_loaded?(ExUnit.CaseTemplate) do
  defmodule Cronwatch.StoreCase do
    @moduledoc """
    The test every CronWatch store passes, as an ExUnit case template: the
    SDK's `store-conformance.ts` step for step, and a replay of the store
    cases in the repository's `conformance/store.json`. The memory store and
    `Cronwatch.Store.Ecto` pass it; run it against a store of your own:

        defmodule MyApp.StoreTest do
          use Cronwatch.StoreCase,
            store: {MyApp.Store, url: "..."},
            fixture: File.read!("path/to/conformance/store.json")
        end

    `store:` is `{module, opts}` (each test gets a store from `module.new/2`,
    started under the test when the module has `child_spec/1`) or a
    zero-arity function answering a fresh `{module, handle}`. Every store a
    test gets must be empty. `fixture:` is the text of `store.json`, which a
    published package cannot read from the repository, so the caller hands
    it in; without it the replay is left out.

    The functions `contract/1` and `replay_fixture/2` can also be called from
    a test of your own.
    """

    use ExUnit.CaseTemplate

    import ExUnit.Assertions

    alias Cronwatch.JobState
    alias Cronwatch.JS
    alias Cronwatch.JS.Object
    alias Cronwatch.Run
    alias Cronwatch.Store

    using opts do
      store = Keyword.fetch!(opts, :store)
      fixture = Keyword.get(opts, :fixture)

      quote do
        @doc false
        def __cronwatch_store__, do: Cronwatch.StoreCase.make(unquote(store))

        test "store conformance" do
          Cronwatch.StoreCase.contract(__cronwatch_store__())
        end

        if unquote(fixture != nil) do
          test "conformance/store.json" do
            assert Cronwatch.StoreCase.replay_fixture(unquote(fixture), &__cronwatch_store__/0) > 0
          end
        end

        # Scenarios over several instances on one store (the SDK's
        # finish-once tests, a client end to end). See scenarios/0.
        for {name, _} <- Cronwatch.StoreCase.scenarios() do
          @cronwatch_scenario name
          test name do
            Cronwatch.StoreCase.scenario(@cronwatch_scenario, &__cronwatch_store__/0)
          end
        end
      end
    end

    @doc """
    Where the scenarios over several instances sharing one store go (the
    SDK's finish-once tests, a client end to end): a list of `{name, fun}`,
    each `fun` given the zero-arity function that makes a store. Each
    scenario makes one store and runs several instances over it (through
    `Cronwatch.StoreCase.Shared`), as several processes share one database.
    """
    @spec scenarios() :: [{String.t(), ((-> Store.t()) -> term())}]
    def scenarios do
      [
        {"two instances finishing one run: one records and judges it, the other reports it already finished",
         &two_finishing_one_run/1},
        {"two instances recording one finished run from a source: it is judged once", &two_recording_one_run/1},
        {"many instances starting and finishing one id: exactly one finish is recorded", &many_starting_one_id/1},
        {"a client end to end", &end_to_end/1}
      ]
    end

    @t0 1_767_605_400_000
    @min 60_000

    # An instance over `store`, with a clock, a channel keeping its alerts and
    # an error handler keeping the errors' text.
    defp instance(store, clock) do
      name = Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")
      {:ok, alerts} = Agent.start_link(fn -> [] end)
      {:ok, errors} = Agent.start_link(fn -> [] end)
      channel = Cronwatch.Alerts.fun("capture", fn a -> Agent.update(alerts, &(&1 ++ [a.type])) end)

      opts = [
        name: name,
        store: {Cronwatch.StoreCase.Shared, store: store},
        clock: fn -> :atomics.get(clock, 1) end,
        alerts: [channel],
        cron_secret: false,
        on_error: fn e, _where -> Agent.update(errors, &(&1 ++ [Cronwatch.Config.describe(e)])) end
      ]

      ExUnit.Callbacks.start_supervised!({Cronwatch, opts}, id: name)
      %{cw: name, alerts: alerts, errors: errors}
    end

    defp clock do
      ref = :atomics.new(1, signed: true)
      :atomics.put(ref, 1, @t0)
      ref
    end

    defp types(ps), do: Enum.flat_map(ps, &Agent.get(&1.alerts, fn a -> a end))
    defp errors(ps), do: Enum.flat_map(ps, &Agent.get(&1.errors, fn e -> e end))

    defp failed_run(id, job, started_at) do
      %Run{
        id: id,
        job: job,
        status: "failed",
        started_at: started_at,
        finished_at: started_at + 1000,
        duration_ms: 1000,
        error: "ERROR: deadlock detected",
        trigger: "pg_cron"
      }
    end

    defp two_finishing_one_run(make) do
      store = make.()
      clock = clock()
      [one, two] = ps = [instance(store, clock), instance(store, clock)]
      for p <- ps, do: Cronwatch.job!("webhook-ingest", failures_before_alert: 2, instance: p.cw)
      {:ok, _} = Cronwatch.start("webhook-ingest", id: "delivery-1", instance: one.cw)
      {:ok, h1} = Cronwatch.resume_run("webhook-ingest", "delivery-1", instance: one.cw)
      {:ok, h2} = Cronwatch.resume_run("webhook-ingest", "delivery-1", instance: two.cw)
      :atomics.add(clock, 1, @min)

      results =
        [h1, h2]
        |> Enum.map(fn h -> Task.async(fn -> Cronwatch.fail(h, %RuntimeError{message: "upstream 502"}) end) end)
        |> Task.await_many(:infinity)

      assert Enum.count(results, & &1) == 1, "one finish recorded"
      assert Enum.any?(errors(ps), &(&1 =~ "already finished as failed; ignored")), inspect(errors(ps))
      assert length(Cronwatch.runs!("webhook-ingest", 50, instance: one.cw)) == 1
      assert must(c(store, :get_state, ["webhook-ingest"])).consecutive_failures == 1, "the failure counted once"
      assert types(ps) == [], "one failure is below failures_before_alert 2"
    end

    defp two_recording_one_run(make) do
      store = make.()
      clock = clock()
      [one, two] = ps = [instance(store, clock), instance(store, clock)]
      for p <- ps, do: Cronwatch.job!("db:rollup", failures_before_alert: 2, instance: p.cw)
      done = failed_run("pgcron:9", "db:rollup", @t0 - @min)
      running = %{done | status: "running", finished_at: nil, duration_ms: nil, error: nil}
      {:ok, _} = Cronwatch.record_run(running, instance: one.cw)
      {:ok, _} = Cronwatch.jobs(instance: two.cw)

      [one, two]
      |> Enum.map(fn p -> Task.async(fn -> Cronwatch.record_run(done, instance: p.cw) end) end)
      |> Task.await_many(:infinity)

      assert must(c(store, :get_state, ["db:rollup"])).consecutive_failures == 1
      assert types(ps) == []

      # The one that lost the race reports it, when both read the run still
      # running; one that read it finished leaves it alone in silence.
      for e <- errors(ps), do: assert(e =~ "pgcron:9 of db:rollup was already finished as failed; ignored", e)
    end

    defp many_starting_one_id(make) do
      store = make.()
      clock = clock()
      ps = for _ <- 1..6, do: instance(store, clock)
      for p <- ps, do: Cronwatch.job!("ingest", instance: p.cw)
      {:ok, _} = Cronwatch.check(instance: hd(ps).cw)

      for k <- 0..4 do
        id = "evt_#{k}"

        finished =
          ps
          |> Enum.with_index()
          |> Enum.map(fn {p, i} ->
            Task.async(fn ->
              {:ok, h} = Cronwatch.start("ingest", id: id, instance: p.cw)
              Cronwatch.finish(h, "worker #{i}")
            end)
          end)
          |> Task.await_many(:infinity)

        assert Enum.count(finished, & &1) == 1, "#{id}: one finish recorded"
      end

      runs = Cronwatch.runs!("ingest", 500, instance: hd(ps).cw)
      assert length(runs) == 5
      assert runs |> Enum.map(& &1.status) |> Enum.uniq() == ["ok"]
      assert Enum.reject(errors(ps), &(&1 =~ "already finished")) == []
    end

    defp end_to_end(make) do
      store = make.()
      clock = clock()
      p = instance(store, clock)
      job = Cronwatch.job!("e2e", schedule: "every 1h", grace: "10m", expect: "done", instance: p.cw)
      {:ok, _} = Cronwatch.check(instance: p.cw)
      assert Cronwatch.run(job, fn _ -> "done" end) == "done"
      :atomics.add(clock, 1, @min)
      assert Cronwatch.run(job, fn _ -> "nothing" end) == "nothing"
      assert types([p]) == ["failed"]
      :atomics.add(clock, 1, @min)
      Cronwatch.run(job, fn ctx -> Cronwatch.log(ctx, "done at last") end)
      assert types([p]) == ["failed", "recovered"]
      :atomics.add(clock, 1, 2 * 60 * @min)
      result = Cronwatch.check!(instance: p.cw)
      assert Enum.map(result.alerts, & &1.type) == ["missed"]
      assert [%{name: "e2e", health: "late"}] = result.jobs
      [last | _] = runs = Cronwatch.runs!("e2e", 50, instance: p.cw)
      assert length(runs) == 3
      assert last.output == "done at last"
      assert must(c(store, :get_state, ["e2e"])).version > 0
      :ok = Cronwatch.forget("e2e", instance: p.cw)
      assert must(c(store, :get_job, ["e2e"])) == nil
      assert must(c(store, :list_runs, ["e2e", 10])) == []
      assert errors([p]) == []
    end

    @doc false
    def scenario(name, make) do
      {_, fun} = List.keyfind(scenarios(), name, 0)
      fun.(make)
    end

    @doc """
    A store from a `store:` option: `{module, opts}` made with `module.new/2`
    (and started under the running test when the module has `child_spec/1`),
    or a zero-arity function answering `{module, handle}`.
    """
    @spec make(term()) :: Store.t()
    def make(fun) when is_function(fun, 0), do: fun.()

    def make({module, opts}) do
      Code.ensure_loaded(module)
      instance = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")

      handle =
        if function_exported?(module, :new, 2) do
          {:ok, handle} = module.new(opts, instance)
          handle
        else
          opts
        end

      if function_exported?(module, :child_spec, 1) do
        ExUnit.Callbacks.start_supervised!(Supervisor.child_spec(module.child_spec(handle), id: {module, instance}))
      end

      {module, handle}
    end

    def make(module) when is_atom(module), do: make({module, []})

    @doc """
    A run as the contract test writes them: finished ten milliseconds after
    it started unless it is running, with one metric.
    """
    @spec new_run(String.t(), String.t(), String.t(), integer()) :: Run.t()
    def new_run(id, job, status, started_at) do
      finished = status != "running"

      %Run{
        id: id,
        job: job,
        status: status,
        started_at: started_at,
        finished_at: if(finished, do: started_at + 10),
        duration_ms: if(finished, do: 10),
        metrics: Object.new([{"n", 1}]),
        trigger: "run"
      }
    end

    @doc """
    JSON text with every object's keys sorted, so two values compare
    whatever order a JSON column (Postgres's JSONB) gave an object's keys
    back in.
    """
    @spec canonical(String.t() | JS.value()) :: String.t()
    def canonical(text) when is_binary(text) do
      case JS.parse(text) do
        {:ok, v} -> sorted(v)
        {:error, _} -> text
      end
    end

    def canonical(v), do: sorted(v)

    defp sorted(%Object{pairs: pairs}) do
      body =
        pairs
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join(",", fn {k, v} -> JS.quote(k) <> ":" <> sorted(v) end)

      "{" <> body <> "}"
    end

    defp sorted(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &sorted/1) <> "]"
    defp sorted(v), do: JS.stringify(v)

    defp same_json(what, got, want) do
      assert canonical(got) == canonical(want), "#{what}:\n got #{got}\nwant #{want}"
    end

    defp must({:ok, v}), do: v
    defp must(:ok), do: :ok
    defp must(other), do: flunk("the store answered #{inspect(other)}")

    defp c(store, fun, args \\ []), do: Store.call(store, fun, args)

    defp ids(runs), do: Enum.map(runs, & &1.id)

    defp definition(text), do: JS.parse!(text)

    defp state(text) do
      {:ok, s} = JobState.from_json(text)
      s
    end

    defp json_of(nil, _), do: "null"
    defp json_of(v, fun), do: fun.(v)

    @doc """
    The contract test: `store-conformance.ts`, step for step, against one
    store, which must be empty. Fails the running test, as an assertion
    does, at the first thing the store gets wrong.
    """
    @spec contract(Store.t()) :: :ok
    def contract({module, _} = store) do
      if function_exported?(module, :init, 1), do: must(c(store, :init))
      assert must(c(store, :get_job, ["a"])) == nil, "no job yet"
      must(c(store, :upsert_job, [definition(~s({"name":"a","schedule":"every 5m"})), 100]))
      must(c(store, :upsert_job, [definition(~s({"name":"a","schedule":"every 10m","tags":["x"]})), 200]))
      for name <- ["b", "B", "_c"], do: must(c(store, :upsert_job, [definition(~s({"name":"#{name}"})), 300]))
      a = must(c(store, :get_job, ["a"]))
      assert a.created_at == 100, "createdAt survives upsert"
      assert a.updated_at == 200
      same_json("definition", JS.stringify(a.definition), ~s({"name":"a","schedule":"every 10m","tags":["x"]}))
      names = store |> c(:list_jobs) |> must() |> Enum.map(& &1.name)
      assert names == ["B", "_c", "a", "b"], "byte order, not locale"

      for r <- [
            new_run("r1", "a", "ok", 1000),
            new_run("r2", "a", "failed", 2000),
            new_run("r3", "a", "running", 3000),
            new_run("r4", "b", "ok", 1500),
            new_run("rb", "B", "running", 2000),
            new_run("rc", "_c", "running", 2000)
          ],
          do: must(c(store, :insert_run, [r]))

      assert ids(must(c(store, :list_runs, ["a", 10]))) == ["r3", "r2", "r1"], "newest first"
      assert ids(must(c(store, :list_runs, ["a", 2]))) == ["r3", "r2"], "limit"
      assert must(c(store, :last_run, ["a"])).id == "r3"
      assert must(c(store, :last_run, ["none"])) == nil
      assert ids(must(c(store, :running_runs))) == ["rb", "rc", "r3"], "oldest first, then insertion order"
      r1 = must(c(store, :get_run, ["r1"]))
      same_json("metrics", JS.stringify(r1.metrics), ~s({"n":1}))
      assert r1.duration_ms == 10

      updated = %{new_run("r3", "a", "ok", 3000) | output: "line1\nline2", metrics: Object.new([{"cost", 0.25}])}
      must(c(store, :update_run, [updated]))
      r3 = must(c(store, :get_run, ["r3"]))
      assert r3.status == "ok"
      assert r3.output == "line1\nline2"
      same_json("updated metrics", JS.stringify(r3.metrics), ~s({"cost":0.25}))
      assert ids(must(c(store, :running_runs))) == ["rb", "rc"]

      # update_run_if writes only over a row whose status is one of those
      # given, and says whether it did.
      assert {:error, _} = c(store, :insert_run, [new_run("r3", "a", "running", 3000)]),
             "an id already recorded is refused"

      must(c(store, :upsert_job, [definition(~s({"name":"q"})), 300]))
      must(c(store, :insert_run, [new_run("rx", "q", "running", 2500)]))

      if Store.has?(store, :update_run_if, 2) do
        first = %{new_run("rx", "q", "failed", 2500) | error: "first"}
        assert must(c(store, :update_run_if, [first, ["running"]])) == true
        second = %{new_run("rx", "q", "ok", 2500) | output: "second"}
        assert must(c(store, :update_run_if, [second, ["running"]])) == false, "a second finish is refused"
        assert must(c(store, :get_run, ["rx"])).error == "first"
        late = %{new_run("rx", "q", "ok", 2500) | output: "late"}
        assert must(c(store, :update_run_if, [late, ["running", "timeout"]])) == false
        must(c(store, :update_run, [%{new_run("rx", "q", "timeout", 2500) | error: "stuck"}]))
        late = %{late | metrics: Object.new([{"m", 2}])}
        assert must(c(store, :update_run_if, [late, ["running", "timeout"]])) == true, "any of the statuses given"

        same_json(
          "late finish",
          json_of(must(c(store, :get_run, ["rx"])), &Run.to_json/1),
          ~s({"id":"rx","job":"q","status":"ok","startedAt":2500,"finishedAt":2510,"durationMs":10,) <>
            ~s("error":null,"output":"late","metrics":{"m":2},"trigger":"run"})
        )

        missing = new_run("missing", "q", "ok", 1)
        assert must(c(store, :update_run_if, [missing, ["running"]])) == false, "a run not there is not written"
        assert must(c(store, :get_run, ["missing"])) == nil

        assert must(c(store, :update_run_if, [new_run("rx", "q", "failed", 2500), []])) == false,
               "no statuses, no write"

        assert must(c(store, :get_run, ["rx"])).status == "ok"
      end

      # delete_run_if, for a store that has it, takes back only a run still
      # of the job and in the status given.
      if Store.has?(store, :delete_run_if, 3) do
        must(c(store, :insert_run, [new_run("rd", "q", "running", 2600)]))
        assert must(c(store, :delete_run_if, ["rd", "a", "running"])) == false, "not another job's"
        assert must(c(store, :delete_run_if, ["rd", "q", "ok"])) == false, "not in another status"
        assert must(c(store, :delete_run_if, ["rx", "q", "running"])) == false, "not a finished run"
        assert must(c(store, :delete_run_if, ["rd", "q", "running"])) == true, "taken back"
        assert must(c(store, :get_run, ["rd"])) == nil
        assert must(c(store, :delete_run_if, ["rd", "q", "running"])) == false, "only once"
        assert must(c(store, :get_run, ["rx"])) != nil, "the finished run kept"
      end

      must(c(store, :delete_job, ["q"]))

      # Forgetting a job while one of its runs is in flight: the run
      # finishing later changes nothing.
      must(c(store, :delete_job, ["B"]))
      must(c(store, :update_run, [%{new_run("rb", "B", "ok", 2000) | output: "late"}]))
      assert must(c(store, :get_run, ["rb"])) == nil, "a forgotten run stays gone"
      assert must(c(store, :list_runs, ["B", 10])) == []
      assert ids(must(c(store, :running_runs))) == ["rc"]
      must(c(store, :delete_job, ["_c"]))

      assert must(c(store, :get_state, ["a"])) == nil
      failed = ~s({"job":"a","open":{"failed":5},"consecutiveFailures":2,"silencedUntil":null,"lastAlertAt":6})
      must(c(store, :set_state, [state(failed)]))
      plain = ~s({"job":"a","open":{},"consecutiveFailures":0,"silencedUntil":99,"lastAlertAt":6})
      must(c(store, :set_state, [state(plain)]))
      same_json("state", json_of(must(c(store, :get_state, ["a"])), &JobState.to_json/1), plain)

      full =
        ~s({"job":"a","open":{"stuck":7},"consecutiveFailures":1,"silencedUntil":null,"lastAlertAt":6,) <>
          ~s("pendingRecovery":["missed"],"undelivered":[{"type":"failed","run":null,"details":) <>
          ~s({"consecutiveFailures":1,"threshold":1},"job":"a","definition":{"name":"a"},"title":"a failed",) <>
          ~s("message":"boom","at":7,"triage":null}]})

      must(c(store, :set_state, [state(full)]))

      same_json(
        "pendingRecovery and undelivered round-trip",
        json_of(must(c(store, :get_state, ["a"])), &JobState.to_json/1),
        full
      )

      must(c(store, :set_state, [state(plain)]))

      # compare_and_set_state writes only over the version it was told to
      # expect.
      if Store.has?(store, :compare_and_set_state, 2) do
        v = fn version, failures ->
          state(
            ~s({"job":"v","open":{},"consecutiveFailures":#{failures},"silencedUntil":null,) <>
              ~s("lastAlertAt":null,"version":#{version}})
          )
        end

        cas = fn st, expected -> must(c(store, :compare_and_set_state, [st, expected])) end
        assert cas.(v.(2, 0), 1) == false, "no row matches only version 0"
        assert must(c(store, :get_state, ["v"])) == nil
        assert cas.(v.(1, 0), 0) == true, "no row counts as version 0"
        assert cas.(v.(1, 9), 0) == false, "a write from a stale read is refused"
        assert cas.(v.(2, 1), 1) == true, "the version read"
        assert cas.(v.(3, 0), 1) == false, "an older version"

        same_json(
          "state after writes",
          json_of(must(c(store, :get_state, ["v"])), &JobState.to_json/1),
          JobState.to_json(v.(2, 1))
        )

        must(
          c(store, :set_state, [
            state(~s({"job":"w","open":{},"consecutiveFailures":3,"silencedUntil":null,"lastAlertAt":null}))
          ])
        )

        w1 =
          state(~s({"job":"w","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"version":1}))

        assert cas.(w1, 1) == false, "state written before versions counts as 0"
        assert cas.(w1, 0) == true
        assert must(c(store, :get_state, ["w"])).version == 1
        must(c(store, :delete_job, ["v"]))
        assert cas.(v.(3, 0), 2) == false, "a forgotten job's state is not written back"
        assert must(c(store, :get_state, ["v"])) == nil
        must(c(store, :delete_job, ["w"]))
      end

      must(c(store, :insert_run, [new_run("r5", "a", "running", 500)]))
      assert must(c(store, :prune, [2500])) == 2, "r1 and r2 pruned; running r5 kept, and b's r4 kept"
      assert ids(must(c(store, :list_runs, ["a", 10]))) == ["r3", "r5"]
      assert ids(must(c(store, :list_runs, ["b", 10]))) == ["r4"]
      assert must(c(store, :prune, [1_000_000])) == 0, "each job keeps its newest run, and running runs stay"

      must(c(store, :delete_job, ["a"]))
      assert must(c(store, :get_job, ["a"])) == nil
      assert must(c(store, :list_runs, ["a", 10])) == []
      assert must(c(store, :get_state, ["a"])) == nil
      assert must(c(store, :get_job, ["b"])).name == "b"
      if function_exported?(module, :close, 1), do: must(c(store, :close))
      :ok
    end

    defp fixture_run(v) do
      {:ok, r} = Run.from_value(v)
      r
    end

    defp fixture_state(v) do
      {:ok, s} = JobState.from_value(v)
      s
    end

    defp init({module, _} = store) do
      if function_exported?(module, :init, 1), do: must(c(store, :init))
    end

    defp close({module, _} = store) do
      if function_exported?(module, :close, 1), do: must(c(store, :close))
    end

    @doc """
    Replays the store cases of `conformance/store.json` (its text) against
    stores from `make`, a zero-arity function answering an empty store each
    call: prune scripts, `compare_and_set_state` steps and `update_run_if`
    steps, each read back and compared with what the SDK's memory store
    answered. Answers how many cases were replayed.
    """
    @spec replay_fixture(String.t(), (-> Store.t())) :: pos_integer()
    def replay_fixture(text, make) do
      fix = JS.parse!(text)

      prune =
        for script <- Object.get(fix, "prune"), reduce: 0 do
          cases ->
            name = Object.get(script, "name")
            store = make.()
            init(store)

            cases =
              for event <- Object.get(script, "events"), reduce: cases do
                cases ->
                  case Object.fetch(event, "insert") do
                    {:ok, runs} ->
                      Enum.each(runs, &must(c(store, :insert_run, [fixture_run(&1)])))
                      cases

                    :error ->
                      pruned = must(c(store, :prune, [Object.get(event, "prune")]))
                      assert pruned == Object.get(event, "pruned"), "#{name}: pruned"

                      for {job, want} <- Object.to_list(Object.get(event, "remaining")) do
                        assert ids(must(c(store, :list_runs, [job, 100]))) == want, "#{name}: #{job} kept"
                      end

                      cases + 1
                  end
              end

            close(store)
            cases
        end

      store = make.()
      init(store)

      cas =
        fix
        |> Object.get("compareAndSetState")
        |> Enum.with_index()
        |> Enum.reduce(0, fn {step, i}, cases ->
          cond do
            Object.has_key?(step, "cas") ->
              st = fixture_state(Object.get(step, "cas"))
              wrote = must(c(store, :compare_and_set_state, [st, Object.get(step, "expected")]))
              assert wrote == Object.get(step, "written"), "compareAndSetState step #{i}: wrote"

            Object.has_key?(step, "set") ->
              must(c(store, :set_state, [fixture_state(Object.get(step, "set"))]))

            true ->
              must(c(store, :delete_job, [Object.get(step, "forget")]))
          end

          for {job, want} <- Object.to_list(Object.get(step, "states")) do
            got = json_of(must(c(store, :get_state, [job])), &JobState.to_json/1)
            same_json("compareAndSetState step #{i}, state of #{job}", got, JS.stringify(want))
          end

          cases + 1
        end)

      close(store)

      store = make.()
      init(store)
      must(c(store, :insert_run, [%{new_run("u1", "a", "running", 1000) | metrics: Object.new()}]))

      update =
        fix
        |> Object.get("updateRunIf")
        |> Enum.with_index()
        |> Enum.reduce(0, fn {step, i}, cases ->
          cond do
            Object.has_key?(step, "set") ->
              must(c(store, :update_run, [fixture_run(Object.get(step, "set"))]))

            Object.has_key?(step, "insert") ->
              outcome =
                case c(store, :insert_run, [fixture_run(Object.get(step, "insert"))]) do
                  :ok -> "inserted"
                  _ -> "refused"
                end

              assert outcome == Object.get(step, "outcome"), "updateRunIf step #{i}"

            true ->
              run = fixture_run(Object.get(step, "run"))
              wrote = must(c(store, :update_run_if, [run, Object.get(step, "from")]))
              assert wrote == Object.get(step, "outcome"), "updateRunIf step #{i}: wrote"
          end

          got = json_of(must(c(store, :get_run, ["u1"])), &Run.to_json/1)
          same_json("updateRunIf step #{i}", got, JS.stringify(Object.get(step, "stored")))
          cases + 1
        end)

      close(store)
      total = prune + cas + update
      assert total > 0, "no cases replayed"
      total
    end
  end
end

defmodule Cronwatch.StoreCase.Shared do
  @moduledoc """
  A store made elsewhere, handed to an instance as it is:
  `store: {Cronwatch.StoreCase.Shared, store: {module, handle}}`. Several
  instances given one store share its data, as several processes share one
  database; `Cronwatch.StoreCase`'s scenarios run that way. Each call goes
  to the store given, and a conditional write it lacks is answered as the
  client's fallback expects.
  """
  @behaviour Cronwatch.Store

  alias Cronwatch.Store

  @impl true
  def new(opts, _instance), do: {:ok, Keyword.fetch!(opts, :store)}

  @impl true
  def init({module, handle}) do
    Code.ensure_loaded(module)
    if function_exported?(module, :init, 1), do: module.init(handle), else: :ok
  end

  @impl true
  def upsert_job(s, d, now), do: Store.call(s, :upsert_job, [d, now])
  @impl true
  def get_job(s, name), do: Store.call(s, :get_job, [name])
  @impl true
  def list_jobs(s), do: Store.call(s, :list_jobs, [])
  @impl true
  def delete_job(s, name), do: Store.call(s, :delete_job, [name])
  @impl true
  def insert_run(s, run), do: Store.call(s, :insert_run, [run])
  @impl true
  def update_run(s, run), do: Store.call(s, :update_run, [run])
  @impl true
  def get_run(s, id), do: Store.call(s, :get_run, [id])
  @impl true
  def list_runs(s, job, limit), do: Store.call(s, :list_runs, [job, limit])
  @impl true
  def last_run(s, job), do: Store.call(s, :last_run, [job])
  @impl true
  def running_runs(s), do: Store.call(s, :running_runs, [])
  @impl true
  def get_state(s, job), do: Store.call(s, :get_state, [job])
  @impl true
  def set_state(s, state), do: Store.call(s, :set_state, [state])
  @impl true
  def prune(s, before), do: Store.call(s, :prune, [before])
  @impl true
  def close(_s), do: :ok

  @impl true
  def update_run_if(s, run, from) do
    if Store.has?(s, :update_run_if, 2) do
      Store.call(s, :update_run_if, [run, from])
    else
      with {:ok, stored} <- Store.call(s, :get_run, [run.id]) do
        if stored && stored.status in from,
          do: with(:ok <- Store.call(s, :update_run, [run]), do: {:ok, true}),
          else: {:ok, false}
      end
    end
  end

  @impl true
  def compare_and_set_state(s, state, expected) do
    if Store.has?(s, :compare_and_set_state, 2) do
      Store.call(s, :compare_and_set_state, [state, expected])
    else
      with :ok <- Store.call(s, :set_state, [state]), do: {:ok, true}
    end
  end

  @impl true
  def delete_run_if(s, id, job, status) do
    if Store.has?(s, :delete_run_if, 3),
      do: Store.call(s, :delete_run_if, [id, job, status]),
      else: {:ok, false}
  end
end
