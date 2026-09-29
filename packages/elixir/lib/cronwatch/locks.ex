defmodule Cronwatch.Locks do
  @moduledoc false
  # Per-key locks, held in turn: a FIFO queue per key, as the SDK's serial()
  # queue runs a job's state updates one after another. The holder and every
  # waiter are monitored, so a lock whose holder died is released, and a
  # waiter that died is taken out of the queue, rather than held for good.

  use GenServer

  @doc false
  def child_spec(name), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [name]}}

  @doc false
  def start_link(name), do: GenServer.start_link(__MODULE__, [], name: server(name))

  @doc false
  def server(instance), do: Module.concat(instance, Locks)

  @doc "Runs `fun` holding the lock on `key`, in turn with every other holder of it."
  def with_lock(instance, key, fun) do
    server = server(instance)
    :ok = GenServer.call(server, {:acquire, key}, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, {:release, key, self()})
    end
  end

  @impl true
  def init([]), do: {:ok, %{locks: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, key}, {pid, _} = from, s) do
    ref = Process.monitor(pid)
    s = %{s | monitors: Map.put(s.monitors, ref, key)}

    case s.locks do
      %{^key => {holder, queue}} ->
        {:noreply, %{s | locks: Map.put(s.locks, key, {holder, :queue.in({from, pid, ref}, queue)})}}

      _ ->
        {:reply, :ok, %{s | locks: Map.put(s.locks, key, {{pid, ref}, :queue.new()})}}
    end
  end

  @impl true
  def handle_cast({:release, key, pid}, s) do
    case s.locks do
      %{^key => {{^pid, ref}, _}} ->
        Process.demonitor(ref, [:flush])
        {:noreply, next(%{s | monitors: Map.delete(s.monitors, ref)}, key)}

      _ ->
        {:noreply, s}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _}, s) do
    case Map.pop(s.monitors, ref) do
      {nil, _} ->
        {:noreply, s}

      {key, monitors} ->
        s = %{s | monitors: monitors}

        case s.locks[key] do
          {{_, ^ref}, _} ->
            {:noreply, next(s, key)}

          {holder, queue} ->
            queue = :queue.filter(fn {_, _, r} -> r != ref end, queue)
            {:noreply, %{s | locks: Map.put(s.locks, key, {holder, queue})}}

          nil ->
            {:noreply, s}
        end
    end
  end

  # Hands the lock to the next waiter, or frees it.
  defp next(s, key) do
    {_, queue} = s.locks[key]

    case :queue.out(queue) do
      {{:value, {from, pid, ref}}, rest} ->
        GenServer.reply(from, :ok)
        %{s | locks: Map.put(s.locks, key, {{pid, ref}, rest})}

      {:empty, _} ->
        %{s | locks: Map.delete(s.locks, key)}
    end
  end
end
