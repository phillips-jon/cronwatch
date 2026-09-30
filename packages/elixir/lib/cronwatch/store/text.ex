defmodule Cronwatch.Store.Text do
  @moduledoc false
  # Postgres refuses U+0000 in TEXT and JSONB, and a refused write loses the
  # whole row, so every store writes text without it (the SDK's params in
  # stores/sql.ts, and its memory store): a run's trigger, output, error and
  # metric names, and every key and string of a definition and a state.
  # Identifiers (a job's name, a run's id) are written as given; the client
  # refuses one with a NUL before it gets here.

  alias Cronwatch.JobState
  alias Cronwatch.JS
  alias Cronwatch.Output
  alias Cronwatch.Run

  @doc "A run as a store writes it."
  @spec run(Run.t()) :: Run.t()
  def run(%Run{} = r) do
    %{
      r
      | trigger: Output.strip_nul(r.trigger),
        output: r.output && Output.strip_nul(r.output),
        error: r.error && Output.strip_nul(r.error),
        metrics: kept(r.metrics)
    }
  end

  @doc "Any JSON value (a definition, metrics) as a store writes it."
  @spec kept(JS.value()) :: JS.value()
  def kept(value) do
    text = JS.stringify(value)
    clean = Output.strip_json_nul(text)
    if clean == text, do: value, else: JS.parse!(clean)
  end

  @doc "A value's JSON text as a store writes it."
  @spec json(JS.value()) :: String.t()
  def json(value), do: value |> JS.stringify() |> Output.strip_json_nul()

  @doc "A state's JSON text as a store writes it."
  @spec state_json(JobState.t()) :: String.t()
  def state_json(%JobState{} = s), do: s |> JobState.to_json() |> Output.strip_json_nul()

  @doc "A state as a store holds it."
  @spec state(JobState.t()) :: JobState.t()
  def state(%JobState{} = s) do
    text = JobState.to_json(s)
    clean = Output.strip_json_nul(text)

    if clean == text do
      s
    else
      {:ok, kept} = JobState.from_json(clean)
      kept
    end
  end
end
