defmodule Cronwatch.Channel do
  @moduledoc """
  Where alerts go: the SDK's `AlertChannel`, as a behaviour.

  A channel is given to an instance as `{module, opts}` (or the module alone
  for `[]`). `c:init/1` checks the options once, when the instance starts,
  and answers the channel's state, which `c:name/1` and `c:send/3` are
  given. `c:send/3` answers `:ok` once the alert went out (to at least one
  recipient), or `{:error, reason}` when it went nowhere; a raise or exit is
  that channel's failure only. Each send runs in a task of its own and is
  stopped after 15 seconds.

  `Cronwatch.Alerts.fun/2` wraps a function as a channel.
  """

  alias Cronwatch.Alert

  @callback init(opts :: term()) :: {:ok, state :: term()} | {:error, String.t()}
  @callback name(state :: term()) :: String.t()
  @callback send(state :: term(), Alert.t(), Cronwatch.ChannelContext.t()) :: :ok | {:error, term()}

  @optional_callbacks init: 1
end

defmodule Cronwatch.ChannelContext do
  @moduledoc """
  What the client hands a channel with each alert: `report/2` passes a
  problem that did not stop the alert going out (one of several recipients
  refusing it, say) to the instance's error handler. `transport` is the
  instance's `transport:` option, for a channel given none of its own.
  """

  defstruct [:on_error, transport: nil]
  @type t :: %__MODULE__{on_error: (term() -> any()), transport: Cronwatch.Transport.spec()}

  @doc "Reports a problem that did not stop the alert going out."
  @spec report(t(), term()) :: :ok
  def report(%__MODULE__{on_error: f}, error) do
    f.(error)
    :ok
  end
end

defmodule Cronwatch.Triage do
  @moduledoc """
  Adds a short diagnosis to every alert except recoveries: the SDK's
  `TriageFn`, as a behaviour. Given to an instance as `{module, opts}`, or as
  a function of one argument (the context). `c:triage/2` is given the
  options and a context map with `:alert`, `:recent_runs` (the job's five
  newest) and `:transport` (the instance's `transport:` option), and answers
  `{:ok, text}`, `nil` or `{:error, reason}`. It is tried once per alert and
  stopped after 25 seconds. An optional `c:init/1` checks the options once,
  when the instance starts, and answers what `c:triage/2` is then given.
  """

  @callback init(opts :: term()) :: {:ok, state :: term()} | {:error, String.t()}

  @callback triage(opts :: term(), context :: %{alert: Cronwatch.Alert.t(), recent_runs: [Cronwatch.Run.t()]}) ::
              {:ok, String.t()} | nil | {:error, term()}

  @optional_callbacks init: 1
end

defmodule Cronwatch.Source do
  @moduledoc """
  Runs that happen somewhere CronWatch cannot wrap, such as inside the
  database: the SDK's `Source`, as a behaviour. Given to an instance's
  `sources:` as `{module, opts}`. A check calls `c:sync/2` on each source
  first, with the options and the instance's name, so what it records (with
  `Cronwatch.record_run/3`) is evaluated in the same check; it answers the
  alerts recording them sent. One that fails is reported and the check
  carries on.
  """

  @callback name(opts :: term()) :: String.t()
  @callback sync(opts :: term(), instance :: atom()) :: {:ok, [Cronwatch.Alert.t()]} | :ok | {:error, term()}
end

defmodule Cronwatch.Alerts do
  @moduledoc "The alert channels. Phase 1 has the console and functions; the SDK's providers follow."

  @doc """
  Wraps a function as a channel: `Cronwatch.Alerts.fun("pager", &MyApp.page/2)`.
  The function is given the alert and a `Cronwatch.ChannelContext` (or just
  the alert, for a function of one argument) and answers `:ok` or
  `{:error, reason}`; anything else it answers counts as sent.
  """
  @spec fun(String.t(), function()) :: {module(), keyword()}
  def fun(name, f) when is_binary(name) and (is_function(f, 1) or is_function(f, 2)) do
    {Cronwatch.Alerts.Fun, name: name, fun: f}
  end
end

defmodule Cronwatch.Alerts.Fun do
  @moduledoc false
  @behaviour Cronwatch.Channel

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}
  @impl true
  def name(%{name: name}), do: name

  @impl true
  def send(%{fun: f}, alert, ctx) do
    result = if is_function(f, 2), do: f.(alert, ctx), else: f.(alert)

    case result do
      {:error, _} = e -> e
      _ -> :ok
    end
  end
end

defmodule Cronwatch.Alerts.Console do
  @moduledoc """
  Writes alerts through `Logger`: the SDK's console channel, and the default.
  A recovery is `Logger.info`, anything else `Logger.error`, with the SDK's
  text: `[cronwatch] <title>`, the message, and the triage when there is one.
  """
  @behaviour Cronwatch.Channel

  require Logger

  @impl true
  def init(_opts), do: {:ok, nil}
  @impl true
  def name(_), do: "console"

  @impl true
  def send(_state, alert, _ctx) do
    triage = if alert.triage in [nil, ""], do: "", else: "\nTriage: #{alert.triage}"
    line = "[cronwatch] #{alert.title}\n#{alert.message}#{triage}"
    if alert.type == "recovered", do: Logger.info(line), else: Logger.error(line)
    :ok
  end
end
