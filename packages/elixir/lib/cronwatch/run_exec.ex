defmodule Cronwatch.Run.Exec do
  @moduledoc false
  # Runs a job's function as a recorded run (client.ts execute()).
  #
  # The function runs in the calling process by default, where the app's
  # context lives. Everything after it returns runs in a task of the
  # instance that the caller waits on, so a caller killed while it waits
  # leaves the recording to finish. A process that dies inside the function
  # has its run recorded by Cronwatch.Runs, which monitors it.

  alias Cronwatch.Config
  alias Cronwatch.Context
  alias Cronwatch.Core
  alias Cronwatch.Evaluate
  alias Cronwatch.Job
  alias Cronwatch.Lines
  alias Cronwatch.Output
  alias Cronwatch.Run
  alias Cronwatch.Runs
  alias Cronwatch.Store
  alias Cronwatch.Telemetry

  @doc "Runs `fun` as a recorded run of `job` and hands back what it did."
  def run(%Job{} = job, fun, opts) do
    c = Config.get(job.instance)
    trigger = Keyword.get(opts, :trigger, "run")
    isolate = Keyword.get(opts, :isolate, false)
    kill = Keyword.get(opts, :kill_at_timeout, false)
    discard = Keyword.get(opts, :discard_when)
    {:ok, timeout} = Evaluate.timeout_ms(job.definition)

    {run, recorded, started} = start(c, job, trigger, nil, discard != nil)
    lines = Runs.table(c.name, :lines)
    Lines.open(lines, run.id)
    cancel = :atomics.new(1, [])

    ctx = %Context{
      instance: c.name,
      job: job.name,
      run_id: run.id,
      started_at: run.started_at,
      key: run.id,
      cancel: cancel,
      trigger: trigger
    }

    info = %{job: job, run: run, recorded: recorded, started: started, cancel: cancel, key: run.id}
    meta = %{instance: c.name, job: job.name, run: run.id, trigger: trigger}

    outcome =
      Telemetry.run_span(meta, fn ->
        outcome =
          if isolate,
            do: call_isolated(c, ctx, info, fun, timeout, kill, &settle(c, job, info, &1, discard, opts)),
            else: call_here(c, ctx, info, fun, timeout)

        {outcome, Map.put(meta, :status, status_of(outcome))}
      end)

    case outcome do
      {:recorded_elsewhere, reason} ->
        exit(reason)

      {:timed_out, _} ->
        c
        |> record(job, info, fn run ->
          snap = Lines.snapshot(lines, run.id)

          %{
            run
            | status: "timeout",
              metrics: snap.metrics,
              output: Core.clean(c, Lines.output(snap)),
              error: Core.clean(c, "Still running after #{Cronwatch.Duration.format(timeout)}; marked as timed out")
          }
        end)
        |> recorded(opts)

        exit(:timeout)

      _ ->
        settle(c, job, info, outcome, discard, opts)
        hand_back(outcome, isolate)
    end
  end

  # Takes the run back (discard_when) or records it as it ended.
  defp settle(c, job, info, outcome, discard, opts) do
    if discard && given_back?(c, job, discard, outcome) && take_back(c, job, info) do
      Lines.close(Runs.table(c.name, :lines), info.key)
    else
      c
      |> record_outcome(job, info, outcome)
      |> recorded(opts)
    end
  end

  # The run as its function ended: judged, recorded and alerted on.
  defp record_outcome(c, job, info, outcome) do
    lines = Runs.table(c.name, :lines)
    failure = failure_text(outcome)
    result = result_of(outcome)

    record(c, job, info, fn run ->
      snap = Lines.snapshot(lines, info.key)
      text = returned_text(result)
      run = %{run | metrics: snap.metrics, output: Lines.output(snap) || (text && Output.cap(text))}
      Core.conclude(c, job.expect, run, failure, Lines.expect_text(snap) || text)
    end)
  end

  # Whether a failed run is one to take back (discard_when): the predicate
  # is asked about a returned {:error, reason} (or :error) and a raised
  # exception, never a throw or an exit. A predicate that raises is
  # reported and the run recorded.
  defp given_back?(c, job, discard, outcome) do
    reason =
      case outcome do
        {:returned, {:error, reason}} -> {:ok, reason}
        {:returned, :error} -> {:ok, :error}
        {:error, e, _} -> {:ok, e}
        _ -> :none
      end

    case reason do
      {:ok, reason} ->
        try do
          discard.(reason) not in [nil, false]
        rescue
          e ->
            Core.report(c, e, "discarding #{job.name}")
            false
        catch
          kind, value ->
            Core.report(c, {kind, value}, "discarding #{job.name}")
            false
        end

      :none ->
        false
    end
  end

  # Takes back a run still running, and says whether the caller is done with
  # it. A store without delete_run_if, or one that fails, is reported and the
  # run is recorded as it ended, so it is not left running to be reported
  # stuck; a row no longer running (a check marked it stuck meanwhile) is
  # reported and left as it is. A run whose start was never written has
  # nothing to take back.
  defp take_back(c, job, info) do
    cond do
      not info.recorded ->
        true

      not Store.has?(c.store, :delete_run_if, 3) ->
        Core.report(
          c,
          Cronwatch.Error.other("the store cannot take back a run (it has no delete_run_if/4); recorded as it ended"),
          "discarding #{job.name}"
        )

        false

      true ->
        try do
          unless Core.store!(c, :delete_run_if, [info.run.id, job.name, "running"]) do
            Core.report(
              c,
              Cronwatch.Error.other("run #{info.run.id} of #{job.name} is no longer running; left as it is"),
              "discarding #{job.name}"
            )
          end

          true
        rescue
          e ->
            Core.report(c, e, "discarding #{job.name}")
            false
        end
    end
  end

  ## A run opened and closed by the caller (the scheduler integrations)

  @doc """
  Opens a run in the calling process, for an integration that sees a run's
  start and end as two events (a telemetry handler): the running row, the
  monitor on this process, the context for `current/0` and the Logger
  metadata, as `run/3` sets them up. `close/2` or `take_back/2` must follow
  in the same process. Options: `trigger`, `id` (a run id of the
  integration's own) and `defer` (close missed and stuck only once the run
  is known not to be given back).
  """
  def open(%Job{} = job, opts) do
    c = Config.get(job.instance)
    trigger = Keyword.get(opts, :trigger, "run")
    {:ok, timeout} = Evaluate.timeout_ms(job.definition)
    {run, recorded, started} = start(c, job, trigger, Keyword.get(opts, :id), Keyword.get(opts, :defer, false))
    Lines.open(Runs.table(c.name, :lines), run.id)
    cancel = :atomics.new(1, [])

    ctx = %Context{
      instance: c.name,
      job: job.name,
      run_id: run.id,
      started_at: run.started_at,
      key: run.id,
      cancel: cancel,
      trigger: trigger
    }

    info = %{job: job, run: run, recorded: recorded, started: started, cancel: cancel, key: run.id}
    Runs.register(c.name, run.id, self(), info, timeout)
    Context.push(ctx)
    previous = Logger.metadata()
    Logger.metadata(cronwatch_job: job.name, cronwatch_run: run.id)
    meta = %{instance: c.name, job: job.name, run: run.id, trigger: trigger, telemetry_span_context: make_ref()}
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:cronwatch, :run, :start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      meta
    )

    %{config: c, job: job, info: info, previous: previous, meta: meta, start_time: start_time}
  end

  @doc """
  Closes a run `open/2` opened, with its outcome as `run/3` sees one
  (`{:returned, value}`, `{:error, exception, stacktrace}`, `{:throw, value,
  stacktrace}` or `{:exit, reason, stacktrace}`), and records it. Nothing is
  recorded when the monitor already has (the process died meanwhile).
  """
  def close(%{config: c, job: job, info: info} = state, outcome) do
    if unwind(state, status_of(outcome)), do: record_outcome(c, job, info, outcome)
    :ok
  end

  @doc """
  Takes back a run `open/2` opened (an attempt given back without failing),
  as `discard_when` does; when the store cannot, the run is recorded with
  `outcome`, as it ended.
  """
  def take_back(%{config: c, job: job, info: info} = state, outcome) do
    if unwind(state, "discarded") do
      if take_back(c, job, info),
        do: Lines.close(Runs.table(c.name, :lines), info.key),
        else: record_outcome(c, job, info, outcome)
    end

    :ok
  end

  # Undoes what open/2 set up in this process, and answers whether the run
  # was still open (the monitor did not record it).
  defp unwind(state, status) do
    Logger.reset_metadata(state.previous)
    Context.pop()
    now = System.monotonic_time()

    :telemetry.execute(
      [:cronwatch, :run, :stop],
      %{duration: now - state.start_time, monotonic_time: now},
      Map.put(state.meta, :status, status)
    )

    Runs.close(state.config.name, state.info.run.id)
  end

  # The run as it was recorded, to the caller's own `recorded:` function
  # (Cronwatch.Handler answers with it), before the outcome is handed back.
  defp recorded(run, opts) do
    case Keyword.get(opts, :recorded) do
      f when is_function(f, 1) -> f.(run)
      _ -> :ok
    end
  end

  # Inserts the running row and closes missed and stuck beside the job,
  # which never waits on it, or, for a run that may be given back, when it
  # is recorded. The store failing never stops the job.
  defp start(c, job, trigger, id, defer) do
    run = %Run{id: id || Core.uuid(), job: job.name, status: "running", started_at: Core.now(c), trigger: trigger}

    recorded =
      try do
        Core.sync!(c, job)
        Core.store!(c, :insert_run, [run])
        true
      rescue
        e ->
          Core.report(c, e, "recording #{job.name}")
          false
      end

    started =
      cond do
        not recorded ->
          nil

        defer ->
          :deferred

        true ->
          {:ok, pid} =
            Task.Supervisor.start_child(Cronwatch.Supervisor.tasks(c.name), fn ->
              try do
                Core.update_state!(c, job.name, fn before -> {Evaluate.on_run_start(before), nil} end)
              rescue
                e -> Core.report(c, e, "starting #{job.name}")
              end
            end)

          pid
      end

    {run, recorded, started}
  end

  defp call_here(c, ctx, info, fun, timeout) do
    Runs.register(c.name, ctx.run_id, self(), info, timeout)
    Context.push(ctx)
    previous = Logger.metadata()
    Logger.metadata(cronwatch_job: ctx.job, cronwatch_run: ctx.run_id)

    try do
      invoke(fun, ctx)
    after
      Logger.reset_metadata(previous)
      Context.pop()
      Runs.close(c.name, ctx.run_id)
    end
  end

  # In a task of the instance, for a function that should not take its
  # caller down. With kill_at_timeout, the task is killed at the job's
  # timeout and the run recorded as a check would mark it.
  #
  # Whoever closes the run in Cronwatch.Runs records it: the task, when its
  # function returns, hands the outcome to the caller and waits for the
  # caller to take it, and records it itself when the caller is gone (killed
  # while it waited), so the run is never left running; the caller, at the
  # timeout or when the task dies; or the monitor, when the task is killed.
  defp call_isolated(c, ctx, info, fun, timeout, kill, orphan) do
    parent = self()
    id = ctx.run_id

    task =
      Task.Supervisor.async_nolink(Cronwatch.Supervisor.tasks(c.name), fn ->
        Runs.register(c.name, id, self(), info, timeout)
        send(parent, {:cronwatch_registered, id})
        Context.push(ctx)
        Logger.metadata(cronwatch_job: ctx.job, cronwatch_run: id)
        outcome = invoke(fun, ctx)
        # Closed here, before the task ends, so the monitor never takes a
        # normal end for a death.
        if Runs.close(c.name, id), do: hand_over(parent, id, outcome, orphan)
        :ok
      end)

    task_ref = task.ref

    receive do
      {:cronwatch_registered, ^id} ->
        deadline = if kill, do: now_ms() + max(Cronwatch.JS.to_int(timeout), 0)
        await_isolated(c, task, id, deadline, timeout)

      # Gone before it was registered: no one else knows of the run.
      {:DOWN, ^task_ref, :process, _, reason} ->
        {:exit, reason, []}
    end
  end

  # The longest a receive can wait at once.
  @max_wait 4_294_967_295

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp await_isolated(c, task, id, deadline, timeout) do
    wait = if deadline, do: min(max(deadline - now_ms(), 0), @max_wait), else: :infinity
    task_ref = task.ref

    receive do
      {:cronwatch_outcome, ^id, pid, outcome} ->
        send(pid, {:cronwatch_taken, id})
        Task.yield(task, :infinity)
        outcome

      {:DOWN, ^task_ref, :process, _, reason} ->
        if Runs.close(c.name, id),
          do: {:exit, reason, []},
          else: {:recorded_elsewhere, reason}
    after
      wait ->
        cond do
          deadline - now_ms() > 0 ->
            await_isolated(c, task, id, deadline, timeout)

          # Past the timeout: closed first, so the monitor does not record
          # the kill as a failure.
          Runs.close(c.name, id) ->
            Task.shutdown(task, :brutal_kill)
            {:timed_out, timeout}

          # The function returned meanwhile: its outcome is on its way.
          true ->
            await_isolated(c, task, id, nil, timeout)
        end
    end
  end

  # The task's side: the caller records the outcome once it has taken it; a
  # caller that died first leaves the recording to the task.
  defp hand_over(parent, id, outcome, orphan) do
    ref = Process.monitor(parent)
    send(parent, {:cronwatch_outcome, id, self(), outcome})

    receive do
      {:cronwatch_taken, ^id} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, :process, _, _} -> orphan.(outcome)
    end
  end

  defp invoke(fun, ctx) do
    {:returned, fun.(ctx)}
  rescue
    e -> {:error, e, __STACKTRACE__}
  catch
    :throw, value -> {:throw, value, __STACKTRACE__}
    :exit, reason -> {:exit, reason, __STACKTRACE__}
  end

  # Everything after the function: in a task that outlives the caller.
  defp record(c, job, info, build) do
    task =
      Task.Supervisor.async_nolink(Cronwatch.Supervisor.tasks(c.name), fn ->
        lines = Runs.table(c.name, :lines)

        try do
          finished_at = Core.now(c)

          run = %{
            info.run
            | finished_at: finished_at,
              duration_ms: Evaluate.run_duration(info.run.started_at, finished_at)
          }

          run = build.(run)
          Lines.close(lines, info.key)
          wait_for(c, job, info.started)

          try do
            case Core.record_finish!(c, job, run, info.recorded, finished_at) do
              nil ->
                :ok

              why ->
                Core.report(
                  c,
                  Cronwatch.Error.other("run #{run.id} of #{job.name} #{why}; ignored"),
                  "finishing #{job.name}"
                )
            end
          rescue
            e -> Core.report(c, e, "recording #{job.name}")
          end

          run
        rescue
          e ->
            Core.report(c, e, "recording #{job.name}")
            nil
        catch
          kind, reason ->
            Core.report(c, {kind, reason}, "recording #{job.name}")
            nil
        after
          # Whatever happened (an app's clock that raised), the run's lines
          # do not outlive it.
          Lines.close(lines, info.key)
        end
      end)

    # nil when the recording itself failed, so a caller's recorded: function
    # is never handed something that is not a run.
    case Task.yield(task, :infinity) do
      {:ok, run} ->
        run

      {:exit, reason} ->
        Core.report(c, {:exit, reason}, "recording #{job.name}")
        nil
    end
  end

  defp wait_for(_c, _job, nil), do: :ok

  # A run that might have been given back closes missed and stuck now that
  # it is known not to be.
  defp wait_for(c, job, :deferred) do
    Core.update_state!(c, job.name, fn before -> {Evaluate.on_run_start(before), nil} end)
  rescue
    e -> Core.report(c, e, "starting #{job.name}")
  end

  defp wait_for(_c, _job, pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end

  @doc "Records a run whose process died inside the function, as failed, with the exit reason."
  def record_dead(instance, _id, info, reason) do
    c = Config.get(instance)

    record(c, info.job, info, fn run ->
      snap = Lines.snapshot(Runs.table(c.name, :lines), run.id)
      run = %{run | metrics: snap.metrics, output: Lines.output(snap)}
      Core.conclude(c, nil, run, Output.describe_exception(:exit, reason, []), nil)
    end)
  end

  # What counts as failed: a raise, a throw, an exit, {:error, reason} and
  # :error; and an HTTP answer of 400 or more.
  defp failure_text({:error, e, st}), do: Output.describe_exception(:error, e, st)
  defp failure_text({:throw, v, st}), do: Output.describe_exception(:throw, v, st)
  defp failure_text({:exit, r, st}), do: Output.describe_exception(:exit, r, st)
  defp failure_text({:returned, {:error, reason}}), do: Output.describe_exception(:returned, reason, [])
  defp failure_text({:returned, :error}), do: Output.describe_exception(:returned, :error, [])
  defp failure_text({:returned, value}), do: http_failure(value)

  defp status_of({:returned, {:error, _}}), do: "failed"
  defp status_of({:returned, :error}), do: "failed"
  defp status_of({:returned, value}), do: if(http_failure(value), do: "failed", else: "ok")
  defp status_of({:timed_out, _}), do: "timeout"
  defp status_of(_), do: "failed"

  @doc false
  # A Plug.Conn, or a Req.Response alone or in {:ok, _}, of status 400 or
  # more, as the SDK fails a run for a fetch Response.
  def http_failure({:ok, value}), do: http_failure(value)

  def http_failure(%{__struct__: struct, status: status})
      when struct in [Plug.Conn, Req.Response] and is_integer(status) do
    if status >= 400, do: "HTTP #{status}" <> reason_phrase(status)
  end

  def http_failure(_), do: nil

  defp reason_phrase(status) do
    if Code.ensure_loaded?(Plug.Conn.Status) do
      # Plug is optional, so the call is made at run time, once it is loaded.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      " " <> apply(Plug.Conn.Status, :reason_phrase, [status])
    else
      ""
    end
  rescue
    _ -> ""
  end

  defp result_of({:returned, value}), do: value
  defp result_of(_), do: nil

  # A binary the function returns, or {:ok, binary}, is the output when
  # nothing was logged, and what expect checks.
  defp returned_text(text) when is_binary(text), do: text
  defp returned_text({:ok, text}) when is_binary(text), do: text
  defp returned_text(_), do: nil

  # A raise, throw or exit is raised again with its stacktrace, so the
  # caller's own handling sees exactly what it would have without
  # CronWatch; a returned value is returned. An isolated run's crash is
  # handed back as an exit.
  defp hand_back({:returned, value}, _isolate), do: value
  defp hand_back({:error, e, st}, _isolate), do: :erlang.raise(:error, e, st)
  defp hand_back({:throw, v, st}, _isolate), do: :erlang.raise(:throw, v, st)
  defp hand_back({:exit, r, st}, false), do: :erlang.raise(:exit, r, st)
  defp hand_back({:exit, r, _st}, true), do: exit(r)
end
