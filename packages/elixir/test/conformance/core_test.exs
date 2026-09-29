defmodule Cronwatch.Conformance.CoreTest do
  @moduledoc """
  Replays the core's fixtures: format.json's alerts and numbers,
  health.json and evaluate.json, each case compared as the JSON the SDK
  writes, byte for byte.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Conformance

  alias Cronwatch.Alert
  alias Cronwatch.Duration
  alias Cronwatch.Evaluate
  alias Cronwatch.Format
  alias Cronwatch.JobState
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Metrics
  alias Cronwatch.Run
  alias Cronwatch.Stats
  alias Cronwatch.StoredJob

  defp run(nil), do: nil

  defp run(v) do
    {:ok, r} = Run.from_value(v)
    r
  end

  defp runs(list), do: Enum.map(list || [], &run/1)

  defp state(v) do
    {:ok, s} = JobState.from_value(v)
    s
  end

  defp stored(o) do
    %StoredJob{
      name: field(o, "name"),
      definition: field(o, "definition"),
      created_at: field(o, "createdAt"),
      updated_at: field(o, "updatedAt")
    }
  end

  # An alert draft from a fixture, {type, run, details}.
  defp draft(o) do
    type = field(o, "type")
    {type, run(field(o, "run")), Alert.details_from(type, field(o, "details") || Object.new())}
  end

  defp draft_value({type, run, details}) do
    %Object{
      pairs: [
        {"type", type},
        {"run", if(run, do: Run.to_value(run))},
        {"details", Alert.details_value(type, details)}
      ]
    }
  end

  defp result({:ok, v}, fun), do: fun.(v)
  defp result({:error, e}, _fun), do: "error: " <> e

  test "format.json: alerts and numbers" do
    f = fixture("format")
    alerts = list(f, "alerts")
    numbers = list(f, "numbers")
    assert alerts != [] and numbers != []

    fails =
      alerts
      |> Enum.with_index()
      |> Enum.reduce(failures(), fn {c, i}, acc ->
        got = Format.compose_alert(draft(field(c, "draft")), field(c, "definition"), field(c, "now"))
        same(acc, "alert #{i}", Alert.to_value(got), field(c, "alert"))
      end)

    fails =
      Enum.reduce(numbers, fails, fn c, acc ->
        n = field(c, "n")
        same(acc, "formatNumber(#{JS.format_number(n)})", Format.format_number(n), field(c, "text"))
      end)

    check!(fails, "format")
  end

  test "health.json" do
    f = fixture("health")

    fails =
      f
      |> list("jobHealth")
      |> Enum.with_index()
      |> Enum.reduce(failures(), fn {c, i}, acc ->
        got =
          Evaluate.job_health(
            field(c, "definition"),
            run(field(c, "lastRun")),
            state(field(c, "state")),
            field(c, "now")
          )

        same(acc, "jobHealth #{i}", result(got, & &1), field(c, "health"))
      end)

    fails =
      f
      |> list("summarize")
      |> Enum.with_index()
      |> Enum.reduce(fails, fn {c, i}, acc ->
        got =
          Evaluate.summarize(
            stored(field(c, "stored")),
            runs(field(c, "recent")),
            state(field(c, "state")),
            field(c, "nextExpectedAt"),
            field(c, "now")
          )

        same(acc, "summarize #{i}", result(got, &Cronwatch.JobSummary.to_value/1), field(c, "summary"))
      end)

    fails =
      Enum.reduce(list(f, "percentile"), fails, fn c, acc ->
        values = field(c, "values")
        got = Stats.percentile(values, field(c, "p"))
        same(acc, "percentile(#{JS.stringify(values)}, #{field(c, "p")})", got, field(c, "percentile"))
      end)

    fails =
      Enum.reduce(list(f, "median"), fails, fn c, acc ->
        values = field(c, "values")
        same(acc, "median(#{JS.stringify(values)})", Stats.median(values), field(c, "median"))
      end)

    fails =
      f
      |> list("normalizeState")
      |> Enum.with_index()
      |> Enum.reduce(fails, fn {c, i}, acc ->
        input = if field(c, "state"), do: state(field(c, "state"))
        got = Evaluate.normalize_state(input, "j")
        same(acc, "normalizeState #{i}", JobState.to_value(got), field(c, "normalized"))
      end)

    fails =
      f
      |> list("muteOpens")
      |> Enum.with_index()
      |> Enum.reduce(fails, fn {c, i}, acc ->
        got = Evaluate.mute_opens(state(field(c, "previous")), state(field(c, "next")))
        same(acc, "muteOpens #{i}", JobState.to_value(got), field(c, "muted"))
      end)

    fails =
      f
      |> list("isStuck")
      |> Enum.with_index()
      |> Enum.reduce(fails, fn {c, i}, acc ->
        got = Evaluate.stuck?(field(c, "definition"), run(field(c, "run")), field(c, "now"))
        same(acc, "isStuck #{i}", result(got, & &1), field(c, "stuck"))
      end)

    fails =
      f
      |> list("unevaluableSummary")
      |> Enum.with_index()
      |> Enum.reduce(fails, fn {c, i}, acc ->
        got =
          Evaluate.unevaluable_summary(
            stored(field(c, "stored")),
            runs(field(c, "recent")),
            state(field(c, "state")),
            field(c, "now")
          )

        same(acc, "unevaluableSummary #{i}", Cronwatch.JobSummary.to_value(got), field(c, "summary"))
      end)

    fails =
      f
      |> list("applySilence")
      |> Enum.with_index()
      |> Enum.reduce(fails, fn {c, i}, acc ->
        e = field(c, "evaluation")
        input = {state(field(e, "state")), Enum.map(list(e, "alerts"), &draft/1)}
        {s, alerts} = Evaluate.apply_silence(state(field(c, "previous")), input, field(c, "now"))
        got = %Object{pairs: [{"state", JobState.to_value(s)}, {"alerts", Enum.map(alerts, &draft_value/1)}]}
        same(acc, "applySilence #{i}", got, field(c, "result"))
      end)

    fails =
      f
      |> list("staleAlert")
      |> Enum.with_index()
      |> Enum.reduce(fails, fn {c, i}, acc ->
        {:ok, alert} = Alert.from_value(field(c, "alert"))
        same(acc, "staleAlert #{i}", Evaluate.stale_alert?(alert, state(field(c, "state"))), field(c, "stale"))
      end)

    fails =
      f
      |> list("runDuration")
      |> Enum.with_index()
      |> Enum.reduce(fails, fn {c, i}, acc ->
        got = Evaluate.run_duration(field(c, "startedAt"), field(c, "finishedAt"))
        same(acc, "runDuration #{i}", got, field(c, "durationMs"))
      end)

    fails =
      f
      |> list("stateVersion")
      |> Enum.with_index()
      |> Enum.reduce(fails, fn {c, i}, acc ->
        {:ok, s} = JobState.from_json(field(c, "state"))
        same(acc, "stateVersion #{i}", JobState.version_or_zero(s), field(c, "version"))
      end)

    assert length(list(f, "runDuration")) >= 8 and length(list(f, "stateVersion")) >= 17
    check!(fails, "health")
  end

  # scripts/conformance.mjs's Sim: one job, its runs (each with the order it
  # was started in, which breaks ties) and its state.
  defmodule Sim do
    @moduledoc false
    defstruct [:def, :stored, :state, runs: []]
  end

  defp sorted(%Sim{runs: runs}) do
    runs
    |> Enum.sort(fn {a, sa}, {b, sb} -> {b.started_at, sb} <= {a.started_at, sa} end)
    |> Enum.map(&elem(&1, 0))
  end

  # Saves an evaluation as the client does (silence applied) and returns its
  # alerts as the SDK writes them.
  defp settle(sim, previous, evaluation, now) do
    {s, drafts} = Evaluate.apply_silence(previous, evaluation, now)
    {%{sim | state: s}, Enum.map(drafts, &Alert.to_value(Format.compose_alert(&1, sim.def, now)))}
  end

  defp finish_run(sim, run, now) do
    history = sim |> sorted() |> Enum.reject(&(&1.id == run.id))
    previous = sim.state
    {:ok, e} = Evaluate.on_run_finish(sim.def, run, previous, history, now)
    settle(sim, previous, e, now)
  end

  defp put_run(sim, run) do
    %{sim | runs: Enum.map(sim.runs, fn {r, o} -> if r.id == run.id, do: {run, o}, else: {r, o} end)}
  end

  defp state_only(sim), do: %Object{pairs: [{"state", JobState.to_value(sim.state)}]}

  defp play(sim, ev) do
    at = field(ev, "at")

    case field(ev, "op") do
      "start" ->
        run = %Run{id: field(ev, "id"), job: Object.get(sim.def, "name"), status: "running", started_at: at}
        sim = %{sim | runs: sim.runs ++ [{run, length(sim.runs)}], state: Evaluate.on_run_start(sim.state)}
        {sim, state_only(sim)}

      "finish" ->
        {run, _} = Enum.find(sim.runs, fn {r, _} -> r.id == field(ev, "id") end)

        if run.status in ["ok", "failed"] do
          {sim,
           %Object{
             pairs: [
               {"alerts", []},
               {"state", JobState.to_value(sim.state)},
               {"ignored", "was already finished as #{run.status}"}
             ]
           }}
        else
          marked = run.status == "timeout"
          {:ok, metrics} = Metrics.from_value(field(ev, "metrics"))

          run = %{
            run
            | finished_at: at,
              duration_ms: max(at - run.started_at, 0),
              status: field(ev, "status"),
              metrics: metrics,
              output: field(ev, "output"),
              error: field(ev, "error")
          }

          sim = put_run(sim, run)

          if marked and run.status != "ok" do
            {sim, %Object{pairs: [{"alerts", []}, {"state", JobState.to_value(sim.state)}]}}
          else
            {sim, alerts} = finish_run(sim, run, at)
            {sim, %Object{pairs: [{"alerts", alerts}, {"state", JobState.to_value(sim.state)}]}}
          end
        end

      "check" ->
        now = at

        running =
          sim.runs
          |> Enum.filter(fn {r, _} -> r.status == "running" end)
          |> Enum.sort_by(fn {r, o} -> {r.started_at, o} end)

        {sim, alerts} =
          Enum.reduce(running, {sim, []}, fn {r, _}, {sim, alerts} ->
            case Evaluate.stuck?(sim.def, r, now) do
              {:ok, true} ->
                {:ok, timeout} = Evaluate.timeout_ms(sim.def)

                r = %{
                  r
                  | status: "timeout",
                    finished_at: now,
                    duration_ms: now - r.started_at,
                    error: "Still running after #{Duration.format(timeout)}; marked as timed out"
                }

                sim = put_run(sim, r)
                {sim, more} = finish_run(sim, r, now)
                {sim, alerts ++ more}

              {:ok, false} ->
                {sim, alerts}
            end
          end)

        recent = sim |> sorted() |> Enum.take(Evaluate.baseline_window())
        previous = sim.state

        {:ok, {evaluation, next, due}} =
          Evaluate.on_check(sim.def, sim.stored, List.first(recent), previous, now)

        {sim, more} = settle(sim, previous, evaluation, now)
        {:ok, summary} = Evaluate.summarize(sim.stored, recent, sim.state, next, now)

        {sim,
         %Object{
           pairs: [
             {"alerts", alerts ++ more},
             {"state", JobState.to_value(sim.state)},
             {"nextExpectedAt", next},
             {"dueAt", due},
             {"summary", Cronwatch.JobSummary.to_value(summary)}
           ]
         }}

      "silence" ->
        sim = %{sim | state: %{sim.state | silenced_until: field(ev, "until")}}
        {sim, state_only(sim)}

      "unsilence" ->
        sim = %{sim | state: %{sim.state | silenced_until: nil}}
        {sim, state_only(sim)}

      "define" ->
        definition = field(ev, "definition")
        {%{sim | def: definition, stored: %{sim.stored | definition: definition}}, nil}
    end
  end

  test "evaluate.json" do
    scenarios = list(fixture("evaluate"), "scenarios")
    assert scenarios != []

    fails =
      Enum.reduce(scenarios, failures(), fn sc, acc ->
        definition = field(sc, "definition")
        created_at = field(sc, "createdAt")
        name = Object.get(definition, "name")

        sim = %Sim{
          def: definition,
          stored: %StoredJob{name: name, definition: definition, created_at: created_at, updated_at: created_at},
          state: Evaluate.empty_state(name)
        }

        {_, acc} =
          sc
          |> list("events")
          |> Enum.with_index()
          |> Enum.reduce({sim, acc}, fn {ev, i}, {sim, acc} ->
            {sim, got} = play(sim, ev)
            what = "#{field(sc, "name")}: event #{i} (#{field(ev, "op")})"
            if got, do: {sim, same(acc, what, got, field(ev, "expect"))}, else: {sim, acc}
          end)

        acc
      end)

    check!(fails, "evaluate")
  end
end
