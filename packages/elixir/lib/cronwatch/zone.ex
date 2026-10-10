defmodule Cronwatch.Zone do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # Time zones for the croner port, from `tz`'s copy of the IANA database,
  # named as `Intl` names them: without regard to case, so
  # `"america/new_york"` is New York, as `Intl.DateTimeFormat` reads it. A fixed
  # offset (`"+05:30"`, `"-0800"`, `"+05"`) is a zone too, since `Intl` and
  # croner both take one.
  #
  # Tz.TimeZoneDatabase is called directly, for the offset at an instant;
  # the app's `config :elixir, :time_zone_database` is never read or set.
  # Without a name, a zone is the process's own: `$TZ` when it names a zone,
  # else the zone `/etc/localtime` links to, else UTC.

  alias Cronwatch.JS

  @typedoc "A zone: UTC, a fixed offset in seconds, or an IANA zone by its database name."
  @type t :: :utc | {:fixed, integer()} | {:tz, String.t()}

  @typedoc "A wall-clock time: year, month (1 to 12), day, hour, minute, second."
  @type wall :: {integer(), integer(), integer(), integer(), integer(), integer()}

  # The names tz's database lists (zones and links), by their lowercase
  # spelling, read from the same IANA files tz compiles, so a name in any
  # case finds its database spelling.
  tz_dir =
    (fn ->
       dir = Application.compile_env(:tz, :data_dir) || to_string(:code.priv_dir(:tz))
       forced = Application.compile_env(:tz, :iana_version)

       names =
         case File.ls(dir) do
           {:ok, names} -> Enum.filter(names, &Regex.match?(~r/^tzdata20[0-9]{2}[a-z]$/, &1))
           _ -> []
         end

       chosen = if forced, do: Enum.find(names, &(&1 == "tzdata#{forced}")), else: Enum.max(names, fn -> nil end)
       if chosen, do: Path.join(dir, chosen)
     end).()

  files = ~w(africa antarctica asia australasia backward etcetera europe northamerica southamerica)

  names =
    if tz_dir do
      for file <- files,
          path = Path.join(tz_dir, file),
          File.exists?(path),
          line <- path |> File.read!() |> String.split("\n"),
          name <-
            (case String.split(line, ~r/\s+/, trim: true) do
               ["Zone", name | _] -> [name]
               ["Link", _target, name | _] -> [name]
               _ -> []
             end),
          do: name
    else
      []
    end

  for file <- files, tz_dir, do: @external_resource(Path.join(tz_dir, file))

  @names Map.new(names, &{String.downcase(&1), &1})

  # jiff's range, the years -9999 to 9999: past it, the offset at its end.
  @min_sec -377_705_116_800
  @max_sec 253_402_300_799

  # 0000-01-01 to 1970-01-01, in days, for Calendar's ISO days.
  @epoch_days 719_528

  @doc """
  The zone a name names, matched without regard to case as `Intl` matches it,
  or a fixed offset; `nil` or `""` is the process's own zone. `{:error,
  message}` for a name that is no zone.
  """
  @spec load(String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def load(nil), do: {:ok, system()}
  def load(""), do: {:ok, system()}

  def load(name) when is_binary(name) do
    case find(name) do
      nil -> {:error, "unknown time zone #{JS.quote(name)}"}
      zone -> {:ok, zone}
    end
  end

  @doc """
  Whether `new Intl.DateTimeFormat("en-US", { timeZone })` accepts the name:
  an IANA zone in any case, `"UTC"`, or a fixed offset such as `"+05:30"`.
  """
  @spec zone?(term()) :: boolean()
  def zone?(name) when is_binary(name) and name != "", do: find(name) != nil
  def zone?(_), do: false

  defp find(name) do
    cond do
      String.contains?(name, <<0>>) -> nil
      String.downcase(name) in ["local", "etc/unknown"] -> nil
      fixed = fixed_offset(name) -> fixed
      String.downcase(name) == "utc" -> :utc
      true -> named(name)
    end
  end

  defp named(name) do
    cond do
      known?(name) -> {:tz, name}
      (spelled = Map.get(@names, String.downcase(name))) && known?(spelled) -> {:tz, spelled}
      true -> nil
    end
  end

  defp known?(name), do: match?({:ok, _}, Tz.PeriodsProvider.periods(name))

  # "+HH", "+HHMM", or "+HH:MM" (or "-"), as Intl reads an offset time zone.
  defp fixed_offset(<<sign, rest::binary>>) when sign in [?+, ?-] do
    parts =
      case rest do
        <<h::binary-size(2)>> -> {h, "00"}
        <<h::binary-size(2), m::binary-size(2)>> -> {h, m}
        <<h::binary-size(2), ?:, m::binary-size(2)>> -> {h, m}
        _ -> nil
      end

    with {hh, mm} <- parts,
         true <- digits?(hh) and digits?(mm),
         {h, m} = {String.to_integer(hh), String.to_integer(mm)},
         true <- h <= 23 and m <= 59 do
      sec = (h * 60 + m) * 60
      {:fixed, if(sign == ?-, do: -sec, else: sec)}
    else
      _ -> nil
    end
  end

  defp fixed_offset(_), do: nil

  defp digits?(s), do: s |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9))

  @doc """
  The process's own zone: `$TZ` when it names a zone (a leading `:` aside),
  else the zone `/etc/localtime` links to, else UTC.
  """
  @spec system() :: t()
  def system do
    from_env =
      case System.get_env("TZ") do
        nil -> nil
        "" -> nil
        ":" <> name -> find(name)
        name -> find(name)
      end

    from_env || localtime() || :utc
  end

  defp localtime do
    case File.read_link("/etc/localtime") do
      {:ok, target} ->
        case String.split(target, "zoneinfo/", parts: 2) do
          [_, name] -> named(name)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "The seconds the zone's wall clock is ahead of UTC at epoch second `sec`."
  @spec offset(integer(), t()) :: integer()
  def offset(_sec, :utc), do: 0
  def offset(_sec, {:fixed, seconds}), do: seconds

  def offset(sec, {:tz, name}) do
    sec = sec |> max(@min_sec) |> min(@max_sec)
    days = Integer.floor_div(sec, 86_400)
    rest = sec - days * 86_400
    iso_days = {days + @epoch_days, {rest * 1_000_000, 86_400_000_000}}

    case Tz.TimeZoneDatabase.time_zone_period_from_utc_iso_days(iso_days, name) do
      {:ok, %{utc_offset: utc, std_offset: std}} -> utc + std
      _ -> 0
    end
  end

  @doc "The wall clock at an epoch second."
  @spec wall_at(integer(), t()) :: wall()
  def wall_at(sec, zone) do
    local = sec + offset(sec, zone)
    days = Integer.floor_div(local, 86_400)
    rest = local - days * 86_400
    {y, m, d} = JS.civil_from_days(days)
    {y, m, d, div(rest, 3600), rem(rest, 3600) |> div(60), rem(rest, 60)}
  end

  # A wall-clock time read as if it were UTC, in epoch seconds (croner's T()).
  defp civil_seconds({y, m, d, h, mi, s}), do: Integer.floor_div(JS.date_utc(y, m - 1, d, h, mi, s, 0), 1000)

  @doc """
  Croner's `fromTZ`: the instant a wall-clock time names, in epoch seconds. A
  time in a spring-forward gap moves forward by the gap; a time that happens
  twice (fall back) is the earlier of the two.
  """
  @spec to_utc(wall(), t()) :: integer()
  def to_utc(w, zone) do
    target = civil_seconds(w)
    guess = target + (target - civil_seconds(wall_at(target, zone)))
    seen = wall_at(guess, zone)

    if seen == w do
      earlier = guess - 3600
      if wall_at(earlier, zone) == w, do: earlier, else: guess
    else
      shifted = guess + target - civil_seconds(seen)
      if wall_at(shifted, zone) == w, do: shifted, else: max(guess, shifted)
    end
  end
end
