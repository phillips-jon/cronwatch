defmodule Cronwatch.ScheduleConformanceTest do
  # Replays conformance/duration.json and conformance/schedule.json, the cases
  # scripts/conformance.mjs writes by running the TypeScript SDK (in UTC),
  # comparing every answer as the JSON the SDK writes, byte for byte.
  use ExUnit.Case, async: true

  import Cronwatch.Test.Conformance

  alias Cronwatch.Duration
  alias Cronwatch.JS.Object
  alias Cronwatch.Schedule

  # A number that may travel as {"special": "NaN"}.
  defp number(%Object{} = o) do
    case Object.get(o, "special") do
      "NaN" -> :nan
      "Infinity" -> :infinity
      "-Infinity" -> :neg_infinity
    end
  end

  defp number(n), do: n

  defp known!(f, sections) do
    for key <- Object.keys(f), key not in ["generatedBy", "sdkVersion"] do
      assert key in sections, "the fixture has a section this port does not replay: #{key}"
    end
  end

  test "duration.json" do
    f = fixture("duration")
    known!(f, ["parse", "format", "relative"])

    failures =
      Enum.reduce(list(f, "parse"), failures(), fn c, acc ->
        input = field(c, "input")
        label = field(c, "label") || ""
        got = Object.new([{"input", input}])
        got = if Object.has_key?(c, "label"), do: Object.put(got, "label", label), else: got

        got =
          case Duration.parse(number(input), label) do
            {:ok, ms} -> Object.put(got, "ms", ms)
            {:error, e} -> Object.put(got, "error", e)
          end

        same(acc, "parse #{inspect(input)}", got, c)
      end)

    failures =
      Enum.reduce(list(f, "format"), failures, fn c, acc ->
        got = Object.new([{"ms", field(c, "ms")}, {"text", Duration.format(number(field(c, "ms")))}])
        same(acc, "format", got, c)
      end)

    failures =
      Enum.reduce(list(f, "relative"), failures, fn c, acc ->
        got =
          Object.new([
            {"at", field(c, "at")},
            {"now", field(c, "now")},
            {"text", Duration.relative(field(c, "at"), field(c, "now"))}
          ])

        same(acc, "relative", got, c)
      end)

    check!(failures, "duration")
    assert length(list(f, "parse")) + length(list(f, "format")) + length(list(f, "relative")) == 103
  end

  test "schedule.json" do
    f = fixture("schedule")
    known!(f, ["parse", "fires", "nextFire", "expectation", "runCovers", "autumn"])

    failures =
      Enum.reduce(list(f, "parse"), failures(), fn c, acc ->
        got = Object.new([{"schedule", field(c, "schedule")}])
        got = if Object.has_key?(c, "timezone"), do: Object.put(got, "timezone", field(c, "timezone")), else: got

        got =
          case Schedule.parse(field(c, "schedule"), field(c, "timezone")) do
            {:ok, p} -> Object.put(got, "parsed", Schedule.to_value(p))
            {:error, e} -> Object.put(got, "error", e)
          end

        same(acc, "parse", got, c)
      end)

    failures =
      Enum.reduce(list(f, "fires"), failures, fn c, acc ->
        {:ok, p} = Schedule.parse(field(c, "schedule"), field(c, "timezone"))
        want = field(c, "fires")

        {out, _} =
          Enum.reduce_while(want, {[], field(c, "from")}, fn _, {out, at} ->
            case Schedule.next_fire(p, at, nil) do
              nil -> {:halt, {out ++ [nil], at}}
              next -> {:cont, {out ++ [next], next}}
            end
          end)

        same(acc, "fires of #{field(c, "schedule")} in #{field(c, "timezone")}", out, want)
      end)

    failures =
      Enum.reduce(list(f, "nextFire"), failures, fn c, acc ->
        {:ok, p} = Schedule.parse(field(c, "schedule"), nil)
        got = Schedule.next_fire(p, field(c, "from"), field(c, "lastRunAt"))
        same(acc, "nextFire", got, field(c, "expected"))
      end)

    failures =
      Enum.reduce(list(f, "expectation"), failures, fn c, acc ->
        {:ok, p} = Schedule.parse(field(c, "schedule"), field(c, "timezone"))

        got =
          case Schedule.expectation(p, field(c, "lastRunAt"), field(c, "registeredAt"), number(field(c, "graceMs"))) do
            nil -> nil
            e -> Object.new([{"dueAt", e.due_at}, {"deadline", e.deadline}])
          end

        what = "expectation of #{field(c, "schedule")} in #{field(c, "timezone")} after #{field(c, "lastRunAt")}"
        same(acc, what, got, field(c, "expected"))
      end)

    failures =
      Enum.reduce(list(f, "runCovers"), failures, fn c, acc ->
        got = Schedule.run_covers(field(c, "startedAt"), field(c, "dueAt"), field(c, "followingAt"))
        same(acc, "runCovers", got, field(c, "expected"))
      end)

    failures =
      Enum.reduce(list(f, "autumn"), failures, fn c, acc ->
        {:ok, p} = Schedule.parse(field(c, "schedule"), field(c, "timezone"))
        from = field(c, "from")
        step = field(c, "stepMs")

        out =
          from
          |> Stream.iterate(&(&1 + step))
          |> Enum.take_while(&(&1 < from + 8 * 3_600_000))
          |> Enum.map(&Schedule.next_fire(p, &1, nil))

        same(acc, "autumn #{field(c, "schedule")} in #{field(c, "timezone")}", out, field(c, "next"))
      end)

    check!(failures, "schedule")

    count = Enum.sum(for s <- ~w(parse fires nextFire expectation runCovers autumn), do: length(list(f, s)))
    assert count == 723
  end
end
