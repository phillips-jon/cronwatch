if Code.ensure_loaded?(Oban) do
  defmodule Cronwatch.Oban do
    @moduledoc """
    CronWatch for Oban (2.20 or newer), with no changes to the app's
    workers: one entry in the instance's options.

        {Cronwatch,
         store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
         integrations: [{Cronwatch.Oban, oban: Oban, defaults: [grace: "5m"]}]}

    and, in Oban's crontab, the check, once per minute across the cluster:

        config :my_app, Oban,
          crontab: [
            {"0 2 * * *", MyApp.Workers.NightlyReport},
            {"* * * * *", Cronwatch.Oban.CheckWorker}
          ]

    ## Which jobs

    The jobs of Oban's Cron plugin, read from `Oban.config/1`: each worker in
    the crontab is a job named after its module as Elixir writes it
    (`MyApp.Workers.NightlyReport`), on the entry's expression in its zone
    (the entry's `timezone`, else the plugin's, else `Etc/UTC`), Oban's
    nicknames (`@daily`) written out as Oban reads them. Each schedule is
    checked against Oban's own reading of it (Oban.Cron.Expression's,
    stepping minute by minute as the plugin does): Oban matches a day of the
    month and a day of the week both, where CronWatch (croner, as
    JavaScript) matches either when both are set, so an expression the two
    read differently is reported once and watched without a schedule. A
    worker with entries on different expressions is one job without a
    schedule. A job the plugin inserted is known by its `meta["cron"]`, so a
    node whose own crontab lacks it (or whose Oban runs in a testing mode)
    still records its runs, declared from the definition the store holds.

    Workers outside the crontab are watched only when named, with
    `workers: [MyApp.Workers.Import]` (or `{module, job_options}`, which also
    gives a crontab worker's job its options), so a queue of a million email
    jobs is not a million runs.

    ## Runs

    Handlers on `[:oban, :job, :start]`, `:stop` and `:exception` run in the
    worker's own process: each attempt is a run (trigger `oban`, id
    `oban:<app>:<job id>:<attempt>`, with the jobs table's prefix before the
    job's id when it is not `public`, since a job's id is unique only within
    its table, and `.<times snoozed>` after the attempt once the job has
    snoozed, since a snooze gives its attempt back), with its context in the
    worker's process, so `Cronwatch.log/1` and `Cronwatch.metric/2` work
    inside `perform/1`. A
    retry is a new attempt and a new run: failing attempts open one failed
    alert and the one that succeeds closes it, and `failures_before_alert`
    says how many attempts to allow first. The worker's process is
    monitored, so a job killed at its `timeout/1` or by a node shutting down
    is a failed run at once.

    A `{:snooze, period}` gives the run back (nothing judged, nothing
    alerted), since the job did not fail and will run again; a store that
    cannot take it back (no `delete_run_if`, or a failed delete) keeps it as
    an `ok` run, still not judged; a `{:cancel, reason}` (and the older
    `:discard`) fails it, since the worker gave up on the job. An attempt left running by a node that died before its monitor
    could record it is closed when Oban's Lifeline rescues the job and its
    next attempt starts: that start fails the earlier attempt's run with
    `Oban rescued the job after its node stopped`.

    ## Jobs gone and the check

    `Cronwatch.Oban.CheckWorker` runs `sync/1` and a check. The sync
    declares the crontab's jobs again, and again without its schedule each
    job of this app's the store holds with a schedule that the crontab no
    longer has. Jobs are tagged `oban` and `oban:<app>`, the app named by the
    `app` option, else `$CRONWATCH_APP_ID`, else the OTP application that
    started the instance.

    Options: `oban` (the Oban instance's name, default `Oban`), `app`,
    `defaults` (job options for every job, before its schedule) and
    `workers`.
    """

    use GenServer

    alias Cronwatch.Bridge
    alias Cronwatch.Bridge.Entry
    alias Cronwatch.Bridge.Watch
    alias Cronwatch.Config
    alias Cronwatch.Core
    alias Cronwatch.Error
    alias Cronwatch.JS
    alias Cronwatch.Run.Exec
    alias Cronwatch.Runs
    alias Cronwatch.Zone
    alias Oban.Cron.Expression

    @tag "oban"
    @trigger "oban"
    @scheduler "Oban"
    @check_worker "Cronwatch.Oban.CheckWorker"
    @cron_plugins [Oban.Cron, Oban.Plugins.Cron]
    @nicknames %{
      "@annually" => "0 0 1 1 *",
      "@yearly" => "0 0 1 1 *",
      "@monthly" => "0 0 1 * *",
      "@weekly" => "0 0 * * 0",
      "@midnight" => "0 0 * * *",
      "@daily" => "0 0 * * *",
      "@hourly" => "0 * * * *"
    }
    @rescued "Oban rescued the job after its node stopped"
    @sync_timeout 30_000

    @doc "The tag every job this integration declares carries."
    def tag, do: @tag

    @doc false
    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.get(opts, :oban, Oban)},
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    @doc false
    def start_link(opts) do
      instance = Keyword.get(opts, :instance, Cronwatch)
      oban = Keyword.get(opts, :oban, Oban)
      GenServer.start_link(__MODULE__, opts, name: server(instance, oban))
    end

    @doc false
    def server(instance, oban), do: Module.concat([instance, __MODULE__, oban])

    @doc """
    Declares the crontab's jobs again, and again without its schedule each
    job of this app's the store holds with a schedule that the crontab no
    longer has (taken out since a node declared it). The check worker runs
    it before each check. Everything is written to the store before it
    returns, within 30 seconds. Options: `instance`, `oban`.
    """
    @spec sync(keyword()) :: :ok | {:error, Error.t()}
    def sync(opts \\ []) do
      instance = Keyword.get(opts, :instance, Cronwatch)
      server = server(instance, Keyword.get(opts, :oban, Oban))

      task =
        Watch.bounded_task(instance, fn ->
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

    @doc "Waits until what the integration declared has been written to the store, for tests and a clean exit."
    @spec settle(keyword()) :: :ok
    def settle(opts \\ []) do
      server = server(Keyword.get(opts, :instance, Cronwatch), Keyword.get(opts, :oban, Oban))
      server |> GenServer.call(:watch, :infinity) |> Watch.settle()
    end

    ## The process

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      instance = Keyword.get(opts, :instance, Cronwatch)
      oban = Keyword.get(opts, :oban, Oban)

      with {:ok, workers} <- workers(Keyword.get(opts, :workers, [])),
           {:ok, watch} <- Watch.start_link(instance: instance, tag: @tag, app: opts[:app], scheduler: @scheduler) do
        cfg = %{
          instance: instance,
          oban: oban,
          server: self(),
          watch: watch,
          app_tag: Watch.app_tag(watch),
          defaults: Keyword.get(opts, :defaults, []),
          workers: workers
        }

        id = {__MODULE__, instance, oban}

        # A process killed before its terminate/2 ran left its handlers
        # attached, holding its dead watch; these replace them.
        :telemetry.detach(id)

        :telemetry.attach_many(
          id,
          [
            [:oban, :job, :start],
            [:oban, :job, :stop],
            [:oban, :job, :exception],
            [:oban, :plugin, :init],
            [:oban, :supervisor, :init]
          ],
          &__MODULE__.handle_event/4,
          cfg
        )

        send(self(), :declare)
        {:ok, %{cfg: cfg, id: id, converted: %{}}}
      else
        {:error, %Error{} = e} -> {:stop, e}
        {:error, reason} -> {:stop, reason}
      end
    end

    defp workers(list) when is_list(list) do
      Enum.reduce_while(list, {:ok, %{}}, fn
        module, {:ok, acc} when is_atom(module) ->
          {:cont, {:ok, Map.put(acc, Oban.Worker.to_string(module), [])}}

        {module, options}, {:ok, acc} when is_atom(module) and is_list(options) ->
          {:cont, {:ok, Map.put(acc, Oban.Worker.to_string(module), options)}}

        other, _ ->
          {:halt,
           {:error,
            Error.invalid("Cronwatch.Oban: workers must be modules or {module, options}, not #{inspect(other)}")}}
      end)
    end

    defp workers(other),
      do: {:error, Error.invalid("Cronwatch.Oban: workers must be a list, not #{inspect(other)}")}

    @impl true
    def handle_call(:declare, _from, s), do: {:reply, s.cfg.watch, declare(s)}
    def handle_call(:watch, _from, s), do: {:reply, s.cfg.watch, s}

    @impl true
    def handle_info(:declare, s), do: {:noreply, declare(s)}
    def handle_info({:EXIT, pid, reason}, %{cfg: %{watch: pid}} = s), do: {:stop, reason, s}
    def handle_info(_msg, s), do: {:noreply, s}

    @impl true
    def terminate(_reason, s) do
      :telemetry.detach(s.id)
      :ok
    end

    # Declares the crontab's entries, when Oban is running; an Oban started
    # later is declared when its supervisor or Cron plugin starts.
    defp declare(s) do
      case crontab(s.cfg.oban) do
        {:ok, crontab, zone} ->
          {entries, s} = entries(s, crontab, zone)
          Watch.declare(s.cfg.watch, entries)
          s

        :not_running ->
          s
      end
    rescue
      e ->
        report(s.cfg, e, "declaring the Oban crontab")
        s
    end

    defp crontab(oban) do
      conf = Oban.config(oban)

      case Enum.find(conf.plugins, fn {module, _} -> module in @cron_plugins end) do
        {_, opts} -> {:ok, Keyword.get(opts, :crontab, []), Keyword.get(opts, :timezone, "Etc/UTC")}
        nil -> {:ok, [], "Etc/UTC"}
      end
    rescue
      _ -> :not_running
    catch
      :exit, _ -> :not_running
    end

    defp entries(s, crontab, plugin_zone) do
      Enum.reduce(crontab, {[], s}, fn item, {acc, s} ->
        {expr, worker, opts} =
          case item do
            {expr, worker} -> {expr, worker, []}
            {expr, worker, opts} -> {expr, worker, opts}
          end

        name = Oban.Worker.to_string(worker)

        cond do
          name == @check_worker ->
            {acc, s}

          not Bridge.valid_name?(name) ->
            Watch.report_once(
              s.cfg.watch,
              "cronwatch: the Oban worker #{JS.quote(name)} is not a CronWatch job name, so its runs are not watched",
              "declaring Oban crontab entry for #{name}"
            )

            {acc, s}

          true ->
            zone = Keyword.get(opts, :timezone, plugin_zone)
            label = "Oban crontab entry for #{name}"
            {converted, s} = convert_cached(s, expr, zone, label)

            entry = %Entry{
              name: name,
              label: label,
              defaults: s.cfg.defaults,
              options: Map.get(s.cfg.workers, name, [])
            }

            entry =
              case converted do
                {:ok, schedule} -> %{entry | schedule: schedule, timezone: zone}
                {:error, problem} -> %{entry | problem: problem}
              end

            {acc ++ [entry], s}
        end
      end)
    end

    # An expression as CronWatch reads it, checked against Oban's own
    # reading; kept per expression and zone, since the crontab does not
    # change while Oban runs.
    defp convert_cached(s, expr, zone, label) do
      key = {expr, zone}

      case s.converted do
        %{^key => found} ->
          {found, s}

        _ ->
          found = convert(expr, zone, "cronwatch: #{label}", Core.now(Config.get(s.cfg.instance)))
          {found, %{s | converted: Map.put(s.converted, key, found)}}
      end
    end

    @doc false
    # {:ok, schedule} or {:error, why}: `where` names the entry in messages.
    def convert(expr, zone, where, now) do
      text = Map.get(@nicknames, expr, expr)

      with {:ok, parsed} <- oban_parse(expr, where),
           :ok <- not_reboot(parsed, where),
           {:ok, tz} <- zone(zone, where),
           :ok <- Bridge.check_fires(runs(parsed, tz), text, zone, where, @scheduler, daily?(parsed), now) do
        {:ok, text}
      end
    end

    defp oban_parse(expr, where) do
      case Expression.parse(expr) do
        {:ok, parsed} -> {:ok, parsed}
        {:error, e} -> {:error, "#{where}: Oban cannot read #{JS.quote(expr)}: #{Exception.message(e)}"}
      end
    end

    defp not_reboot(%{reboot?: true}, where),
      do: {:error, "#{where} runs @reboot, once when Oban starts, which is not a schedule; it is watched without one"}

    defp not_reboot(_, _), do: :ok

    defp zone(zone, where) do
      case Zone.load(zone) do
        {:ok, tz} -> {:ok, tz}
        {:error, e} -> {:error, "#{where}: #{e}"}
      end
    end

    defp daily?(parsed) do
      MapSet.size(parsed.days) == 31 and MapSet.size(parsed.months) == 12 and MapSet.size(parsed.weekdays) == 7
    end

    ## Oban's own fire times

    # How far a walk goes before it takes the expression for one that never
    # fires: some ten years, an hour at a time.
    @walk_limit 90_000

    @doc false
    # Oban's runs of `parsed` in `tz`, as Bridge.check_fires asks for them:
    # the plugin looks at each minute of UTC, read in the entry's zone, and
    # inserts the job when the expression matches it.
    def runs(parsed, tz) do
      fn start, finish ->
        case back(parsed, tz, floor_minute(Integer.floor_div(start, 1000)), 0) do
          {:ok, first} -> forward(parsed, tz, first + 60, finish && Integer.floor_div(finish, 1000), [first], 0)
          other -> other
        end
      end
    end

    defp floor_minute(sec), do: sec - Integer.mod(sec, 60)

    defp forward(_parsed, _tz, _sec, _finish, _out, n) when n > @walk_limit,
      do: Bridge.never_fires("Oban finds no time to run it in the next ten years")

    defp forward(parsed, tz, sec, finish, out, n) do
      case step(parsed, tz, sec, :forward) do
        {:fire, at} ->
          out = [at | out]

          if (finish == nil and length(out) > 8) or (finish != nil and at > finish),
            do: {:ok, out |> Enum.reverse() |> Enum.map(&(&1 * 1000))},
            else: forward(parsed, tz, at + 60, finish, out, n + 1)

        {:skip, next} ->
          forward(parsed, tz, next, finish, out, n + 1)
      end
    end

    defp back(_parsed, _tz, _sec, n) when n > @walk_limit,
      do: Bridge.never_fires("Oban finds no time it ran it in the ten years before")

    defp back(parsed, tz, sec, n) do
      case step(parsed, tz, sec, :back) do
        {:fire, at} -> {:ok, at}
        {:skip, next} -> back(parsed, tz, next, n + 1)
      end
    end

    # The minute `sec` as Oban reads it: a fire, or the next minute to look
    # at. A day or an hour the expression does not name is stepped over to
    # the next (or previous) hour of the zone's clock, and a minute it does
    # not name to the next minute it does, unless the zone's offset changes
    # in between, when the walk goes a minute at a time.
    defp step(parsed, tz, sec, dir) do
      {y, mo, d, h, mi, _} = Zone.wall_at(sec, tz)
      date = wall(y, mo, d, h, mi)
      dow = if Calendar.ISO.valid_date?(y, mo, d), do: Integer.mod(Date.day_of_week(date), 7), else: -1

      day_ok =
        MapSet.member?(parsed.months, mo) and MapSet.member?(parsed.days, d) and MapSet.member?(parsed.weekdays, dow)

      cond do
        not day_ok ->
          day = if dir == :forward, do: (24 - h) * 60 - mi, else: h * 60 + mi + 1
          hour = if dir == :forward, do: 60 - mi, else: mi + 1
          {:skip, jump(tz, sec, dir, day, hour)}

        not MapSet.member?(parsed.hours, h) ->
          {:skip, jump(tz, sec, dir, if(dir == :forward, do: 60 - mi, else: mi + 1))}

        Expression.now?(parsed, date) ->
          {:fire, sec}

        true ->
          minutes = parsed.minutes |> MapSet.to_list() |> Enum.sort()

          minutes =
            if dir == :forward,
              do: Enum.find(minutes, &(&1 > mi)),
              else: minutes |> Enum.reverse() |> Enum.find(&(&1 < mi))

          by =
            case {minutes, dir} do
              {nil, :forward} -> 60 - mi
              {nil, :back} -> mi + 1
              {m, :forward} -> m - mi
              {m, :back} -> mi - m
            end

          {:skip, jump(tz, sec, dir, by)}
      end
    end

    # A jump to the day's end, or where the zone's offset changes before it,
    # to the hour's.
    defp jump(tz, sec, dir, day, hour) do
      target = if dir == :forward, do: sec + day * 60, else: sec - day * 60

      if Zone.offset(target, tz) == Zone.offset(sec, tz),
        do: target,
        else: jump(tz, sec, dir, hour)
    end

    defp jump(tz, sec, dir, minutes) do
      target = if dir == :forward, do: sec + minutes * 60, else: sec - minutes * 60

      cond do
        minutes <= 1 -> target
        Zone.offset(target, tz) == Zone.offset(sec, tz) -> target
        dir == :forward -> sec + 60
        true -> sec - 60
      end
    end

    defp wall(y, mo, d, h, mi) do
      %DateTime{
        year: y,
        month: mo,
        day: d,
        hour: h,
        minute: mi,
        second: 0,
        microsecond: {0, 0},
        time_zone: "Etc/UTC",
        zone_abbr: "UTC",
        utc_offset: 0,
        std_offset: 0,
        calendar: Calendar.ISO
      }
    end

    ## The telemetry handlers

    @doc false
    # Matched rather than read, since a handler that raises is detached, and
    # with it every event of this integration.
    def handle_event([:oban, kind, :init], _measurements, %{conf: %{name: name}} = meta, %{oban: name} = cfg)
        when kind in [:plugin, :supervisor] do
      if kind == :supervisor or meta[:plugin] in @cron_plugins, do: send(cfg.server, :declare)

      :ok
    end

    def handle_event([:oban, :job, event], _measurements, %{conf: %{name: name}} = meta, %{oban: name} = cfg) do
      case event do
        :start -> started(cfg, meta)
        :stop -> stopped(cfg, meta)
        :exception -> failed(cfg, meta)
      end
    rescue
      e -> report(cfg, e, "oban")
    catch
      kind, reason -> report(cfg, {kind, reason}, "oban")
    end

    def handle_event(_event, _measurements, _meta, _cfg), do: :ok

    defp report(cfg, error, where) do
      Core.report(Config.get(cfg.instance), error, where)
    rescue
      _ -> :ok
    end

    # Each :start pushes what its :stop or :exception pops, a placeholder
    # when the attempt is not watched or its start failed, so the two are
    # always paired, however jobs nest (Oban's inline testing mode runs a job
    # inserted inside another's perform/1 there and then).
    defp stack_key(cfg), do: {__MODULE__, cfg.instance, cfg.oban}

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

    defp started(cfg, %{job: job} = meta) do
      opened =
        try do
          case job_for(cfg, job) do
            nil ->
              :none

            cw_job ->
              close_rescued(cfg, cw_job, job, meta[:conf])
              id = if is_integer(job.id), do: run_id(cfg, meta[:conf], job.id, job.attempt, snoozed(job))
              Exec.open(cw_job, trigger: @trigger, id: id, defer: true)
          end
        rescue
          e ->
            report(cfg, e, "oban")
            :none
        catch
          kind, reason ->
            report(cfg, {kind, reason}, "oban")
            :none
        end

      push(cfg, opened)
      :ok
    end

    defp stopped(cfg, meta) do
      case pop(cfg) do
        %{} = run ->
          case meta.state do
            # Nothing judged: one the store cannot take back is recorded, not judged.
            :snoozed -> Exec.take_back(run, :unjudged)
            state when state in [:cancelled, :discard] -> Exec.close(run, {:returned, {:error, perform_error(meta)}})
            _ -> Exec.close(run, {:returned, success(meta[:result])})
          end

        _ ->
          :ok
      end
    end

    defp failed(cfg, meta) do
      case pop(cfg) do
        %{} = run ->
          reason = meta[:reason] || meta[:error]
          stacktrace = meta[:stacktrace] || []

          outcome =
            case meta[:kind] do
              kind when kind in [:exit, :throw] and not is_exception(reason) -> {kind, reason, stacktrace}
              _ -> {:error, reason, stacktrace}
            end

          Exec.close(run, outcome)

        _ ->
          :ok
      end
    end

    # What a successful attempt answered, as a run's result: Oban counts any
    # answer but an error as success, so one that reads as a failure here
    # (`:error`) is taken as done.
    defp success(:error), do: :ok
    defp success({:error, _}), do: :ok
    defp success(result), do: result

    defp perform_error(%{job: job, result: result}), do: Oban.PerformError.exception({job.worker, result})

    # The CronWatch job an attempt is a run of, or nil when it is not
    # watched: a worker the crontab declared here, else one the Cron plugin
    # inserted (declared from the store's definition when it is this app's)
    # or one named in `workers`.
    defp job_for(cfg, job) do
      name = job.worker

      cond do
        name == @check_worker ->
          nil

        # Every job the app's queues run passes through here: one not
        # declared in the instance, not inserted by the Cron plugin and not
        # named is let go with a table read, never a call to the watch, so a
        # busy queue does not wait in line on one process.
        Runs.job(cfg.instance, name) == nil and not cron?(job) and not Map.has_key?(cfg.workers, name) ->
          nil

        found = Watch.job(cfg.watch, name) ->
          found

        cron?(job) or Map.has_key?(cfg.workers, name) ->
          Watch.fallback(cfg.watch, name, cfg.defaults ++ Map.get(cfg.workers, name, []))

        true ->
          nil
      end
    end

    defp cron?(%{meta: meta}) when is_map(meta), do: meta["cron"] == true or meta[:cron] == true
    defp cron?(_), do: false

    # An earlier attempt still running (its node died before its monitor
    # could record it, and Lifeline rescued the job) is failed as this one
    # starts.
    defp close_rescued(cfg, cw_job, %{id: id, attempt: attempt} = job, conf) when is_integer(id) and attempt > 1 do
      prior = run_id(cfg, conf, id, attempt - 1, snoozed(job))

      case Cronwatch.get_run(prior, instance: cfg.instance) do
        {:ok, %{status: "running", job: job_name}} when job_name == cw_job.name ->
          with {:ok, handle} <- Cronwatch.resume(cw_job, prior), do: Cronwatch.fail(handle, @rescued)

        _ ->
          :ok
      end
    end

    defp close_rescued(_cfg, _cw_job, _job, _conf), do: :ok

    @doc false
    # An attempt's run id: the app's tag, the job's id and the attempt
    # (`oban:billing:42:1`), with the jobs table's prefix before the id when
    # it is not the default (`oban:billing:jobs2:42:1`). A job's id is unique
    # only within its table, so two apps sharing a store with an Oban
    # database each, or two Oban instances on different prefixes, would
    # otherwise give two runs one id: the second insert refused, its run
    # unrecorded, and a rescue able to fail the other's run. A job snoozed
    # adds how many times (`oban:billing:42:1.2`): since Oban 2.24 a snooze
    # gives its attempt back, so the execution after it has the snoozed
    # one's attempt, and would otherwise be refused as a run already
    # recorded when the snooze could not be taken back.
    def run_id(cfg, conf, id, attempt, snoozed \\ 0) do
      prefix =
        case conf do
          %{prefix: prefix} when is_binary(prefix) and prefix not in ["", "public"] -> prefix <> ":"
          _ -> ""
        end

      suffix = if is_integer(snoozed) and snoozed > 0, do: ".#{snoozed}", else: ""
      "#{cfg.app_tag}:#{prefix}#{id}:#{attempt}#{suffix}"
    end

    # How many times the job has snoozed (Oban keeps it in the job's meta).
    defp snoozed(%{meta: %{"snoozed" => n}}) when is_integer(n), do: n
    defp snoozed(_), do: 0
  end

  defmodule Cronwatch.Oban.CheckWorker do
    @moduledoc """
    The Oban worker that runs `Cronwatch.Oban.sync/1` and a CronWatch check,
    for a cluster: put it in the Cron plugin's crontab, and the plugin
    inserts it once per minute on the leader, so the whole cluster checks
    once:

        crontab: [{"* * * * *", Cronwatch.Oban.CheckWorker}]

    An instance other than the default is named in its args
    (`{"* * * * *", Cronwatch.Oban.CheckWorker, args: %{instance: "MyApp.Cronwatch"}}`).
    Its runs are never a job; a check that fails is reported to the
    instance's error handler and tried again by the next.
    """

    use Oban.Worker, max_attempts: 1

    @impl Oban.Worker
    def perform(%Oban.Job{args: args} = job) do
      with {:ok, instance} <- instance(args) do
        oban = if job.conf, do: job.conf.name, else: Oban

        case Cronwatch.Oban.sync(instance: instance, oban: oban) do
          :ok -> :ok
          {:error, e} -> Cronwatch.Config.report(Cronwatch.Config.get(instance), e, "oban")
        end

        case Cronwatch.check(instance: instance) do
          {:ok, _} -> :ok
          {:error, e} -> {:error, Cronwatch.Config.describe(e)}
        end
      end
    end

    # The instance's name, never made into a new atom from the job's args.
    defp instance(args) do
      case args["instance"] || args[:instance] do
        nil ->
          {:ok, Cronwatch}

        name when is_atom(name) ->
          {:ok, name}

        name when is_binary(name) ->
          # A module's name (MyApp.Cronwatch) or an atom's (:my_cronwatch).
          text = String.trim_leading(name, ":")
          candidates = if String.starts_with?(name, ":"), do: [text], else: ["Elixir." <> text, text]

          case Enum.find_value(candidates, &existing_instance/1) do
            nil -> {:error, "no Cronwatch instance named #{name}"}
            atom -> {:ok, atom}
          end

        other ->
          {:error, "the instance is named by a string, not #{inspect(other)}"}
      end
    end

    defp existing_instance(text) do
      atom = String.to_existing_atom(text)
      if :persistent_term.get({Cronwatch, atom}, nil), do: atom
    rescue
      ArgumentError -> nil
    end
  end
end
