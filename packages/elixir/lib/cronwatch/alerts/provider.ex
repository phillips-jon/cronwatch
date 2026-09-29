defmodule Cronwatch.Alerts.Provider do
  @moduledoc false
  # Reading the provider channels' options: text options, the link, the
  # recovered switch and the clock, each checked the same way.

  @doc "A text option: the binary given, `\"\"` when it is left out or not text."
  def str(opts, key) do
    case Keyword.get(opts, key) do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  @doc "A credential: trimmed of the spaces and newlines a paste leaves."
  def secret(opts, key), do: Cronwatch.Alerts.Shared.trimmed(Keyword.get(opts, key))

  @doc "The `:link` option: nil or a function of the alert."
  def link(module, opts) do
    case Keyword.get(opts, :link) do
      nil -> {:ok, nil}
      f when is_function(f, 1) -> {:ok, f}
      _ -> {:error, "#{inspect(module)} needs :link to be a function of the alert"}
    end
  end

  @doc "A boolean option, `default` when it is left out."
  def flag(module, opts, key, default) do
    case Keyword.get(opts, key, default) do
      b when is_boolean(b) -> {:ok, b}
      _ -> {:error, "#{inspect(module)} needs #{inspect(key)} to be true or false"}
    end
  end

  @doc "The `:now` option (a clock in epoch milliseconds, for tests): nil or a function of no arguments."
  def clock(module, opts) do
    case Keyword.get(opts, :now) do
      nil -> {:ok, nil}
      f when is_function(f, 0) -> {:ok, f}
      _ -> {:error, "#{inspect(module)} needs :now to be a function of no arguments"}
    end
  end

  @doc "The time now in epoch milliseconds, from the clock when there is one."
  def now(nil), do: System.os_time(:millisecond)
  def now(f), do: f.()

  @doc """
  Checks that the options are a keyword list, and the `:transport` given.
  The refusal never quotes the options, since they hold the channel's
  credentials.
  """
  def keyword(module, opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      with :ok <- Cronwatch.Transport.check(Keyword.get(opts, :transport), inspect(module)), do: {:ok, opts}
    else
      {:error, "#{inspect(module)} takes a keyword list of options"}
    end
  end

  @doc "`text` when it is not empty, else `default`."
  def or_default("", default), do: default
  def or_default(text, _default), do: text
end
