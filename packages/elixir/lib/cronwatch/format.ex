defmodule Cronwatch.Format do
  @moduledoc false
  # Alert titles and messages (format.ts), character for character, and the
  # numbers in them as JavaScript's toLocaleString("en-US") writes them.

  alias Cronwatch.Alert
  alias Cronwatch.Duration
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @doc """
  format.ts `andList`: words joined as an English list, with a serial comma
  from three on: `a`, `a and b`, `a, b, and c`.
  """
  def and_list(words) when length(words) <= 2, do: Enum.join(words, " and ")

  def and_list(words) do
    {init, [last]} = Enum.split(words, -1)
    Enum.join(init, ", ") <> ", and " <> last
  end

  @doc """
  evaluate.ts `formatNumber`: a whole number grouped in thousands (`1,234`),
  anything else rounded to at most four decimals (`0.0123`), as
  `Intl.NumberFormat("en-US")` writes them. ICU starts from the shortest
  decimal digits that read back as the number (as `String(n)` has them),
  rounds half away from zero (0.03125 is `0.0313`), and keeps the sign of a
  negative number that rounds to zero (`-0`).
  """
  def format_number(:nan), do: "NaN"
  def format_number(:infinity), do: "∞"
  def format_number(:neg_infinity), do: "-∞"
  def format_number(n) when is_integer(n) and abs(n) > 9_007_199_254_740_992, do: format_number(n * 1.0)
  def format_number(n) when is_integer(n), do: sign(n < 0) <> group(Integer.to_string(abs(n)))

  def format_number(n) when is_float(n) do
    negative = n < 0 or (n == 0 and <<n::float>> != <<0.0::float>>)
    {digits, point} = if n == 0, do: {"0", 1}, else: JS.shortest(abs(n))
    k = byte_size(digits)

    {whole, frac} =
      cond do
        point <= 0 -> {"0", String.duplicate("0", -point) <> digits}
        point >= k -> {digits <> String.duplicate("0", point - k), ""}
        true -> {binary_part(digits, 0, point), binary_part(digits, point, k - point)}
      end

    {whole, frac} = if byte_size(frac) > 4, do: round4(whole, frac), else: {whole, frac}
    frac = String.trim_trailing(frac, "0")
    sign(negative) <> group(whole) <> if(frac == "", do: "", else: "." <> frac)
  end

  defp sign(true), do: "-"
  defp sign(false), do: ""

  # Rounds to four decimals, half away from zero, on the decimal digits.
  defp round4(whole, frac) do
    kept = whole <> binary_part(frac, 0, 4)
    up = :binary.at(frac, 4) >= ?5
    n = String.to_integer(kept) + if(up, do: 1, else: 0)
    s = n |> Integer.to_string() |> String.pad_leading(5, "0")
    len = byte_size(s)
    {binary_part(s, 0, len - 4), binary_part(s, len - 4, 4)}
  end

  # A comma between each three digits, from the right.
  defp group(digits) when byte_size(digits) <= 3, do: digits

  defp group(digits) do
    head = rem(byte_size(digits), 3)
    <<first::binary-size(^head), rest::binary>> = digits
    chunks = for <<c::binary-size(3) <- rest>>, do: c
    Enum.join(if(head > 0, do: [first | chunks], else: chunks), ",")
  end

  # `2026-01-05 09:30:00 UTC (5m ago)`, or `before 0001-01-01 00:00:00 UTC`
  # for a time before the year 1 (after 9999 likewise).
  defp when_at(at, now) do
    case JS.iso_time(to_number(at)) do
      nil ->
        JS.beyond_dates(to_number(at))

      iso ->
        iso = String.replace(iso, "T", " ", global: false)
        "#{JS.head16(iso, 19)} UTC (#{relative(at, now)})"
    end
  end

  # formatRelative for a time that may carry a fraction of a millisecond (a
  # deadline with a fractional grace).
  defp relative(at, now) do
    diff = to_number(at) - now
    abs = abs(diff)

    cond do
      abs < 5_000 -> "now"
      diff < 0 -> "#{Duration.format(abs)} ago"
      true -> "in #{Duration.format(abs)}"
    end
  end

  defp to_number(n) when is_number(n), do: n
  defp to_number(_), do: 0

  defp first_lines(text, n), do: text |> String.split("\n") |> Enum.take(n) |> Enum.join("\n")

  defp tail(nil, _n), do: ""
  defp tail("", _n), do: ""

  defp tail(text, n) do
    lines = text |> JS.trim_end() |> String.split("\n")
    lines |> Enum.drop(max(length(lines) - n, 0)) |> Enum.join("\n")
  end

  # "Error: x" for a bare message, but not "Error: TypeError: x" for one that
  # already names itself (/^[A-Za-z_$][\w$]*: /).
  defp error_line(err) do
    text = first_lines(err, 4)
    if Regex.match?(~r/\A[A-Za-z_$][A-Za-z0-9_$]*: /, text), do: text, else: "Error: " <> text
  end

  @doc "A JSON value as a JavaScript template literal writes it, and `undefined` for a field that is absent."
  def js_text(:undefined), do: "undefined"
  def js_text(nil), do: "null"
  def js_text(s) when is_binary(s), do: s
  def js_text(b) when is_boolean(b), do: to_string(b)
  def js_text(%Object{}), do: "[object Object]"
  def js_text(list) when is_list(list), do: Enum.map_join(list, ",", fn e -> if e == nil, do: "", else: js_text(e) end)
  def js_text(n), do: JS.format_number(n)

  defp field(def, key), do: Object.get(def, key, :undefined)

  @doc "JavaScript's truthiness of a JSON value."
  def truthy?(v) when v in [nil, false, :undefined, "", 0, :nan], do: false
  def truthy?(v) when is_float(v), do: v != 0
  def truthy?(_), do: true

  @doc "Turns a draft `{type, run, details}` into the title and message every channel shows."
  def compose_alert({type, run, details}, %Object{} = def, now) do
    name = js_text(field(def, "name"))
    {title, lines} = compose(type, run, details, def, name, now)

    %Alert{
      type: type,
      run: run,
      details: details,
      job: name,
      definition: def,
      title: title,
      message: Enum.join(lines, "\n"),
      at: now
    }
  end

  defp compose("missed", run, d, def, name, now) do
    zone = field(def, "timezone")
    zone = if truthy?(zone), do: " (#{js_text(zone)})", else: ""
    last = if run, do: "#{run.status} #{when_at(run.started_at, now)}", else: "never"

    {"#{name} missed its scheduled run",
     [
       "Due #{when_at(d.due_at, now)}, and no run had started by #{when_at(d.deadline, now)} " <>
         "(grace #{Duration.format(d.grace_ms)}).",
       "Schedule: #{js_text(field(def, "schedule"))}#{zone}.",
       "Last run: #{last}."
     ]}
  end

  defp compose("failed", run, d, _def, name, now) do
    lines =
      if is_map(d) and is_integer(d[:consecutive_failures]) and d.consecutive_failures > 1,
        do: ["#{JS.format_number(d.consecutive_failures)} consecutive failures."],
        else: []

    lines =
      if run do
        ran = if run.duration_ms != nil, do: ", ran #{Duration.format(run.duration_ms)}", else: ""
        lines = lines ++ ["Started #{when_at(run.started_at, now)}#{ran}."]
        lines = if run.error in [nil, ""], do: lines, else: lines ++ [error_line(run.error)]
        out = tail(run.output, 8)
        if out != "", do: lines ++ ["Output (tail):\n#{out}"], else: lines
      else
        lines
      end

    {"#{name} failed", lines}
  end

  defp compose("stuck", run, _d, _def, name, now) do
    lines =
      if run do
        ran = run.duration_ms || now - run.started_at

        lines = [
          "Started #{when_at(run.started_at, now)} and never reported finishing. " <>
            "Marked as timed out after #{Duration.format(ran)}."
        ]

        out = tail(run.output, 8)
        if out != "", do: lines ++ ["Output so far (tail):\n#{out}"], else: lines
      else
        []
      end

    {"#{name} is stuck",
     lines ++ ["If the process was killed mid-run (a serverless timeout, a deploy), this is what that looks like."]}
  end

  defp compose("slow", run, d, _def, name, now) do
    lines = [
      "Took #{Duration.format(d.duration_ms)}; the limit is #{Duration.format(d.threshold_ms)} (#{d.basis})."
    ]

    lines = if run, do: lines ++ ["Started #{when_at(run.started_at, now)}."], else: lines
    {"#{name} was slow", lines}
  end

  defp compose("over_budget", run, d, _def, name, now) do
    lines =
      Enum.map(d.breaches, fn b ->
        "#{b.metric}: #{format_number(b.value)}, limit #{format_number(b.limit)} (#{b.basis})."
      end)

    lines = if run, do: lines ++ ["Started #{when_at(run.started_at, now)}."], else: lines
    {"#{name} went over budget", lines}
  end

  defp compose("under_floor", run, d, _def, name, now) do
    lines =
      Enum.map(d.breaches, fn
        %{basis: "floor"} = b -> "#{b.metric}: #{format_number(b.value)}, below the floor of #{format_number(b.limit)}."
        b -> "#{b.metric}: #{format_number(b.value)} (#{b.basis})."
      end)

    lines = if run, do: lines ++ ["Started #{when_at(run.started_at, now)}."], else: lines
    {"#{name} fell short", lines}
  end

  defp compose("recovered", _run, %{reason: "unscheduled"} = d, _def, name, now) do
    missed = if d.since != nil, do: "Missed since #{when_at(d.since, now)}. ", else: ""

    {"#{name} is no longer scheduled",
     ["#{missed}It has no schedule now, so nothing is due; the missed alert is closed."]}
  end

  defp compose("recovered", run, d, _def, name, now) do
    after_text = d.after |> Enum.map(&String.replace(&1, "_", " ", global: false)) |> and_list()
    at = if run, do: when_at(run.started_at, now), else: "just now"
    line = "A run #{at} succeeded" <> if(after_text != "", do: " after: #{after_text}", else: "") <> "."
    lines = if run && run.duration_ms != nil, do: [line, "Ran #{Duration.format(run.duration_ms)}."], else: [line]
    {"#{name} recovered", lines}
  end

  defp compose(_type, _run, _d, _def, _name, _now), do: {"", []}
end
