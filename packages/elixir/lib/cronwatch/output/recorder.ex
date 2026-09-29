defmodule Cronwatch.Output.Recorder do
  @moduledoc """
  The recorder of the SDK's `job.ts` (`createRecorder`): the lines a run logs
  and the numbers it reports, as a value. Where a run keeps its recorder is
  the client's business; this module only says what each line and number
  does to it.

  Lines are kept up to a window well past the output cap, dropped from the
  front beyond it; the first 16 KB of lines are also kept, so an expect rule
  sees a "done" line printed early even when the stored output keeps only
  the tail.
  """

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Output

  # How much logged text is held, in code units, before lines are dropped
  # from the front. `Output.cap/1` trims exactly at the end, so this only
  # bounds memory: well past the cap, so the kept tail is whole.
  @window 64 * 1024

  defstruct lines: :queue.new(), count: 0, size: 0, head: [], head_size: 0, dropped: false, metrics: Object.new()

  @type t :: %__MODULE__{
          lines: :queue.queue({String.t(), non_neg_integer()}),
          count: non_neg_integer(),
          size: non_neg_integer(),
          head: [String.t()],
          head_size: non_neg_integer(),
          dropped: boolean(),
          metrics: Object.t()
        }

  @doc "An empty recorder."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Appends a line."
  @spec log(t(), String.t()) :: t()
  def log(%__MODULE__{} = r, line) when is_binary(line) do
    n = JS.len16(line)
    cap = Output.output_cap()

    r =
      if r.head_size < cap do
        %{r | head: [line | r.head], head_size: r.head_size + n + 1}
      else
        r
      end

    drop(%{r | lines: :queue.in({line, n}, r.lines), count: r.count + 1, size: r.size + n + 1})
  end

  # Drops from the front once well past the cap; the cap trims exactly at the
  # end.
  defp drop(%{size: size, count: count} = r) when size > @window and count > 1 do
    {{:value, {_line, len}}, lines} = :queue.out(r.lines)
    drop(%{r | lines: lines, count: count - 1, size: size - len - 1, dropped: true})
  end

  defp drop(r), do: r

  @doc """
  What the run stores as its output: the lines kept, capped. nil when nothing
  was logged.
  """
  @spec output(t()) :: String.t() | nil
  def output(%__MODULE__{count: 0}), do: nil
  def output(%__MODULE__{} = r), do: Output.cap(join(r))

  @doc """
  What an expect rule is checked against: everything logged, or when that ran
  long, the first 16 KB and the last 16 KB. nil when nothing was logged.
  """
  @spec expect_text(t()) :: String.t() | nil
  def expect_text(%__MODULE__{count: 0}), do: nil

  def expect_text(%__MODULE__{} = r) do
    all = join(r)
    cap = Output.output_cap()

    if not r.dropped and JS.len16(all) <= 2 * cap do
      all
    else
      head = r.head |> Enum.reverse() |> Enum.join("\n")
      JS.head16(head, cap) <> "\n" <> JS.tail16(all, cap)
    end
  end

  @doc """
  Reports a number for the run; a later value for the same name replaces an
  earlier one in its place.
  """
  @spec metric(t(), String.t(), term()) :: {:ok, t()} | {:error, String.t()}
  def metric(%__MODULE__{} = r, name, value) when is_binary(name) do
    if is_number(value) do
      {:ok, %{r | metrics: Object.put(r.metrics, name, JS.normalize(value))}}
    else
      {:error, "metric \"#{name}\" must be a finite number"}
    end
  end

  @doc "The numbers reported, in JavaScript's key order."
  @spec metrics(t()) :: Object.t()
  def metrics(%__MODULE__{metrics: metrics}), do: metrics

  defp join(r), do: r.lines |> :queue.to_list() |> Enum.map_join("\n", &elem(&1, 0))
end
