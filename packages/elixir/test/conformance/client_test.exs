defmodule Cronwatch.Conformance.ClientTest do
  @moduledoc """
  Replays `conformance/client.json` through the client's public API:
  `runIds`, the run ids `start/2`, `resume/2` and `record_run/2` take, and
  `unknownFields`, what a newer release wrote (a definition or state key, a
  run status, a trigger, an open condition this release does not know)
  surviving a check, a silence, an unsilence, a summary and a run, over the
  memory store and the SQL store on SQLite, and on Postgres, MySQL and
  MariaDB when their variables are set.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Conformance, only: [field: 2, list: 2]

  alias Cronwatch.Alert
  alias Cronwatch.JobState
  alias Cronwatch.JobSummary
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Store
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Conformance
  alias Cronwatch.Test.Repo
  alias Cronwatch.Test.Servers

  @t0 Clock.t0()

  defp start(opts) do
    name = :"cw#{System.unique_integer([:positive])}"
    clock = Clock.new()
    alerts = Capture.new()
    {:ok, errors} = Agent.start_link(fn -> [] end)

    base = [
      name: name,
      clock: Clock.fun(clock),
      alerts: [Capture.channel(alerts)],
      cron_secret: false,
      on_error: fn e, where -> Agent.update(errors, &(&1 ++ ["#{where}: #{message(e)}"])) end
    ]

    start_supervised!({Cronwatch, Keyword.merge(base, opts)}, id: name)
    %{cw: name, clock: clock, alerts: alerts, errors: errors}
  end

  defp message(%{__exception__: true} = e), do: Exception.message(e)
  defp message(e), do: inspect(e)

  test "conformance/client.json: run ids" do
    cases = list(Conformance.fixture("client"), "runIds")

    failures =
      Enum.flat_map(cases, fn c ->
        k = start([])
        job = Cronwatch.job!("j", instance: k.cw)
        Clock.set(k.clock, @t0)
        id = field(c, "id")

        got =
          case field(c, "method") do
            "start" ->
              with {:ok, handle} <- Cronwatch.start(job, id: id), do: Cronwatch.finish(handle)

            "resume" ->
              Cronwatch.resume(job, id)

            "recordRun" ->
              run = %Run{
                id: id,
                job: "j",
                status: "ok",
                started_at: @t0 - 1000,
                finished_at: @t0,
                duration_ms: 1000,
                metrics: %Object{},
                trigger: "run"
              }

              Cronwatch.record_run(run, instance: k.cw)
          end

        want =
          case field(c, "error") do
            nil -> :ok
            "recordRun:" <> rest -> {:error, "record_run:" <> rest}
            error -> {:error, error}
          end

        got =
          case got do
            {:error, e} -> {:error, Exception.message(e)}
            _ -> :ok
          end

        if got == want,
          do: [],
          else: ["#{field(c, "method")}(#{JS.len16(id)} units): #{inspect(got)}, want #{inspect(want)}"]
      end)

    assert failures == [], "client.json runIds: #{length(failures)} cases differ:\n" <> Enum.join(failures, "\n")
    assert length(cases) == 36
  end

  test "conformance/client.json: unknown stored fields are kept, over the memory store" do
    replay([])
  end

  test "conformance/client.json: unknown stored fields are kept, over SQLite" do
    pid = Repo.start(Path.join(Repo.tmp_dir(), "client.db"))
    replay(store: {Cronwatch.Store.Ecto, repo: Repo, dynamic_repo: pid})
  end

  for kind <- [:pg, :mysql, :mariadb] do
    @tag Servers.skip_unless(kind)
    test "conformance/client.json: unknown stored fields are kept, over #{kind}" do
      kind = unquote(kind)
      prefix = Servers.prefix()
      pid = Servers.start(kind)
      Servers.drop_at_exit(kind, prefix)
      replay(store: {Cronwatch.Store.Ecto, repo: Servers.repo(kind), prefix: prefix, dynamic_repo: pid})
    end
  end

  defp replay(opts) do
    f = field(Conformance.fixture("client"), "unknownFields")
    seed = field(f, "seed")
    k = start(opts)
    store = Cronwatch.Config.get(k.cw).store
    :ok = Store.call(store, :init, [])
    :ok = Store.call(store, :upsert_job, [field(seed, "definition"), field(seed, "createdAt")])

    for v <- list(seed, "runs") do
      {:ok, run} = Run.from_value(v)
      :ok = Store.call(store, :insert_run, [run])
    end

    {:ok, state} = JobState.from_value(field(seed, "state"))
    :ok = Store.call(store, :set_state, [state])
    inst = [instance: k.cw]

    for step <- list(f, "steps") do
      op = field(step, "op")
      if at = field(step, "at"), do: Clock.set(k.clock, at)

      case op do
        "check" ->
          {:ok, _} = Cronwatch.check(inst)

        "silence" ->
          {:ok, _} = Cronwatch.silence("keep", field(step, "for"), inst)

        "unsilence" ->
          {:ok, _} = Cronwatch.unsilence("keep", inst)

        "summary" ->
          got = Cronwatch.job_summary!("keep", inst) |> JobSummary.to_value() |> open_as_set()
          assert same(got) == same(open_as_set(field(step, "summary"))), "summary"

        "declareAndRun" ->
          declared = Enum.map(field(step, "declared").pairs, fn {key, v} -> {option(key), v} end)
          job = Cronwatch.job!("keep", declared ++ inst)
          Clock.set(k.clock, field(step, "startedAt"))
          {:ok, handle} = Cronwatch.start(job, id: field(step, "id"))
          Clock.set(k.clock, field(step, "finishedAt"))
          %Run{status: "ok"} = Cronwatch.finish(handle, field(step, "output"))
      end

      {:ok, job} = Store.call(store, :get_job, ["keep"])
      {:ok, state} = Store.call(store, :get_state, ["keep"])
      {:ok, runs} = Store.call(store, :list_runs, ["keep", 10])
      alerts = Capture.alerts(k.alerts)
      Agent.update(k.alerts, fn _ -> [] end)
      errors = Agent.get_and_update(k.errors, &{&1, []})

      got =
        Object.new([
          {"job",
           Object.new([
             {"name", job.name},
             {"definition", job.definition},
             {"createdAt", job.created_at},
             {"updatedAt", job.updated_at}
           ])},
          {"state", JobState.to_value(state)},
          {"runs", Enum.map(runs, &Run.to_value/1)},
          {"alerts", Enum.map(alerts, &Alert.to_value/1)},
          {"errors", errors}
        ])

      assert same(got) == same(field(step, "expect")), op
    end
  end

  # A job option from the fixture's declaration: the SDK's name in snake_case.
  defp option(key), do: key |> Macro.underscore() |> String.to_atom()

  # `open` follows the stored state's key order, which a store need not
  # keep: compared as a set.
  defp open_as_set(%Object{} = o), do: Object.put(o, "open", Enum.sort(Object.get(o, "open")))

  # The JSON of a value with every object's keys sorted, so two values
  # compare as JSON values rather than as text.
  defp same(v), do: v |> sorted() |> JS.stringify()

  defp sorted(%Object{pairs: pairs}),
    do: %Object{pairs: pairs |> Enum.map(fn {k, v} -> {k, sorted(v)} end) |> Enum.sort_by(&elem(&1, 0))}

  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)
  defp sorted(v), do: v
end
