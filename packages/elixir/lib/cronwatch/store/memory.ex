defmodule Cronwatch.Store.Memory do
  @moduledoc """
  Keeps everything in memory (the SDK's `stores/memory.ts`). The default when
  no store is given, good for tests and for trying the library out. State is
  gone on restart, so a missed run cannot be noticed across one.

  It is a process of the instance, holding the maps, so its calls are taken
  in turn as the SDK's are by its one thread. Given as
  `store: Cronwatch.Store.Memory` or `{Cronwatch.Store.Memory, []}`; the
  instance starts it. To share one between instances (the SDK's tests run
  several clients on one store), start it yourself with
  `{Cronwatch.Store.Memory, name: MyApp.Store}` and give each instance
  `{Cronwatch.Store.Memory, server: MyApp.Store}`.
  """

  @behaviour Cronwatch.Store

  alias Cronwatch.Store.Memory.Server

  ## The store

  @impl Cronwatch.Store
  def new(opts, instance) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} -> {:ok, %{server: server, owned: false}}
      :error -> {:ok, %{server: Module.concat(instance, Store), owned: true}}
    end
  end

  @impl Cronwatch.Store
  def child_spec(%{server: server, owned: true}) do
    %{id: __MODULE__, start: {Server, :start_link, [[name: server]]}}
  end

  def child_spec(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    %{id: {__MODULE__, name}, start: {Server, :start_link, [[name: name]]}}
  end

  @doc false
  def owned?(%{owned: owned}), do: owned

  @doc "Starts a memory store on its own, registered as `name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Server.start_link(opts)

  @impl Cronwatch.Store
  def init(_handle), do: :ok

  @impl Cronwatch.Store
  def upsert_job(h, definition, now), do: call(h, {:upsert_job, definition, now})
  @impl Cronwatch.Store
  def get_job(h, name), do: call(h, {:get_job, name})
  @impl Cronwatch.Store
  def list_jobs(h), do: call(h, :list_jobs)
  @impl Cronwatch.Store
  def delete_job(h, name), do: call(h, {:delete_job, name})
  @impl Cronwatch.Store
  def insert_run(h, run), do: call(h, {:insert_run, run})
  @impl Cronwatch.Store
  def update_run(h, run), do: call(h, {:update_run, run})
  @impl Cronwatch.Store
  def update_run_if(h, run, from), do: call(h, {:update_run_if, run, from})
  @impl Cronwatch.Store
  def delete_run_if(h, id, job, status), do: call(h, {:delete_run_if, id, job, status})
  @impl Cronwatch.Store
  def get_run(h, id), do: call(h, {:get_run, id})
  @impl Cronwatch.Store
  def list_runs(h, job, limit), do: call(h, {:list_runs, job, limit})

  @impl Cronwatch.Store
  def last_run(h, job) do
    with {:ok, list} <- list_runs(h, job, 1), do: {:ok, List.first(list)}
  end

  @impl Cronwatch.Store
  def running_runs(h), do: call(h, :running_runs)
  @impl Cronwatch.Store
  def get_state(h, job), do: call(h, {:get_state, job})
  @impl Cronwatch.Store
  def set_state(h, state), do: call(h, {:set_state, state})
  @impl Cronwatch.Store
  def compare_and_set_state(h, state, expected), do: call(h, {:cas, state, expected})
  @impl Cronwatch.Store
  def prune(h, before), do: call(h, {:prune, before})
  @impl Cronwatch.Store
  def close(_h), do: :ok

  defp call(%{server: server}, msg), do: GenServer.call(server, msg, :infinity)
end

defmodule Cronwatch.Store.Memory.Server do
  @moduledoc false
  # The memory store's process: the maps, each call taken in turn.

  use GenServer

  alias Cronwatch.JobState
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Store.Text
  alias Cronwatch.StoredJob

  defstruct jobs: %{}, runs: %{}, order: %{}, states: %{}, seq: 0

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], name: Keyword.fetch!(opts, :name))

  @impl GenServer
  def init([]), do: {:ok, %__MODULE__{}}

  @impl GenServer
  def handle_call({:upsert_job, definition, now}, _from, s) do
    name = Object.get(definition, "name")

    created =
      case s.jobs[name] do
        nil -> now
        job -> job.created_at
      end

    job = %StoredJob{name: name, definition: Text.kept(definition), created_at: created, updated_at: now}
    {:reply, :ok, %{s | jobs: Map.put(s.jobs, name, job)}}
  end

  def handle_call({:get_job, name}, _from, s), do: {:reply, {:ok, s.jobs[name]}, s}

  # Byte order, as the SQL stores sort, which is Elixir's order of binaries.
  def handle_call(:list_jobs, _from, s), do: {:reply, {:ok, s.jobs |> Map.values() |> Enum.sort_by(& &1.name)}, s}

  def handle_call({:delete_job, name}, _from, s) do
    gone = for {id, %Run{job: ^name}} <- s.runs, do: id

    {:reply, :ok,
     %{
       s
       | jobs: Map.delete(s.jobs, name),
         states: Map.delete(s.states, name),
         runs: Map.drop(s.runs, gone),
         order: Map.drop(s.order, gone)
     }}
  end

  # Like SQL's primary key: an id already recorded is refused, never
  # overwritten.
  def handle_call({:insert_run, %Run{id: id} = run}, _from, s) do
    if Map.has_key?(s.runs, id) do
      {:reply, {:error, %RuntimeError{message: "run #{id} already exists"}}, s}
    else
      seq = s.seq + 1
      {:reply, :ok, %{s | runs: Map.put(s.runs, id, Text.run(run)), order: Map.put(s.order, id, seq), seq: seq}}
    end
  end

  # Like SQL's UPDATE: a run that is gone (its job was forgotten) stays gone,
  # and only these fields change.
  def handle_call({:update_run, run}, _from, s) do
    case s.runs[run.id] do
      nil -> {:reply, :ok, s}
      existing -> {:reply, :ok, %{s | runs: Map.put(s.runs, run.id, finish(existing, run))}}
    end
  end

  def handle_call({:update_run_if, run, from}, _from, s) do
    case s.runs[run.id] do
      %Run{status: status} = existing ->
        if status in from,
          do: {:reply, {:ok, true}, %{s | runs: Map.put(s.runs, run.id, finish(existing, run))}},
          else: {:reply, {:ok, false}, s}

      nil ->
        {:reply, {:ok, false}, s}
    end
  end

  def handle_call({:delete_run_if, id, job, status}, _from, s) do
    case s.runs[id] do
      %Run{job: ^job, status: ^status} ->
        {:reply, {:ok, true}, %{s | runs: Map.delete(s.runs, id), order: Map.delete(s.order, id)}}

      _ ->
        {:reply, {:ok, false}, s}
    end
  end

  def handle_call({:get_run, id}, _from, s), do: {:reply, {:ok, s.runs[id]}, s}

  def handle_call({:list_runs, job, limit}, _from, s) do
    runs =
      s.runs
      |> Map.values()
      |> Enum.filter(&(&1.job == job))
      |> Enum.sort_by(&{-&1.started_at, -s.order[&1.id]})
      |> Enum.take(limit)

    {:reply, {:ok, runs}, s}
  end

  def handle_call(:running_runs, _from, s) do
    runs =
      s.runs
      |> Map.values()
      |> Enum.filter(&(&1.status == "running"))
      |> Enum.sort_by(&{&1.started_at, s.order[&1.id]})

    {:reply, {:ok, runs}, s}
  end

  def handle_call({:get_state, job}, _from, s), do: {:reply, {:ok, s.states[job]}, s}

  def handle_call({:set_state, state}, _from, s),
    do: {:reply, :ok, %{s | states: Map.put(s.states, state.job, Text.state(state))}}

  def handle_call({:cas, %JobState{} = state, expected}, _from, s) do
    current = if s.states[state.job], do: JobState.version_or_zero(s.states[state.job]), else: 0

    if current == expected,
      do: {:reply, {:ok, true}, %{s | states: Map.put(s.states, state.job, Text.state(state))}},
      else: {:reply, {:ok, false}, s}
  end

  # Each job's newest run is kept whatever its age: without it, a job that
  # runs less often than the retention looks like it never ran.
  def handle_call({:prune, before}, _from, s) do
    newest =
      Enum.reduce(s.runs, %{}, fn {_, r}, acc -> Map.update(acc, r.job, r.started_at, &max(&1, r.started_at)) end)

    gone =
      for {id, r} <- s.runs,
          r.status != "running" and r.started_at < before and r.started_at < newest[r.job],
          do: id

    {:reply, {:ok, length(gone)}, %{s | runs: Map.drop(s.runs, gone), order: Map.drop(s.order, gone)}}
  end

  defp finish(existing, run) do
    run = Text.run(run)

    %{
      existing
      | status: run.status,
        finished_at: run.finished_at,
        duration_ms: run.duration_ms,
        error: run.error,
        output: run.output,
        metrics: run.metrics
    }
  end
end
