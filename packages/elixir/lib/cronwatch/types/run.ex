defmodule Cronwatch.Run do
  @moduledoc """
  One execution of a job, as a store keeps it. Times are epoch milliseconds;
  `status` is the SDK's string (see `Cronwatch.RunStatus`); `output` is the
  lines logged or the text the job returned, capped at 16 KB; `metrics` is a
  `Cronwatch.JS.Object` of numbers; `trigger` is what started the run (`run`,
  `handler`, `start` or a value of the app's).
  """

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Metrics
  alias Cronwatch.Types.Read

  @enforce_keys [:id, :job, :status, :started_at]
  defstruct [
    :id,
    :job,
    :status,
    :started_at,
    finished_at: nil,
    duration_ms: nil,
    error: nil,
    output: nil,
    metrics: %Object{},
    trigger: "run"
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          job: String.t(),
          status: String.t(),
          started_at: integer(),
          finished_at: integer() | nil,
          duration_ms: integer() | nil,
          error: String.t() | nil,
          output: String.t() | nil,
          metrics: Object.t(),
          trigger: String.t()
        }

  @doc "The run as the SDK writes it."
  @spec to_value(t()) :: Object.t()
  def to_value(%__MODULE__{} = r) do
    %Object{
      pairs: [
        {"id", r.id},
        {"job", r.job},
        {"status", r.status},
        {"startedAt", r.started_at},
        {"finishedAt", r.finished_at},
        {"durationMs", r.duration_ms},
        {"error", r.error},
        {"output", r.output},
        {"metrics", r.metrics},
        {"trigger", r.trigger}
      ]
    }
  end

  @doc "The SDK's JSON."
  @spec to_json(t()) :: String.t()
  def to_json(r), do: r |> to_value() |> JS.stringify()

  @doc "Reads the SDK's JSON."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_json(text) do
    with {:ok, v} <- JS.parse(text), do: from_value(v)
  end

  @doc "Reads the SDK's JSON value."
  @spec from_value(term()) :: {:ok, t()} | {:error, String.t()}
  def from_value(%Object{} = o) do
    with {:ok, metrics} <- Metrics.from_value(Object.get(o, "metrics")) do
      {:ok,
       %__MODULE__{
         id: Read.str(o, "id"),
         job: Read.str(o, "job"),
         status: Read.str(o, "status"),
         started_at: Read.int(o, "startedAt"),
         finished_at: Read.nullable_int(o, "finishedAt"),
         duration_ms: Read.nullable_int(o, "durationMs"),
         error: Read.nullable_str(o, "error"),
         output: Read.nullable_str(o, "output"),
         metrics: metrics,
         trigger: Read.str(o, "trigger")
       }}
    end
  end

  def from_value(v), do: {:error, "a run must be an object, not #{Read.kind(v)}"}
end

defmodule Cronwatch.StoredJob do
  @moduledoc """
  A job as a store knows it: its name, its definition (the SDK's JSON object
  as a `Cronwatch.JS.Object`, fields in the order they were given, `expect`
  described in words), and when it was first and last declared.
  """

  alias Cronwatch.JS.Object

  @enforce_keys [:name, :definition]
  defstruct [:name, :definition, created_at: 0, updated_at: 0]

  @type t :: %__MODULE__{name: String.t(), definition: Object.t(), created_at: integer(), updated_at: integer()}
end
