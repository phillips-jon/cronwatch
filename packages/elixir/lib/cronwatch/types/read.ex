defmodule Cronwatch.Types.Read do
  @moduledoc false
  # Reading the SDK's JSON as the SDK reads it: a field of the wrong type is
  # read as JavaScript's coercions would leave it, never as an error, so a
  # row another writer shaped differently does not fail every read.

  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  def str(%Object{} = o, key) do
    case Object.get(o, key) do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  def nullable_str(%Object{} = o, key) do
    case Object.get(o, key) do
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  def number?(v), do: is_number(v) or v in [:infinity, :neg_infinity, :nan]

  def int(%Object{} = o, key) do
    case Object.get(o, key) do
      v -> if number?(v), do: JS.to_int(v), else: 0
    end
  end

  def nullable_int(%Object{} = o, key) do
    v = Object.get(o, key)
    if number?(v), do: JS.to_int(v)
  end

  def float(%Object{} = o, key) do
    v = Object.get(o, key)
    if number?(v), do: v, else: :nan
  end

  def object(%Object{} = o, key) do
    case Object.get(o, key) do
      %Object{} = v -> v
      _ -> Object.new()
    end
  end

  def kind(nil), do: "null"
  def kind(b) when is_boolean(b), do: "boolean"
  def kind(s) when is_binary(s), do: "string"
  def kind(v), do: if(number?(v), do: "number", else: "object")

  def parse(text) do
    case JS.parse(text) do
      {:ok, v} -> {:ok, v}
      {:error, message} -> {:error, message}
    end
  end
end

defmodule Cronwatch.Metrics do
  @moduledoc """
  A run's numbers, as a `Cronwatch.JS.Object` in JavaScript's key order: names
  that are array indices (`"10"`, `"200"`) first in ascending order, then the
  rest in the order they were first reported. Budgets use the same shape.
  """

  alias Cronwatch.JS.Object
  alias Cronwatch.Types.Read

  @type t :: Object.t()

  @doc "Reads a JSON object of numbers; `nil` is none."
  @spec from_value(term()) :: {:ok, t()} | {:error, String.t()}
  def from_value(nil), do: {:ok, Object.new()}

  # An object's pairs are already in order, each key once, so they are kept
  # as they are rather than set again one at a time.
  def from_value(%Object{pairs: pairs} = o) do
    case Enum.find(pairs, fn {_, v} -> not Read.number?(v) end) do
      nil -> {:ok, o}
      {k, v} -> {:error, "metric #{Cronwatch.JS.quote(k)} must be a number, not #{Read.kind(v)}"}
    end
  end

  def from_value(v), do: {:error, "metrics must be an object, not #{Read.kind(v)}"}

  @doc """
  A stored row's metrics as the SDK reads them: the numbers of an object,
  whatever else it holds, and none for anything else.
  """
  @spec lenient(term()) :: t()
  def lenient(%Object{pairs: pairs}), do: %Object{pairs: Enum.filter(pairs, fn {_, v} -> Read.number?(v) end)}

  def lenient(_), do: Object.new()
end
