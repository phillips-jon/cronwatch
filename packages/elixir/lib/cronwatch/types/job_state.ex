defmodule Cronwatch.JobState do
  @moduledoc """
  What the checks remember about a job between runs.

  `open` holds the conditions currently open, in the order they opened, as
  `{condition, since}` pairs. `pending_recovery` holds the conditions that
  alerted and have since closed, waiting for the recovered alert the next
  successful run sends; `undelivered` the alerts no channel accepted. Both are
  `nil` for a state written before the fields existed. `sending` is the
  outbox: the alerts written with the state that opened their condition while
  the process that wrote them sends them, each a map of `until` (when that
  process's lease runs out, epoch milliseconds) and `alert` (nil for an entry
  that holds none), and `value` (the entry as stored, written back as it is
  when it holds no alert); it is `nil` when it holds nothing, and the key is
  then left out. `version` goes up by
  one on every write (see `c:Cronwatch.Store.compare_and_set_state/3`), `nil`
  for a state written before versions, which counts as 0. `extra` keeps the
  keys after the known ones, in stored order (`version` and any a newer
  writer added), so a state is written back as the SDK's spread writes it.
  """

  alias Cronwatch.Alert
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Types.Read

  defstruct job: "",
            open: [],
            consecutive_failures: 0,
            silenced_until: nil,
            last_alert_at: nil,
            pending_recovery: [],
            undelivered: nil,
            sending: nil,
            version: nil,
            extra: []

  @type t :: %__MODULE__{
          job: String.t(),
          open: [{String.t(), integer()}],
          consecutive_failures: integer(),
          silenced_until: integer() | nil,
          last_alert_at: integer() | nil,
          pending_recovery: [String.t()] | nil,
          undelivered: [Alert.t()] | nil,
          sending: [sending()] | nil,
          version: integer() | nil,
          extra: [{String.t(), JS.value()}]
        }

  @typedoc "An alert in the outbox (`sending`), held there while it is sent."
  @type sending :: %{until: term(), alert: Alert.t() | nil, value: JS.value()}

  @known [
    "job",
    "open",
    "consecutiveFailures",
    "silencedUntil",
    "lastAlertAt",
    "pendingRecovery",
    "undelivered",
    "sending"
  ]

  @doc "An outbox entry: `alert`, left to this process to send until `until`."
  @spec sending(Alert.t(), integer()) :: sending()
  def sending(%Alert{} = alert, until), do: %{until: until, alert: alert, value: nil}

  @doc "A new state for a job: nothing open, no failures."
  @spec new(String.t()) :: t()
  def new(job), do: %__MODULE__{job: job}

  @doc "When `condition` opened, or nil when it is not open."
  @spec open_at(t(), String.t()) :: integer() | nil
  def open_at(%__MODULE__{open: open}, condition) do
    case List.keyfind(open, condition, 0) do
      {_, since} -> since
      nil -> nil
    end
  end

  @doc false
  def version_or_zero(%__MODULE__{version: v}), do: counted_version(v) || 0

  @max_version 9_007_199_254_740_991

  @doc false
  # The version a stored `version` value counts as, as the SDK's
  # stateVersion() reads it: a whole number from 0 to 2^53 - 1 (2.0 is 2),
  # else nil, which counts as 0. The SQL stores read it the same way, so a
  # foreign row's 1.5 or "x" is written over by the next update.
  def counted_version(v) when is_integer(v) and v >= 0 and v <= @max_version, do: v
  def counted_version(v) when is_float(v) and v >= 0 and v <= @max_version and v == trunc(v), do: trunc(v)
  def counted_version(_), do: nil

  @doc false
  # The failures in a row a stored `consecutiveFailures` value counts as, as
  # the SDK's failureCount() reads it: a whole number (2.0 is 2) held at
  # 2^53 - 1, else 0, so a foreign row's count at a 64-bit limit stays at the
  # top and a 1.5, "3" or -1 counts as none.
  def failure_count(v) when is_integer(v) and v > 0, do: min(v, @max_version)
  def failure_count(v) when is_float(v) and v > 0 and v == trunc(v), do: min(trunc(v), @max_version)
  def failure_count(_), do: 0

  @doc false
  # One more failure, held at 2^53 - 1.
  def add_failure(n), do: min(failure_count(n) + 1, @max_version)

  # A stored integer is kept as it is, so the state reads back as written
  # (version_or_zero/1 counts it); anything else that is not a whole number
  # (1.5, "x", true) is dropped, and counts as 0.
  defp read_version(v) when is_integer(v), do: v
  defp read_version(v) when is_float(v), do: counted_version(v)
  defp read_version(_), do: nil

  @doc "The state as the SDK writes it."
  @spec to_value(t()) :: Object.t()
  def to_value(%__MODULE__{} = s) do
    head = [
      {"job", s.job},
      {"open", Object.new(s.open)},
      {"consecutiveFailures", s.consecutive_failures},
      {"silencedUntil", s.silenced_until},
      {"lastAlertAt", s.last_alert_at}
    ]

    head = if s.pending_recovery, do: head ++ [{"pendingRecovery", s.pending_recovery}], else: head
    head = if s.undelivered, do: head ++ [{"undelivered", Enum.map(s.undelivered, &Alert.to_value/1)}], else: head
    # Only while it holds an alert: never written as [].
    head = if s.sending in [nil, []], do: head, else: head ++ [{"sending", Enum.map(s.sending, &sending_value/1)}]
    o = %Object{pairs: head}

    {o, wrote} =
      Enum.reduce(s.extra, {o, false}, fn
        {"version", _}, {o, wrote} ->
          if s.version, do: {Object.put(o, "version", s.version), true}, else: {o, wrote}

        {k, v}, {o, wrote} ->
          {Object.put(o, k, v), wrote}
      end)

    if s.version != nil and not wrote, do: Object.put(o, "version", s.version), else: o
  end

  defp sending_value(%{alert: %Alert{} = alert, until: until}),
    do: %Object{pairs: [{"until", until}, {"alert", Alert.to_value(alert)}]}

  defp sending_value(%{value: value}), do: value

  # Read leniently, as releaseSending treats an entry: one that is not an
  # object, or holds no alert, or whose `until` is not a number, is kept as
  # it is (and let go when the lease is checked), never a failed read.
  defp read_sending(%Object{} = o) do
    alert =
      case Alert.from_value(Object.get(o, "alert")) do
        {:ok, alert} -> alert
        {:error, _} -> nil
      end

    %{until: Object.get(o, "until"), alert: alert, value: o}
  end

  defp read_sending(value), do: %{until: nil, alert: nil, value: value}

  @doc "The SDK's JSON."
  @spec to_json(t()) :: String.t()
  def to_json(s), do: s |> to_value() |> JS.stringify()

  @doc "Reads the SDK's JSON."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_json(text) do
    with {:ok, v} <- JS.parse(text), do: from_value(v)
  end

  @doc "Reads the SDK's JSON value."
  @spec from_value(term()) :: {:ok, t()} | {:error, String.t()}
  def from_value(%Object{} = o) do
    open =
      case Object.get(o, "open") do
        %Object{pairs: pairs} ->
          Enum.map(pairs, fn {k, at} -> {k, if(Read.number?(at), do: JS.to_int(at), else: 0)} end)

        _ ->
          []
      end

    pending =
      case Object.get(o, "pendingRecovery") do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> nil
      end

    # An entry that is not an alert is dropped rather than fail every read of
    # the state: it could never be delivered.
    undelivered =
      case Object.get(o, "undelivered") do
        list when is_list(list) ->
          Enum.flat_map(list, fn a ->
            case Alert.from_value(a) do
              {:ok, alert} -> [alert]
              {:error, _} -> []
            end
          end)

        _ ->
          nil
      end

    sending =
      case Object.get(o, "sending") do
        [_ | _] = list -> Enum.map(list, &read_sending/1)
        _ -> nil
      end

    extra = Enum.reject(o.pairs, fn {k, _} -> k in @known end)

    {:ok,
     %__MODULE__{
       job: Read.str(o, "job"),
       open: open,
       consecutive_failures: failure_count(Object.get(o, "consecutiveFailures")),
       silenced_until: Read.nullable_int(o, "silencedUntil"),
       last_alert_at: Read.nullable_int(o, "lastAlertAt"),
       pending_recovery: pending,
       undelivered: undelivered,
       sending: sending,
       version: read_version(Object.get(o, "version")),
       extra: extra
     }}
  end

  def from_value(v), do: {:error, "a job state must be an object, not #{Read.kind(v)}"}
end
