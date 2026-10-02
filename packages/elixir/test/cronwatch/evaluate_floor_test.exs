defmodule Cronwatch.EvaluateFloorTest do
  @moduledoc "The floors case of the SDK's evaluate.test.ts, ported."
  use ExUnit.Case, async: true

  alias Cronwatch.Evaluate
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Test.Clock

  @t0 Clock.t0()
  @hour 3_600_000

  defp run(status, at, metrics) do
    %Run{
      id: "r#{at}",
      job: "j",
      status: status,
      started_at: at,
      finished_at: at + 1000,
      duration_ms: 1000,
      metrics: Object.new(metrics)
    }
  end

  defp finish(def, run, state, history, now) do
    {:ok, {state, alerts}} = Evaluate.on_run_finish(JS.parse!(def), run, state, history, now)
    {state, alerts}
  end

  defp types(alerts), do: Enum.map(alerts, &elem(&1, 0))

  test "floors: a floor, or 0 after five runs that all reported more" do
    floored = ~s({"name":"j","floor":{"rows":10}})
    empty = Evaluate.empty_state("j")

    {short, alerts} = finish(floored, run("ok", @t0, [{"rows", 9}]), empty, [], @t0 + 1000)
    assert types(alerts) == ["under_floor"]
    assert [{_, _, %{breaches: [%{metric: "rows", value: 9, limit: 10, basis: "floor"}]}}] = alerts
    {back, alerts} = finish(floored, run("ok", @t0 + @hour, [{"rows", 10}]), short, [], @t0 + @hour + 1000)
    assert types(alerts) == ["recovered"]
    assert back.under_floor == nil

    bare = ~s({"name":"j"})
    history = for i <- 1..5, do: run("ok", @t0 - i * @hour, [{"rows", 100 * i}, {"errors", 0}])
    four = tl(history)
    assert {_, []} = finish(bare, run("ok", @t0, [{"rows", 0}]), empty, four, @t0), "four runs are not a baseline"

    assert {_, []} = finish(bare, run("ok", @t0, [{"rows", 1}, {"errors", 0}]), empty, history, @t0),
           "an always-0 metric never alerts"

    {zero, alerts} = finish(bare, run("ok", @t0, [{"rows", 0}, {"errors", 0}]), empty, history, @t0)

    assert [
             {"under_floor", _,
              %{
                breaches: [
                  %{
                    metric: "rows",
                    value: 0,
                    limit: 100,
                    basis: "the last 5 runs all reported more than 0, the lowest 100"
                  }
                ]
              }}
           ] = alerts

    assert zero.under_floor == ["rows"]

    # A job that keeps writing nothing stays open, past the point where its
    # zeros are all the history there is.
    {state, runs} =
      Enum.reduce(1..30, {zero, history}, fn i, {state, runs} ->
        runs = [run("ok", @t0 + (i - 1) * @hour, [{"rows", 0}, {"errors", 0}]) | runs]
        now = @t0 + i * @hour
        {next, alerts} = finish(bare, run("ok", now, [{"rows", 0}, {"errors", 0}]), state, Enum.take(runs, 25), now)
        assert alerts == []
        assert Cronwatch.JobState.open_at(next, "under_floor") == @t0
        {next, runs}
      end)

    now = @t0 + 31 * @hour
    {_, alerts} = finish(bare, run("ok", now, [{"rows", 5}, {"errors", 0}]), state, Enum.take(runs, 25), now)
    assert [{"recovered", _, %{after: ["under_floor"]}}] = alerts

    # A metric that has reported 0 before is judged as usual for it, and a
    # floor of 0 turns the check off.
    mixed = Enum.take(history, 4) ++ [run("ok", @t0 - 6 * @hour, [{"rows", 0}])]
    assert {_, []} = finish(bare, run("ok", @t0, [{"rows", 0}]), empty, mixed, @t0)
    assert {_, []} = finish(~s({"name":"j","floor":{"rows":0}}), run("ok", @t0, [{"rows", 0}]), empty, history, @t0)
  end
end
