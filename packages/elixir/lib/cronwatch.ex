defmodule Cronwatch do
  @moduledoc """
  Know when your cron jobs fail, run late or never run.

  The same library as `@cronwatch/sdk`, the library behind cronwatch.dev,
  for Elixir and Erlang services: it records each run of a job in a store
  the app already has, judges it (failed, stuck, slow, over budget, missed
  its schedule), and sends one alert when a condition opens and one recovery
  when it closes. An Elixir process shares a store with Node, Ruby, Python,
  PHP, Go and Rust processes byte for byte.

  An instance is a child of the app's supervision tree:

      children = [
        MyApp.Repo,
        {Cronwatch,
         store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
         retention: "30d",
         check_every: :timer.minutes(1),
         jobs: [
           {"nightly-report", schedule: "0 2 * * *", timezone: "UTC", grace: "15m", expect: "Report written"}
         ]}
      ]

  and a job's function is run as a recorded run:

      Cronwatch.run("nightly-report", fn job ->
        path = MyApp.Reports.build()
        Cronwatch.log(job, "Report written: \#{path}")
        Cronwatch.metric(job, "cost", 1.2)
        {:ok, path}
      end)

  Every function finds its instance from a `Cronwatch.Job` handle, or from
  `instance:` in its options, else the default name, `Cronwatch`. Functions
  that read or write the store answer `{:ok, value}` or
  `{:error, %Cronwatch.Error{}}`, with a `!` variant that raises.
  """

  alias Cronwatch.Check
  alias Cronwatch.Checker
  alias Cronwatch.Config
  alias Cronwatch.Context
  alias Cronwatch.Core
  alias Cronwatch.Error
  alias Cronwatch.Job
  alias Cronwatch.Lines
  alias Cronwatch.Options
  alias Cronwatch.Run
  alias Cronwatch.Run.Exec
  alias Cronwatch.RunHandle
  alias Cronwatch.Runs

  @run_options [:trigger, :isolate, :kill_at_timeout, :discard_when, :instance]

  ## The instance

  @doc """
  The child spec of an instance: `{Cronwatch, opts}` in the app's tree.

  Options: `name` (default `Cronwatch`), `store` (`{module, opts}`, default
  the memory store), `alerts` (a list of channels, default the console),
  `triage`, `sources`, `cron_secret` (a string, `false` for none, or left
  out to read `CRON_SECRET` when needed), `retention` (default `"30d"`),
  `defaults` (`grace`, `timeout`, `timezone` and `failures_before_alert` for
  every job), `redact` (a function, or `false`), `deliver` (`:now` or
  `:check`), `on_error` (a function of the error and where), `clock`,
  `check_every` (check on an interval; leave it out where another process
  checks), and `jobs` (`{name, options}` declared when it starts).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, Cronwatch),
      start: {Cronwatch.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts an instance outside a supervision tree (a script, a test)."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Cronwatch.Supervisor.start_link(opts)

  @doc "The release this package is, the same as every CronWatch package's."
  @spec version() :: String.t()
  def version do
    case Application.spec(:cronwatch, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  The default redaction: blanks values that look like secrets (secret-named
  pairs, credentials in URLs, authorization headers, private keys, JWTs,
  webhook URLs and common API key formats), exactly as the SDK's default
  does. A `redact:` function can call it and add its own on top.
  """
  @spec redact_secrets(String.t()) :: String.t()
  def redact_secrets(text), do: Cronwatch.Output.redact_secrets(text)

  defp instance(opts), do: Keyword.get(opts, :instance, Cronwatch)

  ## Jobs

  @doc """
  Declares a job and answers its handle. Options: `schedule`, `timezone`,
  `grace`, `timeout`, `max_duration`, `budget`, `expect`,
  `failures_before_alert`, `description` and `tags`, kept in the order given
  (the stored definition follows it), and `instance`.
  """
  @spec job(String.t(), keyword()) :: {:ok, Job.t()} | {:error, Error.t()}
  def job(name, options \\ []) do
    {inst, options} = Keyword.pop(options, :instance, Cronwatch)
    c = Config.get(inst)

    with {:ok, job} <- Job.new(c.name, name, options, c.defaults) do
      Runs.declare(c.name, job)
      {:ok, job}
    end
  end

  @doc "`job/2`, raising `Cronwatch.Error`."
  @spec job!(String.t(), keyword()) :: Job.t()
  def job!(name, options \\ []), do: unwrap(job(name, options))

  @doc "The jobs declared in this instance."
  @spec defined_jobs(keyword()) :: [Job.t()]
  def defined_jobs(opts \\ []), do: Runs.jobs(instance(opts))

  @doc """
  Runs `fun` as a recorded run and answers what it answered. `fun` is given
  the run's `Cronwatch.Context`. A raise, throw, exit, `{:error, reason}` or
  `:error` fails the run, and is handed back as it came (raised again with
  its stacktrace, or returned); anything else succeeds. A binary it returns,
  or `{:ok, binary}`, is the output when nothing was logged.

  `job` is a `Cronwatch.Job` or a name, declared on first use (with job
  options among `opts`, declared again). Options: `trigger` (default
  `"run"`), `isolate` (run the function in a task of the instance, so a
  crash does not take the caller down), `kill_at_timeout` (with `isolate`,
  kill it at the job's timeout and record the run as timed out),
  `discard_when` (a function of a failure's reason: when it answers true for
  a returned `{:error, reason}` or a raised exception, the run is taken back
  rather than judged, for an attempt a queue gives back without failing; the
  failure is still handed back), `instance`.
  """
  @spec run(Job.t() | String.t(), (Context.t() -> result), keyword()) :: result when result: term()
  def run(job, fun, opts \\ []) when is_function(fun, 1) do
    {run_opts, job_opts} = Keyword.split(opts, @run_options)
    job = resolve!(job, job_opts, run_opts)
    Exec.run(job, fun, run_opts)
  end

  defp resolve!(%Job{} = job, [], _), do: job

  defp resolve!(name, job_opts, run_opts) when is_binary(name) do
    inst = instance(run_opts)

    case Runs.job(inst, name) do
      %Job{} = job when job_opts == [] -> job
      _ -> job!(name, [{:instance, inst} | job_opts])
    end
  end

  defp resolve!(%Job{} = job, job_opts, _), do: job!(job.name, [{:instance, job.instance} | job_opts])

  @doc "The calling process's run (or the run of the process that started it), or nil."
  @spec current() :: Context.t() | nil
  defdelegate current(), to: Context

  @doc "Adds a line to the current run's output. Nothing happens outside a run."
  @spec log(term()) :: :ok
  def log(value) do
    case current() do
      nil -> :ok
      ctx -> log(ctx, value)
    end
  end

  @doc """
  Adds a line to a run's output, capped at 16 KB (the tail), shown in alerts
  and the dashboard. A value that is not a binary is written with
  `to_string/1`, or `inspect/1` when it has no `String.Chars`.
  """
  @spec log(Context.t() | RunHandle.t(), term()) :: :ok
  def log(%Context{} = ctx, value), do: Lines.log(Runs.table(ctx.instance, :lines), ctx.key, text(value))
  def log(%RunHandle{} = h, value), do: RunHandle.log(h, value)

  @doc "Reports a number for the current run. Nothing happens outside a run."
  @spec metric(String.t() | atom(), number()) :: :ok
  def metric(name, value) do
    case current() do
      nil -> :ok
      ctx -> metric(ctx, name, value)
    end
  end

  @doc """
  Reports a number for a run: tokens, cost, rows, anything, watched against
  budgets and baselines. A later value for the same name replaces an earlier
  one. Raises `Cronwatch.Error` for a value that is not a finite number.
  """
  @spec metric(Context.t() | RunHandle.t(), String.t() | atom(), number()) :: :ok
  def metric(%Context{} = ctx, name, value) do
    {:ok, name, value} = check_metric!(name, value)
    Lines.metric(Runs.table(ctx.instance, :lines), ctx.key, name, value)
  end

  def metric(%RunHandle{} = h, name, value), do: RunHandle.metric(h, name, value)

  @doc false
  def check_metric!(name, value) do
    name = to_string(name)

    if is_number(value) and Cronwatch.Duration.double?(value),
      do: {:ok, name, Cronwatch.JS.normalize(value)},
      else: raise(Error.invalid("metric #{Cronwatch.JS.quote(name)} must be a finite number"))
  end

  @doc "Whether the run's job timeout has passed: the SDK's aborted signal. The function decides what to do."
  @spec cancelled?(Context.t()) :: boolean()
  def cancelled?(%Context{cancel: cancel}), do: :atomics.get(cancel, 1) == 1

  @doc false
  def text(value) when is_binary(value), do: value

  def text(value) do
    if String.Chars.impl_for(value) != nil and not is_list(value), do: to_string(value), else: inspect(value)
  end

  ## Runs that span calls

  @doc """
  Records a running run now, to finish later, perhaps from another process
  (see `resume/2`): the SDK's `job.start()`. Options: `trigger` (default
  `"start"`) and `id`, a stable id of your own (1 to 200 characters, not
  starting with `pgcron:`). A start with an id already recorded for this job
  records nothing and answers a handle on that run. Store failures go to the
  error handler; it never fails for them.

  Called with a keyword list instead of a job, it is the SDK's `start()`:
  checks on an interval (`every:`, default a minute), for an instance
  started without `check_every`.
  """
  @spec start(Job.t() | String.t() | keyword(), keyword()) :: {:ok, RunHandle.t()} | {:error, Error.t()} | :ok
  def start(job_or_opts \\ [], opts \\ [])

  def start(opts, []) when is_list(opts) do
    inst = instance(opts)

    with {:ok, ms} <- Options.duration_ms(Keyword.get(opts, :every, "1m"), "check interval") do
      Checker.start(inst, ms |> max(5_000) |> min(2_147_483_647) |> Cronwatch.JS.to_int())
    end
  end

  def start(job, opts) do
    {run_opts, _} = Keyword.split(opts, [:instance])
    RunHandle.start(resolve!(job, [], run_opts), opts)
  end

  @doc "Stops the interval `start/1` began."
  @spec stop(keyword()) :: :ok
  def stop(opts \\ []), do: Checker.stop(instance(opts))

  @doc """
  A handle on a run this job started elsewhere, by its id, so this process
  can log to it and finish it.
  """
  @spec resume(Job.t(), String.t()) :: {:ok, RunHandle.t()} | {:error, Error.t()}
  def resume(%Job{} = job, run_id), do: RunHandle.resume(job, run_id)

  @doc "`resume/2` by the job's name, which must be declared in this instance."
  @spec resume_run(String.t(), String.t(), keyword()) :: {:ok, RunHandle.t()} | {:error, Error.t()}
  def resume_run(name, run_id, opts \\ []) do
    case Runs.job(instance(opts), name) do
      nil -> {:error, Error.invalid("resumeRun: job #{Cronwatch.JS.quote(name)} is not declared; call job() first")}
      job -> RunHandle.resume(job, run_id)
    end
  end

  defdelegate flush(handle), to: RunHandle
  defdelegate finish(handle, outcome \\ nil), to: RunHandle
  defdelegate fail(handle, reason), to: RunHandle
  defdelegate active?(handle), to: RunHandle

  @doc """
  Records a run that happened outside this process, for a source: the SDK's
  `recordRun()`. Its job must be declared first, its id 1 to 200
  characters with no NUL, and every metric a finite number, as with
  `metric/3` (else nothing is recorded). Runs are
  keyed by id: a new one is inserted, a stored one still running (or marked
  timeout by a check) is finished when this one is not running, and anything
  else is left alone.
  `evaluate: false` stores it without evaluating it. Answers the alerts it
  sent.
  """
  @spec record_run(Run.t(), keyword()) :: {:ok, [Cronwatch.Alert.t()]} | {:error, Error.t()}
  def record_run(%Run{} = run, opts \\ []) do
    safely(fn -> Check.record_run!(config(opts), run, Keyword.get(opts, :evaluate, true)) end)
  end

  @doc "`record_run/2`, raising."
  def record_run!(run, opts \\ []), do: unwrap(record_run(run, opts))

  ## Checks and reads

  @doc """
  Looks for missed and stuck runs across every job, sends alerts, retries
  alerts no channel accepted, and prunes old runs. Concurrent calls share
  one check.
  """
  @spec check(keyword()) :: {:ok, Cronwatch.CheckResult.t()} | {:error, Error.t()}
  def check(opts \\ []), do: Checker.check(instance(opts))

  @doc "`check/1`, raising."
  def check!(opts \\ []), do: unwrap(check(opts))

  @doc "Every job the store knows about, with its health. Sends no alerts."
  @spec jobs(keyword()) :: {:ok, [Cronwatch.JobSummary.t()]} | {:error, Error.t()}
  def jobs(opts \\ []) do
    with {:ok, list} <- jobs_with_runs(0, opts), do: {:ok, Enum.map(list, &elem(&1, 0))}
  end

  @doc "`jobs/1`, raising."
  def jobs!(opts \\ []), do: unwrap(jobs(opts))

  @doc "Every job's summary with its newest `limit` runs, read together: what the dashboard shows."
  @spec jobs_with_runs(integer(), keyword()) ::
          {:ok, [{Cronwatch.JobSummary.t(), [Run.t()]}]} | {:error, Error.t()}
  def jobs_with_runs(limit \\ 20, opts \\ []), do: safely(fn -> Check.jobs_with_runs!(config(opts), limit) end)

  @doc "`jobs_with_runs/2`, raising."
  def jobs_with_runs!(limit \\ 20, opts \\ []), do: unwrap(jobs_with_runs(limit, opts))

  @doc "A job's summary, or nil."
  @spec job_summary(String.t(), keyword()) :: {:ok, Cronwatch.JobSummary.t() | nil} | {:error, Error.t()}
  def job_summary(name, opts \\ []), do: safely(fn -> Check.job_summary!(config(opts), name) end)

  @doc "`job_summary/2`, raising."
  def job_summary!(name, opts \\ []), do: unwrap(job_summary(name, opts))

  @doc "A job's runs, newest first; `limit` is a whole number from 1 to 500."
  @spec runs(String.t(), integer(), keyword()) :: {:ok, [Run.t()]} | {:error, Error.t()}
  def runs(name, limit \\ 50, opts \\ []), do: safely(fn -> Check.runs!(config(opts), name, limit) end)

  @doc "`runs/3`, raising."
  def runs!(name, limit \\ 50, opts \\ []), do: unwrap(runs(name, limit, opts))

  @doc "A run by id, or nil."
  @spec get_run(String.t(), keyword()) :: {:ok, Run.t() | nil} | {:error, Error.t()}
  def get_run(id, opts \\ []), do: safely(fn -> Check.get_run!(config(opts), id) end)

  @doc "`get_run/2`, raising."
  def get_run!(id, opts \\ []), do: unwrap(get_run(id, opts))

  @doc """
  Stops alerts for a job for a while; its state keeps updating underneath.
  The end is a whole millisecond, held at 2^53 - 1.
  """
  @spec silence(String.t(), term(), keyword()) :: {:ok, Cronwatch.JobState.t()} | {:error, Error.t()}
  def silence(name, duration, opts \\ []) do
    c = config(opts)

    with {:ok, ms} <- Options.duration_ms(duration, "silence duration") do
      until = Cronwatch.Evaluate.silence_end(Core.now(c), ms)
      safely(fn -> Check.patch_state!(c, name, &%{&1 | silenced_until: until}) end)
    end
  end

  @doc "`silence/3`, raising."
  def silence!(name, duration, opts \\ []), do: unwrap(silence(name, duration, opts))

  @doc "Ends a job's silence."
  @spec unsilence(String.t(), keyword()) :: {:ok, Cronwatch.JobState.t()} | {:error, Error.t()}
  def unsilence(name, opts \\ []) do
    safely(fn -> Check.patch_state!(config(opts), name, &%{&1 | silenced_until: nil}) end)
  end

  @doc "`unsilence/2`, raising."
  def unsilence!(name, opts \\ []), do: unwrap(unsilence(name, opts))

  @doc """
  Removes a job and its runs from the store. A job still declared in code
  comes back: on its next run, or at the next check or dashboard read of a
  process that declares it.
  """
  @spec forget(String.t(), keyword()) :: :ok | {:error, Error.t()}
  def forget(name, opts \\ []) do
    with {:ok, _} <- safely(fn -> Check.forget!(config(opts), name) end), do: :ok
  end

  @doc "`forget/2`, raising."
  def forget!(name, opts \\ []), do: unwrap(forget(name, opts))

  @doc """
  Writes the job declared in this instance to the store unless the store
  already holds that definition (compared as JSON, keys in any order), and
  answers whether it wrote.
  """
  @spec sync_job(String.t(), keyword()) :: {:ok, boolean()} | {:error, Error.t()}
  def sync_job(name, opts \\ []) do
    c = config(opts)

    case Runs.job(c.name, name) do
      nil ->
        {:error, Error.invalid("sync_job: job #{Cronwatch.JS.quote(name)} is not declared; call job() first")}

      declared ->
        safely(fn ->
          Core.ensure_ready!(c)

          Core.declaring(c, name, fn ->
            # The declaration as it stands once its turn comes: one made
            # since is the one written.
            job = Runs.job(c.name, name) || declared
            stored = Core.store!(c, :get_job, [name])

            if stored && canonical(stored.definition) == canonical(job.definition) do
              Runs.mark_synced(c.name, job)
              false
            else
              Core.store!(c, :upsert_job, [job.definition, Core.now(c)])
              Runs.mark_synced(c.name, job)
              true
            end
          end)
        end)
    end
  end

  defp canonical(%Cronwatch.JS.Object{pairs: pairs}),
    do: pairs |> Enum.map(fn {k, v} -> {k, canonical(v)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(v), do: Cronwatch.JS.stringify(v)

  ## Helpers

  defp config(opts), do: Config.get(instance(opts))

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    e in Error -> {:error, e}
  end

  defp unwrap({:ok, v}), do: v
  defp unwrap(:ok), do: :ok
  defp unwrap({:error, e}), do: raise(e)
end
