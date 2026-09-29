defmodule Cronwatch.Cron do
  @moduledoc """
  A port of croner 10, the cron library the SDK uses: its reading of an
  expression (`Cronwatch.Cron.Pattern`, with its checks and its messages
  word for word) and its walk to the next matching time
  (`Cronwatch.Cron.Date`), habits included: a day the month does not have
  rolls over, a wall-clock time in a spring-forward gap moves forward by the
  gap, and a time that happens twice is the earlier one. The names and the
  order of every step follow croner's source, as the Go, Python, PHP and Rust
  ports do, so they agree on every expression they read, every one they
  refuse and every fire time.

  Where it cannot match croner:

  - A date no month has (`0 0 30 2 *`) makes croner, which walks by
    recursion a year at a time, run out of stack before the year 3000. This
    port walks in a loop and answers that the expression never fires.
  - Croner reads a string with a colon after its first character as a
    one-time date, through JavaScript's lenient `Date.parse`. This port
    refuses every such string: one that looks like an ISO date with
    "CronPattern: a one-time date is not supported by the Elixir port",
    anything else with the message croner gives for text `Date.parse` cannot
    read, "Invalid ISO8601 passed to timezone parser.".
  """

  alias Cronwatch.Cron.Date
  alias Cronwatch.Cron.Pattern
  alias Cronwatch.Zone

  # The instants a JavaScript Date holds, in milliseconds either side of the epoch.
  @date_range 8_640_000_000_000_000

  defstruct [:pattern, :zone]

  @type t :: %__MODULE__{pattern: Pattern.t(), zone: Zone.t()}

  @doc "Reads an expression, to be walked in `zone`. Its errors are croner's, word for word."
  @spec new(String.t(), Zone.t()) :: {:ok, t()} | {:error, String.t()}
  def new(text, zone) do
    if byte_size(text) > 1 and String.contains?(binary_part(text, 1, byte_size(text) - 1), ":") do
      # Croner reads a string with a colon after its first character as a
      # one-time date to fire at, not as a cron expression.
      if iso_date?(text),
        do: {:error, "CronPattern: a one-time date is not supported by the Elixir port"},
        else: {:error, "Invalid ISO8601 passed to timezone parser."}
    else
      with {:ok, pattern} <- Pattern.new(text), do: {:ok, %__MODULE__{pattern: pattern, zone: zone}}
    end
  end

  # /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/, the start of an ISO date and time.
  defp iso_date?(text), do: Regex.match?(~r/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/, text)

  @doc """
  Croner's `nextRuns`: up to `count` fires after `start` (epoch ms), each
  found from the one before. Fewer when the expression stops firing.
  """
  @spec next_runs(t(), non_neg_integer(), integer()) :: [integer()]
  def next_runs(%__MODULE__{}, _count, start) when start < -@date_range or start > @date_range, do: []

  def next_runs(%__MODULE__{pattern: p, zone: zone}, count, start) do
    runs(Date.from_ms(start, zone), p, zone, count, [])
  end

  defp runs(_d, _p, _zone, 0, acc), do: Enum.reverse(acc)

  defp runs(d, p, zone, count, acc) do
    case Date.increment(d, p) do
      {:ok, true, d} -> runs(d, p, zone, count - 1, [Date.time_ms(d, zone) | acc])
      _ -> Enum.reverse(acc)
    end
  end
end
