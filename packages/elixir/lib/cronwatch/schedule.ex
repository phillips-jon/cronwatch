defmodule Cronwatch.Schedule do
  @moduledoc """
  The SDK's `schedule.ts`: schedules (`"0 2 * * *"`, `"@hourly"`,
  `"every 5m"`) with their fire times, due times, deadlines and what a run
  covers. Cron fire times come from the croner port (`Cronwatch.Cron`), so an
  Elixir process and a Node, Ruby, Python, PHP, Go or Rust process sharing
  one store agree on every due time.

  A schedule is read on each call; reading one is cheap next to the store
  calls around it, and nothing is kept between calls.
  """

  alias Cronwatch.Cron
  alias Cronwatch.Duration
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Zone

  @early_slack_ms 60_000
  @max_interval_ms 9_007_199_254_740_992
  @hour 3_600_000

  defstruct [:kind, :source, :timezone, :every_ms, :cron]

  @typedoc """
  A schedule as `parseSchedule` returns it: `kind` is `"cron"` or
  `"interval"`, `timezone` the name given (nil when none), `every_ms` an
  interval's period, and `cron` the croner expression behind a cron.
  """
  @type t :: %__MODULE__{
          kind: String.t(),
          source: String.t(),
          timezone: String.t() | nil,
          every_ms: integer() | nil,
          cron: Cron.t() | nil
        }

  @typedoc "When the next run is due, and the time past which it is missed."
  @type expectation :: %{due_at: integer(), deadline: number()}

  @doc "How early a run may start and still count for the fire it was meant for: a minute."
  @spec early_slack_ms() :: 60_000
  def early_slack_ms, do: @early_slack_ms

  @doc """
  The longest interval kept, 2^53 ms. A longer `every` is read as this long,
  which fires no sooner in any run's lifetime.
  """
  @spec max_interval_ms() :: pos_integer()
  def max_interval_ms, do: @max_interval_ms

  @doc """
  The SDK's `parseSchedule`: a cron of five or six fields, a nickname
  (`"@hourly"`), or `"every 5m"`. Without a timezone (`nil` or `""`) a cron
  is read in the process's zone, as crontab reads the system's; Vercel and
  GitHub Actions run their crons in UTC, so pass `"UTC"` for those. The
  errors are the SDK's, word for word; a zone the database does not have is
  refused here with the message croner throws for it when asked for a fire
  time, since the SDK reads the zone only then (see `timezone?/1`).
  """
  @spec parse(String.t(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def parse(schedule, timezone \\ nil)
  def parse(schedule, ""), do: parse(schedule, nil)

  def parse(schedule, timezone) do
    text = JS.trim(schedule)

    case every(text) do
      {:ok, rest} -> interval(schedule, text, rest)
      :error -> cron(schedule, text, timezone)
    end
  end

  defp interval(schedule, text, rest) do
    with {:ok, ms} <- Duration.parse(rest, "schedule interval") do
      if ms < 1000 do
        {:error, "schedule \"#{schedule}\" is shorter than one second"}
      else
        {:ok, %__MODULE__{kind: "interval", source: text, every_ms: min(ms, @max_interval_ms)}}
      end
    end
  end

  defp cron(schedule, text, timezone) do
    pattern_zone = if timezone == nil, do: Zone.system(), else: :utc

    with {:ok, _} <- tag(Cron.new(text, pattern_zone), schedule),
         {:ok, zone} <- zone(timezone),
         {:ok, c} <- Cron.new(text, zone) do
      {:ok, %__MODULE__{kind: "cron", source: text, timezone: timezone, cron: c}}
    end
  end

  defp tag({:error, message}, schedule),
    do: {:error, "schedule \"#{schedule}\" is not a cron expression or \"every <duration>\": #{message}"}

  defp tag(ok, _schedule), do: ok

  defp zone(nil), do: {:ok, Zone.system()}

  defp zone(timezone) do
    case Zone.load(timezone) do
      {:ok, zone} ->
        {:ok, zone}

      {:error, _} ->
        {:error,
         "CronDate: Failed to convert date to timezone '#{timezone}'. This may happen with invalid timezone names or dates. " <>
           "Original error: toTZ: Invalid timezone '#{timezone}' or date. Please provide a valid IANA timezone (e.g., 'America/New_York', 'Europe/Stockholm'). " <>
           "Original error: Invalid time zone specified: #{timezone}"}
    end
  end

  # /^every\s+(.+)$/i: "every" in any ASCII case, whitespace, and the rest,
  # which must hold no line terminator (JavaScript's "." matches none).
  defp every(<<head::binary-size(5), rest::binary>>) do
    trimmed = JS.trim_start(rest)

    lower = for <<c <- head>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>

    if lower == "every" and byte_size(trimmed) < byte_size(rest) and trimmed != "" and
         not String.contains?(trimmed, ["\n", "\r", "\u2028", "\u2029"]),
       do: {:ok, trimmed},
       else: :error
  end

  defp every(_), do: :error

  @doc """
  The SDK's JSON of a parsed schedule: `{kind, source, timezone}` for a cron
  (timezone only when given) and `{kind, source, everyMs}` for an interval.
  """
  @spec to_value(t()) :: Object.t()
  def to_value(%__MODULE__{} = p) do
    o = Object.new([{"kind", p.kind}, {"source", p.source}])

    cond do
      p.kind == "interval" -> Object.put(o, "everyMs", p.every_ms)
      p.timezone != nil -> Object.put(o, "timezone", p.timezone)
      true -> o
    end
  end

  @doc """
  Whether `new Intl.DateTimeFormat("en-US", { timeZone })` accepts the name:
  an IANA zone in any case, `"UTC"`, or a fixed offset such as `"+05:30"`.
  """
  @spec timezone?(term()) :: boolean()
  def timezone?(name), do: Zone.zone?(name)

  defp next_runs(%__MODULE__{cron: nil}, _count, _start), do: []
  defp next_runs(%__MODULE__{cron: c}, count, start), do: Cron.next_runs(c, count, start)

  @doc """
  The first fire strictly after `from`, or nil when the cron never fires
  again. Croner answers with times in the past when asked from inside the
  hour that repeats when clocks go back, so its answers are filtered, and a
  stretch of nothing but past times is stepped over an hour at a time.
  """
  @spec fire_after(t(), integer()) :: integer() | nil
  def fire_after(p, from), do: fire_after(p, from, from, 0)

  defp fire_after(_p, _from, _probe, 4), do: nil

  defp fire_after(p, from, probe, attempt) do
    case next_runs(p, 8, probe) do
      [] ->
        nil

      runs ->
        case Enum.find(runs, &(&1 > from)) do
          nil -> fire_after(p, from, probe + @hour, attempt + 1)
          t -> t
        end
    end
  end

  @doc """
  Every fire of a cron strictly after `from` and at or before `to`,
  ascending, or nil when there are more than `limit`. Fires are asked for in
  batches, and any that do not move forward are dropped.
  """
  @spec fires_between(t(), integer(), integer(), non_neg_integer()) :: [integer()] | nil
  def fires_between(p, from, to, limit), do: between(p, to, limit, from, from, [], 0, 0)

  defp between(_p, _to, _limit, _probe, _last, out, _n, 1000), do: Enum.reverse(out)

  defp between(p, to, limit, probe, last, out, n, guard) do
    case next_runs(p, min(limit + 1 - n, 24), probe) do
      [] ->
        Enum.reverse(out)

      batch ->
        case take(batch, to, limit, last, out, n) do
          {:done, result} ->
            result

          {:more, last, out, n} ->
            stop = List.last(batch)
            probe = if stop > probe, do: stop, else: probe + @hour
            between(p, to, limit, probe, last, out, n, guard + 1)
        end
    end
  end

  defp take([], _to, _limit, last, out, n), do: {:more, last, out, n}
  defp take([t | rest], to, limit, last, out, n) when t <= last, do: take(rest, to, limit, last, out, n)
  defp take([t | _], to, _limit, _last, out, _n) when t > to, do: {:done, Enum.reverse(out)}
  defp take([_ | _], _to, limit, _last, _out, n) when n + 1 > limit, do: {:done, nil}
  defp take([t | rest], to, limit, _last, out, n), do: take(rest, to, limit, t, [t | out], n + 1)

  @doc """
  The next time the schedule fires strictly after `from`; for an interval,
  counted from the last run when there is one. Nil when a cron never fires
  again.
  """
  @spec next_fire(t(), integer(), integer() | nil) :: integer() | nil
  def next_fire(%__MODULE__{kind: "interval", every_ms: every}, from, last_run_at), do: (last_run_at || from) + every
  def next_fire(p, from, _last_run_at), do: fire_after(p, from)

  @doc """
  The SDK's `expectation()`: when the schedule next wants a run, given the
  last one. For a cron that is the first fire the last run does not already
  cover; with no run yet, the first fire at or after registration. For an
  interval it is the last run's start (or registration) plus the interval.
  Nil for a cron that never fires again.
  """
  @spec expectation(t(), integer() | nil, integer(), number()) :: expectation() | nil
  def expectation(p, last_run_at, registered_at, grace_ms) do
    due =
      cond do
        p.kind == "interval" -> (last_run_at || registered_at) + p.every_ms
        last_run_at == nil -> fire_after(p, registered_at - 1)
        true -> due_after_run(p, last_run_at)
      end

    if due, do: %{due_at: due, deadline: JS.normalize(due + grace_ms)}
  end

  @doc "The first fire of a cron that a run starting at `started_at` does not cover, or nil."
  @spec due_after_run(t(), integer()) :: integer() | nil
  def due_after_run(p, started_at) do
    # A fire at or before the start is covered by the run itself.
    case fire_after(p, started_at) do
      nil ->
        nil

      next ->
        following = fire_after(p, next)

        if run_covers(started_at, next, following) or in_spring_forward_gap?(p, started_at, next),
          do: following,
          else: next
    end
  end

  @doc """
  Whether a run starting at `started_at` covers the fire at `due_at`. A
  minute of slack before the tick absorbs schedulers that fire a touch
  early. When the fire after `due_at` is known, the slack is at most half the
  gap between the two, so one run of an every-minute cron never covers two
  fires.
  """
  @spec run_covers(integer(), integer(), integer() | nil) :: boolean()
  def run_covers(started_at, due_at, following_at \\ nil) do
    slack =
      if following_at == nil,
        do: @early_slack_ms,
        else: min(@early_slack_ms, Integer.floor_div(following_at - due_at, 2))

    started_at >= due_at - slack
  end

  # On the night clocks spring forward, a fire whose local time does not
  # exist (02:30 when 02:00 jumps to 03:00) is moved by croner to the same
  # distance past the jump (03:30), while vixie cron runs it at the jump
  # itself (03:00). A run that starts at or after the jump, and before the
  # first fire after it when that fire lies within one gap of it, is taken
  # to cover that fire, so neither scheduler's run is reported as missed.
  defp in_spring_forward_gap?(%__MODULE__{cron: nil}, _started_at, _fire_at), do: false

  defp in_spring_forward_gap?(%__MODULE__{cron: c} = p, started_at, fire_at) do
    lookback = 3 * @hour
    zone = c.zone
    after_offset = utc_offset(fire_at, zone)
    gap = after_offset - utc_offset(fire_at - lookback, zone)

    if gap <= 0 do
      false
    else
      hi = find_jump(fire_at - lookback, fire_at, after_offset, zone)
      jump_at = Integer.floor_div(hi, 60_000) * 60_000

      if fire_at - jump_at >= gap or started_at < jump_at - @early_slack_ms or started_at >= fire_at do
        false
      else
        # Only the first fire after the jump can be a moved one; a cron that
        # also fires at the jump (every 10 minutes, say) was not moved.
        fire_after(p, jump_at - 1) == fire_at
      end
    end
  end

  # The first minute in the window with the later offset.
  defp find_jump(lo, hi, after_offset, zone) when hi - lo > 60_000 do
    mid = lo + div(hi - lo, 2)

    if utc_offset(mid, zone) == after_offset,
      do: find_jump(lo, mid, after_offset, zone),
      else: find_jump(mid, hi, after_offset, zone)
  end

  defp find_jump(_lo, hi, _after_offset, _zone), do: hi

  # The milliseconds the zone's wall clock is ahead of UTC at `at`.
  defp utc_offset(at, zone), do: Zone.offset(Integer.floor_div(at, 1000), zone) * 1000
end
