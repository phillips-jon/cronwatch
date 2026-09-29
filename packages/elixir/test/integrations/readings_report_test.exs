defmodule Cronwatch.ReadingsReportTest do
  # A report, not a gate: generated cron expressions read by Oban's parser
  # and by the crontab package (Quantum's), each checked against CronWatch's
  # reading (the croner port) as the integrations check a schedule, and how
  # many the two read alike printed. It keeps measured why CronWatch ports
  # croner rather than depending on either (see DESIGN.md, Keeping in step),
  # as the Rust port's report on the croner crate does. Seeded, so the
  # numbers repeat.
  use ExUnit.Case, async: true

  import Bitwise

  alias Crontab.CronExpression.Parser
  alias Cronwatch.JS

  @mask 0xFFFFFFFFFFFFFFFF
  @zones ["Etc/UTC", "America/New_York", "Europe/London", "Australia/Lord_Howe"]
  @count 40

  defp next do
    s = Process.get(:readings) + 0x9E3779B97F4A7C15 &&& @mask
    Process.put(:readings, s)
    z = bxor(s, s >>> 30) * 0xBF58476D1CE4E5B9 &&& @mask
    z = bxor(z, z >>> 27) * 0x94D049BB133111EB &&& @mask
    bxor(z, z >>> 31)
  end

  defp chance, do: (next() >>> 11) / (1 <<< 53)
  defp between(lo, hi), do: lo + rem(next(), hi - lo + 1)

  # A field in the grammar both parsers share: *, a value, a range, a step
  # or a list of values.
  defp field(low, high) do
    kind = chance()

    cond do
      kind < 0.35 ->
        "*"

      kind < 0.6 ->
        "#{between(low, high)}"

      kind < 0.75 ->
        a = between(low, high)
        "#{a}-#{between(a, high)}"

      kind < 0.9 ->
        "*/#{between(2, max(2, div(high - low + 1, 2)))}"

      true ->
        Enum.map_join(Enum.uniq(for(_ <- 1..between(2, 3), do: between(low, high))), ",", &Integer.to_string/1)
    end
  end

  defp expression do
    Enum.join([field(0, 59), field(0, 23), field(1, 28), field(1, 12), field(0, 6)], " ")
  end

  test "Oban's and the crontab package's readings against CronWatch's" do
    Process.put(:readings, 20_260_929)
    now = JS.date_utc(2026, 8, 1)

    results =
      for n <- 1..@count do
        expr = expression()
        zone = Enum.at(@zones, rem(n, length(@zones)))
        oban = Cronwatch.Oban.convert(expr, zone, "x", now)

        quantum =
          case Parser.parse(expr) do
            {:ok, parsed} -> Cronwatch.Quantum.convert(parsed, zone, "x", now)
            {:error, why} -> {:error, why}
          end

        both = match?([_, _, day, _, dow] when day != "*" and dow != "*", String.split(expr))
        {elem(oban, 0), elem(quantum, 0), both}
      end

    oban = Enum.count(results, &(elem(&1, 0) == :ok))
    quantum = Enum.count(results, &(elem(&1, 1) == :ok))
    both = Enum.count(results, &(elem(&1, 2) and elem(&1, 0) != :ok))

    IO.puts(
      "readings report: of #{@count} expressions, Oban runs #{oban} as CronWatch expects and the crontab package " <>
        "(Quantum) #{quantum}; #{both} of Oban's others name a day of the month and a day of the week both. " <>
        "The rest are read differently and would be watched without a schedule"
    )

    assert oban + quantum > 0
  end
end
