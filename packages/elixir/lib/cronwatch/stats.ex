defmodule Cronwatch.Stats do
  @moduledoc false
  # Percentile and median (stats.ts).

  @doc """
  stats.ts `percentile`: the nearest-rank value, with the rank worked out in
  the same floating point steps as JavaScript's, so an Elixir and a Node
  process pick the same run. `nil` for no values.
  """
  def percentile([], _p), do: nil

  def percentile(values, p) do
    sorted = Enum.sort(values)
    n = length(sorted)
    index = trunc(max(min(n - 1.0, Float.ceil(p / 100 * n) - 1), 0.0))
    Enum.at(sorted, index)
  end

  @doc "stats.ts `median`: the middle value, or the mean of the two in the middle."
  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      Cronwatch.JS.normalize((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2)
    else
      Enum.at(sorted, mid)
    end
  end
end
