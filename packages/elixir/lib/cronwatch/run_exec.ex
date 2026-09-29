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
  alias Cronwatch.Telemetry

  @doc "Runs `fun` as a recorded run of `job` and hands back what it did."
  def run(%Job{} = job, fun, opts) do
    c = Config.get(job.instance)
    trigger = Keyword.get(opts, :trigger, "run")
    isolate = Keyword.get(opts, :isolate, false)
    kill = Keyword.get(opts, :kill_at_timeout, false)
    {:ok, timeout} = Evaluate.timeout_ms(job.definition)

    {run, recorded, started} = start(c, job, trigger)
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
            do: call_isolated(c, ctx, info, fun, timeout, kill),
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
        failure = failure_text(outcome)
        result = result_of(outcome)

        c
        |> record(job, info, fn run ->
          snap = Lines.snapshot(lines, run.id)
          text = returned_text(result)
          run = %{run | metrics: snap.metrics, output: Lines.output(snap) || (text && Output.cap(text))}
          Core.conclude(c, job.expect, run, failure, Lines.expect_text(snap) || text)
        end)
        |> recorded(opts)

        hand_back(outcome, isolate)
    end
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
  # which never waits on it. The store failing never stops the job.
  defp start(c, job, trigger) do
    run = %Run{id: Core.uuid(), job: job.name, status: "running", started_at: Core.now(c), trigger: trigger}

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
      if recorded do
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
  defp call_isolated(c, ctx, info, fun, timeout, kill) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(Cronwatch.Supervisor.tasks(c.name), fn ->
        Runs.register(c.name, ctx.run_id, self(), info, timeout)
        send(parent, {:cronwatch_registered, ctx.run_id})
        Context.push(ctx)
        Logger.metadata(cronwatch_job: ctx.job, cronwatch_run: ctx.run_id)
        outcome = invoke(fun, ctx)
        # Closed here, before the task ends, so the monitor never takes a
        # normal end for a death.
        Runs.close(c.name, ctx.run_id)
        outcome
      end)

    receive do
      {:cronwatch_registered, id} when id == ctx.run_id -> :ok
    end

    wait = if kill, do: max(Cronwatch.JS.to_int(timeout), 0), else: :infinity

    case Task.yield(task, wait) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        # Whoever closes the run records it: the monitor, or this caller.
        if Runs.close(c.name, ctx.run_id),
          do: {:exit, reason, []},
          else: {:recorded_elsewhere, reason}

      nil ->
        # Past the timeout: closed first, so the monitor does not record the
        # kill as a failure; a function that returned meanwhile is recorded
        # as it ended.
        closed = Runs.close(c.name, ctx.run_id)

        case Task.shutdown(task, :brutal_kill) do
          {:ok, outcome} -> outcome
          _ when closed -> {:timed_out, timeout}
          _ -> {:recorded_elsewhere, :killed}
        end
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
        finished_at = Core.now(c)
        run = %{info.run | finished_at: finished_at, duration_ms: max(0, finished_at - info.run.started_at)}
        run = build.(run)
        Lines.close(Runs.table(c.name, :lines), info.key)
        wait_for(info.started)

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
      end)

    case Task.yield(task, :infinity) do
      {:ok, run} -> run
      {:exit, reason} -> Core.report(c, {:exit, reason}, "recording #{job.name}")
    end
  end

  defp wait_for(nil), do: :ok

  defp wait_for(pid) do
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
