defmodule Cronwatch.Options do
  @moduledoc false
  # Job options: an ordered keyword list turned into the stored definition,
  # the SDK's JSON object with its fields in the order they were given
  # ({ ...defaults, ...options, name }, expect moved last), and checked as the
  # SDK's validateDefinition checks it.

  alias Cronwatch.Duration
  alias Cronwatch.Error
  alias Cronwatch.Format
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Schedule
  alias Cronwatch.Serialize

  @keys %{
    schedule: "schedule",
    timezone: "timezone",
    grace: "grace",
    timeout: "timeout",
    max_duration: "maxDuration",
    budget: "budget",
    floor: "floor",
    expect: "expect",
    failures_before_alert: "failuresBeforeAlert",
    description: "description",
    tags: "tags"
  }

  @default_keys [:grace, :timeout, :timezone, :failures_before_alert]

  @doc "The option names a job takes."
  def keys, do: Map.keys(@keys)

  @doc "Whether a job name is 1 to 120 characters of letters, digits, ., _, :, or -, starting with a letter or digit."
  def valid_name?(name) when is_binary(name), do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,119}\z/, name)
  def valid_name?(_), do: false

  @doc """
  The definition of a job: `{:ok, {fields, rule}}` where `fields` is the
  definition without expect (name last) and `rule` the expect rule or nil,
  or `{:error, %Cronwatch.Error{}}`.
  """
  def definition(name, options, defaults) do
    with :ok <- check_name(name),
         {:ok, default_pairs} <- pairs(name, defaults, @default_keys),
         {:ok, pairs} <- pairs(name, options, Map.keys(@keys)) do
      {expect, pairs} = pop_expect(default_pairs ++ pairs)
      fields = Object.put(Object.new(pairs), "name", name)

      with {:ok, rule} <- expect_rule(name, expect),
           :ok <- validate(name, fields) do
        {:ok, {fields, rule}}
      end
    end
  end

  @doc "Checks the instance's `defaults:` option."
  def check_defaults(defaults) do
    with {:ok, _} <- pairs("defaults", defaults, @default_keys), do: :ok
  end

  defp check_name(name) do
    if valid_name?(name) do
      :ok
    else
      text = if is_binary(name), do: name, else: inspect(name)

      {:error,
       Error.invalid(
         ~s(job name #{JS.quote(text)} must be 1 to 120 characters of letters, digits, ".", "_", ":", or "-")
       )}
    end
  end

  defp pop_expect(pairs) do
    case Enum.filter(pairs, fn {k, _} -> k == "expect" end) do
      [] -> {:none, pairs}
      found -> {elem(List.last(found), 1), Enum.reject(pairs, fn {k, _} -> k == "expect" end)}
    end
  end

  defp expect_rule(_name, :none), do: {:ok, nil}

  defp expect_rule(name, value) do
    case Serialize.rule(value) do
      {:ok, rule} -> {:ok, rule}
      {:error, message} -> {:error, Error.invalid("job #{JS.quote(name)}: #{message}")}
    end
  end

  # The options as JSON pairs, in the order given.
  defp pairs(name, options, allowed) when is_list(options) do
    Enum.reduce_while(options, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        if key in allowed do
          case json_value(name, key, value) do
            {:ok, v} -> {:cont, {:ok, acc ++ [{@keys[key], v}]}}
            {:error, _} = e -> {:halt, e}
          end
        else
          {:halt, {:error, Error.invalid("job #{JS.quote(to_string(name))}: unknown option #{inspect(key)}")}}
        end

      other, _ ->
        {:halt,
         {:error,
          Error.invalid("job #{JS.quote(to_string(name))}: options must be a keyword list, not #{inspect(other)}")}}
    end)
  end

  defp pairs(name, %{} = options, allowed) when not is_struct(options),
    do: pairs(name, options |> Map.to_list() |> Enum.sort(), allowed)

  defp pairs(name, nil, allowed), do: pairs(name, [], allowed)

  defp pairs(name, other, _allowed),
    do:
      {:error, Error.invalid("job #{JS.quote(to_string(name))}: options must be a keyword list, not #{inspect(other)}")}

  defp json_value(name, key, value) when key in [:grace, :timeout, :max_duration] do
    case duration_value(value) do
      {:ok, v} -> {:ok, v}
      {:error, message} -> {:error, Error.invalid("job #{JS.quote(to_string(name))}: #{@keys[key]} #{message}")}
    end
  end

  defp json_value(name, key, value) when key in [:budget, :floor] do
    list =
      cond do
        is_list(value) -> value
        is_map(value) and not is_struct(value) -> value |> Map.to_list() |> Enum.sort()
        true -> :bad
      end

    if list == :bad or not Enum.all?(list, &match?({k, _} when is_atom(k) or is_binary(k), &1)) do
      what =
        if key == :budget,
          do: "budget must be an object of { metric: ceiling }",
          else: "floor must be an object of { metric: floor }"

      {:error, Error.invalid("job #{JS.quote(to_string(name))}: #{what}")}
    else
      {:ok, Object.new(Enum.map(list, fn {k, v} -> {to_string(k), normalize(v)} end))}
    end
  end

  defp json_value(_name, :tags, value) when is_list(value), do: {:ok, value}
  defp json_value(_name, :expect, value), do: {:ok, value}
  defp json_value(_name, _key, value) when is_number(value), do: {:ok, JS.normalize(value)}
  defp json_value(_name, _key, value), do: {:ok, value}

  defp normalize(v) when is_number(v), do: JS.normalize(v)
  defp normalize(v), do: v

  @doc """
  A duration option as stored: the SDK's text as written, a number of
  milliseconds as it is, and anything `to_timeout/1` takes (a `Duration`, a
  keyword list of units) as its milliseconds.
  """
  def duration_value(value) when is_binary(value), do: {:ok, value}
  def duration_value(value) when is_number(value), do: {:ok, JS.normalize(value)}

  def duration_value(value) when is_struct(value, Elixir.Duration) or (is_list(value) and value != []) do
    {:ok, to_timeout(value)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  def duration_value(value), do: {:ok, value}

  @doc "A duration given to the API (a silence, the retention, an interval) as milliseconds."
  def duration_ms(value, label) do
    case duration_value(value) do
      {:ok, v} ->
        case Duration.parse(v, label) do
          {:ok, ms} -> {:ok, ms}
          {:error, message} -> {:error, Error.invalid(message)}
        end

      {:error, message} ->
        {:error, Error.invalid("#{label} #{message}")}
    end
  end

  # The SDK's error for options that would otherwise quietly turn a check
  # off, over the definition's JSON.
  defp validate(name, def) do
    quoted = JS.quote(name)
    invalid = fn message -> {:error, Error.invalid(message)} end

    with :ok <- check_schedule(quoted, def),
         :ok <- check_timezone(quoted, def),
         :ok <- check_duration(def, "grace", fn _ -> :ok end),
         :ok <-
           check_duration(def, "timeout", fn ms ->
             if ms <= 0, do: invalid.("job #{quoted}: timeout must be longer than zero"), else: :ok
           end),
         :ok <-
           check_duration(def, "maxDuration", fn ms ->
             if ms <= 0, do: invalid.("job #{quoted}: maxDuration must be longer than zero"), else: :ok
           end),
         :ok <- check_failures(quoted, def),
         :ok <- check_budget(quoted, def),
         :ok <- check_floor(quoted, def) do
      check_tags(quoted, def)
    end
  end

  defp check_schedule(quoted, def) do
    case Object.fetch(def, "schedule") do
      :error ->
        :ok

      {:ok, text} when is_binary(text) ->
        if JS.trim(text) == "" do
          {:error, Error.invalid("job #{quoted}: schedule must be a non-empty string")}
        else
          # The zone is checked on its own below, with the SDK's message.
          tz =
            case Object.get(def, "timezone") do
              tz when is_binary(tz) and tz != "" -> if Schedule.timezone?(tz), do: tz
              _ -> nil
            end

          case Schedule.parse(text, tz) do
            {:ok, _} -> :ok
            {:error, message} -> {:error, Error.invalid(message)}
          end
        end

      _ ->
        {:error, Error.invalid("job #{quoted}: schedule must be a non-empty string")}
    end
  end

  defp check_timezone(quoted, def) do
    case Object.fetch(def, "timezone") do
      :error ->
        :ok

      {:ok, tz} ->
        if is_binary(tz) and Schedule.timezone?(tz),
          do: :ok,
          else:
            {:error, Error.invalid("job #{quoted}: timezone #{JS.quote(Format.js_text(tz))} is not an IANA timezone")}
    end
  end

  defp check_duration(def, key, then) do
    case Object.fetch(def, key) do
      :error ->
        :ok

      {:ok, v} ->
        case Duration.parse(v, key) do
          {:ok, ms} -> then.(ms)
          {:error, message} -> {:error, Error.invalid(message)}
        end
    end
  end

  defp check_failures(quoted, def) do
    case Object.fetch(def, "failuresBeforeAlert") do
      :error ->
        :ok

      {:ok, n} ->
        if JS.integer?(n) and n >= 1,
          do: :ok,
          else:
            {:error,
             Error.invalid(
               "job #{quoted}: failuresBeforeAlert must be a whole number, 1 or more (got #{Format.js_text(n)})"
             )}
    end
  end

  defp check_budget(quoted, def) do
    case Object.get(def, "budget") do
      %Object{pairs: pairs} ->
        Enum.reduce_while(pairs, :ok, fn {metric, v}, :ok ->
          if is_number(v) and v >= 0,
            do: {:cont, :ok},
            else:
              {:halt,
               {:error,
                Error.invalid(
                  "job #{quoted}: budget.#{metric} must be a finite number, 0 or more (got #{Format.js_text(v)})"
                )}}
        end)

      _ ->
        :ok
    end
  end

  defp check_floor(quoted, def) do
    budget =
      case Object.get(def, "budget") do
        %Object{} = b -> b
        _ -> Object.new()
      end

    case Object.get(def, "floor") do
      %Object{pairs: pairs} ->
        Enum.reduce_while(pairs, :ok, fn {metric, v}, :ok ->
          cond do
            not is_number(v) ->
              {:halt,
               {:error,
                Error.invalid("job #{quoted}: floor.#{metric} must be a finite number (got #{Format.js_text(v)})")}}

            match?({:ok, c} when is_number(c) and v > c, Object.fetch(budget, metric)) ->
              {:halt,
               {:error,
                Error.invalid(
                  "job #{quoted}: floor.#{metric} (#{Format.js_text(v)}) is above budget.#{metric} (#{Format.js_text(Object.get(budget, metric))}), so every run would alert"
                )}}

            true ->
              {:cont, :ok}
          end
        end)

      _ ->
        :ok
    end
  end

  defp check_tags(quoted, def) do
    case Object.fetch(def, "tags") do
      {:ok, tags} when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1),
          do: :ok,
          else: {:error, Error.invalid("job #{quoted}: tags must be a list of strings")}

      _ ->
        :ok
    end
  end

  @doc "The stored definition: the fields with expect described last."
  def to_stored(fields, rule), do: Serialize.to_stored(fields, rule)
end
