defmodule Cronwatch.Env do
  @moduledoc false
  # The environment, read in one place and when used, never when a module is
  # compiled: the first of CRONWATCH_ENV, APP_ENV, and MIX_ENV set to more
  # than spaces, trimmed and lowercased, as every CronWatch library reads it.
  # Mix.env/0 is not read, since Mix is absent from a release.

  @vars ["CRONWATCH_ENV", "APP_ENV", "MIX_ENV"]
  @development ~w(development dev local test testing)
  @production ~w(production prod)

  @doc "The environment's name, trimmed and lowercased, or nil."
  def name do
    Enum.find_value(@vars, fn var ->
      case System.get_env(var) do
        nil ->
          nil

        value ->
          case Cronwatch.JS.trim(value) do
            "" -> nil
            value -> String.downcase(value)
          end
      end
    end)
  end

  @doc """
  The environment: `"development"` (development, dev, local, test, or
  testing), `"production"` (production or prod), another name as it is, or
  nil when none is set.
  """
  def environment do
    case name() do
      name when name in @development -> "development"
      name when name in @production -> "production"
      name -> name
    end
  end

  @doc "Whether this is development."
  def development?, do: environment() == "development"

  @doc "Whether this is production."
  def production?, do: environment() == "production"

  @doc "A variable, with an empty value counting as unset."
  def read(var) do
    case System.get_env(var) do
      "" -> nil
      value -> value
    end
  end

  @doc """
  A secret from the environment (`CRONWATCH_TOKEN`, `CRON_SECRET`): nil when
  the variable is unset, empty, or only whitespace (as JavaScript's trim sees
  it), so a blank value counts as not set and the dashboard and handlers
  fail closed. Any other value is used as it is, untrimmed.
  """
  def read_secret(var), do: var |> System.get_env() |> secret()

  @doc "A secret given as a string: nil when it is nil, empty, or only whitespace, else as it is."
  def secret(value) when is_binary(value), do: if(Cronwatch.JS.trim(value) == "", do: nil, else: value)
  def secret(_), do: nil
end
