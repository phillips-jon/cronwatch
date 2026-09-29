defmodule Cronwatch.Duration do
  @moduledoc """
  The SDK's `duration.ts`: durations (`"15m"`, `"1h30m"`, a number of
  milliseconds) read and written as the SDK does, its errors word for word.
  """

  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @unit_ms %{"ms" => 1.0, "s" => 1000.0, "m" => 60_000.0, "h" => 3_600_000.0, "d" => 86_400_000.0, "w" => 604_800_000.0}

  # The longest duration text read, in characters (code points). No real
  # duration comes near it, and the SDK's pattern is quadratic on a long run
  # of digits, so a longer text is refused before it is read, quoting its
  # first 32 characters.
  @max_length 64
  @quoted 32

  @doc """
  The SDK's `parseDuration`: `"15m"` is `900000`. It takes text or a number of
  milliseconds, as a stored definition holds either; any other JSON value is
  refused with JavaScript's `String(value)` quoted. Compound text such as
  `"1h30m"` is summed, with whitespace allowed between the parts, and rounded
  as `Math.round` rounds; a number is kept as it is (a float stays a float).
  `label` names the value in the error (`"grace"`, `"timeout"`).
  """
  @spec parse(JS.value(), String.t()) :: {:ok, number()} | {:error, String.t()}
  def parse(value, label \\ "duration")
  def parse(value, ""), do: parse(value, "duration")
  def parse(value, label) when is_binary(value), do: parse_text(value, label)

  def parse(n, label) when is_number(n) or n in [:infinity, :neg_infinity, :nan] do
    if JS.finite?(n) and n >= 0,
      do: {:ok, n},
      else: {:error, "#{label} must be a non-negative number of milliseconds"}
  end

  def parse(other, label), do: {:error, not_a_duration(label, js_string(other))}

  # String(value) for a JSON value, as the SDK's message would quote it.
  defp js_string(nil), do: "null"
  defp js_string(true), do: "true"
  defp js_string(false), do: "false"
  defp js_string(s) when is_binary(s), do: s
  defp js_string(%Object{}), do: "[object Object]"
  defp js_string(list) when is_list(list), do: Enum.map_join(list, ",", &if(&1 == nil, do: "", else: js_string(&1)))
  defp js_string(n) when is_number(n) or is_atom(n), do: JS.format_number(n)
  defp js_string(_), do: "[object Object]"

  defp not_a_duration(label, value) do
    ~s(#{label} "#{value}" is not a duration like "15m", "1h30m" or "90s")
  end

  defp parse_text(value, label) do
    with :ok <- check_length(value, label) do
      text = value |> JS.trim() |> String.downcase()

      if text == "" do
        {:error, "#{label} is empty"}
      else
        {total, consumed} = scan(text, 0.0, [])

        if strip_spaces(IO.iodata_to_binary(consumed)) == strip_spaces(text) do
          {:ok, JS.round(total)}
        else
          {:error, not_a_duration(label, value)}
        end
      end
    end
  end

  defp check_length(value, _label) when byte_size(value) <= @max_length, do: :ok

  defp check_length(value, label) do
    chars = String.codepoints(value)

    if length(chars) > @max_length do
      head = chars |> Enum.take(@quoted) |> Enum.join()
      {:error, "#{label} \"#{head}...\" is too long for a duration (more than #{@max_length} characters)"}
    else
      :ok
    end
  end

  # Every /(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)/g match: its value summed and its
  # text kept; where none starts, the expression moves on one character.
  defp scan("", total, consumed), do: {total, Enum.reverse(consumed)}

  defp scan(text, total, consumed) do
    case match_at(text) do
      {ms, piece, rest} ->
        scan(rest, total + ms, [piece | consumed])

      nil ->
        <<_::utf8, rest::binary>> = text
        scan(rest, total, consumed)
    end
  end

  defp match_at(text) do
    {int, rest} = digits(text)

    if int == "" do
      nil
    else
      {number, rest} =
        case rest do
          <<?., d, _::binary>> when d in ?0..?9 ->
            {frac, rest} = digits(binary_part(rest, 1, byte_size(rest) - 1))
            {int <> "." <> frac, rest}

          _ ->
            {int, rest}
        end

      {space, rest} = spaces(rest, "")

      unit =
        case rest do
          <<"ms", _::binary>> -> "ms"
          <<u, _::binary>> when u in [?s, ?m, ?h, ?d, ?w] -> <<u>>
          _ -> nil
        end

      if unit do
        rest = binary_part(rest, byte_size(unit), byte_size(rest) - byte_size(unit))
        {n, ""} = Float.parse(number)
        {n * @unit_ms[unit], number <> space <> unit, rest}
      end
    end
  end

  defp digits(text), do: digits(text, 0, text)
  defp digits(<<c, rest::binary>>, n, orig) when c in ?0..?9, do: digits(rest, n + 1, orig)
  defp digits(rest, n, orig), do: {binary_part(orig, 0, n), rest}

  defp spaces(<<c::utf8, rest::binary>> = text, acc) do
    if JS.space?(c), do: spaces(rest, acc <> <<c::utf8>>), else: {acc, text}
  end

  defp spaces(text, acc), do: {acc, text}

  defp strip_spaces(s), do: for(<<c::utf8 <- s>>, not JS.space?(c), into: "", do: <<c::utf8>>)

  @doc """
  The SDK's `formatDuration`: `90000` is `"1m 30s"`, at most two units, for
  messages rather than reading back; `"?"` when not finite.
  """
  @spec format(JS.number_value()) :: String.t()
  def format(ms) when ms in [:infinity, :neg_infinity, :nan], do: "?"
  def format(ms) when ms < 1000, do: "#{JS.format_number(JS.round(ms))}ms"

  def format(ms) do
    rest = JS.round(ms / 1000) * 1.0

    {parts, _} =
      Enum.reduce_while([{"d", 86_400.0}, {"h", 3_600.0}, {"m", 60.0}, {"s", 1.0}], {[], rest}, fn {unit, size},
                                                                                                   {parts, rest} ->
        {parts, rest} =
          if rest >= size do
            n = Float.floor(rest / size)
            {parts ++ ["#{JS.format_number(JS.normalize(n))}#{unit}"], rest - n * size}
          else
            {parts, rest}
          end

        if length(parts) == 2, do: {:halt, {parts, rest}}, else: {:cont, {parts, rest}}
      end)

    if parts == [], do: "0s", else: Enum.join(parts, " ")
  end

  @doc ~s(The SDK's `formatRelative`: `"5m ago"`, `"in 2h"`, or `"now"` within five seconds of `now`.)
  @spec relative(integer(), integer()) :: String.t()
  def relative(at, now) do
    diff = at - now

    cond do
      abs(diff) < 5_000 -> "now"
      diff < 0 -> "#{format(abs(diff))} ago"
      true -> "in #{format(abs(diff))}"
    end
  end
end
