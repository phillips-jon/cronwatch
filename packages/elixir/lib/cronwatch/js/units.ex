defmodule Cronwatch.JS.Units do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # Text held as JavaScript holds it, UTF-16 code units (big endian), so a
  # cut through a surrogate pair can keep its lone half. The two places the
  # SDK sends such a half on the wire (Slack's and Discord's cut bodies,
  # triage's prompt) build their text as `Units` and write it with
  # `Cronwatch.JS.stringify_lone/1`, which writes a lone half as `\\udXXX`,
  # as `JSON.stringify` does.

  defstruct units: <<>>

  @type t :: %__MODULE__{units: binary()}

  @doc "Text as units."
  @spec new(String.t()) :: t()
  def new(text) when is_binary(text), do: %__MODULE__{units: Cronwatch.JS.units(text)}

  @doc "The first `n` code units of the text, as JavaScript's `slice(0, n)`."
  @spec head(String.t() | t(), non_neg_integer()) :: t()
  def head(%__MODULE__{units: u}, n), do: %__MODULE__{units: binary_part(u, 0, min(byte_size(u), 2 * n))}
  def head(text, n), do: head(new(text), n)

  @doc "The last `n` code units of the text, as JavaScript's `slice(-n)`."
  @spec tail(String.t() | t(), non_neg_integer()) :: t()
  def tail(%__MODULE__{units: u}, n) do
    take = min(byte_size(u), 2 * n)
    %__MODULE__{units: binary_part(u, byte_size(u) - take, take)}
  end

  def tail(text, n), do: tail(new(text), n)

  @doc "Joins texts and units into units."
  @spec concat([String.t() | t()]) :: t()
  def concat(parts) do
    %__MODULE__{units: Enum.map_join(parts, &raw/1)}
  end

  @doc "The number of code units."
  @spec length(t()) :: non_neg_integer()
  def length(%__MODULE__{units: u}), do: div(byte_size(u), 2)

  @doc "The units of a text or of units."
  @spec raw(String.t() | t()) :: binary()
  def raw(%__MODULE__{units: u}), do: u
  def raw(text) when is_binary(text), do: Cronwatch.JS.units(text)

  @doc "The text, a lone half written as U+FFFD."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{units: u}), do: Cronwatch.JS.from_units(u)

  @doc """
  The runs of the text: `{:text, binary}` for well-formed text and
  `{:lone, unit}` for each lone surrogate.
  """
  @spec segments(t()) :: [{:text, String.t()} | {:lone, char()}]
  def segments(%__MODULE__{units: u}), do: segments(u, [], [])

  defp segments(<<hi::16, lo::16, rest::binary>>, text, acc) when hi in 0xD800..0xDBFF and lo in 0xDC00..0xDFFF do
    segments(rest, [<<0x10000 + Bitwise.bsl(hi - 0xD800, 10) + (lo - 0xDC00)::utf8>> | text], acc)
  end

  defp segments(<<u::16, rest::binary>>, text, acc) when u in 0xD800..0xDFFF do
    segments(rest, [], [{:lone, u} | flush(text, acc)])
  end

  defp segments(<<u::16, rest::binary>>, text, acc), do: segments(rest, [<<u::utf8>> | text], acc)
  defp segments(_, text, acc), do: Enum.reverse(flush(text, acc))

  defp flush([], acc), do: acc
  defp flush(text, acc), do: [{:text, IO.iodata_to_binary(Enum.reverse(text))} | acc]
end
