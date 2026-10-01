defmodule Cronwatch.Bridge do
  @moduledoc """
  What the scheduler integrations share (`Cronwatch.Oban`,
  `Cronwatch.Quantum`), carried over from the Go and Rust ports' bridge. An
  app does not need it; a scheduler integration of your own can.

  For integration authors, outside the 1.x promise: the bridge changes
  whenever an integration needs something, so it can change in any release.
  A scheduler integration of your own builds on it at its own risk.

    * `Cronwatch.Bridge.Watch` declares a scheduler's entries as jobs, one
      per name, tagged with the integration and the app, and declares a job
      whose entry is gone again without its schedule, so it is never
      reported missed.
    * `check_fires/7` checks a schedule taken from a scheduler against the
      scheduler's own fire times.
    * `options_of/1` and `unscheduled/1` are the job options that declare a
      stored definition again, as it is or without its schedule.

  Which jobs are this app's is told by two tags, the integration's (`oban`)
  and the app's under it (`oban:<app>`, see `app_tag/2`), so two apps
  sharing one store never declare each other's jobs without a schedule.
  That is the PHP port's rule for Laravel and Symfony, as the Go and Rust
  ports have it.
  """

  alias Cronwatch.Error
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.JSRE

  @doc """
  The app's name for its tag: `$CRONWATCH_APP_ID` when set, else the OTP
  application of the calling process (the one whose supervision tree
  started it), else `"cronwatch"`. Two apps that share a store and have the
  same OTP application name need `CRONWATCH_APP_ID` (or the integration's
  `app` option) to tell them apart; every node of one app needs the same.
  """
  @spec app_name() :: String.t()
  def app_name do
    case System.get_env("CRONWATCH_APP_ID") do
      id when is_binary(id) and id != "" ->
        case String.trim(id) do
          "" -> own_app()
          trimmed -> trimmed
        end

      _ ->
        own_app()
    end
  end

  defp own_app do
    case :application.get_application() do
      {:ok, app} -> Atom.to_string(app)
      :undefined -> "cronwatch"
    end
  end

  @doc """
  The tag that names the app under an integration's tag: `<tag>:<app>`, the
  app's name lowercased, with anything but letters, digits, `.`, `_` and `-`
  made `-`. A name that is empty once cleaned, or longer than 48
  characters, is cut and given 8 hex characters of its MD5, so two names
  never share a tag. The PHP port's `appTag()`, character for character.
  """
  @spec app_tag(String.t(), String.t()) :: String.t()
  def app_tag(tag, app) do
    # PHP's trim() set, and ASCII letters only, as PHP 8's strtolower (so the
    # Kelvin sign is not a "k").
    trimmed = php_trim(app)

    {slug, _} =
      for <<c::utf8 <- trimmed>>, reduce: {"", false} do
        {acc, run} ->
          c = if c in ?A..?Z, do: c + 32, else: c

          cond do
            c in ?a..?z or c in ?0..?9 or c in [?., ?_, ?-] -> {acc <> <<c>>, false}
            run -> {acc, true}
            true -> {acc <> "-", true}
          end
      end

    slug = trim_dashes(slug)

    slug =
      if slug == "" or byte_size(slug) > 48 do
        sum = :crypto.hash(:md5, app) |> binary_part(0, 4) |> Base.encode16(case: :lower)
        cut = slug |> binary_part(0, min(byte_size(slug), 39))
        prefix = String.trim_leading(cut <> "-", "-")
        prefix <> sum
      else
        slug
      end

    "#{tag}:#{slug}"
  end

  @php_space [?\s, ?\t, ?\n, ?\r, 0, 0x0B]

  defp php_trim(s), do: s |> trim_lead(@php_space) |> trim_trail(@php_space)

  defp trim_dashes(s), do: s |> trim_lead([?-]) |> trim_trail([?-])

  defp trim_lead(<<c, rest::binary>>, set) do
    if c in set, do: trim_lead(rest, set), else: <<c, rest::binary>>
  end

  defp trim_lead("", _set), do: ""

  defp trim_trail(s, set) do
    size = byte_size(s)

    if size > 0 and :binary.last(s) in set,
      do: trim_trail(binary_part(s, 0, size - 1), set),
      else: s
  end

  @doc """
  Whether `name` is a CronWatch job name: 1 to 120 letters, digits, `.`,
  `_`, `:` or `-`, starting with a letter or digit.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: Cronwatch.Options.valid_name?(name)

  @doc """
  What `Cronwatch.job/2` would refuse a job declared with `options` for (its
  name, or an option the SDK refuses, with the SDK's message), without
  declaring anything, so an integration can refuse to watch a scheduler job
  whose runs it could not record.
  """
  @spec validate(String.t(), keyword()) :: :ok | {:error, Error.t()}
  def validate(name, options) do
    with {:ok, _} <- Cronwatch.Options.definition(name, options, []), do: :ok
  end

  @doc "An interval in milliseconds as CronWatch's schedule text, exact to the millisecond: `every 1h30m`."
  @spec every_text(non_neg_integer()) :: String.t()
  def every_text(ms) when is_integer(ms) and ms >= 0 do
    {out, _} =
      Enum.reduce([{"d", 86_400_000}, {"h", 3_600_000}, {"m", 60_000}, {"s", 1000}, {"ms", 1}], {"", ms}, fn
        {name, size}, {out, left} when left >= size -> {out <> "#{div(left, size)}#{name}", rem(left, size)}
        _, acc -> acc
      end)

    if out == "", do: "every 0ms", else: "every " <> out
  end

  @doc """
  `:ok`, or `{:error, message}` for a cron CronWatch would not expect runs
  of when the scheduler makes them. `runs` is the scheduler's own reading:
  given `start` and `finish` (epoch milliseconds, `finish` nil for a
  sample), `{:ok, times}` with the run at or before `start` and every one
  after it up to the first past `finish`, or a sample of them after that
  first one when `finish` is nil, ascending; `never_fires/1` for a schedule
  that never fires again, or `{:error, message}`. `expr` and `zone` are the
  schedule as CronWatch reads it (`zone` `""` for the process's own),
  `where` names the job and `scheduler` the scheduler in messages. `daily`
  is a cron that names no day or month, which meets every clock change of
  one kind alike, so one of each is walked. `now` is the epoch milliseconds
  the horizon starts from.
  """
  defdelegate check_fires(runs, expr, zone, where, scheduler, daily, now), to: Cronwatch.Bridge.Check

  @doc "What a `runs` function given to `check_fires/7` answers for a schedule that never fires again."
  defdelegate never_fires(why), to: Cronwatch.Bridge.Check

  # The options a job keeps when it is declared again without its schedule,
  # as the PHP, Go and Rust ports keep them.
  @kept ["tags", "grace", "timeout", "maxDuration", "budget", "failuresBeforeAlert"]

  @doc """
  The options that declare a job again without its schedule: its
  description followed by ` (no longer scheduled)` (`A scheduled task` when
  it had none), its tags, grace, timeout, maxDuration, budget and
  failuresBeforeAlert.
  """
  @spec unscheduled(Object.t()) :: keyword()
  def unscheduled(%Object{} = definition) do
    description =
      case Object.get(definition, "description") do
        text when is_binary(text) and text != "" -> text
        _ -> "A scheduled task"
      end

    description =
      if String.ends_with?(description, " (no longer scheduled)"),
        do: description,
        else: description <> " (no longer scheduled)"

    [description: description] ++ Enum.flat_map(@kept, &field(definition, &1))
  end

  @doc """
  The options that declare a stored definition again, in its order:
  schedule, timezone, grace, timeout, maxDuration, budget,
  failuresBeforeAlert, description, tags, and expect (`contains` as a
  string, a pattern as a pattern of the same source, run by the JavaScript
  regular expression engine the redaction uses, and a custom function as
  one that passes every output, since the function is the other
  process's). Fields no option gives are left out.
  """
  @spec options_of(Object.t()) :: keyword()
  def options_of(%Object{} = definition) do
    Enum.flat_map(Object.keys(definition), fn
      key when key in ["schedule", "timezone", "description"] ->
        case Object.get(definition, key) do
          text when is_binary(text) -> [{String.to_existing_atom(key), text}]
          _ -> []
        end

      "expect" ->
        expect_of(Object.get(definition, "expect"))

      key ->
        field(definition, key)
    end)
  end

  # One of the fields unscheduled keeps, as stored: a duration's text as
  # text and a number of milliseconds as a number, a budget in the order its
  # metrics were given.
  defp field(definition, key) do
    value = Object.get(definition, key)

    case {key, value} do
      {"tags", tags} when is_list(tags) -> [tags: Enum.filter(tags, &is_binary/1)]
      {"grace", d} when is_binary(d) or is_number(d) -> [grace: d]
      {"timeout", d} when is_binary(d) or is_number(d) -> [timeout: d]
      {"maxDuration", d} when is_binary(d) or is_number(d) -> [max_duration: d]
      {"budget", %Object{} = b} -> [budget: for({k, v} <- Object.to_list(b), is_number(v), do: {k, v})]
      {"failuresBeforeAlert", n} when is_integer(n) and n >= 0 -> [failures_before_alert: n]
      _ -> []
    end
  end

  # The expect rule a stored description came from.
  defp expect_of("contains " <> rest) do
    case JS.parse(rest) do
      {:ok, text} when is_binary(text) -> [expect: text]
      _ -> []
    end
  end

  defp expect_of("matches " <> source), do: [expect: {:matches, stored_pattern(source)}]
  defp expect_of("custom function"), do: [expect: fn _ -> true end]
  defp expect_of(_), do: []

  # A pattern as another process stored it, `/source/flags`: run by the
  # JavaScript engine when it can read it, and passing every output when it
  # cannot, so the definition written back is the one stored. A match that
  # gives up (past the step budget or its 512 frames) counts as not
  # matching, so the run fails as it would on an engine that finished.
  defp stored_pattern(text) do
    parsed =
      with "/" <> rest <- text,
           [_ | _] = parts <- :binary.matches(rest, "/"),
           {at, 1} = List.last(parts),
           body = binary_part(rest, 0, at),
           flags = binary_part(rest, at + 1, byte_size(rest) - at - 1),
           {:ok, re} <- JSRE.compile(body, flags) do
        re
      else
        _ -> nil
      end

    parsed || passing(text)
  end

  # An empty pattern (it matches every output) that describes itself as the
  # stored one.
  defp passing(text) do
    {source, flags} =
      case text do
        "/" <> rest ->
          case :binary.matches(rest, "/") do
            [] ->
              {rest, ""}

            parts ->
              {at, 1} = List.last(parts)
              {binary_part(rest, 0, at), binary_part(rest, at + 1, byte_size(rest) - at - 1)}
          end

        other ->
          {other, ""}
      end

    # A description not of the form /source/flags is kept byte for byte.
    if "/#{source}/#{flags}" == text,
      do: %{JSRE.compile!("", "") | source: source, flags: flags},
      else: %{JSRE.compile!("", "") | source: String.trim_leading(text, "/"), flags: ""}
  end
end
