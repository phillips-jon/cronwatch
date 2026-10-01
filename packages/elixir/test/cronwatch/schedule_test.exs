defmodule Cronwatch.ScheduleTest do
  # The SDK's schedule.test.ts and duration.test.ts, and what only the ports
  # have: zone names in any case, fixed offsets.
  use ExUnit.Case, async: true

  alias Cronwatch.Duration
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Schedule

  @minute 60_000
  @hour 3_600_000
  @day 86_400_000

  defp utc(y, mo, d, h, mi, s), do: JS.date_utc(y, mo, d, h, mi, s, 0)

  defp must(schedule, zone \\ nil) do
    {:ok, p} = Schedule.parse(schedule, zone)
    p
  end

  defp due(p, last_run_at, registered_at, grace) do
    %{due_at: due} = Schedule.expectation(p, last_run_at, registered_at, grace)
    due
  end

  test "parse accepts cron, nicknames and intervals" do
    for s <- ["0 2 * * *", "@hourly", "*/5 * * * *"], do: assert(must(s).kind == "cron", s)
    every = must("every 5m")
    assert every.kind == "interval"
    assert every.every_ms == 5 * @minute

    for {bad, want} <- [
          {"every 500ms", "shorter than one second"},
          {"banana", "not a cron expression"},
          {"every banana", "not a duration"}
        ] do
      {:error, err} = Schedule.parse(bad, nil)
      assert err =~ want, "#{bad}: #{err}"
    end
  end

  test "a parsed schedule is plain data" do
    assert JS.stringify(Schedule.to_value(must("0 2 * * *", "UTC"))) ==
             ~s({"kind":"cron","source":"0 2 * * *","timezone":"UTC"})

    assert JS.stringify(Schedule.to_value(must(" every 90s ", "UTC"))) ==
             ~s({"kind":"interval","source":"every 90s","everyMs":90000})
  end

  test "next fire of crons and intervals" do
    daily = must("0 2 * * *")
    assert Schedule.next_fire(daily, utc(2026, 0, 5, 9, 30, 0), nil) == utc(2026, 0, 6, 2, 0, 0)
    every = must("every 1h")
    assert Schedule.next_fire(every, 1_000, 500) == 500 + @hour
    assert Schedule.next_fire(every, 1_000, nil) == 1_000 + @hour
    # July, EDT (UTC-4): 02:00 local is 06:00Z.
    toronto = must("0 2 * * *", "America/Toronto")
    assert Schedule.next_fire(toronto, utc(2026, 6, 10, 0, 0, 0), nil) == utc(2026, 6, 10, 6, 0, 0)
  end

  test "the expectation for a cron counts forward from the last run" do
    daily = must("0 2 * * *")
    registered = utc(2026, 0, 4, 12, 0, 0)
    first = Schedule.expectation(daily, nil, registered, 10 * @minute)
    assert first.due_at == utc(2026, 0, 5, 2, 0, 0)
    assert first.deadline == utc(2026, 0, 5, 2, 10, 0)
    assert due(daily, nil, utc(2026, 0, 5, 2, 0, 0), 0) == utc(2026, 0, 5, 2, 0, 0), "a fire at registration counts"

    for {ran, want} <- [
          # ran at 02:00:05: the 6th is next
          {utc(2026, 0, 5, 2, 0, 5), utc(2026, 0, 6, 2, 0, 0)},
          # 30 seconds early still covers 02:00
          {utc(2026, 0, 5, 1, 59, 30), utc(2026, 0, 6, 2, 0, 0)},
          # two minutes early does not
          {utc(2026, 0, 5, 1, 58, 0), utc(2026, 0, 5, 2, 0, 0)}
        ] do
      assert due(daily, ran, registered, 0) == want, "ran #{JS.iso_string(ran)}"
    end
  end

  test "one run of an every-minute cron covers one fire" do
    minutely = must("* * * * *")
    t0 = utc(2026, 0, 5, 9, 0, 0)
    assert due(minutely, t0, t0 - @hour, 0) == t0 + @minute, "a run on 09:00 covers 09:00 only"
    assert due(minutely, t0 + 50_000, t0 - @hour, 0) == t0 + 2 * @minute, "a run at 09:00:50 is early for 09:01"
  end

  test "the expectation for yearly crons and intervals" do
    yearly = must("0 0 1 1 *", "UTC")
    last = utc(2026, 0, 1, 0, 0, 3)
    assert due(yearly, last, last - @day, 10 * @minute) == utc(2027, 0, 1, 0, 0, 0)
    leap = must("0 0 29 2 *", "UTC")
    assert due(leap, utc(2024, 1, 29, 0, 0, 1), 0, 0) == utc(2028, 1, 29, 0, 0, 0)
    every = must("every 1h")
    now = utc(2026, 0, 5, 9, 30, 0)
    e = Schedule.expectation(every, now - 2 * @hour, now - @day, 5 * @minute)
    assert e.due_at == now - @hour
    assert e.deadline == now - @hour + 5 * @minute
    assert due(every, nil, now - 30 * @minute, 5 * @minute) == now + 30 * @minute
    assert Schedule.expectation(every, nil, 0, 1.5).deadline == @hour + 1.5
  end

  test "a run at the spring-forward jump covers a moved fire" do
    # 2026-03-08, America/New_York: 02:00 EST jumps to 03:00 EDT at 07:00Z.
    # croner moves the nonexistent 02:30 to 03:30 EDT (07:30Z); vixie cron
    # runs it at 03:00 EDT.
    tz = "America/New_York"
    daily = must("30 2 * * *", tz)
    assert due(daily, utc(2026, 2, 7, 7, 30, 0), 0, 0) == utc(2026, 2, 8, 7, 30, 0)
    assert due(daily, utc(2026, 2, 8, 7, 0, 2), 0, 0) == utc(2026, 2, 9, 6, 30, 0), "the vixie run covers the day"
    assert due(daily, utc(2026, 2, 8, 7, 30, 1), 0, 0) == utc(2026, 2, 9, 6, 30, 0), "so does croner's"
    # A cron that fires at the jump itself was not moved: a run then covers only that fire.
    assert due(must("*/10 * * * *", tz), utc(2026, 2, 8, 7, 0, 2), 0, 0) == utc(2026, 2, 8, 7, 10, 0)
    assert due(must("0 * * * *", tz), utc(2026, 2, 8, 7, 0, 2), 0, 0) == utc(2026, 2, 8, 8, 0, 0)
  end

  test "run_covers allows a minute, at most half the gap" do
    d = utc(2026, 0, 5, 2, 0, 0)

    for {started, following, want} <- [
          {d, nil, true},
          {d - 59_000, nil, true},
          {d + 5 * @minute, nil, true},
          {d - 61_000, nil, false},
          {d - 30_000, d + @minute, true},
          {d - 31_000, d + @minute, false}
        ] do
      assert Schedule.run_covers(started, d, following) == want, "run_covers(#{started - d})"
    end
  end

  test "fires between a span" do
    hourly = must("0 * * * *", "UTC")
    from = utc(2026, 0, 5, 9, 30, 0)
    fires = Schedule.fires_between(hourly, from, from + 24 * @hour, 100)
    assert length(fires) == 24

    Enum.reduce(fires, from, fn fire, at ->
      next = Schedule.next_fire(hourly, at, nil)
      assert fire == next, "fires_between and next_fire disagree"
      next
    end)

    assert Schedule.fires_between(hourly, from, from + 24 * @hour, 23) == nil, "more than the limit is none"
    assert Schedule.fires_between(must("0 3 * * *", "UTC"), from, from + @hour, 5) == [], "an empty span is empty"

    # The night clocks go back in New York: fires only ever move forward.
    night =
      Schedule.fires_between(
        must("30 * * * *", "America/New_York"),
        utc(2026, 10, 1, 4, 0, 0),
        utc(2026, 10, 1, 9, 0, 0),
        20
      )

    assert night == Enum.sort(Enum.uniq(night)), "fires went backwards"
    assert length(night) in 4..5
  end

  test "a date no month has never fires" do
    # croner runs out of stack here; the port walks in a loop and gives up at
    # the year croner does.
    p = must("0 0 30 2 *", "UTC")
    assert Schedule.next_fire(p, utc(2026, 0, 1, 0, 0, 0), nil) == nil
    assert Schedule.expectation(p, nil, utc(2026, 0, 1, 0, 0, 0), 0) == nil
  end

  test "one-time dates are refused" do
    for {text, want} <- [
          {"2026-12-01T00:00:00", "CronPattern: a one-time date is not supported"},
          {"0 2:30 * * *", "Invalid ISO8601 passed to timezone parser."}
        ] do
      {:error, err} = Schedule.parse(text, nil)
      assert String.ends_with?(err, ": " <> want), "#{text}: #{err}"
    end
  end

  test "zones" do
    for name <- [
          "America/New_York",
          "america/new_york",
          "AMERICA/NEW_YORK",
          "utc",
          "UTC",
          "Etc/GMT+5",
          "etc/gmt+5",
          "+05:30",
          "-0800",
          "+05",
          "US/Pacific"
        ] do
      assert Schedule.timezone?(name), "#{name} should be a zone"
    end

    for name <-
          ["", nil, "Local", "local", "Bogus/Zone", "+25:00", "+5", "America/New_York/../New_York", "a\0b"] ++
            ["Etc/Unknown"] do
      refute Schedule.timezone?(name), "#{inspect(name)} should not be a zone"
    end

    # A zone named in another case reads the same as its own spelling.
    lower = must("0 2 * * *", "america/new_york")
    right = must("0 2 * * *", "America/New_York")
    from = utc(2026, 6, 10, 0, 0, 0)
    assert Schedule.next_fire(lower, from, nil) == utc(2026, 6, 10, 6, 0, 0)
    assert Schedule.next_fire(right, from, nil) == utc(2026, 6, 10, 6, 0, 0)

    assert JS.stringify(Schedule.to_value(lower)) ==
             ~s({"kind":"cron","source":"0 2 * * *","timezone":"america/new_york"})

    offset = must("0 2 * * *", "+05:30")
    assert Schedule.next_fire(offset, utc(2026, 0, 1, 0, 0, 0), nil) == utc(2026, 0, 1, 20, 30, 0)
    {:error, err} = Schedule.parse("0 2 * * *", "Bogus/Zone")
    assert String.starts_with?(err, "CronDate: Failed to convert date to timezone 'Bogus/Zone'"), err
  end

  test "the process's zone comes from $TZ" do
    assert Cronwatch.Zone.system() == :utc
    assert {:ok, :utc} = Cronwatch.Zone.load(nil)
  end

  test "parse is safe from many processes" do
    1..32
    |> Enum.map(fn _ ->
      Task.async(fn ->
        for j <- 0..49 do
          p = must("*/15 * * * *", "Europe/London")
          Schedule.next_fire(p, utc(2026, 9, 25, 0, 0, j), nil)
        end
      end)
    end)
    |> Task.await_many(30_000)
  end

  test "durations as text and numbers" do
    for {text, want} <- [
          {"15m", 900_000},
          {"1h30m", 5_400_000},
          {"90s", 90_000},
          {"2d", 172_800_000},
          {"1w", 604_800_000},
          {"250ms", 250},
          {" 1h 5m ", 3_900_000},
          {"1.5h", 5_400_000}
        ] do
      assert Duration.parse(text) == {:ok, want}, inspect(text)
    end

    for {n, want} <- [{1234, 1234}, {5, 5}, {1.5, 1.5}], do: assert(Duration.parse(n) == {:ok, want})

    for bad <- ["", "abc", "5", "5 minutes", "-1m", "1m2"] do
      {:error, err} = Duration.parse(bad)
      assert err =~ "duration", "#{inspect(bad)}: #{err}"
    end

    assert Duration.parse(-5, "grace") == {:error, "grace must be a non-negative number of milliseconds"}
    assert Duration.parse(:infinity, "grace") == {:error, "grace must be a non-negative number of milliseconds"}
    assert Duration.parse(true, "grace") == {:error, ~s(grace "true" is not a duration like "15m", "1h30m" or "90s")}
    assert Duration.parse(nil, "grace") == {:error, ~s(grace "null" is not a duration like "15m", "1h30m" or "90s")}

    assert Duration.parse(Object.new(), "grace") ==
             {:error, ~s(grace "[object Object]" is not a duration like "15m", "1h30m" or "90s")}

    assert Duration.parse([1, nil, "a"], "grace") ==
             {:error, ~s(grace "1,,a" is not a duration like "15m", "1h30m" or "90s")}
  end

  test "a duration over 64 characters is refused, quoting its first 32" do
    too_long = "is too long for a duration (more than 64 characters)"
    assert Duration.parse(String.duplicate("1m", 32)) == {:ok, 32 * 60_000}
    long = " " <> String.duplicate("1m", 32)
    assert Duration.parse(long, "grace") == {:error, ~s(grace "#{binary_part(long, 0, 32)}..." #{too_long})}
    # Characters are code points: forty emoji are eighty UTF-16 units but under the cap.
    forty = String.duplicate("😀", 40)

    assert Duration.parse(forty) ==
             {:error, ~s(duration "#{forty}" is not a duration like "15m", "1h30m" or "90s")}

    assert Duration.parse(String.duplicate("😀", 65)) ==
             {:error, ~s(duration "#{String.duplicate("😀", 32)}..." #{too_long})}

    {micros, result} = :timer.tc(fn -> Duration.parse(String.duplicate("1", 1_048_576), "silence duration") end)
    assert result == {:error, ~s(silence duration "#{String.duplicate("1", 32)}..." #{too_long})}
    assert micros < 10_000_000
  end

  test "format and relative" do
    for {ms, want} <- [
          {500, "500ms"},
          {1_000, "1s"},
          {90_000, "1m 30s"},
          {@hour * 26 + @minute * 5, "1d 2h"},
          {:nan, "?"},
          {:infinity, "?"}
        ] do
      assert Duration.format(ms) == want
    end

    assert Duration.relative(1_000_000, 1_120_000) == "2m ago"
    assert Duration.relative(1_120_000, 1_000_000) == "in 2m"
    assert Duration.relative(1_000_000, 1_002_000) == "now"
  end
end
