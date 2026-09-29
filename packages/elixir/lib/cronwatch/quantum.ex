if Code.ensure_loaded?(Quantum) do
  defmodule Cronwatch.Quantum do
    @moduledoc """
    CronWatch for a Quantum 3.5 scheduler, with no changes to its jobs: one
    entry in the instance's options.

        {Cronwatch,
         store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
         integrations: [{Cronwatch.Quantum, scheduler: MyApp.Scheduler, jobs: [nightly_report: [grace: "15m"]]}]}

    and, among the scheduler's jobs, the check:

        config :my_app, MyApp.Scheduler,
          jobs: [
            nightly_report: [schedule: "0 2 * * *", task: {MyApp.Reports, :nightly, []}],
            cronwatch_check: [schedule: "* * * * *", task: {Cronwatch.Quantum, :check, [[scheduler: MyApp.Scheduler]]}]
          ]

    ## Which jobs

    Every active job of `MyApp.Scheduler.jobs()`, named after its name
    (`:nightly_report` is `nightly_report`); an unnamed job (its name a
    reference) is named after its task when that is `{Module, :function,
    args}` (`MyApp.Reports.nightly`), and otherwise reported once and not
    watched. Its schedule is the `Crontab.CronExpression` composed back to
    text (an extended one with its seconds first, as croner reads six
    fields), in the job's zone (`:utc` is `UTC`), and checked against
    Quantum's own reading of it: the crontab package's fire times, with a
    time that does not exist or happens twice in the zone skipped, as
    Quantum skips it. One that differs (the crontab package matches a day of
    the month and a day of the week both, where croner matches either) is
    reported once and watched without a schedule. Jobs added, deleted,
    activated or deactivated at run time are followed through Quantum's own
    telemetry (`[:quantum, :job, :add | :update | :delete]`), and the jobs are
    read again every minute besides; a job no longer active is declared
    again without its schedule.

    ## Runs

    Quantum's `[:quantum, :job, :start]`, `:stop` and `:exception` events, in
    the task that runs the job, start and finish a run (trigger `quantum`),
    with its context in that task, so `Cronwatch.log/1` works inside the
    job's function. A job's function answering `{:error, reason}` fails the
    run, as `Cronwatch.run/3` has it. The task is monitored, so a job killed
    part way is a failed run at once.

    ## Jobs gone and the check

    `check/1` runs `sync/1` and a CronWatch check; give it to the scheduler
    as a job (above). The sync declares the scheduler's jobs again, and again
    without its schedule each job of this app's the store holds with a
    schedule the scheduler no longer has. Jobs are tagged `quantum` and
    `quantum:<app>`, the app named by the `app` option, else
    `$CRONWATCH_APP_ID`, else the OTP application that started the instance.

    Options: `scheduler` (the Quantum scheduler module, required), `app`,
    `defaults` (job options for every job, before its schedule) and `jobs`
    (job options by the Quantum job's name).
    """

    use GenServer

    alias Crontab.CronExpression
    alias Crontab.CronExpression.Composer
    alias Cronwatch.Bridge
    alias Cronwatch.Bridge.Entry
    alias Cronwatch.Bridge.Watch
    alias Cronwatch.Config
    alias Cronwatch.Core
    alias Cronwatch.Error
    alias Cronwatch.JS
    alias Cronwatch.Run.Exec
    alias Cronwatch.Zone

    @tag "quantum"
    @trigger "quantum"
    @scheduler "Quantum"
    @sync_timeout 30_000
    @resync_every 60_000

    @doc false
    def child_spec(opts) do
      %{id: {__MODULE__, Keyword.fetch!(opts, :scheduler)}, start: {__MODULE__, :start_link, [opts]}}
    end

    @doc false
    def start_link(opts) do
      instance = Keyword.get(opts, :instance, Cronwatch)
      GenServer.start_link(__MODULE__, opts, name: server(instance, Keyword.fetch!(opts, :scheduler)))
    end

    @doc false
    def server(instance, scheduler), do: Module.concat([instance, __MODULE__, scheduler])

    @doc """
    Declares the scheduler's jobs again, and again without its schedule each
    job of this app's the store holds with a schedule the scheduler no
    longer has. Everything is written to the store before it returns, within
    30 seconds. Options: `instance`, `scheduler`.
    """
    @spec sync(keyword()) :: :ok | {:error, Error.t()}
    def sync(opts) do
      instance = Keyword.get(opts, :instance, Cronwatch)
      server = server(instance, Keyword.fetch!(opts, :scheduler))

      task =
        Task.Supervisor.async_nolink(Cronwatch.Supervisor.tasks(instance), fn ->
          watch = GenServer.call(server, :declare, :infinity)
          Watch.settle(watch)

          case Watch.unschedule(watch) do
            {:ok, _} -> :ok
            error -> error
          end
        end)

      case Task.yield(task, @sync_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error, Error.other("the sync failed: #{Cronwatch.Output.describe_exception(:exit, reason, [])}")}

        nil ->
          {:error, Error.other("the sync took longer than #{div(@sync_timeout, 1000)} seconds; gave up")}
      end
    end

    @doc """
    `sync/1`, then a CronWatch check: the task of a scheduler job
    (`{Cronwatch.Quantum, :check, [[scheduler: MyApp.Scheduler]]}`), whose
    runs are never a job. A sync that fails is reported to the instance's
    error handler, and the check runs all the same.
    """
    @spec check(keyword()) :: {:ok, Cronwatch.CheckResult.t()} | {:error, Error.t()}
    def check(opts) do
      instance = Keyword.get(opts, :instance, Cronwatch)

      case sync(opts) do
        :ok -> :ok
        {:error, e} -> Core.report(Config.get(instance), e, "quantum")
      end

      Cronwatch.check(instance: instance)
    end

    @doc "Waits until what the integration declared has been written to the store, for tests and a clean exit."
    @spec settle(keyword()) :: :ok
    def settle(opts) do
      server = server(Keyword.get(opts, :instance, Cronwatch), Keyword.fetch!(opts, :scheduler))
      server |> GenServer.call(:watch, :infinity) |> Watch.settle()
    end

    ## The process

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      instance = Keyword.get(opts, :instance, Cronwatch)
      scheduler = Keyword.fetch!(opts, :scheduler)

      case Watch.start_link(instance: instance, tag: @tag, app: opts[:app], scheduler: @scheduler) do
        {:ok, watch} ->
          cfg = %{
            instance: instance,
            scheduler: scheduler,
            server: self(),
            watch: watch,
            defaults: Keyword.get(opts, :defaults, []),
            jobs: Map.new(Keyword.get(opts, :jobs, []), fn {name, options} -> {to_string(name), options} end)
          }

          id = {__MODULE__, instance, scheduler}

          :telemetry.attach_many(
            id,
            for(event <- [:start, :stop, :exception, :add, :update, :delete], do: [:quantum, :job, event]),
            &__MODULE__.handle_event/4,
            cfg
          )

          send(self(), :declare)
          {:ok, %{cfg: cfg, id: id, converted: %{}, timer: nil}}

        {:error, reason} ->
          {:stop, reason}
      end
    end

    @impl true
    def handle_call(:declare, _from, s), do: {:reply, s.cfg.watch, declare(s)}
    def handle_call(:watch, _from, s), do: {:reply, s.cfg.watch, s}

    @impl true
    def handle_info(:declare, s) do
      if s.timer, do: Process.cancel_timer(s.timer)
      s = declare(s)
      {:noreply, %{s | timer: Process.send_after(self(), :declare, @resync_every)}}
    end

    def handle_info({:EXIT, pid, reason}, %{cfg: %{watch: pid}} = s), do: {:stop, reason, s}
    def handle_info(_msg, s), do: {:noreply, s}

    @impl true
    def terminate(_reason, s) do
      :telemetry.detach(s.id)
      :ok
    end

    defp declare(s) do
      case jobs(s.cfg.scheduler) do
        {:ok, jobs} ->
          {entries, s} =
            Enum.reduce(jobs, {[], s}, fn {_name, job}, {acc, s} ->
              case entry(s, job) do
                {nil, s} -> {acc, s}
                {e, s} -> {acc ++ [e], s}
              end
            end)

          Watch.declare(s.cfg.watch, entries)
          s

        :not_running ->
          s
      end
    rescue
      e ->
        report(s.cfg, e, "declaring the Quantum jobs")
        s
    end

    defp jobs(scheduler) do
      {:ok, scheduler.jobs()}
    rescue
      _ -> :not_running
    catch
      :exit, _ -> :not_running
    end

    # The check is never a job.
    defp entry(s, %Quantum.Job{task: {__MODULE__, :check, _}}), do: {nil, s}

    defp entry(s, %Quantum.Job{state: :active} = job) do
      case name_of(job) do
        {:ok, name} ->
          if Bridge.valid_name?(name) do
            label = "Quantum job #{name}"
            {converted, s} = convert_cached(s, job, label)
            e = %Entry{name: name, label: label, defaults: s.cfg.defaults, options: Map.get(s.cfg.jobs, name, [])}

            e =
              case converted do
                {:ok, schedule, zone} -> %{e | schedule: schedule, timezone: zone}
                {:error, problem} -> %{e | problem: problem}
              end

            {e, s}
          else
            Watch.report_once(
              s.cfg.watch,
              "cronwatch: the Quantum job #{JS.quote(name)} is not a CronWatch job name, so its runs are not watched",
              "declaring Quantum job #{name}"
            )

            {nil, s}
          end

        {:error, why} ->
          Watch.report_once(s.cfg.watch, why, "declaring a Quantum job")
          {nil, s}
      end
    end

    defp entry(s, _inactive), do: {nil, s}

    @doc false
    # The CronWatch name of a Quantum job: its name, or the function its task
    # calls when it has none.
    def name_of(%{name: name}) when is_atom(name) and name not in [nil, true, false],
      do: {:ok, name |> Atom.to_string() |> String.replace_prefix("Elixir.", "")}

    def name_of(%{name: name}) when is_binary(name), do: {:ok, name}

    def name_of(%{task: {module, fun, args}}) when is_atom(module) and is_atom(fun) and is_list(args),
      do: {:ok, "#{inspect(module)}.#{fun}"}

    def name_of(_),
      do:
        {:error,
         "cronwatch: a Quantum job with no name whose task is an anonymous function cannot be watched; give it a name"}

    defp convert_cached(s, job, label) do
      key = {job.schedule, job.timezone}

      case s.converted do
        %{^key => found} ->
          {found, s}

        _ ->
          found = convert(job.schedule, job.timezone, "cronwatch: #{label}", Core.now(Config.get(s.cfg.instance)))
          {found, %{s | converted: Map.put(s.converted, key, found)}}
      end
    end

    @doc false
    # {:ok, schedule, zone} or {:error, why}.
    def convert(%CronExpression{reboot: true}, _zone, where, _now),
      do:
        {:error, "#{where} runs @reboot, once when Quantum starts, which is not a schedule; it is watched without one"}

    def convert(%CronExpression{} = expr, zone, where, now) do
      zone_text = if zone == :utc, do: "UTC", else: to_string(zone)

      if expr.year == [:*] do
        text = Composer.compose(expr, skip_year: true)

        with {:ok, tz} <- load(zone_text, where),
             :ok <- Bridge.check_fires(runs(expr, tz), text, zone_text, where, @scheduler, daily?(expr), now) do
          {:ok, text, zone_text}
        end
      else
        {:error,
         "#{where} names years (#{Composer.compose(expr)}), which CronWatch cannot read; it is watched without a schedule"}
      end
    end

    defp load(zone, where) do
      case Zone.load(zone) do
        {:ok, tz} -> {:ok, tz}
        {:error, e} -> {:error, "#{where}: #{e}"}
      end
    end

    defp daily?(expr), do: expr.day == [:*] and expr.month == [:*] and expr.weekday == [:*]

    ## Quantum's own fire times

    @walk_limit 20_000

    @doc false
    # Quantum's runs of `expr` in `tz`, as Bridge.check_fires asks for them:
    # the next time the crontab package gives from the zone's clock, turned
    # back into an instant, and a time that does not exist or happens twice
    # stepped over a minute on (Quantum's execution broadcaster).
    def runs(expr, tz) do
      fn start, finish ->
        with {:ok, first} <- previous(expr, tz, Integer.floor_div(start, 1000), 0) do
          forward(expr, tz, first + 1, finish && Integer.floor_div(finish, 1000), [first])
        end
      end
    end

    defp forward(expr, tz, from, finish, out) do
      case next(expr, tz, from, 0) do
        {:ok, at} ->
          out = [at | out]

          if (finish == nil and length(out) > 8) or (finish != nil and at > finish),
            do: {:ok, out |> Enum.reverse() |> Enum.map(&(&1 * 1000))},
            else: forward(expr, tz, at + 1, finish, out)

        other ->
          other
      end
    end

    defp next(_expr, _tz, _from, n) when n > @walk_limit,
      do: Bridge.never_fires("Quantum finds no valid time to run it")

    defp next(expr, tz, from, n) do
      case Crontab.Scheduler.get_next_run_date(expr, naive(from, tz)) do
        {:ok, date} ->
          case instant(date, tz) do
            {:ok, at} -> {:ok, at}
            :invalid -> next(expr, tz, from + 60, n + 1)
          end

        {:error, why} ->
          Bridge.never_fires(to_string(why))
      end
    end

    defp previous(expr, tz, at, n), do: previous_from(expr, tz, at, naive(at, tz), n)

    defp previous_from(expr, tz, at, local, n) do
      case Crontab.Scheduler.get_previous_run_date(expr, local) do
        {:ok, date} ->
          case instant(date, tz) do
            {:ok, s} when s <= at ->
              {:ok, s}

            _ when n > @walk_limit ->
              Bridge.never_fires("Quantum finds no valid time it ran it")

            _ ->
              previous_from(expr, tz, at, NaiveDateTime.add(date, -1, :second), n + 1)
          end

        {:error, why} ->
          Bridge.never_fires(to_string(why))
      end
    end

    defp naive(sec, tz) do
      {y, mo, d, h, mi, s} = Zone.wall_at(sec, tz)
      %NaiveDateTime{year: y, month: mo, day: d, hour: h, minute: mi, second: s, microsecond: {0, 0}}
    end

    # The one instant a wall-clock time names in the zone, or :invalid for
    # one that does not exist (clocks going forward) or happens twice
    # (clocks going back), which Quantum does not run.
    defp instant(%NaiveDateTime{} = date, tz) do
      wall = {date.year, date.month, date.day, date.hour, date.minute, date.second}

      civil =
        Integer.floor_div(JS.date_utc(date.year, date.month - 1, date.day, date.hour, date.minute, date.second), 1000)

      found =
        [civil - 86_400, civil, civil + 86_400]
        |> Enum.map(&Zone.offset(&1, tz))
        |> Enum.uniq()
        |> Enum.map(&(civil - &1))
        |> Enum.filter(&(Zone.wall_at(&1, tz) == wall))
        |> Enum.uniq()

      case found do
        [one] -> {:ok, one}
        _ -> :invalid
      end
    end

    ## The telemetry handlers

    @doc false
    def handle_event(
          [:quantum, :job, event],
          _measurements,
          %{scheduler: scheduler} = meta,
          %{scheduler: scheduler} = cfg
        ) do
      case event do
        e when e in [:add, :update, :delete] -> send(cfg.server, :declare)
        :start -> started(cfg, meta.job)
        :stop -> stopped(cfg, meta)
        :exception -> failed(cfg, meta)
      end

      :ok
    rescue
      e -> report(cfg, e, "quantum")
    catch
      kind, reason -> report(cfg, {kind, reason}, "quantum")
    end

    def handle_event(_event, _measurements, _meta, _cfg), do: :ok

    defp report(cfg, error, where) do
      Core.report(Config.get(cfg.instance), error, where)
    rescue
      _ -> :ok
    end

    # Each :start pushes what its :stop or :exception pops, a placeholder
    # when the job is not watched or its start failed, so the two are always
    # paired.
    defp stack_key(cfg), do: {__MODULE__, cfg.instance, cfg.scheduler}

    defp push(cfg, entry), do: Process.put(stack_key(cfg), [entry | Process.get(stack_key(cfg), [])])

    defp pop(cfg) do
      case Process.get(stack_key(cfg), []) do
        [top | rest] ->
          if rest == [], do: Process.delete(stack_key(cfg)), else: Process.put(stack_key(cfg), rest)
          top

        [] ->
          nil
      end
    end

    defp started(cfg, job) do
      opened =
        try do
          case job_for(cfg, job) do
            nil -> :none
            cw_job -> Exec.open(cw_job, trigger: @trigger)
          end
        rescue
          e ->
            report(cfg, e, "quantum")
            :none
        catch
          kind, reason ->
            report(cfg, {kind, reason}, "quantum")
            :none
        end

      push(cfg, opened)
    end

    defp stopped(cfg, meta) do
      case pop(cfg) do
        %{} = run -> Exec.close(run, {:returned, meta[:result]})
        _ -> :ok
      end
    end

    defp failed(cfg, meta) do
      case pop(cfg) do
        %{} = run -> Exec.close(run, {meta[:kind] || :error, meta[:reason], meta[:stacktrace] || []})
        _ -> :ok
      end
    end

    # The check's runs are never a job.
    defp job_for(_cfg, %{task: {__MODULE__, :check, _}}), do: nil

    defp job_for(cfg, job) do
      case name_of(job) do
        {:ok, name} ->
          Watch.job(cfg.watch, name) ||
            if(Bridge.valid_name?(name),
              do: Watch.fallback(cfg.watch, name, cfg.defaults ++ Map.get(cfg.jobs, name, []))
            )

        {:error, _} ->
          nil
      end
    end
  end
end
