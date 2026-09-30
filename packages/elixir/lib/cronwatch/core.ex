defmodule Cronwatch.Core do
  @moduledoc false
  # What runs, handles and checks share (client.ts's private methods): the
  # store calls, the one read-modify-write of a job's state, and the finish
  # of a run, written only by the process whose conditional write lands.
  #
  # Functions ending in ! raise %Cronwatch.Error{} when the store fails, as
  # the SDK's throw; the public API turns that back into {:error, error} or
  # hands it to the error handler, as the SDK does at the same places.

  alias Cronwatch.Config
  alias Cronwatch.Delivery
  alias Cronwatch.Error
  alias Cronwatch.Evaluate
  alias Cronwatch.JobState
  alias Cronwatch.Locks
  alias Cronwatch.Output
  alias Cronwatch.Run
  alias Cronwatch.Runs
  alias Cronwatch.Serialize
  alias Cronwatch.Store

  require Logger

  # Reads and writes of one job's state before an update gives up on a
  # store that keeps changing under it.
  @state_attempts 10
  # Runs read for a baseline, and the most read when failures crowd out the
  # successes.
  @history_page 25
  @history_max 200

  def now(c), do: Config.now(c)

  def report(c, error, where), do: Config.report(c, error, where)

  @doc "Calls the store, answering its value or raising %Cronwatch.Error{kind: :store}."
  def store!(%Config{store: store}, fun, args) do
    case Store.call(store, fun, args) do
      :ok -> :ok
      {:ok, value} -> value
      {:error, %Error{} = e} -> raise e
      {:error, reason} -> raise Error.store(reason)
      other -> raise Error.store({:bad_return, fun, other})
    end
  end

  @doc "Creates the store's tables once, before first use; a failure lets the next call try again."
  def ensure_ready!(%Config{} = c) do
    unless Runs.flag?(c.name, :ready) do
      Locks.with_lock(c.name, :ready, fn ->
        unless Runs.flag?(c.name, :ready) do
          if Store.has?(c.store, :init, 0), do: store!(c, :init, [])

          if c.default_store and Cronwatch.Env.production?() do
            Logger.warning(
              "[cronwatch] using the in-memory store: runs and state are lost on restart. " <>
                "Pass a store, such as {Cronwatch.Store.Ecto, repo: MyApp.Repo}."
            )
          end

          Runs.flag(c.name, :ready)
        end
      end)
    end

    :ok
  end

  @doc """
  Writes the declaration of `job`'s name as it stands, unless the store has
  it. A handle kept from an earlier declaration writes the one that replaced
  it, never its own over it, and one forgotten since writes its own. A name
  declared again while its write was under way is still to be written.
  """
  def sync!(c, job) do
    ensure_ready!(c)

    unless Runs.synced?(c.name, job.name) do
      declaring(c, job.name, fn ->
        unless Runs.synced?(c.name, job.name) do
          standing = Runs.job(c.name, job.name) || job
          store!(c, :upsert_job, [standing.definition, now(c)])
          Runs.mark_synced(c.name, standing)
        end
      end)
    end

    :ok
  end

  @doc """
  Runs `fun` in its turn among the writes of one name's declaration, which
  reach the store in the order they were asked for, so one still under way
  cannot land after a later one. A lock of its own, not the state's.
  """
  def declaring(c, name, fun), do: Locks.with_lock(c.name, {:sync, name}, fun)

  @doc "The job's stored state, with every field present."
  def read_state!(c, name), do: Evaluate.normalize_state(store!(c, :get_state, [name]), name)

  @doc """
  Every read-modify-write of a job's state goes through here. Holding the
  job's lock (in turn with this process's other updates to it), it reads the
  state, asks `change` for `{next, result}`, and writes it with the version
  one higher, only if the stored version is still the one read; a refused
  write starts again from a fresh read, up to 10 times. Nothing is written
  when the state is unchanged. Answers `{state_as_stored, result}`.
  """
  def update_state!(c, name, change) do
    Locks.with_lock(c.name, {:state, name}, fn -> update_loop(c, name, change, 1) end)
  end

  defp update_loop(c, name, change, attempt) do
    current = read_state!(c, name)
    {state, result} = change.(current)

    if JobState.to_json(state) == JobState.to_json(current) do
      {current, result}
    else
      version = JobState.version_or_zero(current)
      next = %{state | version: version + 1}

      cond do
        write_state!(c, next, version) ->
          {next, result}

        attempt >= @state_attempts ->
          raise Error.other(
                  "the state of #{name} changed under #{@state_attempts} attempts in a row to update it; gave up"
                )

        true ->
          update_loop(c, name, change, attempt + 1)
      end
    end
  end

  # A conditional write, or for a store without one, a plain one that always
  # succeeds.
  defp write_state!(c, state, expected) do
    if Store.has?(c.store, :compare_and_set_state, 2) do
      store!(c, :compare_and_set_state, [state, expected])
    else
      store!(c, :set_state, [state])
      true
    end
  end

  @doc "A conditional run write, or for a store without one, a read then a plain write."
  def write_run_if!(c, run, from) do
    if Store.has?(c.store, :update_run_if, 2) do
      store!(c, :update_run_if, [run, from])
    else
      case store!(c, :get_run, [run.id]) do
        %Run{status: status} ->
          if status in from do
            store!(c, :update_run, [run])
            true
          else
            false
          end

        nil ->
          false
      end
    end
  end

  @doc """
  Writes a finished run over its stored row, only while that row is still
  running, or else still marked timeout by a check. Only the process whose
  write lands goes on to evaluate the run. `{:ok, late_after_timeout}` or
  `{:ignored, why}`.
  """
  def claim_finish!(c, run) do
    cond do
      write_run_if!(c, run, ["running"]) ->
        {:ok, false}

      write_run_if!(c, run, ["timeout"]) ->
        {:ok, true}

      true ->
        case store!(c, :get_run, [run.id]) do
          nil -> {:ignored, "was not found"}
          stored -> {:ignored, "was already finished as #{stored.status}"}
        end
    end
  end

  @doc """
  Writes a finished run and evaluates it. `recorded` says whether its start
  was written; if not, it is inserted now. Answers why nothing was recorded,
  or nil. Raises when the store does, so a handle can be finished again.
  """
  def record_finish!(c, job, run, recorded, finished_at) do
    inserted =
      if recorded do
        :claim
      else
        # The start was never written; the store may be back by now.
        sync!(c, job)

        try do
          store!(c, :insert_run, [run])
          finish_run(c, job.definition, run, finished_at)
          :done
        rescue
          e in Error ->
            # Another process may have recorded a run with this id meanwhile.
            stored =
              try do
                store!(c, :get_run, [run.id])
              rescue
                Error -> nil
              end

            cond do
              stored == nil -> reraise e, __STACKTRACE__
              stored.job != run.job -> {:ignored, "belongs to job #{Cronwatch.JS.quote(stored.job)}"}
              true -> :claim
            end
        end
      end

    case inserted do
      :done ->
        nil

      {:ignored, why} ->
        why

      :claim ->
        case claim_finish!(c, run) do
          {:ignored, why} ->
            why

          {:ok, late} ->
            if not late or run.status == "ok", do: finish_run(c, job.definition, run, finished_at)
            nil
        end
    end
  end

  @doc """
  Evaluates a finished run, already written, against the job's state and
  sends what that produces. Never raises; answers the alerts.
  """
  def finish_run(c, definition, run, now) do
    # The history is read once per finish, on the first attempt, even when
    # the state update is tried again.
    key = {__MODULE__, :history, make_ref()}

    drafts =
      try do
        {_, drafts} =
          update_state!(c, run.job, fn previous ->
            history = Process.get(key) || Process.put(key, history!(c, run)) || Process.get(key)
            {:ok, e} = ok_or_raise(Evaluate.on_run_finish(definition, run, previous, history, now))
            Evaluate.apply_silence(previous, e, now)
          end)

        {:ok, drafts}
      rescue
        e ->
          report(c, e, "evaluating #{run.job}")
          :error
      after
        Process.delete(key)
      end

    case drafts do
      {:ok, drafts} -> Delivery.dispatch(c, drafts, definition, now)
      :error -> []
    end
  end

  defp ok_or_raise({:ok, v}), do: {:ok, v}
  defp ok_or_raise({:error, message}), do: raise(Error.invalid(message))

  @doc """
  The runs before `run`, newest first, with up to twenty successful ones when
  the store has them: one small read normally, a larger one only when
  failures crowd the successes out of it.
  """
  def history!(c, run) do
    runs = store!(c, :list_runs, [run.job, @history_page])
    others = Enum.reject(runs, &(&1.id == run.id))

    runs =
      if length(runs) == @history_page and Enum.count(others, &(&1.status == "ok")) < Evaluate.baseline_window(),
        do: store!(c, :list_runs, [run.job, @history_max]),
        else: runs

    Enum.reject(runs, &(&1.id == run.id))
  end

  @doc """
  Sets a finished run's status and error from how it ended, then redacts
  its output and error. `failure` is nil or the error's text; the expect
  rule is checked only when the run did not fail.
  """
  def conclude(c, rule, run, failure, expect_text) do
    run =
      case failure do
        nil ->
          case Serialize.check_expectation(rule, expect_text) do
            nil -> %{run | status: "ok"}
            unmet -> %{run | status: "failed", error: unmet}
          end

        text ->
          %{run | status: "failed", error: text}
      end

    # Redacted after the expect check, so a rule can still match what was
    # logged. NULs go last, so not even a custom redact can store one.
    %{run | output: clean(c, run.output), error: clean(c, run.error)}
  end

  @doc "Redacts text as stored, NULs removed last."
  def clean(_c, nil), do: nil
  def clean(c, text), do: Output.strip_nul(Config.redact(c, text))

  @doc "A random run id, as crypto.randomUUID() makes one."
  def uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>> |> Base.encode16(case: :lower) |> dashes()
  end

  defp dashes(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>), do: "#{a}-#{b}-#{c}-#{d}-#{e}"
end
