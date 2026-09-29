defmodule Cronwatch.Web.Text do
  @moduledoc false
  # What the dashboard's pages need to write values the way the SDK's
  # templates do (routes/escape.ts and JavaScript itself): escapeHtml,
  # escapeName, String(value), toFixed, Math.round and encodeURIComponent,
  # and how a header's bytes are read and a secret compared. Carried over
  # from the Rust port's web/text.rs.

  import Bitwise

  alias Cronwatch.Format
  alias Cronwatch.JS

  @doc "`escapeHtml` for text: `& < > \" '` escaped. Every string a page shows goes through it."
  @spec escape_html(String.t()) :: String.t()
  def escape_html(s) when is_binary(s) do
    if :binary.match(s, ["&", "<", ">", "\"", "'"]) == :nomatch, do: s, else: escape(s, [])
  end

  defp escape(<<?&, rest::binary>>, acc), do: escape(rest, ["&amp;" | acc])
  defp escape(<<?<, rest::binary>>, acc), do: escape(rest, ["&lt;" | acc])
  defp escape(<<?>, rest::binary>>, acc), do: escape(rest, ["&gt;" | acc])
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["&quot;" | acc])
  defp escape(<<?', rest::binary>>, acc), do: escape(rest, ["&#39;" | acc])
  defp escape(<<c, rest::binary>>, acc), do: escape(rest, [c | acc])
  defp escape(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  @doc "`escapeHtml(value ?? \"\")` for a JSON value: `String(value)`, with nil as nothing."
  @spec escape_value(term()) :: String.t()
  def escape_value(nil), do: ""
  def escape_value(v), do: escape_html(Format.js_text(v))

  defguardp separator?(c) when c in [?_, ?:, ?., ?/, ?-]

  @doc """
  `escapeName`: a job name shown as text, with `<wbr>` after each run of
  `_ : . / -` that something else follows, so a long name wraps at its
  separators. Only for text, never an attribute, a URL or a title.
  """
  @spec escape_name(String.t()) :: String.t()
  def escape_name(s), do: s |> escape_html() |> wbr([]) |> IO.iodata_to_binary()

  defp wbr(<<c, n, rest::binary>>, acc) when separator?(c) and not separator?(n),
    do: wbr(<<n, rest::binary>>, ["<wbr>", c | acc])

  defp wbr(<<c, rest::binary>>, acc), do: wbr(rest, [c | acc])
  defp wbr(<<>>, acc), do: Enum.reverse(acc)

  @doc "`String(n)` for a number."
  @spec num(JS.number_value()) :: String.t()
  def num(n), do: JS.format_number(JS.normalize(n))

  @doc "`Math.round`: the nearest whole number, a half rounded up."
  @spec js_round(number()) :: integer()
  def js_round(x), do: JS.round(x)

  @doc """
  `Number.prototype.toFixed`: the decimal nearest the exact value of the
  double, a half rounded away from zero. Worked out in whole numbers, from
  the double's own bits.
  """
  @spec to_fixed(number(), non_neg_integer()) :: String.t()
  def to_fixed(x, digits) when is_integer(x), do: to_fixed(x * 1.0, digits)

  def to_fixed(x, digits) when is_float(x) do
    if abs(x) >= 1.0e21 do
      JS.format_number(x)
    else
      digits = min(digits, 10)
      <<_sign::1, exponent::11, fraction::52>> = <<abs(x)::float>>

      {mantissa, e} =
        if exponent == 0, do: {fraction, -1074}, else: {fraction ||| 1 <<< 52, exponent - 1075}

      scaled = mantissa * Integer.pow(5, digits)
      k = e + digits

      n =
        if k >= 0 do
          scaled <<< k
        else
          shift = -k
          q = scaled >>> shift
          r = scaled &&& (1 <<< shift) - 1
          q + if r >= 1 <<< (shift - 1), do: 1, else: 0
        end

      text = Integer.to_string(n)

      text =
        if digits > 0 do
          text =
            if byte_size(text) <= digits,
              do: String.duplicate("0", digits + 1 - byte_size(text)) <> text,
              else: text

          point = byte_size(text) - digits
          binary_part(text, 0, point) <> "." <> binary_part(text, point, digits)
        else
          text
        end

      if x < 0, do: "-" <> text, else: text
    end
  end

  @doc "`encodeURIComponent`."
  @spec encode_uri_component(String.t()) :: String.t()
  def encode_uri_component(s) do
    for <<c <- s>>, into: "" do
      if c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"-_.!~*'()",
        do: <<c>>,
        else: "%" <> hex(c)
    end
  end

  @hex List.to_tuple(~c"0123456789ABCDEF")

  @doc false
  def hex(c), do: <<elem(@hex, c >>> 4), elem(@hex, c &&& 15)>>

  @doc "Text read from the wire as fetch's `Headers` read it: each byte one character."
  @spec latin1(binary()) :: String.t()
  def latin1(bytes), do: :unicode.characters_to_binary(bytes, :latin1, :utf8)

  @doc """
  Compares two secrets without stopping at the first character that
  differs, over UTF-16 code units as the SDK compares them.
  """
  @spec constant_time_eq(String.t(), String.t()) :: boolean()
  def constant_time_eq(a, b) do
    {ua, ub} = {JS.units(a), JS.units(b)}
    byte_size(ua) == byte_size(ub) and :crypto.hash_equals(ua, ub)
  end
end
