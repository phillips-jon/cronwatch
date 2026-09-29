defmodule Cronwatch.Bridge.Check do
  @moduledoc false
  # The check that a schedule taken from a scheduler (Oban's crontab read by
  # Oban's own parser, a Quantum job's read by the crontab package) makes
  # CronWatch expect runs exactly when the scheduler makes them, as the Go
  # port checks robfig/cron's and the Rust port tokio-cron-scheduler's: the
  # scheduler's own runs, from its own code, walked beside CronWatch's fires
  # around every clock change in the next few years and from the start of
  # each month of a sample year, so the answer does not depend on when the
  # app starts.
  #
  # Between two runs of the scheduler, CronWatch must not want one of its
  # own, or it would report it missed: a fire CronWatch has and the
  # scheduler does not (a time the scheduler skips when clocks go forward, a
  # run its fields drop that day) is refused unless the run before it covers
  # it (a minute of early slack, or a fire moved past a spring-forward jump).
  # Away from clock changes every run the scheduler makes must also be one
  # CronWatch expects; near one, the scheduler may run a repeated time twice,
  # which CronWatch takes as an early run. The Rust port's bridge/check.rs,
  # line for line.

  alias Cronwatch.JS
  alias Cronwatch.Schedule
  alias Cronwatch.Zone

  @horizon_years 5
  @change_window_ms 2 * 86_400_000
  @sample_year 2026
  @day_ms 86_400_000

  @doc "How many runs a runs function gives after the first when it is asked without an end."
  def sample_runs, do: 8

  @doc "What a runs function answers for a schedule that never fires again."
  def never_fires(why), do: {:never, why}

  @doc """
  `:ok`, or `{:error, message}` for a cron CronWatch would not expect runs
  of when the scheduler makes them. `runs` is the scheduler's own reading:
  given `start` and `finish` (epoch milliseconds, `finish` nil for a
  sample), `{:ok, times}` with the run at or before `start` and every one
  after it up to the first past `finish`, or `sample_runs/0` of them after
  that first one when `finish` is nil, ascending; `never_fires/1` for a
  schedule that never fires again, or `{:error, message}`. `expr` and
  `zone` are the schedule as CronWatch reads it (`zone` `""` for the
  process's own), `where` names the job and `scheduler` the scheduler in
  messages. `daily` is a cron that names no day or month, which meets every
  clock change of one kind alike, so one of each is walked. `now` is the
  epoch milliseconds the horizon starts from.
  """
  def check_fires(runs, expr, zone, where, scheduler, daily, now) do
    with {:ok, parsed} <- read(expr, zone, where),
         {:ok, tz} <- load(zone, where) do
      checker = %{
        runs: runs,
        parsed: parsed,
        tz: tz,
        zone: zone,
        where: "#{where} is #{JS.quote(expr)}",
        scheduler: scheduler
      }

      case walk(checker, daily, now) do
        {:never, why} -> {:error, "#{checker.where}, which never fires: #{why}"}
        other -> other
      end
    end
  end

  defp read(expr, zone, where) do
    case Schedule.parse(expr, zone) do
      {:ok, %Schedule{kind: "cron"} = p} -> {:ok, p}
      {:ok, _} -> {:error, "#{where} is #{JS.quote(expr)}, which CronWatch cannot read: not a cron"}
      {:error, e} -> {:error, "#{where} is #{JS.quote(expr)}, which CronWatch cannot read: #{e}"}
    end
  end

  defp load(zone, where) do
    case Zone.load(zone) do
      {:ok, tz} -> {:ok, tz}
      {:error, e} -> {:error, "#{where}: #{e}"}
    end
  end

  defp walk(k, daily, now) do
    year = elem(Zone.wall_at(Integer.floor_div(now, 1000), :utc), 0)
    changes = transitions(k.tz, year_start(year), year_start(year + @horizon_years + 1))

    result =
      Enum.reduce_while(changes, MapSet.new(), fn change, seen ->
        kind = {Integer.mod(div(change.at, 1000) + change.before, 86_400), change.after - change.before}

        if daily and MapSet.member?(seen, kind) do
          {:cont, seen}
        else
          seen = MapSet.put(seen, kind)
          start = change.at - @change_window_ms
          finish = start + 2 * @change_window_ms

          # Near a change only CronWatch's own fires can be refused, so a
          # stretch where it has none needs no walk.
          case Schedule.fire_after(k.parsed, start - 1) do
            first when is_integer(first) and first <= finish ->
              with {:ok, found} <- ask(k, start, finish),
                   :ok <- compare(k, found, false) do
                {:cont, seen}
              else
                err -> {:halt, err}
              end

            _ ->
              {:cont, seen}
          end
        end
      end)

    case result do
      %MapSet{} -> samples(k)
      err -> err
    end
  end

  defp samples(k) do
    Enum.reduce_while(0..11, {:ok, nil}, fn month, {:ok, until} ->
      start = JS.date_utc(@sample_year, month, 1)

      if until != nil and start < until do
        # A sparse cron's earlier sample reached past this month.
        {:cont, {:ok, until}}
      else
        case ask(k, start, nil) do
          {:ok, []} ->
            {:cont, {:ok, until}}

          {:ok, found} ->
            last = List.last(found)
            near = transitions(k.tz, hd(found) - @day_ms, last + @day_ms) != []

            case compare(k, found, not near) do
              :ok -> {:cont, {:ok, last}}
              err -> {:halt, err}
            end

          err ->
            {:halt, err}
        end
      end
    end)
    |> case do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp ask(k, start, finish) do
    case k.runs.(start, finish) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:never, why} -> {:never, why}
      {:error, message} -> {:error, message}
    end
  end

  # CronWatch's fires after `start`, up to and including `finish`.
  defp fires(k, start, finish), do: fires(k, start, finish, [])

  defp fires(k, at, finish, acc) do
    case Schedule.fire_after(k.parsed, at) do
      fire when is_integer(fire) and fire <= finish -> fires(k, fire, finish, [fire | acc])
      _ -> Enum.reverse(acc)
    end
  end

  # Refuses where, after one of the scheduler's runs, CronWatch would want a
  # run before the scheduler's next (or, when strict, where the scheduler's
  # next is not a time CronWatch fires).
  defp compare(_k, runs, _strict) when length(runs) < 2, do: :ok

  defp compare(k, runs, strict) do
    all = fires(k, hd(runs), List.last(runs))
    expected = if strict, do: MapSet.new(all), else: MapSet.new()
    pairs = Enum.zip(runs, tl(runs))

    Enum.reduce_while(pairs, all, fn {at, following}, left ->
      left = Enum.drop_while(left, &(&1 <= at))
      own = left == [] or hd(left) < following
      unexpected = strict and not MapSet.member?(expected, following)

      if not own and not unexpected do
        {:cont, left}
      else
        due = Schedule.due_after_run(k.parsed, at)

        if not unexpected and is_integer(due) and due >= following,
          do: {:cont, left},
          else: {:halt, {:error, mismatch(k, at, following, due)}}
      end
    end)
    |> case do
      {:error, _} = err -> err
      _ -> :ok
    end
  end

  defp zone_name(%{zone: ""}), do: "the process's zone"
  defp zone_name(%{zone: zone}), do: zone

  defp stamp(k, ms) do
    {y, mo, d, h, mi, s} = Zone.wall_at(Integer.floor_div(ms, 1000), k.tz)
    "#{pad(y, 4)}-#{pad(mo)}-#{pad(d)} #{pad(h)}:#{pad(mi)}:#{pad(s)}"
  end

  defp pad(n, width \\ 2), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  defp mismatch(k, at, following, due) do
    skipped =
      if due do
        Enum.find(transitions(k.tz, due - @day_ms, due + 1000), fn change ->
          gap = change.after - change.before
          gap > 0 and due < change.at + gap * 1000
        end)
      end

    if skipped do
      {oy, om, od, oh, omi, _} = Zone.wall_at(Integer.floor_div(skipped.at, 1000) + skipped.before, :utc)
      {_, _, _, nh, nmi, _} = Zone.wall_at(Integer.floor_div(skipped.at, 1000) + skipped.after, :utc)

      "#{k.where}, due at a time that does not exist in #{zone_name(k)} on #{pad(oy, 4)}-#{pad(om)}-#{pad(od)}, " <>
        "when clocks go forward from #{pad(oh)}:#{pad(omi)} to #{pad(nh)}:#{pad(nmi)}. " <>
        "#{k.scheduler} does not run it then and CronWatch would expect it at #{stamp(k, due)}, so it would be reported missed. " <>
        "Move the time outside the change, give the schedule a zone without daylight saving (such as UTC), " <>
        "or give the job a schedule of its own"
    else
      expected = if due, do: stamp(k, due), else: "nothing"

      "#{k.where} in #{zone_name(k)}, but after a run at #{stamp(k, at)} #{k.scheduler} runs it next at " <>
        "#{stamp(k, following)} and CronWatch would expect #{expected}, so it cannot be converted exactly; " <>
        "give the job a schedule of its own"
    end
  end

  defp year_start(year), do: JS.date_utc(year, 0, 1)

  # The scan step: no zone changes its clocks twice within six hours.
  @scan_s 6 * 3600

  @doc """
  The zone's clock changes between two instants (epoch milliseconds):
  `%{at: ms, before: seconds, after: seconds}`, the offsets before and after.
  """
  def transitions(:utc, _start_ms, _end_ms), do: []
  def transitions({:fixed, _}, _start_ms, _end_ms), do: []

  def transitions(tz, start_ms, end_ms) do
    first = Integer.floor_div(start_ms, 1000)
    last = Integer.floor_div(end_ms, 1000)
    scan(tz, first, Zone.offset(first, tz), last, [])
  end

  defp scan(_tz, at, _offset, last, acc) when at >= last, do: Enum.reverse(acc)

  defp scan(tz, at, offset, last, acc) do
    next = min(at + @scan_s, last)
    after_offset = Zone.offset(next, tz)

    if after_offset == offset do
      scan(tz, next, offset, last, acc)
    else
      # The first second with the new offset.
      change = bisect(tz, at, next, offset)
      scan(tz, next, after_offset, last, [%{at: change * 1000, before: offset, after: after_offset} | acc])
    end
  end

  defp bisect(_tz, low, high, _offset) when high - low <= 1, do: high

  defp bisect(tz, low, high, offset) do
    mid = low + div(high - low, 2)
    if Zone.offset(mid, tz) == offset, do: bisect(tz, mid, high, offset), else: bisect(tz, low, mid, offset)
  end
end
