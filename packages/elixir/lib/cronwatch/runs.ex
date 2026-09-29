defmodule Cronwatch.Runs do
  @moduledoc false
  # The instance's tables and the monitor on every run in flight.
  #
  # It owns the ETS tables: the declared jobs (name to Job, written through
  # this process so two declarations of one name do not race), the runs in
  # flight (id to what recording one needs), the processes running them (for
  # current/0 through $callers), the lines and metrics runs and handles
  # collect (Cronwatch.Lines), the handles' own state, and a few flags. It
  # monitors the process of every run it holds, and records a run whose
  # process died at once, as failed, with the exit reason. It flips a run's
  # cancelled flag at the job's timeout.

  use GenServer

  alias Cronwatch.Config
  alias Cronwatch.Lines
  alias Cronwatch.Run.Exec

  @max_timer 4_294_967_295

  @doc false
  def child_spec(name), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [name]}}

  @doc false
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: server(name))

  @doc false
  def server(instance), do: Module.concat(instance, Runs)

  @doc "An instance's table."
  def table(instance, which), do: :"#{instance}.cronwatch.#{which}"

  ## Jobs

  @doc "Declares a job: stores it, not yet written to the store."
  def declare(instance, job), do: GenServer.call(server(instance), {:declare, job}, :infinity)

  @doc "Forgets a declared job."
  def undeclare(instance, name), do: GenServer.call(server(instance), {:undeclare, name}, :infinity)

  @doc "The declared job, or nil."
  def job(instance, name) do
    case :ets.lookup(table(instance, :jobs), name) do
      [{_, job, _}] -> job
      [] -> nil
    end
  end

  @doc "Every declared job, by name."
  def jobs(instance) do
    instance |> table(:jobs) |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.name)
  end

  @doc "Whether the declared job has been written to the store since it was declared."
  def synced?(instance, name) do
    match?([{_, _, true}], :ets.lookup(table(instance, :jobs), name))
  end

  @doc "Marks the declared job written, when it is still the same declaration."
  def mark_synced(instance, job) do
    t = table(instance, :jobs)

    case :ets.lookup(t, job.name) do
      [{_, ^job, _}] -> :ets.update_element(t, job.name, {3, true})
      _ -> false
    end
  end

  ## Flags

  @doc "Sets a flag, answering whether it was newly set."
  def flag(instance, name), do: :ets.insert_new(table(instance, :flags), {name})

  @doc "Whether a flag is set."
  def flag?(instance, name), do: :ets.member(table(instance, :flags), name)

  @doc "Clears a flag."
  def unflag(instance, name), do: :ets.delete(table(instance, :flags), name)

  ## Runs

  @doc """
  Registers a run in flight: its process is monitored, and its cancelled
  flag is set at `timeout_ms`.
  """
  def register(instance, run_id, pid, info, timeout_ms) do
    GenServer.call(server(instance), {:register, run_id, pid, info, timeout_ms}, :infinity)
  end

  @doc "Closes a run, answering whether it was still open."
  def close(instance, run_id), do: GenServer.call(server(instance), {:close, run_id}, :infinity)

  @doc "The info of a run in flight, or nil."
  def info(instance, run_id) do
    case :ets.lookup(table(instance, :runs), run_id) do
      [{_, _pid, _ref, info}] -> info
      [] -> nil
    end
  end

  @doc "The ids of the runs a process is running, innermost last."
  def runs_of(instance, pid) do
    for {_, id} <- :ets.lookup(table(instance, :pids), pid), do: id
  end

  ## Handles

  @doc "Registers a handle's state, owned by `owner`, dropped when it ends."
  def register_handle(instance, id, owner, state) do
    GenServer.call(server(instance), {:handle, id, owner, state}, :infinity)
  end

  @doc "A handle's state, or nil once its owner ended."
  def handle(instance, id) do
    case :ets.lookup(table(instance, :handles), id) do
      [{_, _owner, state}] -> state
      [] -> nil
    end
  end

  @doc "Changes a handle's state."
  def put_handle(instance, id, state) do
    :ets.update_element(table(instance, :handles), id, {3, state})
  end

  ## The process

  @impl true
  def init(instance) do
    Process.flag(:trap_exit, true)
    opts = [:named_table, :public, read_concurrency: true]
    :ets.new(table(instance, :jobs), [:set | opts])
    :ets.new(table(instance, :runs), [:set | opts])
    :ets.new(table(instance, :pids), [:bag | opts])
    :ets.new(table(instance, :lines), [:ordered_set, :named_table, :public, write_concurrency: true])
    :ets.new(table(instance, :handles), [:set | opts])
    :ets.new(table(instance, :flags), [:set | opts])
    config = Config.get(instance)
    for job <- config.jobs, do: :ets.insert(table(instance, :jobs), {job.name, job, false})
    {:ok, %{instance: instance, runs: %{}, owners: %{}}}
  end

  @impl true
  def handle_call({:declare, job}, _from, s) do
    :ets.insert(table(s.instance, :jobs), {job.name, job, false})
    {:reply, :ok, s}
  end

  def handle_call({:undeclare, name}, _from, s) do
    :ets.delete(table(s.instance, :jobs), name)
    {:reply, :ok, s}
  end

  def handle_call({:register, id, pid, info, timeout_ms}, _from, s) do
    ref = Process.monitor(pid)
    :ets.insert(table(s.instance, :runs), {id, pid, ref, info})
    :ets.insert(table(s.instance, :pids), {pid, id})
    timer = arm(id, timeout_ms)
    {:reply, :ok, %{s | runs: Map.put(s.runs, ref, {id, pid, timer})}}
  end

  def handle_call({:close, id}, _from, s) do
    case :ets.lookup(table(s.instance, :runs), id) do
      [{_, pid, ref, _}] ->
        Process.demonitor(ref, [:flush])
        {_, s} = drop_run(s, ref, id, pid)
        {:reply, true, s}

      [] ->
        {:reply, false, s}
    end
  end

  def handle_call({:handle, id, owner, state}, _from, s) do
    :ets.insert(table(s.instance, :handles), {id, owner, state})

    owners =
      case s.owners do
        %{^owner => {ref, ids}} -> Map.put(s.owners, owner, {ref, [id | ids]})
        _ -> Map.put(s.owners, owner, {Process.monitor(owner), [id]})
      end

    {:reply, :ok, %{s | owners: owners}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    case s.runs do
      %{^ref => {id, _pid, _timer}} ->
        info = info(s.instance, id)
        {_, s} = drop_run(s, ref, id, pid)
        record_dead(s.instance, id, info, reason)
        {:noreply, s}

      _ ->
        case s.owners do
          %{^pid => {^ref, ids}} ->
            for id <- ids do
              :ets.delete(table(s.instance, :handles), id)
              Lines.close(table(s.instance, :lines), {:handle, id})
            end

            {:noreply, %{s | owners: Map.delete(s.owners, pid)}}

          _ ->
            {:noreply, s}
        end
    end
  end

  def handle_info({:timeout, id, left}, s) do
    if left > 0 do
      arm(id, left)
    else
      case info(s.instance, id) do
        %{cancel: cancel} -> :atomics.put(cancel, 1, 1)
        _ -> :ok
      end
    end

    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    Config.erase(s.instance)
    :ok
  end

  defp arm(id, ms) do
    ms = Cronwatch.JS.to_int(Float.ceil(ms * 1.0))
    wait = min(ms, @max_timer)
    Process.send_after(self(), {:timeout, id, ms - wait}, wait)
  end

  defp drop_run(s, ref, id, pid) do
    case Map.pop(s.runs, ref) do
      {{_, _, timer}, runs} ->
        if timer, do: Process.cancel_timer(timer)
        :ets.delete(table(s.instance, :runs), id)
        :ets.delete_object(table(s.instance, :pids), {pid, id})
        {true, %{s | runs: runs}}

      {nil, _} ->
        {false, s}
    end
  end

  # A process that dies inside a job's function has its run recorded as
  # failed at once, in a task of the instance, rather than left running to
  # be reported stuck at its timeout.
  defp record_dead(_instance, _id, nil, _reason), do: :ok

  defp record_dead(instance, id, info, reason) do
    Task.Supervisor.start_child(Cronwatch.Supervisor.tasks(instance), fn ->
      Exec.record_dead(instance, id, info, reason)
    end)
  end
end
