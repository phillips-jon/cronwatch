defmodule Cronwatch.JobSummary do
  @moduledoc """
  A job and its health, as the dashboard shows it. `stats` covers the last
  twenty runs of any status (`runs`, `ok_rate`), with `p50_ms` and `p95_ms`
  over the successful ones among them. `next_expected_at` is when the
  schedule says the next run is due, `nil` without a schedule.
  """

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Run

  @enforce_keys [:name, :definition, :health]
  defstruct [
    :name,
    :definition,
    :health,
    open: [],
    last_run: nil,
    next_expected_at: nil,
    consecutive_failures: 0,
    silenced_until: nil,
    stats: %{runs: 0, ok_rate: 1, p50_ms: nil, p95_ms: nil}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          definition: Object.t(),
          health: String.t(),
          open: [String.t()],
          last_run: Run.t() | nil,
          next_expected_at: integer() | nil,
          consecutive_failures: integer(),
          silenced_until: integer() | nil,
          stats: %{runs: integer(), ok_rate: number(), p50_ms: integer() | nil, p95_ms: integer() | nil}
        }

  @doc "The summary as the SDK writes it."
  @spec to_value(t()) :: Object.t()
  def to_value(%__MODULE__{} = s) do
    stats = %Object{
      pairs: [
        {"runs", s.stats.runs},
        {"okRate", s.stats.ok_rate},
        {"p50Ms", s.stats.p50_ms},
        {"p95Ms", s.stats.p95_ms}
      ]
    }

    %Object{
      pairs: [
        {"name", s.name},
        {"definition", s.definition},
        {"health", s.health},
        {"open", s.open},
        {"lastRun", if(s.last_run, do: Run.to_value(s.last_run))},
        {"nextExpectedAt", s.next_expected_at},
        {"consecutiveFailures", s.consecutive_failures},
        {"silencedUntil", s.silenced_until},
        {"stats", stats}
      ]
    }
  end

  @doc "The SDK's JSON."
  @spec to_json(t()) :: String.t()
  def to_json(s), do: s |> to_value() |> JS.stringify()
end

defmodule Cronwatch.CheckResult do
  @moduledoc "What a check found and sent."

  alias Cronwatch.Alert
  alias Cronwatch.JobSummary
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  defstruct checked_at: 0, jobs: [], alerts: [], pruned: 0

  @type t :: %__MODULE__{
          checked_at: integer(),
          jobs: [JobSummary.t()],
          alerts: [Alert.t()],
          pruned: non_neg_integer()
        }

  @doc "The result as the SDK writes it."
  @spec to_value(t()) :: Object.t()
  def to_value(%__MODULE__{} = r) do
    %Object{
      pairs: [
        {"checkedAt", r.checked_at},
        {"jobs", Enum.map(r.jobs, &JobSummary.to_value/1)},
        {"alerts", Enum.map(r.alerts, &Alert.to_value/1)},
        {"pruned", r.pruned}
      ]
    }
  end

  @doc "The SDK's JSON."
  @spec to_json(t()) :: String.t()
  def to_json(r), do: r |> to_value() |> JS.stringify()
end

for module <- [Cronwatch.Run, Cronwatch.JobState, Cronwatch.Alert, Cronwatch.JobSummary, Cronwatch.CheckResult] do
  defimpl JSON.Encoder, for: module do
    def encode(value, _encoder), do: @for.to_json(value)
  end
end

defimpl JSON.Encoder, for: Cronwatch.JS.Object do
  def encode(value, _encoder), do: Cronwatch.JS.stringify(value)
end
