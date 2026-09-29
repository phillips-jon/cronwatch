defmodule Cronwatch.Error do
  @moduledoc """
  What a CronWatch function answers with `{:error, %Cronwatch.Error{}}`, or
  raises from its `!` variant.

  `kind` is `:invalid` for what the SDK refuses (a bad job name, option,
  schedule or duration), with the SDK's message; `:store` for the store
  failing, with the store's own error as `reason`; `:other` for anything
  else.
  """

  defexception [:kind, :message, :reason]

  @type t :: %__MODULE__{kind: :invalid | :store | :other, message: String.t(), reason: term()}

  @doc false
  def invalid(message), do: %__MODULE__{kind: :invalid, message: message}

  @doc false
  def store(reason), do: %__MODULE__{kind: :store, message: describe(reason), reason: reason}

  @doc false
  def other(message, reason \\ nil), do: %__MODULE__{kind: :other, message: message, reason: reason}

  @doc false
  def describe(%{__exception__: true} = e), do: Exception.message(e)
  def describe({:exit, reason}), do: "exit: " <> describe(reason)
  def describe({:throw, value}), do: "throw: " <> describe(value)
  def describe(s) when is_binary(s), do: s
  def describe(other), do: inspect(other)
end
