defmodule Cronwatch.Bridge.Entry do
  @moduledoc """
  One job a scheduler runs, as an integration reads it: its `name`, a
  `label` naming it in messages (`Oban crontab entry for
  MyApp.Workers.Nightly`), its `schedule` as CronWatch reads it (`""` for
  none), the `timezone` it is read in (`""` for the process's own), a
  `problem` (why an entry with a schedule of its own has none here, reported
  once), the integration's `defaults` for every job (before the schedule),
  and the entry's own `options` (after it, so a schedule among them
  replaces the scheduler's).

  Part of `Cronwatch.Bridge`: for integration authors, outside the 1.x
  promise.
  """

  defstruct name: nil, label: nil, schedule: "", timezone: "", problem: nil, defaults: [], options: []

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          schedule: String.t(),
          timezone: String.t(),
          problem: String.t() | nil,
          defaults: keyword(),
          options: keyword()
        }
end

defmodule Cronwatch.Bridge.Watch do
  @moduledoc """
  Part of `Cronwatch.Bridge`: for integration authors, outside the 1.x
  promise.

  The jobs an integration declared for one scheduler, the jobs gone from
  it, and the jobs a worker runs that another process declared: the Go
  port's `bridge/watch.go` and the Rust port's `Watch`, with both audits'
  fixes. A process of its own, which is the declaring lock: `declare/2`,
  the end of `fallback/3`, and `unschedule/1`'s declarations run in it one at
  a time, so one never takes another's entries for gone or leaves the
  instance holding a job without its schedule.

  Start it with `start_link/1` (`instance:`, `tag:`, `app:`, and
  `scheduler:`, how messages name the scheduler), under the integration.
  """

  use GenServer

  alias Cronwatch.Bridge
  alias Cronwatch.Bridge.Entry
  alias Cronwatch.Config
  alias Cronwatch.Core
  alias Cronwatch.Error
  alias Cronwatch.Job
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Runs

  # One write of a declaration to the store, bounded so a store that hangs
  # never holds the writer for good. The application environment can
  # shorten it (the tests do).
  @save_timeout 30_000

  @doc false
  def save_timeout, do: Application.get_env(:cronwatch, :bridge_save_timeout, @save_timeout)

  @type watch :: GenServer.server()

  @doc "Starts a watch: `instance:`, `tag:`, `app:` (nil for `Cronwatch.Bridge.app_name/0`), `scheduler:`, `name:`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    app =
      case Keyword.get(opts, :app) do
        app when is_binary(app) and app != "" -> app
        _ -> Bridge.app_name()
      end

    init = %{
      instance: Keyword.get(opts, :instance, Cronwatch),
      tag: Keyword.fetch!(opts, :tag),
      app_tag: Bridge.app_tag(Keyword.fetch!(opts, :tag), app),
      scheduler: Keyword.get(opts, :scheduler, Keyword.fetch!(opts, :tag))
    }

    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, init, name: name)
      :error -> GenServer.start_link(__MODULE__, init)
    end
  end

  @doc false
  def child_spec(opts), do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc "The instance the watch declares jobs on."
  @spec instance(watch()) :: atom()
  def instance(watch), do: GenServer.call(watch, :instance, :infinity)

  @doc "The app's tag under the integration's."
  @spec app_tag(watch()) :: String.t()
  def app_tag(watch), do: GenServer.call(watch, :app_tag, :infinity)

  @doc "Hands `message` to the instance's error handler the first time this watch sees it for that `where`."
  @spec report_once(watch(), String.t(), String.t()) :: :ok
  def report_once(watch, message, where), do: GenServer.call(watch, {:report_once, message, where}, :infinity)

  @doc "The job declared under `name`, or one declared for a run of it (`fallback/3`), or nil."
  @spec job(watch(), String.t()) :: Job.t() | nil
  def job(watch, name), do: GenServer.call(watch, {:job, name}, :infinity)

  @doc "Whether `name` was declared from a scheduler entry by this watch."
  @spec declares?(watch(), String.t()) :: boolean()
  def declares?(watch, name), do: GenServer.call(watch, {:declares?, name}, :infinity)

  @doc """
  Declares every entry the scheduler has now, one job per name, and
  declares again without its schedule a job this watch declared whose
  entries are all gone. Several entries of one name on different schedules
  are one job without a schedule, reported once. Each job is tagged with the
  integration's tag and the app's. A declaration that has not changed is
  left alone; one the instance refuses is reported, as is each entry's
  problem, once. What is declared is written to the store in a task of its
  own (`settle/1` waits for it), since a node that only schedules neither
  runs nor checks, and a declaration kept in memory would never reach the
  nodes that do.
  """
  @spec declare(watch(), [Entry.t()]) :: :ok
  def declare(watch, entries), do: GenServer.call(watch, {:declare, entries}, :infinity)

  @doc "`options` with the integration's and the app's tags added to the ones the options give."
  @spec tagged(watch(), keyword()) :: keyword()
  def tagged(watch, options) do
    {tag, app_tag} = GenServer.call(watch, :tags, :infinity)
    add_tags(options, [tag, app_tag])
  end

  @doc "Waits until what `declare/2` declared has been written to the store, for tests and a clean exit."
  @spec settle(watch()) :: :ok
  def settle(watch), do: GenServer.call(watch, :settle, :infinity)

  @doc """
  The job a run in this process belongs to when this watch has not declared
  it from a scheduler entry of its own (a worker whose app schedules the job
  on another node): declared again from the definition the store holds,
  when that is this app's (tagged with its app tag), so the schedule another
  node stored is kept, else with `options` and this watch's tags. Declared
  once per name. Nil, with the reason reported, when the instance refuses it
  or the store cannot be read (the run then goes unrecorded, and the next
  one asks again), since a declaration made without the stored one would
  write over its schedule. A job `declare/2` has declared is `declare/2`'s.
  """
  @spec fallback(watch(), String.t(), keyword()) :: Job.t() | nil
  def fallback(watch, name, options) do
    case job(watch, name) do
      %Job{} = job ->
        job

      nil ->
        {instance, app_tag} = GenServer.call(watch, :instance_and_tag, :infinity)
        c = Config.get(instance)

        stored =
          try do
            Core.ensure_ready!(c)
            {:ok, Core.store!(c, :get_job, [name])}
          rescue
            e ->
              Core.report(c, e, "declaring #{name}")
              :error
          end

        case stored do
          :error ->
            nil

          {:ok, stored} ->
            made =
              if stored && app_tag in tags_of(stored.definition),
                do: {:stored, Bridge.options_of(stored.definition)},
                else: {:tagged, options}

            # In turn with declare, and after looking again: a job declared
            # from a scheduler entry meanwhile is that one.
            GenServer.call(watch, {:fallback, name, made}, :infinity)
        end
    end
  end

  @doc """
  Declares again without its schedule every job of this app's (tagged with
  its app tag) that the store holds with a schedule and this process has not
  declared: a scheduler entry taken out since the job was declared, by this
  node or an earlier one, so it is never reported missed and a missed alert
  already open closes. Call it just before a check. It first writes back
  this watch's own declarations wherever the store holds something else (an
  older release still up during a deploy may have taken the schedule out of
  a job it does not run). A watch that never declared an entry of its
  scheduler leaves every job alone. Everything is written before it returns.
  Answers the names declared again.
  """
  @spec unschedule(watch()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def unschedule(watch) do
    {seen, mine, instance} = GenServer.call(watch, :mine, :infinity)

    if seen do
      c = Config.get(instance)
      defined = defined(instance)

      failed =
        for name <- Enum.sort(mine), MapSet.member?(defined, name), {:error, e} <- [write(instance, name)] do
          "declaring #{name}: #{Config.describe(e)}"
        end

      stored =
        try do
          Core.ensure_ready!(c)
          {:ok, Core.store!(c, :list_jobs, [])}
        rescue
          e -> {:error, Config.describe(e)}
        end

      case stored do
        {:error, message} ->
          {:error, Error.other(Enum.join(failed ++ [message], "\n"))}

        {:ok, stored} ->
          # In turn with declare and fallback, and with what is declared read
          # again: a job declared since the first read must keep its schedule.
          {names, more} = GenServer.call(watch, {:unscheduled, stored}, :infinity)

          # Written before returning: a node that never checks would
          # otherwise leave the schedule in the store, and a write left to
          # run behind could land after another node put the schedule back.
          written =
            for name <- names, {:error, e} <- [write(instance, name)], do: "declaring #{name}: #{Config.describe(e)}"

          case failed ++ more ++ written do
            [] -> {:ok, names}
            all -> {:error, Error.other(Enum.join(all, "\n"))}
          end
      end
    else
      {:ok, []}
    end
  end

  @doc """
  `Cronwatch.sync_job/2` within the watch's deadline (30 seconds), in a task
  of the instance, so a store that hangs or raises is this declaration's
  failure only.
  """
  @spec write(atom(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def write(instance, name) do
    task = bounded_task(instance, fn -> Cronwatch.sync_job(name, instance: instance) end)
    timeout = save_timeout()

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, Error.other("exited: #{Cronwatch.Output.describe_exception(:exit, reason, [])}")}

      nil ->
        {:error,
         Error.other(
           "writing the declaration of #{JS.quote(name)} took longer than #{JS.format_number(timeout / 1000)} seconds; gave up"
         )}
    end
  end

  @doc false
  # A task of the instance, not linked to the caller (a raise in it is the
  # caller's answer, not its crash), that is killed when the caller ends:
  # the caller holds it to a deadline, and a caller killed first (a sync
  # given up on, a worker at its timeout) would otherwise leave it waiting
  # on a store that hangs, one more with every check.
  def bounded_task(instance, fun) do
    task = Task.Supervisor.async_nolink(Cronwatch.Supervisor.tasks(instance), fun)
    caller = self()

    spawn(fn ->
      caller_ref = Process.monitor(caller)
      task_ref = Process.monitor(task.pid)

      receive do
        {:DOWN, ^caller_ref, :process, _, _} -> Process.exit(task.pid, :kill)
        {:DOWN, ^task_ref, :process, _, _} -> :ok
      end
    end)

    task
  end

  defp defined(instance), do: instance |> Runs.jobs() |> MapSet.new(& &1.name)

  defp tags_of(%Object{} = definition) do
    case Object.get(definition, "tags") do
      tags when is_list(tags) -> tags
      _ -> []
    end
  end

  defp tags_of(_), do: []

  # The options with tags added after the ones they give, in the place the
  # options give them.
  defp add_tags(options, add) do
    given = options |> Keyword.get_values(:tags) |> List.last() |> List.wrap()
    tags = Enum.reduce(add, given, fn t, acc -> if t in acc, do: acc, else: acc ++ [t] end)

    if Keyword.has_key?(options, :tags) do
      {out, _} =
        Enum.reduce(options, {[], false}, fn
          {:tags, _}, {acc, false} -> {[{:tags, tags} | acc], true}
          {:tags, _}, {acc, true} -> {acc, true}
          pair, {acc, done} -> {[pair | acc], done}
        end)

      Enum.reverse(out)
    else
      options ++ [tags: tags]
    end
  end

  ## The process

  @impl true
  def init(init) do
    {:ok,
     Map.merge(init, %{
       jobs: %{},
       fallback: %{},
       reported: MapSet.new(),
       seen: false,
       pending: MapSet.new(),
       saver: nil,
       waiters: []
     })}
  end

  @impl true
  def handle_call(:instance, _from, s), do: {:reply, s.instance, s}
  def handle_call(:app_tag, _from, s), do: {:reply, s.app_tag, s}
  def handle_call(:tags, _from, s), do: {:reply, {s.tag, s.app_tag}, s}
  def handle_call(:instance_and_tag, _from, s), do: {:reply, {s.instance, s.app_tag}, s}

  def handle_call({:report_once, message, where}, _from, s), do: {:reply, :ok, report_once_in(s, message, where)}

  # A job forgotten since (the dashboard's Forget) is no longer declared in
  # the instance. One the scheduler still has is declared again, so its run
  # writes it back with its schedule; a fallback's is let go, so the next
  # fallback reads the store again.
  def handle_call({:job, name}, _from, s) do
    declared? = Runs.job(s.instance, name) != nil

    case s.jobs do
      %{^name => d} ->
        unless declared?, do: Runs.declare(s.instance, d.job)
        {:reply, d.job, s}

      _ ->
        case s.fallback do
          %{^name => job} when declared? -> {:reply, job, s}
          _ -> {:reply, nil, %{s | fallback: Map.delete(s.fallback, name)}}
        end
    end
  end

  def handle_call({:declares?, name}, _from, s), do: {:reply, Map.has_key?(s.jobs, name), s}

  def handle_call({:declare, entries}, _from, s), do: {:reply, :ok, declare_in(s, entries)}

  def handle_call(:settle, from, s) do
    if s.saver, do: {:noreply, %{s | waiters: [from | s.waiters]}}, else: {:reply, :ok, s}
  end

  def handle_call(:take_pending, {pid, _}, %{saver: {pid, _}} = s) do
    if MapSet.size(s.pending) == 0 do
      {:reply, :done, saved(s)}
    else
      {:reply, Enum.sort(s.pending), %{s | pending: MapSet.new()}}
    end
  end

  def handle_call(:take_pending, _from, s), do: {:reply, :done, s}

  def handle_call({:fallback, name, made}, _from, s) do
    case s.jobs do
      %{^name => d} ->
        {:reply, d.job, s}

      _ ->
        options =
          case made do
            {:stored, options} -> options
            {:tagged, options} -> add_tags(options, [s.tag, s.app_tag])
          end

        case Cronwatch.job(name, [{:instance, s.instance} | options]) do
          {:ok, job} ->
            {:reply, job, %{s | fallback: Map.put(s.fallback, name, job)}}

          {:error, e} ->
            {:reply, nil, report_once_in(s, Config.describe(e), "declaring #{name}")}
        end
    end
  end

  def handle_call(:mine, _from, s), do: {:reply, {s.seen, Map.keys(s.jobs), s.instance}, s}

  def handle_call({:unscheduled, stored}, _from, s) do
    defined = defined(s.instance)

    {names, failed} =
      Enum.reduce(stored, {[], []}, fn job, {names, failed} ->
        def = job.definition

        if MapSet.member?(defined, job.name) or schedule_of(def) == "" or s.app_tag not in tags_of(def) do
          {names, failed}
        else
          case Cronwatch.job(job.name, [{:instance, s.instance} | Bridge.unscheduled(def)]) do
            {:ok, _} -> {names ++ [job.name], failed}
            {:error, e} -> {names, failed ++ ["declaring #{job.name}: #{Config.describe(e)}"]}
          end
        end
      end)

    {:reply, {names, failed}, s}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{saver: {_, ref}} = s) do
    # A writer that ended without finishing (killed, or its instance going
    # down) lets go, so the next declaration starts another and settle does
    # not wait for good.
    {:noreply, saved(s)}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp saved(s) do
    for w <- s.waiters, do: GenServer.reply(w, :ok)
    %{s | saver: nil, waiters: []}
  end

  defp report_once_in(s, message, where) do
    key = {where, message}

    if MapSet.member?(s.reported, key) do
      s
    else
      Core.report(Config.get(s.instance), Error.other(message), where)
      %{s | reported: MapSet.put(s.reported, key)}
    end
  end

  defp schedule_of(%Object{} = def) do
    case Object.get(def, "schedule") do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp schedule_of(_), do: ""

  defp declare_in(s, entries) do
    {order, by_name} =
      Enum.reduce(entries, {[], %{}}, fn e, {order, by} ->
        if Map.has_key?(by, e.name),
          do: {order, Map.update!(by, e.name, &(&1 ++ [e]))},
          else: {order ++ [e.name], Map.put(by, e.name, [e])}
      end)

    s = if entries != [], do: %{s | seen: true}, else: s
    s = %{s | jobs: Map.new(s.jobs, fn {k, d} -> {k, %{d | current: false}} end)}

    s =
      Enum.reduce(order, s, fn name, s ->
        [first | _] = group = by_name[name]

        {s, times} =
          Enum.reduce(group, {s, []}, fn e, {s, times} ->
            s = if e.problem, do: report_once_in(s, e.problem, "declaring #{e.label}"), else: s
            text = if e.timezone != "", do: "#{e.schedule} in #{e.timezone}", else: e.schedule
            text = if text == "", do: "no schedule", else: text
            {s, if(text in times, do: times, else: times ++ [text])}
          end)

        {schedule, zone, s} =
          if length(times) > 1 do
            message =
              "cronwatch: #{JS.quote(name)} is run by #{length(group)} #{s.scheduler} entries on different schedules " <>
                "(#{Enum.join(times, "; ")}), so it is watched without a schedule; give each a name of its own"

            {"", "", report_once_in(s, message, "declaring #{first.label}")}
          else
            {first.schedule, first.timezone, s}
          end

        options =
          first.defaults ++
            if(schedule != "", do: [schedule: schedule], else: []) ++
            if(schedule != "" and zone != "", do: [timezone: zone], else: []) ++ first.options

        declare_one(s, name, first.label, add_tags(options, [s.tag, s.app_tag]), true)
      end)

    # Jobs whose entries are gone keep their runs and lose their schedule.
    gone =
      for {name, d} <- s.jobs, not d.current, schedule_of(d.job.definition) != "" do
        {name, d.job.definition}
      end

    gone
    |> Enum.sort()
    |> Enum.reduce(s, fn {name, def}, s -> declare_one(s, name, JS.quote(name), Bridge.unscheduled(def), false) end)
  end

  defp declare_one(s, name, label, options, current) do
    c = Config.get(s.instance)

    case Job.new(c.name, name, options, c.defaults) do
      {:error, e} ->
        report_once_in(s, Config.describe(e), "declaring #{label}")

      {:ok, job} ->
        key = JS.stringify(job.definition)

        # Unchanged only while the instance still declares it: a job
        # forgotten since (the dashboard's Forget) is declared again, or a
        # check would take it for an entry gone from the scheduler.
        case {s.jobs, Runs.job(c.name, name)} do
          {%{^name => %{key: ^key} = d}, %Job{}} ->
            %{s | jobs: Map.put(s.jobs, name, %{d | current: d.current or current})}

          _ ->
            Runs.declare(c.name, job)
            was = Map.get(s.jobs, name, %{current: false})
            declared = %{job: job, key: key, current: was.current or current}
            s = %{s | jobs: Map.put(s.jobs, name, declared), fallback: Map.delete(s.fallback, name)}
            save(s, name)
        end
    end
  end

  # Writes the declaration to the store in the background, one writer at a
  # time, each write the instance's declaration as it is then.
  defp save(s, name) do
    s = %{s | pending: MapSet.put(s.pending, name)}

    if s.saver do
      s
    else
      watch = self()
      instance = s.instance

      case Task.Supervisor.start_child(Cronwatch.Supervisor.tasks(instance), fn -> save_all(watch, instance) end) do
        {:ok, pid} -> %{s | saver: {pid, Process.monitor(pid)}}
        _ -> s
      end
    end
  end

  defp save_all(watch, instance) do
    case GenServer.call(watch, :take_pending, :infinity) do
      :done ->
        :ok

      names ->
        defined = defined(instance)

        for name <- names, MapSet.member?(defined, name) do
          case write(instance, name) do
            {:ok, _} -> :ok
            {:error, e} -> Core.report(Config.get(instance), e, "declaring #{name}")
          end
        end

        save_all(watch, instance)
    end
  end
end
