defmodule Cronwatch.Alert do
  @moduledoc """
  A condition opening or closing, with the text every channel shows.

  `type` is the SDK's string (`"failed"`, `"recovered"`, ...). `details` is a
  map whose keys depend on it:

    * `"missed"`: `due_at`, `deadline`, `grace_ms`, `last_run_at`
    * `"failed"` and `"stuck"`: `consecutive_failures`, `threshold`
    * `"slow"`: `duration_ms`, `threshold_ms`, `basis`
    * `"over_budget"` and `"under_floor"`: `breaches`, each a map of
      `metric`, `value`, `limit` and `basis` (for `"under_floor"`, `limit`
      is the floor, or for a metric without one the lowest of the earlier
      runs it was judged against)
    * `"recovered"`: `after` (the conditions that closed), `reason` (`nil`, or
      `"unscheduled"` when missed closed because the job lost its schedule)
      and `since` (when missed opened, for that reason)

  Each details map also holds `extra`, the keys a newer release added, in
  stored order, when it was read with any; the details of a type this
  release does not know are the `Cronwatch.JS.Object` as read.

  `triage` is a short diagnosis from the triage function; `triage_tried`
  with `triage` nil means triage was tried and gave nothing, so it is not
  tried again for this alert. `extra` keeps the fields after the known ones,
  in stored order, that a newer release added: a queued alert is written
  back, and sent on retry, with every field it was read with, as the SDK
  keeps it.

  `value` is the object an alert was read from, when that is not what this
  release would write for it (a foreign or damaged queued alert, missing a
  field or holding one of the wrong type): while the alert is unchanged it
  is written back as it was read, as the SDK keeps such an entry, and the
  retry judges it by what it holds: a recovery whose details do not list
  what it recovers from, or an alert whose time is not a number, is dropped
  as stale.
  It is nil for an alert made here or read as this release writes it.
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
    at: 0,
    extra: [],
    value: nil
  ]

  @known ~w(type run details job definition title message at triage)

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
          at: integer(),
          extra: [{String.t(), Object.value()}],
          value: Object.t() | nil
        }

  @doc "The alert as the SDK writes it."
  @spec to_value(t()) :: Object.t()
  def to_value(%__MODULE__{value: %Object{} = value} = a) do
    # Unchanged since it was read: as it was read.
    case from_value(value) do
      {:ok, read} when read == a -> value
      _ -> written(a)
    end
  end

  def to_value(%__MODULE__{} = a), do: written(a)

  defp written(a) do
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
    o = if a.triage_tried or a.triage != nil, do: Object.put(o, "triage", a.triage), else: o
    put_extra(o, a.extra)
  end

  defp put_extra(o, nil), do: o
  defp put_extra(o, extra), do: Enum.reduce(extra, o, fn {k, v}, o -> Object.put(o, k, v) end)

  # The details map with the keys a newer release added, when there are any.
  defp with_extra(map, %Object{pairs: pairs}, known) do
    case Enum.reject(pairs, fn {k, _} -> k in known end) do
      [] -> map
      extra -> Map.put(map, :extra, extra)
    end
  end

  @doc "The SDK's JSON."
  @spec to_json(t()) :: String.t()
  def to_json(a), do: a |> to_value() |> JS.stringify()

  @doc false
  # The details of a type this release does not know, kept as read.
  def details_value(_type, %Object{} = d), do: d

  def details_value(type, d), do: type |> known_details_value(d) |> put_extra(d[:extra])

  defp known_details_value("missed", d) do
    %Object{
      pairs: [{"dueAt", d.due_at}, {"deadline", d.deadline}, {"graceMs", d.grace_ms}, {"lastRunAt", d.last_run_at}]
    }
  end

  defp known_details_value("slow", d) do
    %Object{pairs: [{"durationMs", d.duration_ms}, {"thresholdMs", d.threshold_ms}, {"basis", d.basis}]}
  end

  defp known_details_value(type, d) when type in ["over_budget", "under_floor"] do
    breaches =
      Enum.map(d.breaches, fn b ->
        put_extra(
          %Object{pairs: [{"metric", b.metric}, {"value", b.value}, {"limit", b.limit}, {"basis", b.basis}]},
          b[:extra]
        )
      end)

    %Object{pairs: [{"breaches", breaches}]}
  end

  defp known_details_value("recovered", d) do
    o = %Object{pairs: [{"after", d.after}]}
    o = if d[:reason] in [nil, ""], do: o, else: Object.put(o, "reason", d.reason)
    if d[:since] != nil, do: Object.put(o, "since", d.since), else: o
  end

  defp known_details_value(_type, d) do
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
        |> with_extra(o, ~w(dueAt deadline graceMs lastRunAt))

      "slow" ->
        %{
          duration_ms: Read.int(o, "durationMs"),
          threshold_ms: Read.float(o, "thresholdMs"),
          basis: Read.str(o, "basis")
        }
        |> with_extra(o, ~w(durationMs thresholdMs basis))

      t when t in ["over_budget", "under_floor"] ->
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
                |> with_extra(b, ~w(metric value limit basis))
              end)

            _ ->
              []
          end

        with_extra(%{breaches: breaches}, o, ["breaches"])

      "recovered" ->
        after_list =
          case Object.get(o, "after") do
            list when is_list(list) -> Enum.filter(list, &is_binary/1)
            _ -> []
          end

        with_extra(
          %{after: after_list, reason: Read.nullable_str(o, "reason"), since: Read.nullable_int(o, "since")},
          o,
          ~w(after reason since)
        )

      failure when failure in ["failed", "stuck"] ->
        with_extra(
          %{consecutive_failures: Read.int(o, "consecutiveFailures"), threshold: Read.int(o, "threshold")},
          o,
          ~w(consecutiveFailures threshold)
        )

      # A type a newer release added: its details are kept as read.
      _ ->
        o
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
    # read of the job's state; a run that is not one reads as none.
    run =
      case Object.get(o, "run") do
        %Object{} = r ->
          case Run.from_value(Object.put(r, "metrics", Metrics.lenient(Object.get(r, "metrics")))) do
            {:ok, run} -> Run.with_extra(run, r)
            {:error, _} -> nil
          end

        _ ->
          nil
      end

    alert = %__MODULE__{
      type: type,
      run: run,
      details: details_from(type, Read.object(o, "details")),
      job: Read.str(o, "job"),
      definition: Read.object(o, "definition"),
      title: Read.str(o, "title"),
      message: Read.str(o, "message"),
      triage_tried: Object.has_key?(o, "triage"),
      triage: Read.nullable_str(o, "triage"),
      at: Read.int(o, "at"),
      extra: Enum.reject(o.pairs, fn {k, _} -> k in @known end)
    }

    # Kept as read only when that is not what this release writes for it.
    if JS.stringify(written(alert)) == JS.stringify(o),
      do: {:ok, alert},
      else: {:ok, %{alert | value: o}}
  end

  def from_value(v), do: {:error, "an alert must be an object, not #{Read.kind(v)}"}
end
