defmodule Cronwatch.CronTest do
  # The walk's habits, each checked against what croner answers (the parity
  # test checks thousands more against croner itself).
  use ExUnit.Case, async: true

  alias Cronwatch.Cron
  alias Cronwatch.Cron.Pattern
  alias Cronwatch.JS
  alias Cronwatch.Zone

  @min_i64 -9_223_372_036_854_775_808
  @max_i64 9_223_372_036_854_775_807

  defp runs(text, zone, count, from) do
    {:ok, tz} = Zone.load(zone)
    {:ok, c} = Cron.new(text, tz)
    c |> Cron.next_runs(count, from) |> Enum.map(&JS.iso_string/1)
  end

  test "croner's habits" do
    jan = JS.date_utc(2026, 0, 1)

    cases = [
      {"a wall-clock time in a spring-forward gap moves forward by the gap", "30 2 8 3 *", "America/New_York", 1,
       ["2026-03-08T07:30:00.000Z"]},
      {"a time that happens twice is the earlier one", "30 1 1 11 *", "America/New_York", 2,
       ["2026-11-01T05:30:00.000Z", "2027-11-01T05:30:00.000Z"]},
      {"a year field fires in that year only", "0 0 0 1 1 * 2030", "UTC", 2, ["2030-01-01T00:00:00.000Z"]},
      {"a fixed offset is a zone", "0 2 * * *", "+05:30", 1, ["2026-01-01T20:30:00.000Z"]},
      {"a date no month has never fires", "0 0 30 2 *", "UTC", 1, []},
      {"the last weekday of the month", "0 0 LW * *", "UTC", 2,
       ["2026-01-30T00:00:00.000Z", "2026-02-27T00:00:00.000Z"]},
      {"the nearest weekday to the first", "0 0 1W * *", "UTC", 2,
       ["2026-02-02T00:00:00.000Z", "2026-03-02T00:00:00.000Z"]},
      {"the second Friday", "0 0 * * 5#2", "UTC", 2, ["2026-01-09T00:00:00.000Z", "2026-02-13T00:00:00.000Z"]}
    ]

    for {name, text, zone, count, want} <- cases do
      assert runs(text, zone, count, jan) == want, "#{name}: #{text}"
    end
  end

  test "croner's messages" do
    cases = [
      {"",
       "CronPattern: invalid configuration format (''), exactly five, six, or seven space separated parts are required."},
      {"0 0 * * 5W", "CronPattern: configuration entry 5 (5W) contains illegal characters."},
      {"0 0 1#2 * *", "CronPattern: configuration entry 3 (1#2) contains illegal characters."},
      {"0 0 * 2L *", "CronPattern: configuration entry 4 (2L) contains illegal characters."},
      {"0 0 1-5W * *", "CronPattern: Syntax error, W is not allowed in a range."},
      {"* * * * * * 0", "CronPattern: Invalid value for year: 0 (supported range: 1-9999)"},
      {"0 0 * * 1#2.5", "CronPattern: configuration entry 5 (1#2.5) contains illegal characters."},
      {"@reboot",
       "CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection."},
      # Croner takes this for a one-time date; the SDK and the port refuse it (see Cronwatch.Cron).
      {"0 12:30 * * *", "Invalid ISO8601 passed to timezone parser."}
    ]

    for {text, want} <- cases, do: assert(Cron.new(text, :utc) == {:error, want}, inspect(text))
  end

  test "fromTZ" do
    {:ok, ny} = Zone.load("America/New_York")
    # 02:30 does not exist on 2026-03-08: croner's fromTZ moves it to 03:30 EDT.
    assert Zone.to_utc({2026, 3, 8, 2, 30, 0}, ny) * 1000 == JS.date_utc(2026, 2, 8, 7, 30, 0, 0)
    # 01:30 happens twice on 2026-11-01: the earlier, EDT.
    assert Zone.to_utc({2026, 11, 1, 1, 30, 0}, ny) * 1000 == JS.date_utc(2026, 10, 1, 5, 30, 0, 0)
    assert Zone.wall_at(div(JS.date_utc(2026, 6, 1, 12, 0, 0, 0), 1000), ny) == {2026, 7, 1, 8, 0, 0}
  end

  test "Number and parseInt" do
    for {text, want} <- [{"5", 5}, {" 7x", 7}, {"-3", -3}, {"+2", 2}], do: assert(Pattern.parse_int(text) == want)
    for text <- ["x", "", "+-1", " "], do: assert(Pattern.parse_int(text) == :nan, inspect(text))

    for {text, want} <- [{"", 0}, {" 2 ", 2}, {"1e1", 10}, {"2.", 2}, {".5", 0.5}],
        do: assert(Pattern.to_number(text) == want, inspect(text))

    for text <- ["x", "1L", "e1", ".", "1e", "--1"], do: assert(Pattern.to_number(text) == :nan, inspect(text))
  end

  test "a start no JavaScript Date holds has no fires" do
    # A foreign row's time near the ends of the 64-bit range; croner is never
    # given one.
    for text <- ["0 * * * *", "0 0 L * ?", "0 0 * * 5#2"],
        from <- [@min_i64, @min_i64 + 1, -8_640_000_000_000_001, 8_640_000_000_000_001, @max_i64] do
      assert runs(text, "Europe/London", 2, from) == [], "#{text} from #{from}"
    end

    assert runs("0 0 1 1 *", "UTC", 1, -8_640_000_000_000_000) == ["-271820-01-01T00:00:00.000Z"]
  end
end
