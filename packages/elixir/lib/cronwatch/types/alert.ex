defmodule Cronwatch.Alert do
  @moduledoc """
  A condition opening or closing, with the text every channel shows.

  `type` is the SDK's string (`"failed"`, `"recovered"`, ...). `details` is a
  map whose keys depend on it:

    * `"missed"`: `due_at`, `deadline`, `grace_ms`, `last_run_at`
    * `"failed"` and `"stuck"`: `consecutive_failures`, `threshold`
    * `"slow"`: `duration_ms`, `threshold_ms`, `basis`
    * `"over_budget"`: `breaches`, each a map of `metric`, `value`, `limit`
      and `basis`
    * `"recovered"`: `after` (the conditions that closed), `reason` (`nil`, or
      `"unscheduled"` when missed closed because the job lost its schedule)
      and `since` (when missed opened, for that reason)

  `triage` is a short diagnosis from the triage function; `triage_tried`
  with `triage` nil means triage was tried and gave nothing, so it is not
  tried again for this alert.
  """

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Metrics
  alias Cronwatch.Run
  alias Cronwatch.Types.Read

  @enforce_keys [:type, :details]
  defstruct [
    :type,
    :details,
    run: nil,
    job: "",
    definition: %Object{},
    title: "",
    message: "",
    triage: nil,
    triage_tried: false,
    at: 0
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          details: map(),
          run: Run.t() | nil,
          job: String.t(),
          definition: Object.t(),
          title: String.t(),
          message: String.t(),
          triage: String.t() | nil,
          triage_tried: boolean(),
          at: integer()
        }

  @doc "The alert as the SDK writes it."
  @spec to_value(t()) :: Object.t()
  def to_value(%__MODULE__{} = a) do
    pairs = [
      {"type", a.type},
      {"run", if(a.run, do: Run.to_value(a.run))},
      {"details", details_value(a.type, a.details)},
      {"job", a.job},
      {"definition", a.definition},
      {"title", a.title},
      {"message", a.message},
      {"at", a.at}
    ]

    o = %Object{pairs: pairs}
    if a.triage_tried or a.triage != nil, do: Object.put(o, "triage", a.triage), else: o
  end

  @doc "The SDK's JSON."
  @spec to_json(t()) :: String.t()
  def to_json(a), do: a |> to_value() |> JS.stringify()

  @doc false
  def details_value("missed", d) do
    %Object{
      pairs: [{"dueAt", d.due_at}, {"deadline", d.deadline}, {"graceMs", d.grace_ms}, {"lastRunAt", d.last_run_at}]
    }
  end

  def details_value("slow", d) do
    %Object{pairs: [{"durationMs", d.duration_ms}, {"thresholdMs", d.threshold_ms}, {"basis", d.basis}]}
  end

  def details_value("over_budget", d) do
    breaches =
      Enum.map(d.breaches, fn b ->
        %Object{pairs: [{"metric", b.metric}, {"value", b.value}, {"limit", b.limit}, {"basis", b.basis}]}
      end)

    %Object{pairs: [{"breaches", breaches}]}
  end

  def details_value("recovered", d) do
    o = %Object{pairs: [{"after", d.after}]}
    o = if d[:reason] not in [nil, ""], do: Object.put(o, "reason", d.reason), else: o
    if d[:since] != nil, do: Object.put(o, "since", d.since), else: o
  end

  def details_value(_type, d) do
    %Object{pairs: [{"consecutiveFailures", d.consecutive_failures}, {"threshold", d.threshold}]}
  end

  @doc false
  def details_from(type, %Object{} = o) do
    case type do
      "missed" ->
        %{
          due_at: Read.int(o, "dueAt"),
          deadline: Read.float(o, "deadline"),
          grace_ms: Read.float(o, "graceMs"),
          last_run_at: Read.nullable_int(o, "lastRunAt")
        }

      "slow" ->
        %{
          duration_ms: Read.int(o, "durationMs"),
          threshold_ms: Read.float(o, "thresholdMs"),
          basis: Read.str(o, "basis")
        }

      "over_budget" ->
        breaches =
          case Object.get(o, "breaches") do
            list when is_list(list) ->
              Enum.map(list, fn b ->
                b = if match?(%Object{}, b), do: b, else: Object.new()

                %{
                  metric: Read.str(b, "metric"),
                  value: Read.float(b, "value"),
                  limit: Read.float(b, "limit"),
                  basis: Read.str(b, "basis")
                }
              end)

            _ ->
              []
          end

        %{breaches: breaches}

      "recovered" ->
        after_list =
          case Object.get(o, "after") do
            list when is_list(list) -> Enum.filter(list, &is_binary/1)
            _ -> []
          end

        %{after: after_list, reason: Read.nullable_str(o, "reason"), since: Read.nullable_int(o, "since")}

      _ ->
        %{consecutive_failures: Read.int(o, "consecutiveFailures"), threshold: Read.int(o, "threshold")}
    end
  end

  @doc "Reads the SDK's JSON."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_json(text) do
    with {:ok, v} <- JS.parse(text), do: from_value(v)
  end

  @doc "Reads the SDK's JSON value."
  @spec from_value(term()) :: {:ok, t()} | {:error, String.t()}
  def from_value(%Object{} = o) do
    type = Read.str(o, "type")

    # A queued alert's run keeps the metrics that are numbers, as a stored
    # run row does, so one another writer stored otherwise cannot fail every
    # read of the job's state.
    run =
      case Object.get(o, "run") do
        nil -> {:ok, nil}
        %Object{} = r -> Run.from_value(Object.put(r, "metrics", Metrics.lenient(Object.get(r, "metrics"))))
        r -> Run.from_value(r)
      end

    with {:ok, run} <- run do
      {:ok,
       %__MODULE__{
         type: type,
         run: run,
         details: details_from(type, Read.object(o, "details")),
         job: Read.str(o, "job"),
         definition: Read.object(o, "definition"),
         title: Read.str(o, "title"),
         message: Read.str(o, "message"),
         triage_tried: Object.has_key?(o, "triage"),
         triage: Read.nullable_str(o, "triage"),
         at: Read.int(o, "at")
       }}
    end
  end

  def from_value(v), do: {:error, "an alert must be an object, not #{Read.kind(v)}"}
end
