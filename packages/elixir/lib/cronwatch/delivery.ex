defmodule Cronwatch.Delivery do
  @moduledoc false
  # Composing, triaging, sending, and queueing alerts (client.ts outbox,
  # dispatch, retryUndelivered, recordDelivery, deliver, and addTriage).

  alias Cronwatch.ChannelContext
  alias Cronwatch.Config
  alias Cronwatch.Core
  alias Cronwatch.Evaluate
  alias Cronwatch.Format
  alias Cronwatch.Telemetry

  # How long one channel may take to send one alert.
  @channel_timeout 15_000
  @triage_timeout 25_000
  # Wall-clock time one check spends retrying undelivered alerts, across
  # every job.
  @retry_budget 20_000

  # The three limits, read when used; the tests shorten them through the
  # application environment (:channel_timeout, :triage_timeout,
  # :retry_budget), which apps leave alone.
  defp limit(key, default), do: Application.get_env(:cronwatch, key, default)
  defp channel_timeout, do: limit(:channel_timeout, @channel_timeout)
  defp triage_timeout, do: limit(:triage_timeout, @triage_timeout)
  defp retry_budget, do: limit(:retry_budget, @retry_budget)

  @doc """
  An evaluation as it is written, inside `Cronwatch.Core.update_state!/3`
  (so it only computes): its drafts composed into alerts and held in the
  same state (`Cronwatch.Evaluate.hold_alerts/4`), so the write that opens a
  condition also keeps its alerts, and a process that stops before sending
  them does not lose them. Answers `{state, {alerts, dropped}}`.
  """
  def outbox(%Config{} = c, state, drafts, definition, now) do
    alerts = Enum.map(drafts, &Format.compose_alert(&1, definition, now))
    until = Core.now(c) + Evaluate.send_lease_ms()
    {state, dropped} = Evaluate.hold_alerts(state, alerts, until, c.deliver == :check)
    {state, {alerts, dropped}}
  end

  @doc "Reports alerts let go because a job's queue was full."
  def report_dropped(_c, _name, dropped) when dropped <= 0, do: :ok

  def report_dropped(c, name, dropped) do
    Core.report(
      c,
      Cronwatch.Error.other(
        "#{dropped} undelivered alert#{if dropped == 1, do: "", else: "s"} for #{name} dropped: " <>
          "only the newest #{Evaluate.max_undelivered()} are kept for retry"
      ),
      "alert queue for #{name}"
    )
  end

  @doc """
  Triages and sends each alert the outbox holds (see `outbox/5`). The state,
  with the alerts in it, was saved before this, so a slow channel holds up
  nothing else; afterwards only the delivery fields are written back, onto a
  fresh read of the state, and the alerts leave `sending`. Triage is made
  here, never stored with the held alert. With `deliver: :check` the alerts
  were queued for a check elsewhere instead. Answers the alerts.
  """
  def dispatch(_c, _name, [], _now), do: []

  def dispatch(%Config{deliver: :check} = c, _name, alerts, _now) do
    for alert <- alerts, do: Telemetry.alert(:queued, meta(c, alert, nil))
    alerts
  end

  def dispatch(%Config{} = c, name, alerts, now) do
    {sent, delivered, failed} =
      Enum.reduce(alerts, {[], [], []}, fn alert, {sent, delivered, failed} ->
        alert = if c.triage && alert.type != "recovered", do: add_triage(c, alert, triage_timeout()), else: alert

        if deliver(c, alert) do
          {sent ++ [alert], delivered ++ [alert], failed}
        else
          Telemetry.alert(:queued, meta(c, alert, nil))
          {sent ++ [alert], delivered, failed ++ [alert]}
        end
      end)

    record_delivery(c, name, delivered, failed, [], now)
    sent
  end

  @doc """
  Sends the alerts no channel accepted last time, once each, oldest first;
  one that no longer describes the job is dropped instead. Retries across a
  check share the retry budget of wall-clock time, kept in `spent`.
  Answers `{delivered, spent}`.
  """
  def retry_undelivered(%Config{} = c, name, state, now, spent) do
    pending = state.undelivered || []

    if pending == [] or Evaluate.silenced?(state, now) or c.deliver == :check do
      {[], spent}
    else
      dropped = Enum.filter(pending, &Evaluate.stale_alert?(&1, state))
      for a <- dropped, do: Telemetry.alert(:dropped, meta(c, a, nil))

      {delivered, failed, spent} =
        pending
        |> Enum.reject(&(&1 in dropped))
        |> Enum.reduce_while({[], [], spent}, fn alert, {delivered, failed, spent} ->
          left = retry_budget() - spent

          if left <= 0 do
            {:halt, {delivered, failed, spent}}
          else
            started = System.monotonic_time(:millisecond)

            # An alert queued by a process that delivers at check time was
            # never triaged. One that was tried is not tried again.
            alert =
              if c.triage && alert.type != "recovered" && not alert.triage_tried,
                do: add_triage(c, alert, min(triage_timeout(), left)),
                else: alert

            {delivered, failed} =
              if deliver(c, alert), do: {delivered ++ [alert], failed}, else: {delivered, failed ++ [alert]}

            {:cont, {delivered, failed, spent + max(0, System.monotonic_time(:millisecond) - started)}}
          end
        end)

      record_delivery(c, name, delivered, failed, dropped, now)
      {delivered, spent}
    end
  end

  # Marks delivered alerts done, drops stale ones, and keeps failed ones for
  # the next check, taking them all out of `sending` (record_sent). A failed
  # alert replaces its stored copy, so a triage made on this attempt is kept.
  # last_alert_at moves only on a delivery. When this write fails, alerts
  # still in `sending` are retried once their lease runs out.
  defp record_delivery(c, name, delivered, failed, dropped, now) do
    {_, trimmed} =
      Core.update_state!(c, name, fn previous ->
        Evaluate.record_sent(Evaluate.normalize_state(previous, name), delivered, failed, dropped, now)
      end)

    report_dropped(c, name, trimmed)
  rescue
    e -> Core.report(c, e, "recording alert delivery for #{name}")
  end

  @doc """
  Sends to every channel at once, each in a task of its own stopped after 15
  seconds. True when at least one accepted it, or there are none.
  """
  def deliver(%Config{alerts: []}, _alert), do: true

  def deliver(%Config{} = c, alert) do
    tasks =
      Enum.map(c.alerts, fn {module, state} = channel ->
        name = channel_name(channel)
        ctx = %ChannelContext{on_error: fn e -> Core.report(c, e, "alert channel #{name}") end, transport: c.transport}

        task =
          Task.Supervisor.async_nolink(Cronwatch.Supervisor.tasks(c.name), fn ->
            guarded(fn -> module.send(state, alert, ctx) end)
          end)

        {task, name}
      end)

    results = Task.yield_many(Enum.map(tasks, &elem(&1, 0)), channel_timeout())

    tasks
    |> Enum.zip(results)
    |> Enum.map(fn {{task, name}, {_, result}} ->
      outcome =
        case result do
          {:ok, :ok} ->
            :ok

          {:ok, {:error, reason}} ->
            {:error, reason}

          {:ok, other} ->
            {:error, "channel #{name} answered #{inspect(other)}"}

          {:exit, reason} ->
            {:error, {:exit, reason}}

          nil ->
            Task.shutdown(task, :brutal_kill)
            {:error, Cronwatch.Error.other("timed out after #{channel_timeout()}ms")}
        end

      case outcome do
        :ok ->
          Telemetry.alert(:sent, meta(c, alert, name))
          true

        {:error, reason} ->
          Core.report(c, reason, "alert channel #{name}")
          Telemetry.alert(:failed, meta(c, alert, name))
          false
      end
    end)
    |> Enum.any?()
  end

  defp channel_name({module, state}) do
    module.name(state)
  rescue
    _ -> inspect(module)
  catch
    _, _ -> inspect(module)
  end

  # Sets the alert's triage to the diagnosis, or to nil when there is none, so
  # it is tried once per alert.
  defp add_triage(c, alert, timeout) do
    recent =
      try do
        Core.store!(c, :list_runs, [alert.job, 5])
      rescue
        _ -> []
      end

    context = %{alert: alert, recent_runs: recent, transport: c.transport}

    task =
      Task.Supervisor.async_nolink(Cronwatch.Supervisor.tasks(c.name), fn ->
        guarded(fn ->
          case c.triage do
            f when is_function(f, 1) -> f.(context)
            {module, opts} -> module.triage(opts, context)
            module when is_atom(module) -> module.triage([], context)
          end
        end)
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, text}} when is_binary(text) and text != "" -> {:ok, text}
        {:ok, text} when is_binary(text) and text != "" -> {:ok, text}
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, _} -> {:ok, nil}
        {:exit, reason} -> {:error, {:exit, reason}}
        nil -> {:error, Cronwatch.Error.other("timed out after #{timeout}ms")}
      end

    case result do
      {:ok, text} ->
        %{alert | triage: text, triage_tried: true}

      {:error, reason} ->
        Core.report(c, reason, "triage for #{alert.job}")
        %{alert | triage: nil, triage_tried: true}
    end
  end

  # A raise, throw, or exit in a channel or triage is its error, answered
  # from the task rather than crashing it (and logging a crash report).
  defp guarded(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  defp meta(c, alert, channel) do
    %{
      instance: c.name,
      job: alert.job,
      type: alert.type,
      condition: if(alert.type == "recovered", do: nil, else: alert.type),
      channel: channel
    }
  end
end
