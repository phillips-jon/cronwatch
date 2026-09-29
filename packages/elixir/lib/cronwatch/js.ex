defmodule Cronwatch.JS do
  @moduledoc """
  What the port needs of JavaScript's own behaviour, so that every value the
  SDK writes, compares or counts is written, compared and counted the same way
  here: numbers as `Number.prototype.toString` prints them, `JSON.stringify`
  and `JSON.parse` (objects keep JavaScript's key order, see
  `Cronwatch.JS.Object`), string lengths and cuts in UTF-16 code units, the
  characters `\\s` matches, and `Date`'s calendar arithmetic.

  A JSON value is `nil`, a boolean, a number (an integer, a float, or one of
  `:infinity`, `:neg_infinity` and `:nan`, which JavaScript has and Erlang's
  floats do not), a binary, a list, or a `Cronwatch.JS.Object`. `parse/1`
  reads a whole number that JavaScript holds exactly (up to 2^53) as an
  integer and anything else as a float, so a value reads back as it was
  written.
  """

  alias Cronwatch.JS.Object

  @type number_value :: integer() | float() | :infinity | :neg_infinity | :nan
  @type value :: nil | boolean() | number_value() | String.t() | [value()] | Object.t()

  # 2^53: every integer up to it is a double exactly.
  @max_safe 9_007_199_254_740_992

  # How deep arrays and objects may nest, as the Rust port holds it: text
  # nested thousands deep is refused with the same answer in every bounded
  # port.
  @max_depth 256

  @doc false
  def max_depth, do: @max_depth

  ## Numbers

  @doc """
  `String(n)`: the shortest digits that read back as `n`, in plain notation
  from 1e-7 up to 1e21 and exponential notation outside it, as
  `Number.prototype.toString` writes them.
  """
  @spec format_number(number_value()) :: String.t()
  def format_number(:nan), do: "NaN"
  def format_number(:infinity), do: "Infinity"
  def format_number(:neg_infinity), do: "-Infinity"

  def format_number(n) when is_integer(n) do
    if abs(n) <= @max_safe, do: Integer.to_string(n), else: format_number(to_float(n))
  end

  def format_number(n) when is_float(n) and n == 0, do: "0"

  def format_number(n) when is_float(n) do
    sign = if n < 0, do: "-", else: ""
    {digits, point} = shortest(abs(n))
    k = byte_size(digits)

    body =
      cond do
        k <= point and point <= 21 ->
          digits <> String.duplicate("0", point - k)

        0 < point and point <= 21 ->
          binary_part(digits, 0, point) <> "." <> binary_part(digits, point, k - point)

        -6 < point and point <= 0 ->
          "0." <> String.duplicate("0", -point) <> digits

        true ->
          head = binary_part(digits, 0, 1)
          tail = if k > 1, do: "." <> binary_part(digits, 1, k - 1), else: ""
          exp = point - 1
          head <> tail <> "e" <> if(exp >= 0, do: "+", else: "") <> Integer.to_string(exp)
      end

    sign <> body
  end

  @doc false
  # The shortest round-tripping digits of a positive float and ECMAScript's n:
  # the value is 0.d1d2...dk * 10^n.
  def shortest(x) do
    text = :erlang.float_to_binary(x, [:short])

    {mantissa, exp} =
      case :binary.split(text, "e") do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    {int, frac} =
      case :binary.split(mantissa, ".") do
        [i, f] -> {i, f}
        [i] -> {i, ""}
      end

    digits = int <> frac
    point = byte_size(int) + exp
    {digits, point} = strip_leading(digits, point)
    {strip_trailing(digits), point}
  end

  defp strip_leading(<<?0, rest::binary>>, point) when rest != "", do: strip_leading(rest, point - 1)
  defp strip_leading(digits, point), do: {digits, point}

  defp strip_trailing(digits) do
    case String.trim_trailing(digits, "0") do
      "" -> "0"
      d -> d
    end
  end

  @doc "A number as the double JavaScript would hold, or a special value."
  @spec to_float(number_value()) :: float() | :infinity | :neg_infinity | :nan
  def to_float(n) when is_float(n), do: n
  def to_float(n) when n in [:infinity, :neg_infinity, :nan], do: n

  def to_float(n) when is_integer(n) do
    n * 1.0
  rescue
    ArithmeticError -> if n > 0, do: :infinity, else: :neg_infinity
  end

  @doc "`Number.isFinite`."
  @spec finite?(term()) :: boolean()
  def finite?(n), do: is_integer(n) or is_float(n)

  @doc "`Number.isInteger`."
  @spec integer?(term()) :: boolean()
  def integer?(n) when is_integer(n), do: true
  def integer?(n) when is_float(n), do: n == Float.round(n)
  def integer?(_), do: false

  @doc """
  A JavaScript number as an integer, as the ports hold times: truncated, NaN
  as 0, and held at the ends of the 64-bit range.
  """
  @spec to_int(term()) :: integer()
  @min_i64 -9_223_372_036_854_775_808
  @max_i64 9_223_372_036_854_775_807
  def to_int(n) when is_integer(n), do: n |> max(@min_i64) |> min(@max_i64)
  def to_int(n) when is_float(n) and n >= 9.223_372_036_854_776e18, do: @max_i64
  def to_int(n) when is_float(n) and n <= -9.223_372_036_854_776e18, do: @min_i64
  def to_int(n) when is_float(n), do: trunc(n)
  def to_int(:infinity), do: @max_i64
  def to_int(:neg_infinity), do: @min_i64
  def to_int(_), do: 0

  @doc """
  A number as the port keeps it: a float that is a whole number JavaScript
  holds exactly becomes an integer, so `2.0` and `2` are one value.
  """
  @spec normalize(number_value()) :: number_value()
  def normalize(n) when is_float(n) and n == trunc(n) and abs(n) <= @max_safe, do: trunc(n)
  def normalize(n), do: n

  @doc "`Math.round`: halves round up, towards positive infinity."
  @spec round(number()) :: integer()
  def round(n) when is_integer(n), do: n
  def round(n) when is_float(n), do: Kernel.floor(n + 0.5)

  @doc "`Math.floor(a / b)` for whole numbers, `b > 0`."
  @spec floor_div(integer(), pos_integer()) :: integer()
  def floor_div(a, b), do: Integer.floor_div(a, b)

  @doc "A modulo whose result has the sign of `b`."
  @spec modulo(integer(), integer()) :: integer()
  def modulo(a, b), do: Integer.mod(a, b)

  ## JSON

  @doc """
  `JSON.stringify`: the same bytes for the same value. A number that is not
  finite is `null`, as JavaScript writes it. Atoms other than `nil`, `true`
  and `false` are written as their names, and maps as objects in their keys'
  term order.
  """
  @spec stringify(value()) :: String.t()
  def stringify(v), do: v |> write() |> IO.iodata_to_binary()

  defp write(nil), do: "null"
  defp write(true), do: "true"
  defp write(false), do: "false"
  defp write(n) when n in [:infinity, :neg_infinity, :nan], do: "null"
  defp write(n) when is_number(n), do: format_number(n)
  defp write(s) when is_binary(s), do: quote_iodata(s)
  defp write(a) when is_atom(a), do: quote_iodata(Atom.to_string(a))
  defp write([]), do: "[]"
  defp write(list) when is_list(list), do: [?[, Enum.intersperse(Enum.map(list, &write/1), ?,), ?]]
  defp write(%Object{pairs: pairs}), do: write_pairs(pairs)
  defp write(%{} = map) when not is_struct(map), do: write(Object.new(map))

  defp write_pairs([]), do: "{}"

  defp write_pairs(pairs) do
    [?{, Enum.intersperse(Enum.map(pairs, fn {k, v} -> [quote_iodata(k), ?:, write(v)] end), ?,), ?}]
  end

  @doc "`JSON.stringify` of a string."
  @spec quote(String.t()) :: String.t()
  def quote(s), do: s |> quote_iodata() |> IO.iodata_to_binary()

  defp quote_iodata(s), do: [?", escape(s, s, 0, 0, []), ?"]

  # Copies runs of bytes that need no escape as slices of the original.
  defp escape(<<>>, orig, start, len, acc), do: Enum.reverse([binary_part(orig, start, len) | acc])

  defp escape(<<c, rest::binary>>, orig, start, len, acc) when c >= 0x20 and c != ?" and c != ?\\ do
    escape(rest, orig, start, len + 1, acc)
  end

  defp escape(<<c, rest::binary>>, orig, start, len, acc) do
    e =
      case c do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        0x08 -> "\\b"
        0x0C -> "\\f"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        _ -> "\\u00" <> hex2(c)
      end

    escape(rest, orig, start + len + 1, 0, [e, binary_part(orig, start, len) | acc])
  end

  defp hex2(c), do: c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

  @doc """
  `JSON.parse`: objects in JavaScript's key order (a key given twice keeps
  its first place and its last value). A lone surrogate escape (`\\ud800`)
  becomes U+FFFD. Arrays and objects nested more than 256 deep are refused.
  The error is `JSON.parse`'s wording with the byte position.
  """
  @spec parse(String.t()) :: {:ok, value()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    rest = skip_space(text)

    case value(rest, text, 0) do
      {:ok, v, rest} ->
        case skip_space(rest) do
          "" -> {:ok, v}
          rest -> fail("Unexpected non-whitespace character after JSON", text, rest)
        end

      {:error, _} = e ->
        e
    end
  catch
    {:json_error, message} -> {:error, message}
  end

  @doc "`parse/1`, raising `ArgumentError` on text that is not JSON."
  @spec parse!(String.t()) :: value()
  def parse!(text) do
    case parse(text) do
      {:ok, v} -> v
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp fail(what, text, rest), do: {:error, "#{what} at position #{byte_size(text) - byte_size(rest)}"}

  defp throw_fail(what, text, rest),
    do: throw({:json_error, "#{what} at position #{byte_size(text) - byte_size(rest)}"})

  defp skip_space(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(rest), do: rest

  defp value(_rest, _text, depth) when depth >= @max_depth, do: {:error, "JSON nested too deeply"}
  defp value("", text, _depth), do: fail("Unexpected end of JSON input", text, "")

  defp value(<<?{, rest::binary>>, text, depth) do
    case skip_space(rest) do
      <<?}, rest::binary>> -> {:ok, Object.new(), rest}
      rest -> members(rest, text, depth, Object.new())
    end
  end

  defp value(<<?[, rest::binary>>, text, depth) do
    case skip_space(rest) do
      <<?], rest::binary>> -> {:ok, [], rest}
      rest -> elements(rest, text, depth, [])
    end
  end

  defp value(<<?", _::binary>> = rest, text, _depth) do
    {s, rest} = string(rest, text)
    {:ok, s, rest}
  end

  defp value(<<"true", rest::binary>>, _text, _depth), do: {:ok, true, rest}
  defp value(<<"false", rest::binary>>, _text, _depth), do: {:ok, false, rest}
  defp value(<<"null", rest::binary>>, _text, _depth), do: {:ok, nil, rest}
  defp value(<<c, _::binary>> = rest, text, _depth) when c == ?- or c in ?0..?9, do: number(rest, text)
  defp value(rest, text, _depth), do: fail("Unexpected token", text, rest)

  defp members(rest, text, depth, o) do
    rest = skip_space(rest)

    if match?(<<?", _::binary>>, rest) do
      {k, rest} = string(rest, text)

      case skip_space(rest) do
        <<?:, rest::binary>> ->
          case value(skip_space(rest), text, depth + 1) do
            {:ok, v, rest} ->
              o = Object.put(o, k, v)

              case skip_space(rest) do
                <<?,, rest::binary>> -> members(rest, text, depth, o)
                <<?}, rest::binary>> -> {:ok, o, rest}
                rest -> fail("Expected ',' or '}' after property value", text, rest)
              end

            e ->
              e
          end

        rest ->
          fail("Expected ':' after property name", text, rest)
      end
    else
      fail("Expected property name", text, rest)
    end
  end

  defp elements(rest, text, depth, acc) do
    case value(skip_space(rest), text, depth + 1) do
      {:ok, v, rest} ->
        case skip_space(rest) do
          <<?,, rest::binary>> -> elements(rest, text, depth, [v | acc])
          <<?], rest::binary>> -> {:ok, Enum.reverse([v | acc]), rest}
          rest -> fail("Expected ',' or ']' after array element", text, rest)
        end

      e ->
        e
    end
  end

  defp number(rest, text) do
    {sign, r} =
      case rest do
        <<?-, r::binary>> -> {"-", r}
        r -> {"", r}
      end

    {int, r} =
      case r do
        <<?0, r::binary>> ->
          {"0", r}

        r ->
          case digits(r) do
            {"", _} -> throw_fail("No number after minus sign", text, r)
            got -> got
          end
      end

    {frac, r} =
      case r do
        <<?., r2::binary>> ->
          case digits(r2) do
            {"", _} -> throw_fail("Unterminated fractional number", text, r2)
            {d, r3} -> {d, r3}
          end

        r ->
          {nil, r}
      end

    {exp, r} =
      case r do
        <<e, r2::binary>> when e in [?e, ?E] ->
          {esign, r3} =
            case r2 do
              <<s, r3::binary>> when s in [?+, ?-] -> {<<s>>, r3}
              r3 -> {"", r3}
            end

          case digits(r3) do
            {"", _} -> throw_fail("Exponent part is missing a number", text, r3)
            {d, r4} -> {esign <> d, r4}
          end

        r ->
          {nil, r}
      end

    {:ok, to_number(sign, int, frac, exp), r}
  end

  defp digits(rest), do: digits(rest, 0, rest)
  defp digits(<<c, r::binary>>, n, orig) when c in ?0..?9, do: digits(r, n + 1, orig)
  defp digits(r, n, orig), do: {binary_part(orig, 0, n), r}

  defp to_number(sign, int, nil, nil) when byte_size(int) < 16, do: String.to_integer(sign <> int)

  defp to_number(sign, int, frac, exp) do
    text = sign <> int <> "." <> (frac || "0") <> "e" <> (exp || "0")

    case Float.parse(text) do
      {f, ""} ->
        normalize(f)

      _ ->
        # Out of range reads as JavaScript reads it: Infinity, or 0 for an
        # exponent far below.
        cond do
          String.starts_with?(exp || "", "-") -> 0
          sign == "-" -> :neg_infinity
          true -> :infinity
        end
    end
  end

  defp string(<<?", rest::binary>>, text), do: chars(rest, text, rest, 0, [])

  defp chars(<<?", rest::binary>>, _text, orig, n, acc) do
    {IO.iodata_to_binary(Enum.reverse([binary_part(orig, 0, n) | acc])), rest}
  end

  defp chars(<<?\\, rest::binary>>, text, orig, n, acc) do
    acc = [binary_part(orig, 0, n) | acc]
    {piece, rest} = escape_seq(rest, text)
    chars(rest, text, rest, 0, [piece | acc])
  end

  defp chars(<<c, _::binary>> = rest, text, _orig, _n, _acc) when c < 0x20 do
    throw_fail("Bad control character in string literal", text, rest)
  end

  defp chars(<<_, rest::binary>>, text, orig, n, acc), do: chars(rest, text, orig, n + 1, acc)
  defp chars(<<>>, text, _orig, _n, _acc), do: throw_fail("Unterminated string", text, "")

  defp escape_seq(<<e, rest::binary>>, _text) when e in [?", ?\\, ?/], do: {<<e>>, rest}
  defp escape_seq(<<?b, rest::binary>>, _text), do: {<<8>>, rest}
  defp escape_seq(<<?f, rest::binary>>, _text), do: {<<12>>, rest}
  defp escape_seq(<<?n, rest::binary>>, _text), do: {"\n", rest}
  defp escape_seq(<<?r, rest::binary>>, _text), do: {"\r", rest}
  defp escape_seq(<<?t, rest::binary>>, _text), do: {"\t", rest}

  defp escape_seq(<<?u, rest::binary>> = at, text) do
    case hex4(rest) do
      {u, rest} when u in 0xD800..0xDBFF ->
        with <<?\\, ?u, r2::binary>> <- rest,
             {lo, r3} when lo in 0xDC00..0xDFFF <- hex4(r2) do
          {<<0x10000 + Bitwise.bsl(u - 0xD800, 10) + (lo - 0xDC00)::utf8>>, r3}
        else
          _ -> {"�", rest}
        end

      {u, rest} when u in 0xDC00..0xDFFF ->
        {"�", rest}

      {u, rest} ->
        {<<u::utf8>>, rest}

      nil ->
        throw_fail("Bad Unicode escape", text, binary_part(at, 1, byte_size(at) - 1))
    end
  end

  defp escape_seq(<<>>, text), do: throw_fail("Unterminated string", text, "")
  defp escape_seq(<<_, rest::binary>>, text), do: throw_fail("Bad escaped character", text, rest)

  defp hex4(<<a, b, c, d, rest::binary>>) do
    case Integer.parse(<<a, b, c, d>>, 16) do
      {n, ""} when a not in [?+, ?-] -> {n, rest}
      _ -> nil
    end
  end

  defp hex4(_), do: nil

  ## Text

  @doc "Whether JavaScript's `\\s` matches the code point: WhiteSpace and LineTerminator."
  @spec space?(non_neg_integer()) :: boolean()
  def space?(c) when c in 0x2000..0x200A, do: true

  def space?(c),
    do: c in [?\t, ?\n, 0x0B, 0x0C, ?\r, ?\s, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]

  @doc "`String.prototype.trim`."
  @spec trim(String.t()) :: String.t()
  def trim(s), do: s |> trim_start() |> trim_end()

  @doc "`String.prototype.trimStart`."
  @spec trim_start(String.t()) :: String.t()
  def trim_start(<<c::utf8, rest::binary>> = s), do: if(space?(c), do: trim_start(rest), else: s)
  def trim_start(s), do: s

  @doc "`String.prototype.trimEnd`."
  @spec trim_end(String.t()) :: String.t()
  def trim_end(s) do
    case last_non_space(s, 0, 0) do
      n when n == byte_size(s) -> s
      n -> binary_part(s, 0, n)
    end
  end

  defp last_non_space(<<c::utf8, rest::binary>> = s, at, keep) do
    next = at + (byte_size(s) - byte_size(rest))
    last_non_space(rest, next, if(space?(c), do: keep, else: next))
  end

  defp last_non_space(<<_, rest::binary>>, at, _keep), do: last_non_space(rest, at + 1, at + 1)
  defp last_non_space(<<>>, _at, keep), do: keep

  @doc "A string's `.length`: its UTF-16 code units."
  @spec len16(String.t()) :: non_neg_integer()
  def len16(s), do: len16(s, 0)
  defp len16(<<c::utf8, rest::binary>>, n) when c > 0xFFFF, do: len16(rest, n + 2)
  defp len16(<<_::utf8, rest::binary>>, n), do: len16(rest, n + 1)
  defp len16(<<_, rest::binary>>, n), do: len16(rest, n + 1)
  defp len16(<<>>, n), do: n

  @doc """
  `s.slice(start, end)` in UTF-16 code units, with JavaScript's clamping (a
  negative index counts from the end). A cut through a surrogate pair keeps
  the lone half, written here as U+FFFD, the character it becomes once
  written out as UTF-8, so a stored or hashed result is the same bytes.
  """
  @spec slice16(String.t(), integer(), integer()) :: String.t()
  def slice16(s, start, stop) do
    n = len16(s)
    clamp = fn i -> if i < 0, do: max(i + n, 0), else: min(i, n) end
    {start, stop} = {clamp.(start), clamp.(stop)}

    cond do
      start >= stop -> ""
      start == 0 and stop == n -> s
      true -> s |> cut(0, start, stop, []) |> IO.iodata_to_binary()
    end
  end

  defp cut(<<c::utf8, rest::binary>>, at, start, stop, acc) do
    hi = at + if c > 0xFFFF, do: 2, else: 1

    cond do
      hi <= start -> cut(rest, hi, start, stop, acc)
      at >= stop -> Enum.reverse(acc)
      at >= start and hi <= stop -> cut(rest, hi, start, stop, [<<c::utf8>> | acc])
      true -> cut(rest, hi, start, stop, ["�" | acc])
    end
  end

  defp cut(<<b, rest::binary>>, at, start, stop, acc) do
    cond do
      at + 1 <= start -> cut(rest, at + 1, start, stop, acc)
      at >= stop -> Enum.reverse(acc)
      true -> cut(rest, at + 1, start, stop, [<<b>> | acc])
    end
  end

  defp cut(<<>>, _at, _start, _stop, acc), do: Enum.reverse(acc)

  @doc "`s.slice(0, n)`."
  @spec head16(String.t(), non_neg_integer()) :: String.t()
  def head16(s, n), do: slice16(s, 0, n)

  @doc "`s.slice(s.length - n)`: the last `n` code units."
  @spec tail16(String.t(), non_neg_integer()) :: String.t()
  def tail16(s, n) do
    len = len16(s)
    slice16(s, len - n, len)
  end

  @doc "The string as UTF-16 code units, big endian, as JavaScript holds it."
  @spec units(String.t()) :: binary()
  def units(s) do
    case :unicode.characters_to_binary(s, :utf8, {:utf16, :big}) do
      bin when is_binary(bin) -> bin
      _ -> s |> scrub() |> :unicode.characters_to_binary(:utf8, {:utf16, :big})
    end
  end

  @doc """
  The text of UTF-16 code units, big endian; a lone surrogate becomes U+FFFD,
  as it does once JavaScript writes it out as UTF-8.
  """
  @spec from_units(binary()) :: String.t()
  def from_units(u), do: u |> from_units([]) |> IO.iodata_to_binary()

  defp from_units(<<hi::16, lo::16, rest::binary>>, acc) when hi in 0xD800..0xDBFF and lo in 0xDC00..0xDFFF do
    from_units(rest, [<<0x10000 + Bitwise.bsl(hi - 0xD800, 10) + (lo - 0xDC00)::utf8>> | acc])
  end

  defp from_units(<<u::16, rest::binary>>, acc) when u in 0xD800..0xDFFF, do: from_units(rest, ["�" | acc])
  defp from_units(<<u::16, rest::binary>>, acc), do: from_units(rest, [<<u::utf8>> | acc])
  defp from_units(<<>>, acc), do: Enum.reverse(acc)

  @doc """
  The text with every byte sequence that is not UTF-8 replaced by U+FFFD, as
  the SDK reads such text: a stored value another writer left, a SQLite text
  column, a process's output.
  """
  @spec scrub(binary()) :: String.t()
  def scrub(s) do
    if String.valid?(s), do: s, else: s |> String.replace_invalid("�")
  end

  ## Dates

  @doc "The days since 1970-01-01 of a proleptic Gregorian date, month 1 to 12."
  @spec days_from_civil(integer(), integer(), integer()) :: integer()
  def days_from_civil(y, m, d) do
    y = if m <= 2, do: y - 1, else: y
    era = floor_div(y, 400)
    yoe = y - era * 400
    mp = rem(m + 9, 12)
    doy = div(153 * mp + 2, 5) + d - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    era * 146_097 + doe - 719_468
  end

  @doc "The date of a day counted from 1970-01-01: `{year, month, day}`, month 1 to 12."
  @spec civil_from_days(integer()) :: {integer(), 1..12, 1..31}
  def civil_from_days(z) do
    z = z + 719_468
    era = floor_div(z, 146_097)
    doe = z - era * 146_097
    yoe = div(doe - div(doe, 1460) + div(doe, 36_524) - div(doe, 146_096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = if mp + 3 > 12, do: mp - 9, else: mp + 3
    {if(m <= 2, do: y + 1, else: y), m, d}
  end

  @doc """
  `Date.UTC(year, month, day, hour, minute, second, ms)` with a 0-based
  month, every field free to overflow into the next, as `Date.UTC` allows.
  """
  @spec date_utc(integer(), integer(), integer(), integer(), integer(), integer(), integer()) :: integer()
  def date_utc(year, month, day, hour \\ 0, minute \\ 0, second \\ 0, ms \\ 0) do
    year = year + floor_div(month, 12)
    month = modulo(month, 12)
    days = days_from_civil(year, month + 1, 1) + day - 1
    days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000 + ms
  end

  @doc """
  `new Date(ms).toISOString()`: `"2026-01-05T09:30:00.000Z"`, with a signed
  six-digit year outside 0 to 9999.
  """
  @spec iso_string(integer()) :: String.t()
  def iso_string(ms) do
    days = floor_div(ms, 86_400_000)
    rest = Integer.mod(ms, 86_400_000)
    {y, m, d} = civil_from_days(days)

    year =
      cond do
        y < 0 -> "-" <> pad(-y, 6)
        y > 9999 -> "+" <> pad(y, 6)
        true -> pad(y, 4)
      end

    "#{year}-#{pad(m, 2)}-#{pad(d, 2)}T#{pad(div(rest, 3_600_000), 2)}:#{pad(rem(div(rest, 60_000), 60), 2)}:" <>
      "#{pad(rem(div(rest, 1000), 60), 2)}.#{pad(rem(rest, 1000), 3)}Z"
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
