defmodule Cronwatch.RunHandle do
  @moduledoc """
  A run recorded by `Cronwatch.start/2`, or found by `Cronwatch.resume/2`, to
  finish later, perhaps from another process: the SDK's `RunHandle`.

  Lines and metrics wait in the handle (in the instance's table, owned by
  the process that made the handle and dropped when it ends) until
  `flush/1` or `finish/2` merges them onto a fresh read of the stored run.
  The store never fails out of `start`, `resume`, `flush` or `finish`:
  failures go to the error handler, and a store that fails during `finish`
  leaves the handle active, lines kept, so it can be called again. A handle
  whose process ended while it was active records nothing; a run left
  unfinished is what the stuck check is for.
  """

  alias Cronwatch.Config
  alias Cronwatch.Core
  alias Cronwatch.Error
  alias Cronwatch.Evaluate
  alias Cronwatch.Job
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Lines
  alias Cronwatch.Locks
  alias Cronwatch.Output
  alias Cronwatch.Run
  alias Cronwatch.Run.Exec
  alias Cronwatch.Runs

  @enforce_keys [:instance, :id, :job, :ref]
  defstruct [:instance, :id, :job, :started_at, :ref]

  @type t :: %__MODULE__{
          instance: atom(),
          id: String.t(),
          job: String.t(),
          started_at: integer() | nil,
          ref: reference()
        }

  # Run ids that start with this belong to the pg_cron source.
  @reserved "pgcron:"

  @doc false
  def reserved_prefix, do: @reserved

  ## Making one

  @doc false
  def start(%Job{} = job, opts) do
    c = Config.get(job.instance)
    trigger = Keyword.get(opts, :trigger, "start")

    case Keyword.fetch(opts, :id) do
      :error ->
        record_start(c, job, trigger, nil)

      {:ok, id} ->
        with :ok <- check_run_id(job.name, id, "start") do
          # Keyed by job as well, so another job's start with the same id is
          # not handed this job's run: it fails as it would one call later.
          Locks.with_lock(c.name, {:start, job.name, id}, fn -> record_start(c, job, trigger, id) end)
        end
    end
  end

  defp record_start(c, job, trigger, id) do
    stored =
      if id do
        try do
          Core.ensure_ready!(c)
          Core.store!(c, :get_run, [id])
        rescue
          e ->
            Core.report(c, e, "recording #{job.name}")
            nil
        end
      end

    if stored do
      existing(c, job, stored)
    else
      run = %Run{id: id || Core.uuid(), job: job.name, status: "running", started_at: Core.now(c), trigger: trigger}

      recorded =
        try do
          Core.sync!(c, job)
          Core.store!(c, :insert_run, [run])
          true
        rescue
          e ->
            # Another process may have started a run with this id first.
            again =
              if id do
                try do
                  Core.store!(c, :get_run, [id])
                rescue
                  _ -> nil
                end
              end

            if again, do: {:existing, again}, else: reported(c, e, "recording #{job.name}")
        end

      case recorded do
        {:existing, stored} ->
          existing(c, job, stored)

        recorded ->
          if recorded do
            try do
              Core.update_state!(c, job.name, fn before -> {Evaluate.on_run_start(before), nil} end)
            rescue
              e -> Core.report(c, e, "starting #{job.name}")
            end
          end

          {:ok, make(c, job, run.id, run, recorded, nil)}
      end
    end
  end

  @doc false
  def resume(%Job{} = job, run_id) do
    c = Config.get(job.instance)

    with :ok <- check_run_id(job.name, run_id, "resume") do
      try do
        Core.ensure_ready!(c)
        Core.store!(c, :get_run, [run_id])
      rescue
        e ->
          Core.report(c, e, "resuming #{job.name}")
          {:ok, make(c, job, run_id, nil, true, nil)}
      else
        nil -> {:ok, make(c, job, run_id, nil, true, "was not found")}
        stored -> existing(c, job, stored)
      end
    end
  end

  # Reports an error and answers false: nothing was recorded.
  defp reported(c, error, where) do
    Core.report(c, error, where)
    false
  end

  # A handle on a stored run. One still running, or marked timeout by a
  # check, can be finished.
  defp existing(c, job, stored) do
    if stored.job != job.name do
      {:error,
       Error.invalid("run #{JS.quote(stored.id)} belongs to job #{JS.quote(stored.job)}, not #{JS.quote(job.name)}")}
    else
      inactive = if stored.status in ["ok", "failed"], do: "already finished as #{stored.status}"
      {:ok, make(c, job, stored.id, stored, true, inactive)}
    end
  end

  defp make(c, job, id, base, recorded, inactive) do
    ref = make_ref()

    state = %{
      job: job,
      base: base,
      recorded: recorded,
      inactive: inactive,
      finished: inactive != nil,
      finish_called: false,
      head: nil
    }

    Runs.register_handle(c.name, ref, self(), state)
    Lines.open(lines(c), {:handle, ref})
    %__MODULE__{instance: c.name, id: id, job: job.name, started_at: base && base.started_at, ref: ref}
  end

  # A run id no store could hold, or one reserved for the pg_cron source.
  defp check_run_id(job, id, method) do
    cond do
      not is_binary(id) or id == "" or JS.len16(id) > 200 ->
        got = if is_binary(id), do: "#{JS.len16(id)} characters", else: inspect(id)
        {:error, Error.invalid("job #{JS.quote(job)}: #{method}() needs a run id of 1 to 200 characters (got #{got})")}

      String.starts_with?(id, @reserved) ->
        {:error,
         Error.invalid(
           "job #{JS.quote(job)}: #{method}() cannot take a run id starting with #{JS.quote(@reserved)}, " <>
             "which the pg_cron source uses for its runs"
         )}

      true ->
        :ok
    end
  end

  ## Using one

  defp lines(%Config{name: name}), do: Runs.table(name, :lines)
  defp lines(instance) when is_atom(instance), do: Runs.table(instance, :lines)
  defp state(h), do: Runs.handle(h.instance, h.ref)

  defp update(h, fun) do
    case state(h) do
      nil -> nil
      s -> Runs.put_handle(h.instance, h.ref, fun.(s))
    end
  end

  @doc "False once finished, and from the start for a resumed run that already finished or does not exist."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{} = h) do
    case state(h) do
      %{finished: finished} -> not finished
      nil -> false
    end
  end

  @doc "Adds a line of output, kept in the handle until `flush/1` or `finish/2`."
  @spec log(t(), term()) :: :ok
  def log(%__MODULE__{} = h, value), do: Lines.log(lines(h.instance), {:handle, h.ref}, Cronwatch.text(value))

  @doc "Reports a number for this run; a later value for the same name replaces an earlier one."
  @spec metric(t(), String.t() | atom(), number()) :: :ok
  def metric(%__MODULE__{} = h, name, value) do
    {:ok, name, value} = Cronwatch.check_metric!(name, value)
    Lines.metric(lines(h.instance), {:handle, h.ref}, name, value)
  end

  @doc """
  Appends the lines and metrics added so far to the stored run, which must
  still be running and belong to this job, and only while it is running, so
  a flush never undoes a finish.
  """
  @spec flush(t()) :: :ok
  def flush(%__MODULE__{} = h) do
    c = Config.get(h.instance)
    Locks.with_lock(c.name, {:handle, h.ref}, fn -> do_flush(c, h) end)
    :ok
  end

  defp do_flush(c, h) do
    s = state(h)
    key = {:handle, h.ref}
    t = lines(c)

    with %{finished: false, recorded: true} <- s,
         snap = Lines.snapshot(t, key),
         true <- snap.lines != [] or snap.metrics.pairs != [] do
      # Lines logged while this waits on the store go to a new recorder.
      taken = Lines.take(t, key)
      put_back = fn -> Lines.put_back(t, key, taken) end
      name = s.job.name

      try do
        case Core.store!(c, :get_run, [h.id]) do
          # Not running: the lines stay here for finish(), which reports why
          # it cannot record them.
          %Run{status: "running", job: ^name} = stored ->
            added = Lines.output(taken)
            output = if added, do: join_output(stored.output, Core.clean(c, added)), else: stored.output
            written = %{stored | output: output, metrics: Object.merge(stored.metrics, taken.metrics)}

            if Core.write_run_if!(c, written, ["running"]) do
              text = Lines.expect_text(taken)

              if text != nil and (s.head == nil or JS.len16(s.head) < Output.output_cap()) do
                head = JS.head16(join_lines(s.head, text) || "", Output.output_cap())
                update(h, &%{&1 | head: head})
              end
            else
              put_back.()
            end

          %Run{status: "running"} = stored ->
            put_back.()

            Core.report(
              c,
              Error.other("run #{h.id} of #{name} belongs to job #{JS.quote(stored.job)}; ignored"),
              "flushing #{name}"
            )

          _ ->
            put_back.()
        end
      rescue
        e ->
          put_back.()
          Core.report(c, e, "flushing #{name}")
      end
    end
  end

  @doc """
  Finishes the run, judges it like any other and sends what that produces.
  `outcome` is nil (success), the text the run produced, `{:ok, result}`
  (treated as a job function's result), or `{:error, reason}` (a failure).
  Answers the run as recorded, or nil when nothing was recorded: the run was
  already finished (here or elsewhere), was not found, or belongs to another
  job, which is reported to the error handler. When several processes
  finish one run, only the one whose write lands judges it.
  """
  @spec finish(t(), term()) :: Run.t() | nil
  def finish(%__MODULE__{} = h, outcome \\ nil) do
    c = Config.get(h.instance)
    s = state(h)
    name = h.job
    ignored = fn why -> Core.report(c, Error.other("run #{h.id} of #{name} #{why}; ignored"), "finishing #{name}") end

    cond do
      s == nil ->
        ignored.("was already finished by this handle")
        nil

      s.finish_called ->
        ignored.("was already finished by this handle")
        nil

      true ->
        was_inactive = s.finished
        update(h, &%{&1 | finish_called: true, finished: true})

        result =
          Locks.with_lock(c.name, {:handle, h.ref}, fn ->
            if was_inactive do
              ignored.(s.inactive)
              nil
            else
              do_finish(c, h, outcome, ignored)
            end
          end)

        # Done with for good, unless the store failed part way and it can be
        # finished again: forgotten now, as a finished handle answers the
        # same whether its state is kept or not.
        case state(h) do
          %{finish_called: true} -> Runs.drop_handle(c.name, h.ref)
          _ -> :ok
        end

        result
    end
  end

  @doc "`finish(handle, {:error, reason})`."
  @spec fail(t(), term()) :: Run.t() | nil
  def fail(%__MODULE__{} = h, reason), do: finish(h, {:error, reason})

  defp do_finish(c, h, outcome, ignored) do
    s = state(h)
    job = s.job
    t = lines(c)
    key = {:handle, h.ref}

    # The store failed part way and nothing was recorded, so the handle can
    # be finished again.
    retryable = fn e ->
      update(h, &%{&1 | finish_called: false, finished: false})
      Core.report(c, e, "finishing #{job.name}")
      nil
    end

    try do
      from = if s.recorded, do: Core.store!(c, :get_run, [h.id]) || s.base, else: s.base

      cond do
        from == nil ->
          ignored.("was not found")
          nil

        from.job != job.name ->
          ignored.("belongs to job #{JS.quote(from.job)}")
          nil

        from.status in ["ok", "failed"] ->
          ignored.("was already finished as #{from.status}")
          nil

        true ->
          {failure, result} =
            case outcome do
              {:error, reason} -> {Output.describe_exception(:returned, reason, []), nil}
              {:ok, value} -> {Exec.http_failure(value), value}
              value -> {Exec.http_failure(value), value}
            end

          text =
            case result do
              t when is_binary(t) -> t
              {:ok, t} when is_binary(t) -> t
              _ -> nil
            end

          snap = Lines.snapshot(t, key)
          finished_at = Core.now(c)
          added = Lines.output(snap) || (text && Output.cap(text))

          run = %{
            from
            | status: "running",
              finished_at: finished_at,
              duration_ms: Core.sat(max(0, finished_at - from.started_at)),
              error: nil,
              output: join_output(from.output, added),
              metrics: Object.merge(from.metrics, snap.metrics)
          }

          expect_text = join_lines(s.head, join_lines(from.output, Lines.expect_text(snap) || text))
          run = Core.conclude(c, job.expect, run, failure, expect_text)

          case Core.record_finish!(c, job, run, s.recorded, finished_at) do
            nil ->
              Lines.close(t, key)
              run

            why ->
              ignored.(why)
              nil
          end
      end
    rescue
      e -> retryable.(e)
    end
  end

  # Two stretches of text as one, a line apart; either may be nil.
  defp join_lines(nil, after_text), do: after_text
  defp join_lines("", after_text), do: after_text
  defp join_lines(before, nil), do: before
  defp join_lines(before, after_text), do: before <> "\n" <> after_text

  # Output appended to stored output, capped like any run's.
  defp join_output(before, after_text) do
    case join_lines(before, after_text) do
      nil -> nil
      joined -> Output.cap(joined)
    end
  end

  defimpl Inspect do
    def inspect(h, _opts), do: "#Cronwatch.RunHandle<#{h.job} #{h.id}>"
  end
end
