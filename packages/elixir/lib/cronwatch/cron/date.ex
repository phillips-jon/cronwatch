defmodule Cronwatch.Cron.Date do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # Croner's CronDate: a wall-clock time whose fields are moved forward to the
  # next match, a field at a time, spilling into the next month or year as
  # croner does. The fields are year, month (0 based), day, hour, minute,
  # second and milliseconds, held in a tuple in that order.

  import Bitwise

  alias Cronwatch.Cron.Pattern
  alias Cronwatch.JS
  alias Cronwatch.Zone

  @days_in_month {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

  @year 0
  @month 1
  @second 5
  @millis 6

  # Croner's fieldOrder: the field, the field above it, the pattern's table
  # and the offset from a field value to its table index.
  @order {{1, 0, :month, 0}, {2, 1, :day, -1}, {3, 2, :hour, 0}, {4, 3, :minute, 0}, {5, 4, :second, 0}}
  @n_order 5

  @years 10_000

  @type t :: {integer(), integer(), integer(), integer(), integer(), integer(), integer()}

  # Croner's getLastDayOfMonth, month 0 based; nil for a month outside 0 to
  # 11 (croner's undefined).
  defp last_day_of_month(year, 1) do
    {_, _, d} = JS.civil_from_days(Integer.floor_div(JS.date_utc(year, 2, 0), 86_400_000))
    d
  end

  defp last_day_of_month(_year, month) when month in 0..11, do: elem(@days_in_month, month)
  defp last_day_of_month(_year, _month), do: nil

  # new Date(Date.UTC(year, month, day)).getUTCDay(), month 0 based and free
  # to overflow. 0 is Sunday.
  defp weekday(year, month, day), do: Integer.mod(Integer.floor_div(JS.date_utc(year, month, day), 86_400_000) + 4, 7)

  @doc "`new CronDate(new Date(at), tz)`."
  @spec from_ms(integer(), Zone.t()) :: t()
  def from_ms(at, zone) do
    sec = Integer.floor_div(at, 1000)
    {y, m, d, h, mi, s} = Zone.wall_at(sec, zone)
    {y, m - 1, d, h, mi, s, at - sec * 1000}
  end

  # Croner's apply(): fields out of their range are carried into the fields
  # above, as a Date made from them would be. It says whether it changed
  # anything.
  defp apply_date({year, month, day, hour, minute, second, millis} = f) do
    out =
      month not in 0..11 or day > elem(@days_in_month, month) or day < 1 or hour > 59 or minute > 59 or
        second > 59 or hour < 0 or minute < 0 or second < 0

    if out do
      at = JS.date_utc(year, month, day, hour, minute, second, millis)
      sec = Integer.floor_div(at, 1000)
      days = Integer.floor_div(sec, 86_400)
      rest = sec - days * 86_400
      {y, mo, d} = JS.civil_from_days(days)
      {{y, mo - 1, d, div(rest, 3600), rem(rest, 3600) |> div(60), rem(rest, 60), at - sec * 1000}, true}
    else
      {f, false}
    end
  end

  defp last_weekday(year, month) do
    last = last_day_of_month(year, month) || 0

    case weekday(year, month, last) do
      0 -> last - 2
      6 -> last - 1
      _ -> last
    end
  end

  defp nearest_weekday(year, month, day) do
    last = last_day_of_month(year, month)

    if last != nil and day > last do
      -1
    else
      case weekday(year, month, day) do
        0 -> if last == day, do: day - 2, else: day + 1
        6 -> if day == 1, do: day + 2, else: day - 1
        _ -> day
      end
    end
  end

  defp nth_weekday?(year, month, day, bits) do
    count = div(day - 1, 7) + 1
    nth = Pattern.nth_bits()

    cond do
      (bits &&& Pattern.any_bits()) != 0 and count in 1..tuple_size(nth) and (elem(nth, count - 1) &&& bits) != 0 ->
        true

      (bits &&& Pattern.last_bit()) != 0 ->
        last = last_day_of_month(year, month) || 0
        day + 7 > last

      true ->
        false
    end
  end

  # Croner's findNext: 1 when the field already matches, 2 when it was moved
  # forward to a match, 3 when none is left in its range.
  defp find_next(f, p, {field, _above, k, offset}) do
    before = elem(f, field)
    table = Map.fetch!(p, k)
    size = tuple_size(table)
    year = elem(f, @year)
    month = elem(f, @month)
    last = if p.last_day_of_month, do: last_day_of_month(year, month)
    first_weekday = if not p.star_dow and k == :day, do: weekday(year, month, 1), else: 0

    nearest =
      if k == :day,
        do: for({1, c} <- p.nearest_weekdays |> Tuple.to_list() |> Enum.with_index(), do: c),
        else: []

    ctx = %{k: k, offset: offset, year: year, month: month, last: last, first_weekday: first_weekday, nearest: nearest}
    scan(f, p, field, before, table, size, ctx, before + offset)
  end

  defp scan(f, _p, _field, _before, _table, size, _ctx, u) when u >= size, do: {:ok, 3, f}

  defp scan(f, p, field, before, table, size, ctx, u) do
    %{k: k, offset: offset, year: year, month: month} = ctx
    matched = if u >= 0, do: elem(table, u), else: 0

    matched = if k == :day and matched == 0 and nearest_match?(ctx, u), do: 1, else: matched

    matched = if k == :day and p.last_weekday and u - offset == last_weekday(year, month), do: 1, else: matched
    matched = if k == :day and p.last_day_of_month and ctx.last == u - offset, do: 1, else: matched

    result =
      if k == :day and not p.star_dow do
        bits = elem(p.day_of_week, Integer.mod(ctx.first_weekday + (u - offset - 1), 7))

        bits =
          cond do
            bits != 0 and (bits &&& Pattern.any_bits()) != 0 ->
              if nth_weekday?(year, month, u - offset, bits), do: 1, else: 0

            bits != 0 ->
              {:error, "CronDate: Invalid value for dayOfWeek encountered. #{bits}"}

            true ->
              0
          end

        case bits do
          {:error, _} = e ->
            e

          bits ->
            cond do
              p.use_and_logic -> if matched != 0, do: bits, else: matched
              not p.star_dom -> if matched == 0, do: bits, else: matched
              matched != 0 -> bits
              true -> matched
            end
        end
      else
        matched
      end

    case result do
      {:error, _} = e ->
        e

      0 ->
        scan(f, p, field, before, table, size, ctx, u + 1)

      _ ->
        value = u - offset
        {:ok, if(before != value, do: 2, else: 1), put_elem(f, field, value)}
    end
  end

  # Whether a day the pattern names with W moves to day index `u` this month.
  defp nearest_match?(%{nearest: nearest, year: year, month: month, offset: offset}, u) do
    Enum.any?(nearest, fn c ->
      m = nearest_weekday(year, month, c - offset)
      m != -1 and m == u - offset
    end)
  end

  # Croner's recurse(), walked in a loop: each field in turn from the month
  # down is moved to its next match, a field that runs out carries into the
  # one above and the walk starts again from the month. Croner recurses a
  # year at a time, so for a date no month has it runs out of stack; the
  # loop answers false (never) at the year croner gives up at.
  defp recurse(f, p, level) do
    with {:ok, f} <- year_check(f, p, level) do
      step = elem(@order, Integer.mod(level, @n_order))

      case find_next(f, p, step) do
        {:error, _} = e ->
          e

        {:ok, 1, _} ->
          advance(f, p, level)

        {:ok, n, f} ->
          f =
            if level + 1 < @n_order,
              do:
                Enum.reduce((level + 1)..(@n_order - 1)//1, f, fn i, f ->
                  {field, _, _, offset} = elem(@order, Integer.mod(i, @n_order))
                  put_elem(f, field, -offset)
                end),
              else: f

          if n == 3 do
            {field, above, _, offset} = step
            f = f |> put_elem(above, elem(f, above) + 1) |> put_elem(field, -offset)
            {f, _} = apply_date(f)

            if level == 0 and not p.star_year do
              f = skip_years(f, p)
              if elem(f, @year) >= @years, do: {:ok, false, f}, else: recurse(f, p, 0)
            else
              recurse(f, p, 0)
            end
          else
            case apply_date(f) do
              {f, true} -> recurse(f, p, level - 1)
              {f, false} -> advance(f, p, level)
            end
          end
      end
    end
  end

  defp advance(f, p, level) do
    level = level + 1

    cond do
      level >= @n_order -> {:ok, true, f}
      p.star_year and elem(f, @year) >= 3000 -> {:ok, false, f}
      not p.star_year and elem(f, @year) >= @years -> {:ok, false, f}
      true -> recurse(f, p, level)
    end
  end

  defp year_check(f, p, 0) when not p.star_year do
    y = elem(f, @year)

    f =
      if y in 0..(@years - 1) and not Pattern.has_year?(p, y) do
        case Enum.find((y + 1)..(@years - 1)//1, &Pattern.has_year?(p, &1)) do
          nil -> :never
          found -> {found, 0, 1, 0, 0, 0, 0}
        end
      else
        f
      end

    cond do
      f == :never -> {:ok, false, nil}
      elem(f, @year) >= @years -> {:ok, false, f}
      true -> {:ok, f}
    end
  end

  defp year_check(f, _p, _level), do: {:ok, f}

  defp skip_years(f, p) do
    y = elem(f, @year)

    if y in 0..(@years - 1) and not Pattern.has_year?(p, y),
      do: skip_years(put_elem(f, @year, y + 1), p),
      else: f
  end

  @doc """
  Croner's `increment()`: one second on, then the next match. `{:ok, true,
  date}` when there is one, `{:ok, false, _}` when there is none, or croner's
  error.
  """
  @spec increment(t(), Pattern.t()) :: {:ok, boolean(), t() | nil} | {:error, String.t()}
  def increment(f, p) do
    f = f |> put_elem(@second, elem(f, @second) + 1) |> put_elem(@millis, 0)
    {f, _} = apply_date(f)
    recurse(f, p, 0)
  end

  @doc "`getDate(false).getTime()`: the instant this wall-clock time names."
  @spec time_ms(t(), Zone.t()) :: integer()
  def time_ms({y, m, d, h, mi, s, _}, zone), do: Zone.to_utc({y, m + 1, d, h, mi, s}, zone) * 1000
end
