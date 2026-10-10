defmodule Cronwatch.CronerParityTest do
  # The croner port against croner itself: thousands of generated cron
  # expressions (valid and not, nicknames, names, ranges, steps, lists, L, W,
  # LW, #, ?, +, six and seven fields, in zones with and without daylight
  # saving, from times around the clock changes) answered by the SDK in Node
  # (test/testdata/schedule_fuzz.mjs, which imports packages/sdk/dist) and by
  # this port, which must agree on every error message and every fire time.
  # Seeded, so a failure repeats; the generator is the Go, Python, PHP, and
  # Rust ports', over the same SplitMix64, so all of them see the same cases.
  use ExUnit.Case, async: true

  import Bitwise

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Schedule

  @moduletag timeout: 600_000

  @mask 0xFFFFFFFFFFFFFFFF
  @zones ["", "UTC", "America/New_York", "Europe/London", "Australia/Lord_Howe", "America/Santiago"] ++
           ["Asia/Kolkata", "Pacific/Chatham", "Europe/Berlin"]
  @months ~w(jan FEB Mar apr may jun jul aug sep oct nov dec)
  @days ~w(sun MON Tue wed thu fri sat)
  @nicknames ~w(@yearly @annually @monthly @weekly @daily @midnight @hourly @HOURLY @reboot @every)

  @helper Path.expand("../testdata/schedule_fuzz.mjs", __DIR__)
  @dist Path.expand("../../../sdk/dist/index.js", __DIR__)

  # SplitMix64: small, seeded, and the same on every platform. The state is
  # kept in the process dictionary, as the generator is a sequence of draws.
  defp next do
    s = Process.get(:fuzz) + 0x9E3779B97F4A7C15 &&& @mask
    Process.put(:fuzz, s)
    z = bxor(s, s >>> 30) * 0xBF58476D1CE4E5B9 &&& @mask
    z = bxor(z, z >>> 27) * 0x94D049BB133111EB &&& @mask
    bxor(z, z >>> 31)
  end

  defp chance, do: (next() >>> 11) / (1 <<< 53)
  defp between(lo, hi), do: lo + rem(next(), hi - lo + 1)
  defp pick(items), do: Enum.at(items, rem(next(), length(items)))

  # One cron field: mostly valid, sometimes out of range or malformed.
  defp field(low, high, names) do
    size = high - low + 1
    kind = chance()

    cond do
      kind < 0.3 ->
        "*"

      kind < 0.45 ->
        value(low, high, names)

      kind < 0.6 ->
        {a, b} = pair(low, high)
        {a, b} = if chance() < 0.05, do: {b + 1, a}, else: {a, b}
        "#{a}-#{b}"

      kind < 0.75 ->
        "*/#{pick([1, 2, 3, 5, 7, 10, 15, 30, size, size + 1, 0])}"

      kind < 0.85 ->
        {a, b} = pair(low, high)
        step = between(1, max(div(size, 2), 1))
        "#{a}-#{b}/#{step}"

      kind < 0.97 ->
        n = between(2, 4)
        Enum.map_join(1..n, ",", fn _ -> value(low, high, names) end)

      true ->
        pick(["?", "x", "", "5/15", "/5", "1-", "-1"])
    end
  end

  defp value(low, high, names) do
    cond do
      names != [] and chance() < 0.3 -> pick(names)
      chance() < 0.05 -> Integer.to_string(pick([high + 1, low - 1, 99]))
      true -> Integer.to_string(between(low, high))
    end
  end

  defp pair(low, high) do
    a = between(low, high)
    b = between(low, high)
    if a > b, do: {b, a}, else: {a, b}
  end

  defp day_of_month do
    kind = chance()

    cond do
      kind < 0.1 -> pick(["L", "LW", "15W", "1W", "31W", "5L", "L,15"])
      kind < 0.2 -> "?"
      true -> field(1, 31, [])
    end
  end

  defp day_of_week do
    kind = chance()

    cond do
      kind < 0.1 ->
        a = between(0, 7)
        b = between(0, 6)
        "#{a}##{b}"

      kind < 0.18 ->
        "#{between(0, 6)}L"

      kind < 0.24 ->
        "+" <> field(0, 7, @days)

      kind < 0.3 ->
        a = pick(@days)
        b = pick(@days)
        "#{a}-#{b}"

      true ->
        field(0, 7, @days)
    end
  end

  defp expression do
    if chance() < 0.05 do
      pick(@nicknames)
    else
      minute = field(0, 59, [])
      hour = field(0, 23, [])
      dom = day_of_month()
      month = field(1, 12, @months)
      dow = day_of_week()
      parts = [minute, hour, dom, month, dow]
      parts = if chance() < 0.25, do: [field(0, 59, []) | parts], else: parts
      parts = if chance() < 0.02, do: parts ++ ["*"], else: parts
      Enum.join(parts, " ")
    end
  end

  defp cases(seed, count) do
    Process.put(:fuzz, seed)

    # Around the nights clocks change in the zones above, and ordinary days.
    starts = [
      JS.date_utc(2026, 2, 8, 6, 30, 0, 0),
      JS.date_utc(2026, 10, 1, 5, 10, 0, 0),
      JS.date_utc(2026, 2, 29, 0, 45, 0, 0),
      JS.date_utc(2026, 9, 25, 0, 50, 0, 0),
      JS.date_utc(2026, 9, 3, 15, 20, 0, 0),
      JS.date_utc(2026, 3, 4, 14, 55, 0, 0),
      JS.date_utc(2026, 0, 5, 9, 30, 0, 0),
      JS.date_utc(2027, 1, 27, 23, 59, 59, 0),
      JS.date_utc(2028, 1, 28, 12, 0, 0, 0)
    ]

    for _ <- 1..count do
      base = pick(starts)
      hours = between(-3, 3) * 3_600_000
      seconds = between(0, 3_599) * 1000
      millis = pick([0, 0, 500, 999])
      from = base + hours + seconds + millis
      schedule = expression()
      n = between(1, 6)
      timezone = pick(@zones)
      %{schedule: schedule, timezone: timezone, from: from, count: n}
    end
  end

  # This port's answer, as the helper writes the SDK's: {error} or {fires}.
  defp answer(c) do
    case Schedule.parse(c.schedule, c.timezone) do
      {:error, e} ->
        Object.new([{"error", e}])

      {:ok, p} ->
        {fires, _} =
          Enum.reduce_while(1..c.count, {[], c.from}, fn _, {fires, at} ->
            case Schedule.next_fire(p, at, nil) do
              nil -> {:halt, {fires ++ [nil], at}}
              next -> {:cont, {fires ++ [next], next}}
            end
          end)

        Object.new([{"fires", fires}])
    end
  end

  defp show(a) do
    case Object.fetch(a, "error") do
      {:ok, e} ->
        "error #{e}"

      :error ->
        fires = Object.get(a, "fires", [])
        "[" <> Enum.map_join(fires, " ", &if(&1 == nil, do: "null", else: JS.iso_string(&1))) <> "]"
    end
  end

  defp node? do
    System.find_executable("node") != nil
  end

  test "the port agrees with croner" do
    cond do
      not File.exists?(@dist) ->
        IO.puts("croner parity: skipped, packages/sdk/dist is not built (npm run build --workspace packages/sdk)")

      not node?() ->
        IO.puts("croner parity: skipped, node is not installed")

      true ->
        for seed <- [1, 2, 3], do: check_seed(seed)
    end
  end

  defp check_seed(seed) do
    generated = cases(seed, 1000)

    input =
      Enum.map(generated, fn c ->
        zone = if c.timezone == "", do: nil, else: c.timezone
        Object.new([{"schedule", c.schedule}, {"timezone", zone}, {"from", c.from}, {"count", c.count}])
      end)

    file = Path.join(System.tmp_dir!(), "cronwatch-elixir-schedule-fuzz-#{System.unique_integer([:positive])}.json")
    File.write!(file, JS.stringify(input))
    {out, status} = System.cmd("node", [@helper, file], env: [{"TZ", "UTC"}], stderr_to_stdout: true)
    File.rm(file)
    assert status == 0, "node: #{out}"
    expected = JS.parse!(out)

    {differences, valid, refused, threw} =
      generated
      |> Enum.zip(expected)
      |> Enum.reduce({[], 0, 0, 0}, fn {c, want}, {diffs, valid, refused, threw} ->
        got = answer(c)
        {valid, refused} = if Object.has_key?(want, "error"), do: {valid, refused + 1}, else: {valid + 1, refused}

        case Object.fetch(want, "throws") do
          {:ok, throws} ->
            # croner walks by recursion, a year at a time, so a date no month
            # has (February 30) runs out of stack before the year 3000. The
            # port walks in a loop and finds nothing: it never fires.
            prefix = Object.get(want, "fires", []) ++ [nil]
            fires = Object.get(got, "fires", [])

            if Enum.take(fires, length(prefix)) == prefix do
              {diffs, valid, refused, threw + 1}
            else
              diff =
                "#{c.schedule} in #{inspect(c.timezone)} from #{c.from}\n    croner threw #{throws} after #{show(want)}\n    elixir #{show(got)}"

              {[diff | diffs], valid, refused, threw + 1}
            end

          :error ->
            if JS.stringify(want) == JS.stringify(got) do
              {diffs, valid, refused, threw}
            else
              diff =
                "#{c.schedule} in #{inspect(c.timezone)} from #{c.from}\n    croner #{show(want)}\n    elixir #{show(got)}"

              {[diff | diffs], valid, refused, threw}
            end
        end
      end)

    differences = Enum.sort(differences)

    assert differences == [],
           "seed #{seed}: #{length(differences)} of #{length(generated)} differ:\n" <>
             Enum.join(Enum.take(differences, 10), "\n")

    assert valid >= 300, "seed #{seed}: only #{valid} generated expressions were valid"

    IO.puts(
      "croner parity, seed #{seed}: #{length(generated)} cases: #{valid} valid (#{threw} where croner ran out of stack), " <>
        "#{refused} refused with croner's message"
    )
  end
end
