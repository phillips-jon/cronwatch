defmodule Cronwatch.Test.Wrap do
  @moduledoc """
  A store wrapped for the concurrency and hardening tests, as the SDK's
  tests wrap theirs in a Proxy. Options: `inner` (the `{module, handle}`
  wrapped), `slow_state` (milliseconds each `get_state` waits after reading,
  as over a network, so two processes reading at about the same time both get
  the old state), `refuse_cas` (compare_and_set_state always answers false,
  as if another process wrote between every read and write) and `init`
  (a function called by `init/1`, answering `:ok` or `{:error, reason}`)
  and `before` (a map of a call's name to a function run before it is
  passed on).
  """
  @behaviour Cronwatch.Store

  alias Cronwatch.Store.Memory

  def spec(opts), do: {__MODULE__, Map.new(opts)}

  @doc "A memory store's handle for a store process started under `name`."
  def memory(name) do
    {:ok, h} = Memory.new([server: name], nil)
    {Memory, h}
  end

  defp call(%{inner: {m, h}} = w, fun, args) do
    if f = w[:before][fun], do: f.()
    apply(m, fun, [h | args])
  end

  @impl true
  def new(opts, _instance), do: {:ok, Map.new(opts)}

  @impl true
  def init(%{init: f}), do: f.()
  def init(%{inner: {m, h}}), do: if(function_exported?(m, :init, 1), do: m.init(h), else: :ok)

  @impl true
  def upsert_job(h, d, now), do: call(h, :upsert_job, [d, now])
  @impl true
  def get_job(h, n), do: call(h, :get_job, [n])
  @impl true
  def list_jobs(h), do: call(h, :list_jobs, [])
  @impl true
  def delete_job(h, n), do: call(h, :delete_job, [n])
  @impl true
  def insert_run(h, r), do: call(h, :insert_run, [r])
  @impl true
  def update_run(h, r), do: call(h, :update_run, [r])
  @impl true
  def update_run_if(h, r, f), do: call(h, :update_run_if, [r, f])
  @impl true
  def get_run(h, i), do: call(h, :get_run, [i])
  @impl true
  def list_runs(h, j, l), do: call(h, :list_runs, [j, l])
  @impl true
  def last_run(h, j), do: call(h, :last_run, [j])
  @impl true
  def running_runs(h), do: call(h, :running_runs, [])

  @impl true
  def get_state(h, j) do
    result = call(h, :get_state, [j])
    if ms = h[:slow_state], do: Process.sleep(ms)
    result
  end

  @impl true
  def set_state(h, s), do: call(h, :set_state, [s])

  @impl true
  def compare_and_set_state(%{refuse_cas: true}, _s, _v), do: {:ok, false}
  def compare_and_set_state(h, s, v), do: call(h, :compare_and_set_state, [s, v])

  @impl true
  def prune(h, b), do: call(h, :prune, [b])
end

defmodule Cronwatch.Test.WrapNoCas do
  @moduledoc "`Cronwatch.Test.Wrap` without compare_and_set_state, as a custom store that lacks it."
  @behaviour Cronwatch.Store

  alias Cronwatch.Test.Wrap

  def spec(opts), do: {__MODULE__, Map.new(opts)}

  @impl true
  def new(opts, _instance), do: {:ok, Map.new(opts)}
  @impl true
  defdelegate init(h), to: Wrap
  @impl true
  defdelegate upsert_job(h, d, now), to: Wrap
  @impl true
  defdelegate get_job(h, n), to: Wrap
  @impl true
  defdelegate list_jobs(h), to: Wrap
  @impl true
  defdelegate delete_job(h, n), to: Wrap
  @impl true
  defdelegate insert_run(h, r), to: Wrap
  @impl true
  defdelegate update_run(h, r), to: Wrap
  @impl true
  defdelegate update_run_if(h, r, f), to: Wrap
  @impl true
  defdelegate get_run(h, i), to: Wrap
  @impl true
  defdelegate list_runs(h, j, l), to: Wrap
  @impl true
  defdelegate last_run(h, j), to: Wrap
  @impl true
  defdelegate running_runs(h), to: Wrap
  @impl true
  defdelegate get_state(h, j), to: Wrap
  @impl true
  defdelegate set_state(h, s), to: Wrap
  @impl true
  defdelegate prune(h, b), to: Wrap
end

defmodule Cronwatch.Test.More do
  @moduledoc "Helpers the concurrency and hardening tests share."

  import ExUnit.Callbacks

  @doc "A memory store process of its own, for instances that share it; answers its name."
  def shared_memory do
    name = :"store#{System.unique_integer([:positive])}"
    start_supervised!({Cronwatch.Store.Memory, name: name}, id: name)
    name
  end

  @doc "The stored state of a job, read straight from the store."
  def state({module, handle}, job) do
    {:ok, s} = module.get_state(handle, job)
    s
  end

  @doc "A channel from a function of the alert, answering :ok or {:error, _} (or raising)."
  def channel(name, f), do: Cronwatch.Alerts.fun(name, f)

  @doc """
  Forwards the telemetry `events` of instance `cw` to the calling process as
  `{:event, ref, event, measurements, metadata}`, until the test ends.
  """
  def events(cw, events) do
    ref = make_ref()
    :telemetry.attach_many(ref, events, &__MODULE__.forward/4, {self(), ref, cw})
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  @doc false
  def forward(event, measurements, meta, {pid, ref, cw}) do
    if meta[:instance] == cw, do: send(pid, {:event, ref, event, measurements, meta})
  end

  @doc "A counter in an Agent."
  def counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    agent
  end

  def bump(agent), do: Agent.get_and_update(agent, &{&1 + 1, &1 + 1})
  def count(agent), do: Agent.get(agent, & &1)

  @doc "A value held in an Agent, for switches the tests flip."
  def switch(value) do
    {:ok, agent} = Agent.start_link(fn -> value end)
    agent
  end

  def get(agent), do: Agent.get(agent, & &1)
  def put(agent, v), do: Agent.update(agent, fn _ -> v end)
  def push(agent, v), do: Agent.update(agent, &(&1 ++ [v]))
end
