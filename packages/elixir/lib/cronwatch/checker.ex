defmodule Cronwatch.Checker do
  @moduledoc false
  # The one check concurrent callers share, and the interval (the SDK's
  # check() and start()). A call joins the check in flight or starts one, in
  # a task of its own, and every caller waiting gets the same answer, so a
  # caller that gives up neither fails the check for the others nor leaves a
  # job half checked. A crash in the check is that check's error; the next
  # call starts a new one. Each tick asks for a check without waiting on it,
  # as setInterval does, so a tick while a long check runs shares that check.

  use GenServer

  alias Cronwatch.Check
  alias Cronwatch.Config
  alias Cronwatch.Error

  require Logger

  @doc false
  def child_spec(name), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [name]}}

  @doc false
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: server(name))

  @doc false
  def server(instance), do: Module.concat(instance, Checker)

  @doc "Runs a check, or joins the one in flight."
  def check(instance), do: GenServer.call(server(instance), :check, :infinity)

  @doc "Checks on an interval of `ms`; nothing when already started."
  def start(instance, ms), do: GenServer.call(server(instance), {:start, ms}, :infinity)

  @doc "Stops the interval."
  def stop(instance), do: GenServer.call(server(instance), :stop, :infinity)

  @impl true
  def init(instance) do
    s = %{instance: instance, task: nil, waiting: [], timer: nil, every: nil}
    config = Config.get(instance)
    {:ok, if(config.check_every, do: arm(s, config.check_every, 1_000), else: s)}
  end

  @impl true
  def handle_call(:check, from, s), do: {:noreply, begin(%{s | waiting: [from | s.waiting]})}

  def handle_call({:start, ms}, _from, %{every: nil} = s) do
    config = Config.get(s.instance)

    if config.deliver == :check and Cronwatch.Runs.flag(s.instance, :warned_deferred_start) do
      Logger.warning(
        "[cronwatch] start() was called with deliver: :check, so these checks send no alerts. " <>
          "Another process must run checks with deliver: :now (the default) to send them."
      )
    end

    {:reply, :ok, arm(s, ms, 1_000)}
  end

  def handle_call({:start, _ms}, _from, s), do: {:reply, :ok, s}

  def handle_call(:stop, _from, s) do
    if s.timer, do: Process.cancel_timer(s.timer)
    {:reply, :ok, %{s | timer: nil, every: nil}}
  end

  @impl true
  def handle_info(:tick, %{every: every} = s) when every != nil do
    {:noreply, s |> arm(every, every) |> begin()}
  end

  def handle_info(:tick, s), do: {:noreply, s}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(s, result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = s) do
    {:noreply, finish(s, {:error, Error.other("the check stopped: #{Exception.format_exit(reason)}", reason)})}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp arm(s, every, first) do
    if s.timer, do: Process.cancel_timer(s.timer)
    %{s | every: every, timer: Process.send_after(self(), :tick, first)}
  end

  defp begin(%{task: nil} = s) do
    instance = s.instance

    task =
      Task.Supervisor.async_nolink(Cronwatch.Supervisor.tasks(instance), fn ->
        c = Config.get(instance)

        try do
          {:ok, Check.run!(c)}
        rescue
          e in Error ->
            {:error, e}

          e ->
            {:error, Error.other(Exception.message(e), e)}
        end
      end)

    %{s | task: task}
  end

  defp begin(s), do: s

  defp finish(s, result) do
    if s.waiting == [] do
      case result do
        {:error, e} -> Config.report(Config.get(s.instance), e, "check")
        _ -> :ok
      end
    end

    for from <- s.waiting, do: GenServer.reply(from, result)
    %{s | task: nil, waiting: []}
  end
end
