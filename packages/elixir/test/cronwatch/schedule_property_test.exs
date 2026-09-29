defmodule Cronwatch.SchedulePropertyTest do
  # The Rust port's `cron` fuzz target as a property: an expression in any of
  # nine zones (with and without daylight saving, half and quarter hours off,
  # the process's own, or any text), read without raising, and its fire times
  # from any instant each later than the last. Duration text goes through the
  # same door a job's options do. A few hundred cases run with `mix test`;
  # `CRONWATCH_PROPERTY_RUNS` asks for more.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cronwatch.Duration
  alias Cronwatch.Schedule

  @moduletag :property

  @runs String.to_integer(System.get_env("CRONWATCH_PROPERTY_RUNS", "200"))
  @zones [nil, "UTC", "America/New_York", "Europe/London", "Australia/Lord_Howe", "Asia/Kolkata"] ++
           ["Pacific/Chatham", "+05:45", "america/santiago"]

  defp field(low, high) do
    one_of([
      constant("*"),
      integer(low..high) |> map(&Integer.to_string/1),
      list_of(integer(low..high), length: 2) |> map(fn pair -> pair |> Enum.sort() |> Enum.join("-") end),
      integer(1..(high - low + 1)) |> map(&"*/#{&1}"),
      list_of(integer(low..high), min_length: 2, max_length: 4) |> map(&Enum.join(&1, ",")),
      member_of(["?", "L", "LW", "15W", "5L", "1#2", "x", "", "-1", "+1"])
    ])
  end

  defp expression do
    one_of([
      member_of(["@hourly", "@daily", "@weekly", "@monthly", "@yearly", "every 90s", "every 1h30m"]),
      tuple({field(0, 59), field(0, 23), field(1, 31), field(1, 12), field(0, 7)})
      |> map(fn t -> t |> Tuple.to_list() |> Enum.join(" ") end),
      string(:printable, max_length: 40)
    ])
  end

  property "fire times only move forward" do
    check all(
            text <- expression(),
            zone <- one_of([member_of(@zones), string(:ascii, max_length: 12)]),
            from <- integer(-62_135_596_800_000..253_402_300_799_000),
            max_runs: @runs
          ) do
      case Schedule.parse(text, zone) do
        {:error, message} ->
          assert is_binary(message)

        {:ok, p} ->
          Enum.reduce_while(1..5, from, fn _, at ->
            case Schedule.next_fire(p, at, nil) do
              nil ->
                {:halt, at}

              next ->
                assert next > at, "#{text} in #{inspect(zone)}: #{next} after #{at}"
                {:cont, next}
            end
          end)
      end
    end
  end

  property "duration text is read or refused, never raised" do
    check all(
            text <- one_of([string(:printable, max_length: 80), string(~c"0123456789.msdhw ", max_length: 70)]),
            max_runs: @runs
          ) do
      case Duration.parse(text, "grace") do
        {:ok, ms} -> assert is_integer(ms) and ms >= 0
        {:error, message} -> assert String.starts_with?(message, "grace ")
      end
    end
  end
end
