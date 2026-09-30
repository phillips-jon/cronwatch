defmodule Cronwatch.Lines do
  @moduledoc false
  # The lines and metrics a run or a handle collects (job.ts's recorder),
  # kept in the instance's ETS table so a log from any process (a Task the
  # job started) is an ETS write, never a message to a busy process.
  #
  # Rows, for a key (a run's id, or {:handle, id}):
  #   {{key, :meta}, seq, size, head_size, window_start, dropped, metric_seq}
  #   {{key, seq}, line, length, head?}
  #   {{key, :metric, name}, order, value}
  #
  # Lines are dropped from the front once the window holds more than 64 K
  # code units (the output keeps only the last 16 K); the first 16 K logged
  # are kept apart for expect, as the SDK's recorder keeps its head.

  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @cap 16 * 1024
  @window 64 * 1024

  @doc "Starts collecting for a key."
  def open(table, key), do: :ets.insert(table, {{key, :meta}, 0, 0, 0, 1, 0, 0})

  @doc "Stops collecting for a key and forgets everything it held."
  def close(table, key) do
    :ets.select_delete(table, [
      {{{key, :_}, :_, :_, :_, :_, :_, :_}, [], [true]},
      {{{key, :_}, :_, :_, :_}, [], [true]},
      {{{key, :_, :_}, :_, :_}, [], [true]}
    ])

    :ok
  end

  @doc "Whether the key is open."
  def open?(table, key), do: :ets.member(table, {key, :meta})

  @doc "Appends a line. Nothing happens for a key that is closed."
  def log(table, key, line) when is_binary(line) do
    n = JS.len16(line)
    [seq, size, head_size] = :ets.update_counter(table, {key, :meta}, [{2, 1}, {3, n + 1}, {4, 0}])
    head? = head_size < @cap
    if head?, do: :ets.update_counter(table, {key, :meta}, {4, n + 1})
    :ets.insert(table, {{key, seq}, line, n, head?})
    # A close between the counter and the insert (a Task logging as its run
    # ends) would leave the line behind for good.
    unless :ets.member(table, {key, :meta}), do: :ets.delete(table, {key, seq})
    if size > @window, do: trim(table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Drops lines from the front of the window while it holds more than the
  # window and more than one line.
  defp trim(table, key) do
    case :ets.lookup(table, {key, :meta}) do
      [{_, seq, size, _, start, _, _}] when size > @window and seq > start ->
        at = :ets.update_counter(table, {key, :meta}, {5, 1}) - 1

        case :ets.lookup(table, {key, at}) do
          [{_, _line, len, head?}] ->
            unless head?, do: :ets.delete(table, {key, at})
            :ets.update_counter(table, {key, :meta}, [{3, -(len + 1)}])
            :ets.update_element(table, {key, :meta}, {6, 1})

          [] ->
            :ok
        end

        trim(table, key)

      _ ->
        :ok
    end
  end

  @doc "Reports a number; a later value for the same name replaces an earlier one in its place."
  def metric(table, key, name, value) when is_binary(name) do
    if :ets.member(table, {key, :meta}) do
      unless :ets.update_element(table, {key, :metric, name}, {3, value}) do
        order = :ets.update_counter(table, {key, :meta}, {7, 1})

        unless :ets.insert_new(table, {{key, :metric, name}, order, value}) do
          :ets.update_element(table, {key, :metric, name}, {3, value})
        end

        unless :ets.member(table, {key, :meta}), do: :ets.delete(table, {key, :metric, name})
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The metrics reported, in JavaScript's key order."
  def metrics(table, key) do
    table
    |> :ets.select([{{{key, :metric, :"$1"}, :"$2", :"$3"}, [], [{{:"$2", :"$1", :"$3"}}]}])
    |> Enum.sort()
    |> Enum.reduce(Object.new(), fn {_, name, value}, o -> Object.put(o, name, value) end)
  end

  @doc "What was collected: the window's lines, the head's, whether any were dropped, and the metrics."
  def snapshot(table, key) do
    {start, dropped} =
      case :ets.lookup(table, {key, :meta}) do
        [{_, _, _, _, start, dropped, _}] -> {start, dropped == 1}
        [] -> {1, false}
      end

    rows =
      table
      |> :ets.select([{{{key, :"$1"}, :"$2", :_, :"$3"}, [{:is_integer, :"$1"}], [{{:"$1", :"$2", :"$3"}}]}])
      |> Enum.sort()

    %{
      lines: for({seq, line, _} <- rows, seq >= start, do: line),
      head: for({_, line, true} <- rows, do: line),
      dropped: dropped,
      metrics: metrics(table, key)
    }
  end

  @doc """
  The lines still held (past 64 KB the oldest are let go), joined and not
  yet capped: the run's output is redacted first, then capped
  (`Cronwatch.Output.redact_and_cap/2`). nil when nothing was logged.
  """
  def output(%{lines: []}), do: nil
  def output(%{lines: lines}), do: Enum.join(lines, "\n")

  @doc """
  What an expect rule is checked against: everything logged, or when that ran
  long, the first 16 KB and the last 16 KB. nil when nothing was logged.
  """
  def expect_text(%{lines: []}), do: nil

  def expect_text(%{lines: lines, head: head, dropped: dropped}) do
    all = Enum.join(lines, "\n")

    if not dropped and JS.len16(all) <= 2 * @cap do
      all
    else
      JS.head16(Enum.join(head, "\n"), @cap) <> "\n" <> JS.tail16(all, @cap)
    end
  end

  @doc "Takes what was collected and starts afresh."
  def take(table, key) do
    snap = snapshot(table, key)
    close(table, key)
    open(table, key)
    snap
  end

  @doc """
  Puts back what `take/2` took, before whatever was collected since: both as
  lines of text, and the metrics merged (the later ones win).
  """
  def put_back(table, key, taken) do
    later = take(table, key)

    for snap <- [taken, later], text = expect_text(snap), text != nil, do: log(table, key, text)
    for snap <- [taken, later], {name, value} <- snap.metrics.pairs, do: metric(table, key, name, value)
    :ok
  end
end
