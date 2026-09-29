defmodule Cronwatch.Test.Clock do
  @moduledoc "A clock the tests drive, as the SDK's tests' clock(): epoch milliseconds in an atomics."

  # Monday 2026-01-05 09:30:00Z, the SDK tests' clock start.
  @t0 1_767_605_400_000
  def t0, do: @t0
  def min, do: 60_000
  def hour, do: 3_600_000

  def new(start \\ @t0) do
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, 1, start)
    ref
  end

  def fun(ref), do: fn -> :atomics.get(ref, 1) end
  def now(ref), do: :atomics.get(ref, 1)
  def set(ref, t), do: :atomics.put(ref, 1, t)
  def advance(ref, ms), do: :atomics.add_get(ref, 1, ms)
end

defmodule Cronwatch.Test.Capture do
  @moduledoc "A channel that keeps what it is sent, as the SDK's tests' capture()."
  @behaviour Cronwatch.Channel

  def new do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    agent
  end

  def channel(agent), do: {__MODULE__, agent}

  @impl true
  def init(agent), do: {:ok, agent}
  @impl true
  def name(_), do: "capture"

  @impl true
  def send(agent, alert, _ctx) do
    Agent.update(agent, &(&1 ++ [alert]))
    :ok
  end

  def alerts(agent), do: Agent.get(agent, & &1)
  def types(agent), do: Enum.map(alerts(agent), & &1.type)
end

defmodule Cronwatch.Test.Flaky do
  @moduledoc "Wraps a store so the named calls fail while they are in the broken set, as the SDK's tests' flaky()."
  @behaviour Cronwatch.Store

  def new(inner) do
    {:ok, agent} = Agent.start_link(fn -> MapSet.new() end)
    {{__MODULE__, %{inner: inner, broken: agent}}, agent}
  end

  def break(agent, calls), do: Agent.update(agent, &Enum.into(List.wrap(calls), &1))
  def mend(agent, calls \\ :all)
  def mend(agent, :all), do: Agent.update(agent, fn _ -> MapSet.new() end)
  def mend(agent, calls), do: Agent.update(agent, &MapSet.difference(&1, MapSet.new(List.wrap(calls))))

  defp call(%{inner: {m, h}, broken: agent}, fun, args) do
    if fun in Agent.get(agent, & &1) do
      {:error, %RuntimeError{message: "store down: #{fun}"}}
    else
      apply(m, fun, [h | args])
    end
  end

  @impl true
  def new(opts, _instance), do: {:ok, opts}
  @impl true
  def init(h), do: call(h, :init, [])
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
  def delete_run_if(h, i, j, s), do: call(h, :delete_run_if, [i, j, s])
  @impl true
  def get_run(h, i), do: call(h, :get_run, [i])
  @impl true
  def list_runs(h, j, l), do: call(h, :list_runs, [j, l])
  @impl true
  def last_run(h, j), do: call(h, :last_run, [j])
  @impl true
  def running_runs(h), do: call(h, :running_runs, [])
  @impl true
  def get_state(h, j), do: call(h, :get_state, [j])
  @impl true
  def set_state(h, s), do: call(h, :set_state, [s])
  @impl true
  def compare_and_set_state(h, s, v), do: call(h, :compare_and_set_state, [s, v])
  @impl true
  def prune(h, b), do: call(h, :prune, [b])
  @impl true
  def close(_h), do: :ok
end

defmodule Cronwatch.Test.Client do
  @moduledoc "Starting instances for the client tests, as the SDK's tests' make()."

  import ExUnit.Callbacks

  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock

  @doc """
  An instance on a fresh memory store with a test clock and a capturing
  channel. Answers `%{cw: name, clock: ref, alerts: agent, errors: agent}`;
  errors collects `{where, error}` unless `on_error:` is given.
  """
  def make(opts \\ []) do
    name = :"cw#{System.unique_integer([:positive])}"
    clock = Keyword.get_lazy(opts, :clock_ref, fn -> Clock.new() end)
    alerts = Capture.new()
    {:ok, errors} = Agent.start_link(fn -> [] end)

    base = [
      name: name,
      clock: Clock.fun(clock),
      alerts: [Capture.channel(alerts)],
      cron_secret: false,
      on_error: fn e, where -> Agent.update(errors, &(&1 ++ [{where, e}])) end
    ]

    opts = Keyword.merge(base, Keyword.delete(opts, :clock_ref))
    start_supervised!({Cronwatch, opts}, id: name)
    %{cw: name, clock: clock, alerts: alerts, errors: errors}
  end

  @doc "Where each reported error happened."
  def wheres(errors), do: errors |> Agent.get(& &1) |> Enum.map(&elem(&1, 0))

  @doc "Waits until `fun` is truthy, trying for a second or so."
  def eventually(fun, tries \\ 100) do
    cond do
      result = fun.() -> result
      tries == 0 -> raise ExUnit.AssertionError, message: "not true in time"
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
