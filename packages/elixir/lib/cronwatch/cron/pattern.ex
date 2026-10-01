defmodule Cronwatch.Cron.Pattern do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # Croner's CronPattern: the fields of an expression as tables of what
  # matches, read with croner's checks and its messages word for word. A table
  # entry is 1 (a match) or, in the day of the week, croner's bits for the nth
  # weekday (1, 2, 4, 8, 16), 32 for the last one and 63 for any.

  alias Cronwatch.JS

  @nth_bits {1, 2, 4, 8, 16}
  @last_bit 32
  @any_bits 63

  @month_names ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @day_names ~w(sun mon tue wed thu fri sat)

  @sizes %{
    second: 60,
    minute: 60,
    hour: 24,
    day: 31,
    month: 12,
    day_of_week: 7,
    year: 10_000,
    nearest_weekdays: 31
  }

  @names %{
    second: "second",
    minute: "minute",
    hour: "hour",
    day: "day",
    month: "month",
    day_of_week: "dayOfWeek",
    year: "year",
    nearest_weekdays: "nearestWeekdays"
  }

  defstruct pattern: "",
            second: nil,
            minute: nil,
            hour: nil,
            day: nil,
            month: nil,
            day_of_week: nil,
            nearest_weekdays: nil,
            every_year: false,
            years: nil,
            last_day_of_month: false,
            last_weekday: false,
            star_dom: false,
            star_dow: false,
            star_year: false,
            use_and_logic: false

  @type t :: %__MODULE__{}

  @doc false
  def nth_bits, do: @nth_bits
  @doc false
  def last_bit, do: @last_bit
  @doc false
  def any_bits, do: @any_bits

  @doc "Reads an expression as croner's CronPattern does; the error is croner's message."
  @spec new(String.t()) :: {:ok, t()} | {:error, String.t()}
  def new(text) do
    empty = fn size -> Tuple.duplicate(0, size) end

    p = %__MODULE__{
      pattern: text,
      second: empty.(60),
      minute: empty.(60),
      hour: empty.(24),
      day: empty.(31),
      month: empty.(12),
      day_of_week: empty.(7),
      nearest_weekdays: empty.(31)
    }

    {:ok, parse(p)}
  catch
    {:cron_error, message} -> {:error, message}
  end

  defp fail(message), do: throw({:cron_error, message})

  @doc "Croner's `year[y]`: whether year `y` matches (false outside the table)."
  @spec has_year?(t(), integer()) :: boolean()
  def has_year?(_p, y) when y < 0 or y >= 10_000, do: false
  def has_year?(%{every_year: true}, _y), do: true
  def has_year?(%{years: nil}, _y), do: false
  def has_year?(%{years: years}, y), do: MapSet.member?(years, y)

  defp parse(p) do
    p =
      if String.contains?(p.pattern, "@"),
        do: %{p | pattern: JS.trim(nicknames(p.pattern))},
        else: p

    parts =
      case split_spaces(p.pattern) do
        [] -> [""]
        parts -> parts
      end

    if length(parts) < 5 or length(parts) > 7 do
      fail(
        "CronPattern: invalid configuration format ('#{p.pattern}'), exactly five, six, or seven space separated parts are required."
      )
    end

    parts = if length(parts) == 5, do: ["0" | parts], else: parts
    parts = if length(parts) == 6, do: parts ++ ["*"], else: parts
    parts = List.to_tuple(parts)

    {p, parts} =
      cond do
        String.upcase(elem(parts, 3)) == "LW" ->
          {%{p | last_weekday: true}, put_elem(parts, 3, "")}

        String.contains?(String.upcase(elem(parts, 3)), "L") ->
          {%{p | last_day_of_month: true}, put_elem(parts, 3, replace_fold(elem(parts, 3), "l", ""))}

        true ->
          {p, parts}
      end

    p = if elem(parts, 3) == "*", do: %{p | star_dom: true}, else: p
    p = if elem(parts, 6) == "*", do: %{p | star_year: true}, else: p

    parts =
      if JS.len16(elem(parts, 4)) >= 3 do
        months =
          @month_names
          |> Enum.with_index(1)
          |> Enum.reduce(elem(parts, 4), fn {name, i}, acc -> replace_fold(acc, name, Integer.to_string(i)) end)

        put_elem(parts, 4, months)
      else
        parts
      end

    parts =
      if JS.len16(elem(parts, 5)) >= 3 do
        days =
          @day_names
          |> Enum.with_index()
          |> Enum.reduce(replace_fold(elem(parts, 5), "-sun", "-7"), fn {name, i}, acc ->
            replace_fold(acc, name, Integer.to_string(i))
          end)

        put_elem(parts, 5, days)
      else
        parts
      end

    {p, parts} =
      case elem(parts, 5) do
        "+" <> rest ->
          if rest == "", do: fail("CronPattern: Day-of-week field cannot be empty after '+' modifier.")
          {%{p | use_and_logic: true}, put_elem(parts, 5, rest)}

        _ ->
          {p, parts}
      end

    p = if elem(parts, 5) == "*", do: %{p | star_dow: true}, else: p

    parts =
      if String.contains?(p.pattern, "?"),
        do: parts |> Tuple.to_list() |> Enum.map(&String.replace(&1, "?", "*")) |> List.to_tuple(),
        else: parts

    parts = Tuple.to_list(parts)
    illegal_characters(parts)

    fields = [
      {:second, 0, {1, nil}},
      {:minute, 0, {1, nil}},
      {:hour, 0, {1, nil}},
      {:day, -1, {1, nil}},
      {:month, -1, {1, nil}},
      {:day_of_week, 0, {@any_bits, nil}},
      {:year, 0, {1, nil}}
    ]

    fields
    |> Enum.zip(parts)
    |> Enum.reduce(p, fn {{k, offset, v}, text}, p -> part(p, k, text, offset, v) end)
  end

  defp split_spaces(text) do
    {words, current} =
      for <<c::utf8 <- text>>, reduce: {[], ""} do
        {words, current} ->
          if JS.space?(c), do: {[current | words], ""}, else: {words, current <> <<c::utf8>>}
      end

    [current | words] |> Enum.reverse() |> Enum.reject(&(&1 == ""))
  end

  defp part(p, k, text, offset, v) do
    last_dom = k == :day and p.last_day_of_month
    last_wd = k == :day and p.last_weekday

    if text == "" and not last_dom and not last_wd do
      fail("CronPattern: configuration entry #{@names[k]} (#{text}) is empty, check for trailing spaces.")
    end

    cond do
      text == "*" and k == :year ->
        %{p | every_year: true}

      text == "*" ->
        {n, _} = v
        Map.put(p, k, Tuple.duplicate(n, @sizes[k]))

      match?([_, _ | _], String.split(text, ",")) ->
        text |> String.split(",") |> Enum.reduce(p, &part(&2, k, &1, offset, v))

      String.contains?(text, "-") and String.contains?(text, "/") ->
        range_with_stepping(p, text, k, offset, v)

      String.contains?(text, "-") ->
        range_of(p, text, k, offset, v)

      String.contains?(text, "/") ->
        stepping(p, text, k, v)

      text != "" ->
        number(p, text, k, offset, v)

      true ->
        p
    end
  end

  defp number(p, text, k, offset, v) do
    {base, nth} = extract_nth(text, k)
    nearest = String.contains?(String.upcase(text), "W")

    if k != :day and nearest,
      do: fail("CronPattern: Nearest weekday modifier (W) only allowed in day-of-month.")

    k = if nearest, do: :nearest_weekdays, else: k

    case parse_int(base) do
      :nan -> fail("CronPattern: #{@names[k]} is not a number: '#{text}'")
      n -> set(p, k, n + offset, modifier_or(nth, v))
    end
  end

  defp set(p, :day_of_week, at, v) do
    at = if at == 7, do: 0, else: at
    if at < 0 or at > 6, do: fail("CronPattern: Invalid value for dayOfWeek: #{JS.format_number(at)}")
    nth_weekday(p, at, v)
  end

  defp set(p, :year, at, {n, s}) do
    if at < 1 or at >= 10_000,
      do: fail("CronPattern: Invalid value for year: #{JS.format_number(at)} (supported range: 1-9999)")

    years = p.years || MapSet.new()
    years = if n != 0 or s != nil, do: MapSet.put(years, at), else: MapSet.delete(years, at)
    %{p | years: years}
  end

  defp set(p, k, at, {n, _}) do
    if at < 0 or at >= @sizes[k], do: fail("CronPattern: Invalid value for #{@names[k]}: #{JS.format_number(at)}")
    Map.update!(p, k, &put_elem(&1, at, n))
  end

  defp range_with_stepping(p, text, k, offset, v) do
    if String.contains?(String.upcase(text), "W"),
      do: fail("CronPattern: Syntax error, W is not allowed in ranges with stepping.")

    {base, nth} = extract_nth(text, k)
    illegal = "CronPattern: Syntax error, illegal range with stepping: '#{text}'"

    {range, step_text} =
      case :binary.split(base, "/") do
        [r, s] -> {r, s}
        _ -> fail(illegal)
      end

    {low_text, high_text} =
      case :binary.split(range, "-") do
        [l, h] -> {l, h}
        _ -> fail(illegal)
      end

    unless digits_only?(low_text) and digits_only?(high_text) and digits_only?(step_text), do: fail(illegal)

    low = String.to_integer(low_text) + offset
    high = String.to_integer(high_text) + offset
    step = String.to_integer(step_text)
    validate_range(low, high, step, @sizes[k], text)
    v = modifier_or(nth, v)
    walk(p, k, low, high, step, v)
  end

  defp walk(p, _k, at, high, _step, _v) when at > high, do: p
  defp walk(p, k, at, high, step, v), do: p |> set(k, at, v) |> walk(k, at + step, high, step, v)

  defp range_of(p, text, k, offset, v) do
    if String.contains?(String.upcase(text), "W"), do: fail("CronPattern: Syntax error, W is not allowed in a range.")

    {base, nth} = extract_nth(text, k)

    {low, high} =
      case String.split(base, "-") do
        [l, h] -> {parse_int(l), parse_int(h)}
        _ -> fail("CronPattern: Syntax error, illegal range: '#{text}'")
      end

    if low == :nan, do: fail("CronPattern: Syntax error, illegal lower range (NaN)")
    if high == :nan, do: fail("CronPattern: Syntax error, illegal upper range (NaN)")
    {low, high} = {low + offset, high + offset}
    validate_range(low, high, nil, @sizes[k], text)
    walk(p, k, low, high, 1, modifier_or(nth, v))
  end

  defp stepping(p, text, k, v) do
    if String.contains?(String.upcase(text), "W"),
      do: fail("CronPattern: Syntax error, W is not allowed in parts with stepping.")

    {base, nth} = extract_nth(text, k)

    {prefix, step_text} =
      case String.split(base, "/") do
        [a, b] -> {a, b}
        _ -> fail("CronPattern: Syntax error, illegal stepping: '#{text}'")
      end

    if prefix == "" do
      fail(
        "CronPattern: Syntax error, stepping with missing prefix ('#{text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead."
      )
    end

    if prefix != "*" do
      fail(
        "CronPattern: Syntax error, stepping with numeric prefix ('#{text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead."
      )
    end

    step = parse_int(step_text)
    if step == :nan, do: fail("CronPattern: Syntax error, illegal stepping: (NaN)")
    size = @sizes[k]
    validate_range(0, size - 1, step, size, text)
    if step > 0, do: walk(p, k, 0, size - 1, step, modifier_or(nth, v)), else: p
  end

  defp nth_weekday(p, day, {n, s}) do
    cond do
      s != nil and String.upcase(s) == "L" ->
        %{p | day_of_week: put_elem(p.day_of_week, day, Bitwise.bor(elem(p.day_of_week, day), @last_bit))}

      s == nil and n == @any_bits ->
        %{p | day_of_week: put_elem(p.day_of_week, day, @any_bits)}

      true ->
        num = if s != nil, do: to_number(s), else: n

        if num != :nan and num < 6 and num > 0 do
          index = num - 1

          if index == trunc(index) and index >= 0 and trunc(index) < tuple_size(@nth_bits) do
            bit = elem(@nth_bits, trunc(index))
            %{p | day_of_week: put_elem(p.day_of_week, day, Bitwise.bor(elem(p.day_of_week, day), bit))}
          else
            p
          end
        else
          if s != nil,
            do: fail("CronPattern: nth weekday out of range, should be 1-5 or L. Value: #{s}, Type: string"),
            else:
              fail(
                "CronPattern: nth weekday out of range, should be 1-5 or L. Value: #{JS.format_number(num)}, Type: number"
              )
        end
    end
  end

  # Croner's `nth[1] || value`: the modifier when there is one, else the field's value.
  defp modifier_or(nth, _v) when is_binary(nth) and nth != "", do: {0, nth}
  defp modifier_or(_nth, v), do: v

  defp nicknames(pattern) do
    case pattern |> JS.trim() |> String.downcase() do
      x when x in ["@yearly", "@annually"] ->
        "0 0 1 1 *"

      "@monthly" ->
        "0 0 1 * *"

      "@weekly" ->
        "0 0 * * 0"

      x when x in ["@daily", "@midnight"] ->
        "0 0 * * *"

      "@hourly" ->
        "0 * * * *"

      "@reboot" ->
        fail(
          "CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection."
        )

      _ ->
        pattern
    end
  end

  # Croner's check of each field's characters: digits, "/*,-" everywhere, W
  # and L in the day of the month, # and L in the day of the week.
  defp illegal_characters(parts) do
    parts
    |> Enum.with_index()
    |> Enum.each(fn {part, i} ->
      extra =
        case i do
          3 -> ~c"WwLl"
          5 -> ~c"#Ll"
          _ -> []
        end

      allowed = ~c"/*0123456789,-" ++ extra

      if Enum.any?(String.to_charlist(part), &(&1 not in allowed)) do
        fail("CronPattern: configuration entry #{i} (#{part}) contains illegal characters.")
      end
    end)
  end

  defp validate_range(low, high, step, size, text) do
    if low > high, do: fail("CronPattern: From value is larger than to value: '#{text}'")

    if step != nil do
      if step == 0, do: fail("CronPattern: Syntax error, illegal stepping: 0")

      if step > size,
        do: fail("CronPattern: Syntax error, steps cannot be greater than maximum value of part (#{size})")
    end

    :ok
  end

  defp digits_only?(""), do: false
  defp digits_only?(s), do: s |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9))

  # Splits a day-of-week modifier off: "1#2" is 1 and "2", "5L" is 5 and "L".
  # Anywhere else a modifier is an error.
  defp extract_nth(text, k) do
    cond do
      String.contains?(text, "#") ->
        if k != :day_of_week, do: fail("CronPattern: nth (#) only allowed in day-of-week field")

        case String.split(text, "#") do
          [base, nth | _] -> {base, nth}
          [base] -> {base, ""}
        end

      String.ends_with?(String.upcase(text), "L") ->
        if k != :day_of_week,
          do: fail("CronPattern: L modifier only allowed in day-of-week field (use L alone for day-of-month)")

        {binary_part(text, 0, byte_size(text) - 1), "L"}

      true ->
        {text, nil}
    end
  end

  # Replaces every occurrence of an ASCII word, matched without regard to
  # ASCII case (a JavaScript /gi regular expression).
  defp replace_fold(text, word, with) do
    size = byte_size(word)
    lower = String.downcase(word)
    replace_fold(text, lower, size, with, [])
  end

  defp replace_fold(<<>>, _word, _size, _with, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp replace_fold(text, word, size, with, acc) do
    case text do
      <<head::binary-size(^size), rest::binary>> ->
        if ascii_downcase(head) == word do
          replace_fold(rest, word, size, with, [with | acc])
        else
          <<b, rest::binary>> = text
          replace_fold(rest, word, size, with, [<<b>> | acc])
        end

      <<b, rest::binary>> ->
        replace_fold(rest, word, size, with, [<<b>> | acc])
    end
  end

  defp ascii_downcase(s), do: for(<<c <- s>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)

  @doc "`parseInt(text, 10)`: an integer, or `:nan` when no digits lead."
  @spec parse_int(String.t()) :: integer() | :nan
  def parse_int(text) do
    s = JS.trim_start(text)

    {sign, s} =
      case s do
        <<"-", rest::binary>> -> {-1, rest}
        <<"+", rest::binary>> -> {1, rest}
        _ -> {1, s}
      end

    case Integer.parse(s) do
      {n, _} when n >= 0 -> if leading_digit?(s), do: sign * n, else: :nan
      _ -> :nan
    end
  end

  defp leading_digit?(<<c, _::binary>>) when c in ?0..?9, do: true
  defp leading_digit?(_), do: false

  @doc "JavaScript's `Number(text)` for the characters a field may hold: `:nan` when it is not a number."
  @spec to_number(String.t()) :: number() | :nan
  def to_number(text) do
    s = JS.trim(text)

    cond do
      s == "" ->
        0

      Regex.match?(~r/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/, s) ->
        {sign, body} =
          case s do
            "-" <> b -> {"-", b}
            "+" <> b -> {"", b}
            b -> {"", b}
          end

        {mantissa, exp} =
          case Regex.run(~r/^([^eE]*)(?:[eE](.*))?$/, body) do
            [_, m] -> {m, "0"}
            [_, m, e] -> {m, e}
          end

        mantissa =
          cond do
            String.starts_with?(mantissa, ".") -> "0" <> mantissa
            String.ends_with?(mantissa, ".") -> mantissa <> "0"
            String.contains?(mantissa, ".") -> mantissa
            true -> mantissa <> ".0"
          end

        case Float.parse(sign <> mantissa <> "e" <> exp) do
          {f, ""} -> JS.normalize(f)
          _ -> if sign == "-", do: :neg_infinity, else: :infinity
        end

      true ->
        :nan
    end
  end
end
