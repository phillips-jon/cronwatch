defmodule Cronwatch.Check do
  @moduledoc false
  # The check (client.ts runCheck), the reads the dashboard makes, silence,
  # forget and record_run. Functions ending in ! raise %Cronwatch.Error{}.

  alias Cronwatch.CheckResult
  alias Cronwatch.Config
  alias Cronwatch.Core
  alias Cronwatch.Delivery
  alias Cronwatch.Duration
  alias Cronwatch.Error
  alias Cronwatch.Evaluate
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Runs
  alias Cronwatch.Serialize
  alias Cronwatch.Telemetry

  @prune_interval 60 * 60_000

  @doc """
  Looks for missed and stuck runs across every job, sends alerts, retries
  alerts no channel accepted, and prunes old runs.
  """
  def run!(%Config{} = c) do
    Telemetry.check_span(%{instance: c.name}, fn ->
      result = do_check!(c)
      {result, %{instance: c.name, jobs: length(result.jobs), alerts: length(result.alerts), pruned: result.pruned}}
    end)
  end

  defp do_check!(c) do
    Core.ensure_ready!(c)

    alerts =
      Enum.flat_map(c.sources, fn {module, opts} = source ->
        try do
          case module.sync(opts, c.name) do
            {:ok, alerts} when is_list(alerts) -> alerts
            {:error, reason} -> raise Error.other(Error.describe(reason), reason)
            _ -> []
          end
        rescue
          e ->
            Core.report(c, e, "source #{source_name(source)}")
            []
        catch
          # An exit (a call to a process that timed out) or a throw is the
          # source's failure too, never the whole check's.
          kind, reason ->
            Core.report(c, {kind, reason}, "source #{source_name(source)}")
            []
        end
      end)

    for job <- Runs.jobs(c.name), do: Core.sync!(c, job)
    now = Core.now(c)

    # Runs that never reported back. One that cannot be judged (its job's
    # stored timeout no longer parses, say) is reported and skipped.
    alerts = alerts ++ Enum.flat_map(Core.store!(c, :running_runs, []), &stuck(c, &1, now))

    # Each job on its own: one that cannot be evaluated is reported, shown as
    # failing and does not stop the others.
    {jobs, alerts, _spent} =
      Enum.reduce(stored_jobs!(c), {[], alerts, 0}, fn {stored, readable}, {jobs, alerts, spent} ->
        try do
          evaluable!(stored, readable)
          recent = Core.store!(c, :list_runs, [stored.name, Evaluate.baseline_window()])

          {state, {{held, dropped}, next}} =
            Core.update_state!(c, stored.name, fn previous ->
              {:ok, {evaluation, next, _due}} =
                ok!(Evaluate.on_check(stored.definition, stored, List.first(recent), previous, now))

              {state, drafts} = Evaluate.apply_silence(previous, evaluation, now)
              # Alerts a process stopped sending part way go back to the retry queue.
              {state, released} = Evaluate.release_sending(state, Core.now(c))
              {state, {held, dropped}} = Delivery.outbox(c, state, drafts, stored.definition, now)
              {state, {{held, released + dropped}, next}}
            end)

          Delivery.report_dropped(c, stored.name, dropped)
          {retried, spent} = Delivery.retry_undelivered(c, stored.name, state, now, spent)
          sent = Delivery.dispatch(c, stored.name, held, now)
          {:ok, summary} = ok!(Evaluate.summarize(stored, recent, state, next, now))
          {jobs ++ [summary], alerts ++ retried ++ sent, spent}
        rescue
          e ->
            Core.report(c, e, "checking #{stored.name}")
            {jobs ++ [unevaluable(c, stored, now)], alerts, spent}
        end
      end)

    pruned =
      if now - last_prune(c) > @prune_interval do
        :ets.insert(Runs.table(c.name, :flags), {:last_prune, now})

        try do
          Core.store!(c, :prune, [now - Cronwatch.JS.to_int(c.retention_ms)])
        rescue
          e ->
            Core.report(c, e, "pruning")
            0
        end
      else
        0
      end

    %CheckResult{checked_at: now, jobs: jobs, alerts: alerts, pruned: pruned}
  end

  # Every stored job, once each declaration has been written. A job declared
  # here that the store no longer has was forgotten by another process after
  # this one wrote it: it is written again, as its next run would, so it is
  # checked and shown while any process still declares it.
  # Each is read leniently, as `{job, readable}` (Serialize.read_stored_job).
  defp stored_jobs!(c) do
    for job <- Runs.jobs(c.name), do: Core.sync!(c, job)
    jobs = Core.store!(c, :list_jobs, [])
    listed = MapSet.new(jobs, & &1.name)

    case Enum.reject(Runs.jobs(c.name), &MapSet.member?(listed, &1.name)) do
      [] ->
        Enum.map(jobs, &Serialize.read_stored_job/1)

      missing ->
        # Not one forgotten here meanwhile.
        for job <- missing, Runs.job(c.name, job.name) == job do
          Runs.unmark_synced(c.name, job.name)
          Core.sync!(c, job)
        end

        Enum.map(Core.store!(c, :list_jobs, []), &Serialize.read_stored_job/1)
    end
  end

  # A job whose stored definition is not a JSON object is not evaluated: it
  # is reported, and shown as failing, while the others carry on.
  defp evaluable!(_stored, true), do: :ok

  defp evaluable!(stored, false),
    do: raise(Error.invalid("job #{Cronwatch.JS.quote(stored.name)}: its stored definition is not a JSON object"))

  defp last_prune(c) do
    case :ets.lookup(Runs.table(c.name, :flags), :last_prune) do
      [{_, at}] -> at
      [] -> 0
    end
  end

  defp source_name({module, opts}) do
    module.name(opts)
  rescue
    _ -> inspect(module)
  catch
    _, _ -> inspect(module)
  end

  defp stuck(c, listed, now) do
    job = Runs.job(c.name, listed.job)

    definition =
      if job do
        job.definition
      else
        case Core.store!(c, :get_job, [listed.job]) do
          nil ->
            nil

          found ->
            {stored, readable} = Serialize.read_stored_job(found)
            evaluable!(stored, readable)
            stored.definition
        end
      end

    # Read again just before the write: lines and metrics flushed since the
    # list was read (while earlier stuck runs were sent, say) are kept.
    with %Object{} <- definition,
         {:ok, true} <- ok!(Evaluate.stuck?(definition, listed, now)),
         %Run{status: "running", job: job_name} = run when job_name == listed.job <-
           Core.store!(c, :get_run, [listed.id]) do
      {:ok, timeout} = ok!(Evaluate.timeout_ms(definition))

      run = %{
        run
        | status: "timeout",
          finished_at: now,
          duration_ms: Evaluate.run_duration(run.started_at, now),
          error: "Still running after #{Duration.format(timeout)}; marked as timed out"
      }

      # Only over a row still running: a finish that landed meanwhile wins.
      if Core.write_run_if!(c, run, ["running"]), do: Core.finish_run(c, definition, run, now), else: []
    else
      _ -> []
    end
  rescue
    e ->
      Core.report(c, e, "checking #{listed.job}")
      []
  end

  defp ok!({:error, message}), do: raise(Error.invalid(message))
  defp ok!(ok), do: ok

  @doc "The summary of a job whose evaluation failed, from whatever can still be read."
  def unevaluable(c, stored, now) do
    recent =
      try do
        Core.store!(c, :list_runs, [stored.name, Evaluate.baseline_window()])
      rescue
        _ -> []
      end

    state =
      try do
        Core.read_state!(c, stored.name)
      rescue
        _ -> Evaluate.empty_state(stored.name)
      end

    Evaluate.unevaluable_summary(stored, recent, state, now)
  end

  # A job's summary and its newest runs, without alerting.
  defp snapshot(c, {stored, readable}, now, runs) do
    recent =
      try do
        {:ok, Core.store!(c, :list_runs, [stored.name, max(runs, Evaluate.baseline_window())])}
      rescue
        e -> {:error, e}
      end

    case recent do
      {:error, e} ->
        Core.report(c, e, "reading #{stored.name}")
        {unevaluable(c, stored, now), []}

      {:ok, recent} ->
        try do
          evaluable!(stored, readable)
          state = Core.read_state!(c, stored.name)
          {:ok, {_, next, _}} = ok!(Evaluate.on_check(stored.definition, stored, List.first(recent), state, now))
          {:ok, summary} = ok!(Evaluate.summarize(stored, recent, state, next, now))
          {summary, Enum.take(recent, runs)}
        rescue
          e ->
            Core.report(c, e, "reading #{stored.name}")
            {unevaluable(c, stored, now), Enum.take(recent, runs)}
        end
    end
  end

  @doc "Every job's summary with its newest `limit` runs."
  def jobs_with_runs!(c, limit) do
    Core.ensure_ready!(c)
    jobs = stored_jobs!(c)
    now = Core.now(c)
    limit = clamp_limit(limit, 20, 0)
    for stored <- jobs, do: snapshot(c, stored, now, limit)
  end

  @doc """
  A job's summary, or nil for one the store does not have. One declared
  here and forgotten elsewhere is written again, as a check does.
  """
  def job_summary!(c, name) do
    Core.ensure_ready!(c)
    if job = Runs.job(c.name, name), do: Core.sync!(c, job, true)

    case Core.store!(c, :get_job, [name]) do
      nil -> nil
      stored -> c |> snapshot(Serialize.read_stored_job(stored), Core.now(c), 0) |> elem(0)
    end
  end

  @doc "A job's runs, newest first."
  def runs!(c, name, limit) do
    Core.ensure_ready!(c)
    Core.store!(c, :list_runs, [name, clamp_limit(limit, 50, 1)])
  end

  @doc "A run by id."
  def get_run!(c, id) do
    Core.ensure_ready!(c)
    Core.store!(c, :get_run, [id])
  end

  defp metric_pairs(nil), do: []
  defp metric_pairs(%Object{} = metrics), do: Object.to_list(metrics)
  defp metric_pairs(metrics) when is_map(metrics) and not is_struct(metrics), do: Enum.to_list(metrics)
  defp metric_pairs(_), do: []

  # A whole number in range, or the fallback for anything that is not a
  # number.
  defp clamp_limit(limit, fallback, min) do
    n = if is_number(limit), do: trunc(limit), else: fallback
    n |> max(min) |> min(500)
  end

  @doc "Reads, changes and writes one job's state, in turn with every other update to it."
  def patch_state!(c, name, change) do
    Core.ensure_ready!(c)

    {state, _} =
      Core.update_state!(c, name, fn current -> {change.(Evaluate.normalize_state(current, name)), nil} end)

    state
  end

  @doc """
  Removes a job and its runs from the store. A job still declared in code
  comes back: here on its next run, and in any other process that declares
  it on its next run there, or at that process's next check or dashboard
  read.
  """
  def forget!(c, name) do
    Core.ensure_ready!(c)
    Runs.undeclare(c.name, name)
    Core.store!(c, :delete_job, [name])
  end

  @doc """
  Records a run that happened outside this process, for a source. Its job
  must be declared first. Answers the alerts it sent.
  """
  def record_run!(c, %Run{} = input, evaluate?) do
    declared = Runs.job(c.name, input.job)

    unless declared do
      raise Error.invalid("record_run: job #{Cronwatch.JS.quote(input.job)} is not declared; call job() first")
    end

    # The longest id start/2 takes; MySQL's column would hold 255, but every store holds 200.
    if not is_binary(input.id) or input.id == "" or Cronwatch.JS.len16(input.id) > 200 do
      got = if is_binary(input.id), do: "#{Cronwatch.JS.len16(input.id)} characters", else: inspect(input.id)

      raise Error.invalid(
              "record_run: run ids must be 1 to 200 characters (got #{got}; job #{Cronwatch.JS.quote(input.job)})"
            )
    end

    if String.contains?(input.id, <<0>>) do
      raise Error.invalid("record_run: run ids cannot contain a NUL character (job #{Cronwatch.JS.quote(input.job)})")
    end

    # Refused as metric/3 refuses them: a store keeps NaN and Infinity as null.
    for {metric, value} <- metric_pairs(input.metrics), not (is_number(value) and Cronwatch.Duration.double?(value)) do
      raise Error.invalid(
              "record_run: metric #{Cronwatch.JS.quote(to_string(metric))} must be a finite number " <>
                "(job #{Cronwatch.JS.quote(input.job)}, run #{Cronwatch.JS.quote(input.id)})"
            )
    end

    Core.sync!(c, declared)

    run =
      if input.status == "ok" do
        case Serialize.check_expectation(declared.expect, input.output) do
          nil -> input
          unmet -> %{input | status: "failed", error: unmet}
        end
      else
        input
      end

    run = %{
      run
      | output: Core.clean(c, run.output),
        error: Core.clean(c, run.error)
    }

    definition = declared.definition

    case Core.store!(c, :get_run, [run.id]) do
      nil ->
        inserted =
          try do
            Core.store!(c, :insert_run, [run])
            :inserted
          rescue
            e in Error ->
              # Another process recorded it first.
              again =
                try do
                  Core.store!(c, :get_run, [run.id])
                rescue
                  Error -> nil
                end

              if again, do: {:over, again}, else: reraise(e, __STACKTRACE__)
          end

        case inserted do
          {:over, stored} ->
            record_over(c, definition, stored, run, evaluate?)

          :inserted ->
            if evaluate? do
              Core.update_state!(c, run.job, fn before -> {Evaluate.on_run_start(before), nil} end)
              if run.status == "running", do: [], else: Core.finish_run(c, definition, run, Core.now(c))
            else
              []
            end
        end

      stored ->
        record_over(c, definition, stored, run, evaluate?)
    end
  end

  defp record_over(c, definition, stored, run, evaluate?) do
    cond do
      stored.job != run.job ->
        Core.report(
          c,
          Error.other("run #{run.id} of #{run.job} belongs to job #{Cronwatch.JS.quote(stored.job)}; ignored"),
          "recording #{run.job}"
        )

        []

      stored.status not in ["running", "timeout"] or run.status == "running" ->
        []

      true ->
        case Core.claim_finish!(c, run) do
          {:ignored, why} ->
            Core.report(c, Error.other("run #{run.id} of #{run.job} #{why}; ignored"), "recording #{run.job}")
            []

          {:ok, late} ->
            if not evaluate? or (late and run.status != "ok"),
              do: [],
              else: Core.finish_run(c, definition, run, Core.now(c))
        end
    end
  end
end
