defmodule Cronwatch.JS.Object do
  @moduledoc """
  A JavaScript object: keys in JavaScript's order, which is every key that is
  an array index (a canonical whole number below 2^32 - 1) in ascending order,
  then every other key in the order it was first set.

  Elixir maps have no order, so every JSON object CronWatch reads or writes is
  one of these, and is written in that order.
  """

  defstruct pairs: []

  @type t :: %__MODULE__{pairs: [{String.t(), value()}]}

  @typedoc "A JSON value: JavaScript's numbers include its infinities and NaN."
  @type value :: nil | boolean() | number_value() | String.t() | [value()] | t()

  @typedoc "A JavaScript number."
  @type number_value :: integer() | float() | :infinity | :neg_infinity | :nan

  @doc "An empty object."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  An object of these pairs, set in turn: a key given twice keeps its first
  place and its last value, as a JavaScript object literal does. A map is set
  in its keys' term order.
  """
  @spec new(Enumerable.t()) :: t()
  def new(pairs) do
    {order, values} =
      Enum.reduce(pairs, {[], %{}}, fn {k, v}, {order, values} ->
        k = to_key(k)
        if Map.has_key?(values, k), do: {order, %{values | k => v}}, else: {[k | order], Map.put(values, k, v)}
      end)

    from_order(Enum.reverse(order), values)
  end

  @doc false
  # The object of these keys, each once, in the order each was first set, and
  # their values: array indices first, in ascending order, then the rest.
  # Setting a key at a time costs a walk of the pairs each, which made an
  # object of many keys (a request body, a stored row) quadratic to read.
  @spec from_order([String.t()], %{String.t() => value()}) :: t()
  def from_order(keys, values) do
    {indices, rest} =
      keys
      |> Enum.map(&{array_index(&1), &1})
      |> Enum.split_with(fn {n, _} -> n != nil end)

    ordered = Enum.map(Enum.sort(indices), &elem(&1, 1)) ++ Enum.map(rest, &elem(&1, 1))
    %__MODULE__{pairs: Enum.map(ordered, &{&1, Map.fetch!(values, &1)})}
  end

  defp to_key(k) when is_binary(k), do: k
  defp to_key(k) when is_atom(k), do: Atom.to_string(k)

  @doc """
  Gives `key` the value: a new key takes its place in JavaScript's order, a
  key already there keeps its place.
  """
  @spec put(t(), String.t(), value()) :: t()
  def put(%__MODULE__{pairs: pairs} = o, key, value) when is_binary(key) do
    case replace(pairs, key, value) do
      {:ok, pairs} ->
        %{o | pairs: pairs}

      :none ->
        case array_index(key) do
          nil -> %{o | pairs: pairs ++ [{key, value}]}
          n -> %{o | pairs: insert_index(pairs, n, {key, value})}
        end
    end
  end

  defp replace([], _key, _value), do: :none
  defp replace([{key, _} | rest], key, value), do: {:ok, [{key, value} | rest]}

  defp replace([pair | rest], key, value) do
    case replace(rest, key, value) do
      {:ok, rest} -> {:ok, [pair | rest]}
      :none -> :none
    end
  end

  # Before the first key that is not an index or is a larger index.
  defp insert_index([], _n, pair), do: [pair]

  defp insert_index([{k, _} = head | rest] = all, n, pair) do
    case array_index(k) do
      m when is_integer(m) and m < n -> [head | insert_index(rest, n, pair)]
      _ -> [pair | all]
    end
  end

  @doc "The value at `key`, or `default`."
  @spec get(t(), String.t(), term()) :: term()
  def get(%__MODULE__{pairs: pairs}, key, default \\ nil) do
    case List.keyfind(pairs, key, 0) do
      {_, v} -> v
      nil -> default
    end
  end

  @doc "`{:ok, value}` when the key is there, else `:error`."
  @spec fetch(t(), String.t()) :: {:ok, value()} | :error
  def fetch(%__MODULE__{pairs: pairs}, key) do
    case List.keyfind(pairs, key, 0) do
      {_, v} -> {:ok, v}
      nil -> :error
    end
  end

  @doc "Whether the key is there."
  @spec has_key?(t(), String.t()) :: boolean()
  def has_key?(%__MODULE__{pairs: pairs}, key), do: List.keymember?(pairs, key, 0)

  @doc "The object without `key`."
  @spec delete(t(), String.t()) :: t()
  def delete(%__MODULE__{pairs: pairs} = o, key), do: %{o | pairs: List.keydelete(pairs, key, 0)}

  @doc "`Object.keys`: the keys in JavaScript's order."
  @spec keys(t()) :: [String.t()]
  def keys(%__MODULE__{pairs: pairs}), do: Enum.map(pairs, &elem(&1, 0))

  @doc "The keys and values, in order."
  @spec to_list(t()) :: [{String.t(), value()}]
  def to_list(%__MODULE__{pairs: pairs}), do: pairs

  @doc "How many keys there are."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{pairs: pairs}), do: length(pairs)

  @doc "`{...a, ...b}`."
  @spec merge(t(), t()) :: t()
  def merge(a, %__MODULE__{pairs: pairs}), do: Enum.reduce(pairs, a, fn {k, v}, o -> put(o, k, v) end)

  @doc false
  # The key as an array index, which JavaScript orders before every other key,
  # or nil.
  @spec array_index(String.t()) :: non_neg_integer() | nil
  def array_index(key) when byte_size(key) == 0 or byte_size(key) > 10, do: nil
  def array_index(<<?0, _, _::binary>>), do: nil

  def array_index(key) do
    if all_digits?(key) do
      n = String.to_integer(key)
      if n < 4_294_967_295, do: n
    end
  end

  defp all_digits?(<<>>), do: true
  defp all_digits?(<<c, rest::binary>>) when c in ?0..?9, do: all_digits?(rest)
  defp all_digits?(_), do: false

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{pairs: pairs}, opts) do
      container_doc("#JS.Object<{", pairs, "}>", opts, fn {k, v}, o -> concat([to_doc(k, o), ": ", to_doc(v, o)]) end,
        separator: ","
      )
    end
  end
end
