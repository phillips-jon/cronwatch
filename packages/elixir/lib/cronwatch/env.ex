defmodule Cronwatch.Env do
  @moduledoc false
  # The environment, read in one place and when used, never when a module is
  # compiled: the first of CRONWATCH_ENV, APP_ENV and MIX_ENV that is set.
  # Mix.env/0 is not read, since Mix is absent from a release.

  @development ~w(development dev local test testing)

  @doc "The environment's name, or nil."
  def name do
    Enum.find_value(["CRONWATCH_ENV", "APP_ENV", "MIX_ENV"], fn var ->
      case System.get_env(var) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  @doc "Whether this is development: development, dev, local, test or testing."
  def development?, do: name() in @development

  @doc "Whether this is production: production or prod."
  def production?, do: name() in ["production", "prod"]

  @doc "A variable, with an empty value counting as unset."
  def read(var) do
    case System.get_env(var) do
      "" -> nil
      value -> value
    end
  end
end
