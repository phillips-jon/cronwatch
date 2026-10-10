if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Cronwatch.Sources.PgCron do
    @moduledoc """
    Watches pg_cron jobs, which run inside Postgres where nothing can wrap
    them: the SDK's `pgCron()` source (`sources/pgcron.ts`), line for line as
    the Go and Rust ports have it. On every check it reads `cron.job` and
    declares each job with its schedule, then copies new rows of
    `cron.job_run_details` in as runs (ids `pgcron:<prefix><runid>`), so the
    usual evaluation raises missed, failed, stuck, and slow alerts.

        {Cronwatch,
         store: {Cronwatch.Store.Ecto, repo: MyApp.Repo},
         sources: [{Cronwatch.Sources.PgCron, repo: MyApp.Repo, prefix: "db:"}],
         check_every: :timer.minutes(1)}

    Options:

      * `:repo` (required, unless `:query` is given): an Ecto repo over
        Postgres (`Ecto.Adapters.Postgres`), on the database pg_cron runs in
        (its `cron.database_name`).
      * `:dynamic_repo`: a repo started with `name: nil` (its pid) or under
        another name, put with `put_dynamic_repo/1` around each query.
      * `:query`: a function of the SQL and its parameters answering
        `{:ok, rows}` (each row a map of column name to value) or
        `{:error, reason}`, in place of `:repo`: the SDK's `Queryable`, for a
        connection that is not an Ecto repo.
      * `:jobs`, `:job_ids`: the jobs to watch by name and by id; with both,
        a job either names is watched. Neither (the default) is every job the
        role can see.
      * `:pick`: a function of a `Cronwatch.Sources.PgCron.Job` answering
        whether to watch it, in place of `:jobs` and `:job_ids`.
      * `:prefix`: goes before every job name, to keep them apart from the
        app's own (`"db:"`). It also keeps run ids apart. Default `""`.
      * `:job_name`: a function of a `Cronwatch.Sources.PgCron.Job` answering
        its CronWatch name. Default `job_name/1`. The prefix goes in front
        either way. One that raises, throws, or exits, or answers no string,
        like a `:pick` or `:options` function that fails, is reported once
        and fails only that job, which keeps its last declaration until the
        function works again.
      * `:options`: job options (`grace`, `timeout`, `max_duration`, `expect`,
        and the rest) for every job, or a function of a
        `Cronwatch.Sources.PgCron.Job` answering them per job. The schedule
        and timezone always come from pg_cron.
      * `:timezone`: the zone pg_cron reads its cron expressions in. Default
        the server's `cron.timezone`, read from `pg_settings`, which shows it
        only to roles with `pg_read_all_settings`; UTC (pg_cron's default) is
        assumed when it cannot be read.

    A job that is renamed, unscheduled, or no longer picked keeps its old
    name's runs and history, and that name is declared again without a
    schedule, so it is never reported missed. Its description says why.

    Settings are read from `pg_settings`, which answers no row for a setting
    the role may not read, where `current_setting()` would raise an error
    that aborts the caller's transaction; every query runs on its own and
    nothing is committed or rolled back. A query made from inside the repo's
    own transaction runs from a task, on a connection of its own, as the SQL
    store's statements do.

    Where the source is between checks (each job's cursor, the runs still
    going, and the runs held before they start) lives in the instance's own
    table, so it ends with the instance, and a new instance finds its place
    again from the store.
    """

    @behaviour Cronwatch.Source

    alias Cronwatch.Config
    alias Cronwatch.Core
    alias Cronwatch.Error
    alias Cronwatch.Evaluate
    alias Cronwatch.JS
    alias Cronwatch.JS.Object
    alias Cronwatch.Run
    alias Cronwatch.Runs
    alias Cronwatch.Store.Ecto, as: EctoStore

    defmodule Job do
      @moduledoc """
      A row of `cron.job`, as `:pick`, `:job_name`, and `:options` are given
      it. `job_name` is nil for a job scheduled without a name.
      """
      defstruct job_id: 0, job_name: nil, schedule: "", database: "", username: "", active: true

      @type t :: %__MODULE__{
              job_id: integer(),
              job_name: String.t() | nil,
              schedule: String.t(),
              database: String.t(),
              username: String.t(),
              active: boolean()
            }
    end

    # How many of a job's newest runs are copied, without alerting, the first
    # time it is seen.
    @backfill 20
    # Run details read per query, and the most read in one sync.
    @page 500
    @max_pages 10
    # How long a run pg_cron has queued but not started (no start time yet)
    # is waited for. After that it is copied as running from when it was
    # first seen, so a run that never starts is marked stuck like any other.
    @hold_ms 10 * 60_000

    @jobs_sql "SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid"
    # pg_settings has no row for a setting the role may not read, where
    # current_setting() raises an error that would abort the caller's
    # transaction.
    @setting_sql "SELECT setting FROM pg_settings WHERE name = $1"
    # Every tracked job's runs after its cursor, and any run still open here,
    # whatever its job. The arrays are passed as array literals in text.
    @runs_sql """
    SELECT d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time
      FROM cron.job_run_details d
      LEFT JOIN unnest($1::text::bigint[], $2::text::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid
      WHERE d.runid > c.after OR d.runid = ANY($3::text::bigint[])
      ORDER BY d.runid LIMIT 500\
    """
    @newest_sql "SELECT d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time " <>
                  "FROM cron.job_run_details d WHERE d.jobid = $1 ORDER BY d.runid DESC LIMIT 20"

    @known [:repo, :dynamic_repo, :query, :jobs, :job_ids, :pick, :prefix, :job_name, :options, :timezone]

    @doc false
    # How long a queued run is held before it is copied as running: ten minutes, in milliseconds.
    @deprecated "Internal to the pg_cron source, public by accident; removed in 1.0"
    def hold_ms, do: @hold_ms

    @impl Cronwatch.Source
    def name(_opts), do: "pg_cron"

    ## The SDK's helpers

    @doc false
    @deprecated "Internal to the pg_cron source, public by accident; removed in 1.0"
    def schedule(schedule), do: schedule_of(schedule)

    @doc false
    # A pg_cron schedule as a CronWatch one: a cron expression, `$` for the
    # last day of the month read as `L`, or `N seconds` as `every Ns`. pg_cron
    # reads only the first five fields of an expression and ignores the rest,
    # so only those are kept (a sixth would otherwise be read as seconds). nil
    # for one that has no cadence to watch (`@reboot`).
    @spec schedule_of(String.t()) :: String.t() | nil
    def schedule_of(schedule) when is_binary(schedule) do
      text = JS.trim(schedule)

      case seconds(text) do
        {:ok, n} ->
          "every #{JS.stringify(n)}s"

        :error ->
          if ascii_downcase(text) == "@reboot" do
            nil
          else
            fields = split(text)

            fields =
              if length(fields) > 5 and not String.starts_with?(hd(fields), "@"), do: Enum.take(fields, 5), else: fields

            fields =
              if length(fields) == 5 and String.contains?(Enum.at(fields, 2), "$"),
                do: List.update_at(fields, 2, &String.replace(&1, "$", "L")),
                else: fields

            Enum.join(fields, " ")
          end
      end
    end

    # /^(\d+)\s*seconds?$/i over trimmed text.
    defp seconds(text) do
      {digits, rest} = take_digits(text, "")

      rest = rest |> JS.trim_start() |> ascii_downcase()

      if digits != "" and rest in ["second", "seconds"],
        do: {:ok, String.to_integer(digits)},
        else: :error
    end

    defp take_digits(<<c, rest::binary>>, acc) when c in ?0..?9, do: take_digits(rest, acc <> <<c>>)
    defp take_digits(rest, acc), do: {acc, rest}

    # /i without the u flag folds ASCII letters only.
    defp ascii_downcase(s), do: for(<<c <- s>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)

    # text.split(/\s+/), the text already trimmed: "" is [""].
    defp split(text) do
      {fields, current} =
        text
        |> String.to_charlist()
        |> Enum.reduce({[], []}, fn c, {fields, current} ->
          cond do
            not JS.space?(c) -> {fields, [c | current]}
            current == [] -> {fields, current}
            true -> {[current | fields], []}
          end
        end)

      [current | fields]
      |> Enum.reverse()
      |> Enum.map(&(&1 |> Enum.reverse() |> List.to_string()))
      |> case do
        [] -> [""]
        list -> list
      end
    end

    @doc false
    @deprecated "Internal to the pg_cron source, public by accident; removed in 1.0"
    def job_name(job), do: default_name(job)

    @doc false
    # The default CronWatch name for a pg_cron job, before the prefix: its
    # jobname with each run of anything other than letters, digits, `.`, `_`,
    # `:`, and `-` turned into `-`, leading punctuation dropped, at most 100
    # characters, or `pg_cron:<jobid>` when nothing is left.
    @spec default_name(Job.t() | map()) :: String.t()
    def default_name(%{job_id: id} = job) do
      {cleaned, _} =
        (Map.get(job, :job_name) || "")
        |> String.to_charlist()
        |> Enum.reduce({[], false}, fn c, {acc, in_run} ->
          cond do
            safe?(c) -> {[c | acc], false}
            in_run -> {acc, true}
            true -> {[?- | acc], true}
          end
        end)

      cleaned =
        cleaned
        |> Enum.reverse()
        |> Enum.drop_while(&(not alnum?(&1)))
        |> Enum.take(100)
        |> List.to_string()

      if cleaned == "", do: "pg_cron:#{id}", else: cleaned
    end

    defp alnum?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9
    defp safe?(c), do: alnum?(c) or c in [?., ?_, ?:, ?-]

    @doc false
    @deprecated "Internal to the pg_cron source, public by accident; removed in 1.0"
    def run_of(row, job, id_prefix, fallback_at), do: to_run(row, job, id_prefix, fallback_at)

    @doc false
    # A row of `cron.job_run_details` as a CronWatch run, or nil for one that
    # has not started (no start time, not finished). The row is a map of the
    # table's columns (`"runid"`, `"jobid"`, `"status"`, `"return_message"`,
    # `"start_time"`, `"end_time"`), times as `DateTime`s, epoch milliseconds,
    # or ISO text. A finished row with no start time (pg_cron writes these for
    # runs a server restart cut off, "server restarted") starts at its end
    # time, else at `fallback_at` (the source passes the job's newest run's
    # start, or now).
    @spec to_run(map(), String.t(), String.t(), integer()) :: Run.t() | nil
    def to_run(row, job, id_prefix, fallback_at) do
      status = text(row["status"])
      start_time = time(row["start_time"])
      end_time = time(row["end_time"])
      done = finished?(status)

      if start_time == nil and not done do
        nil
      else
        started_at = start_time || end_time || fallback_at

        message =
          case text(row["return_message"]) do
            nil -> nil
            m -> if JS.trim(m) == "", do: nil, else: JS.trim(m)
          end

        status =
          case status do
            "succeeded" -> "ok"
            "failed" -> "failed"
            _ -> "running"
          end

        finished_at = if done, do: max(started_at, end_time || started_at)

        %Run{
          id: "#{id_prefix}#{run_id(row["runid"])}",
          job: job,
          status: status,
          started_at: started_at,
          finished_at: finished_at,
          duration_ms: finished_at && Evaluate.run_duration(started_at, finished_at),
          error: if(status == "failed", do: message || "pg_cron reported the run as failed"),
          output: if(status == "ok", do: message),
          metrics: Object.new(),
          trigger: "pg_cron"
        }
      end
    end

    defp finished?(status), do: status in ["succeeded", "failed"]

    ## Reading values as the driver or a fake gives them

    defp text(nil), do: nil
    defp text(v) when is_binary(v), do: v
    defp text(v), do: to_string(v)

    defp int(nil), do: nil
    defp int(v) when is_integer(v), do: v
    defp int(v) when is_float(v), do: trunc(v)

    defp int(v) when is_binary(v) do
      case Integer.parse(JS.trim(v)) do
        {n, ""} -> n
        _ -> 0
      end
    end

    defp int(_), do: 0

    # A runid as written into a run id, as JavaScript prints the number.
    defp run_id(v), do: v |> int() |> Integer.to_string()

    defp time(nil), do: nil
    defp time(%DateTime{} = t), do: DateTime.to_unix(t, :millisecond)
    defp time(%NaiveDateTime{} = t), do: t |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
    defp time(ms) when is_integer(ms), do: ms

    defp time(text) when is_binary(text) do
      case DateTime.from_iso8601(text) do
        {:ok, t, _} -> DateTime.to_unix(t, :millisecond)
        _ -> nil
      end
    end

    defp bool(v), do: v in [true, "t", "true"]

    defp job_of(r) do
      %Job{
        job_id: int(r["jobid"]) || 0,
        job_name: text(r["jobname"]),
        schedule: text(r["schedule"]) || "",
        database: text(r["database"]) || "",
        username: text(r["username"]) || "",
        active: bool(r["active"])
      }
    end

    # A Postgres array literal, {1,2,3}.
    @doc false
    def array_of(ids), do: "{" <> Enum.map_join(ids, ",", &Integer.to_string/1) <> "}"

    # The jobid a description this source wrote names ("pg_cron job 7 in ...").
    @doc false
    def description_job_id(description) when is_binary(description) do
      with "pg_cron job " <> rest <- description,
           {digits, " in " <> _} when digits != "" <- take_digits(rest, "") do
        String.to_integer(digits)
      else
        _ -> nil
      end
    end

    def description_job_id(_), do: nil

    # The pg_cron runid of a run id this source made, or nil: Number() of the
    # rest, a safe integer.
    @doc false
    def run_id_of(id, id_prefix) do
      if String.starts_with?(id, id_prefix) do
        rest = id |> binary_part(byte_size(id_prefix), byte_size(id) - byte_size(id_prefix)) |> JS.trim()

        case {rest, Float.parse(rest)} do
          {"", _} -> 0
          {_, {n, ""}} when n == trunc(n) and abs(n) <= 9_007_199_254_740_991 -> trunc(n)
          _ -> nil
        end
      end
    end

    ## Querying

    defp query(o, sql, params) do
      case o[:query] do
        f when is_function(f, 2) ->
          case f.(sql, params) do
            {:ok, rows} when is_list(rows) -> {:ok, rows}
            {:error, _} = e -> e
            other -> {:error, Error.other("Cronwatch.Sources.PgCron: :query answered #{inspect(other)}")}
          end

        _ ->
          repo = repo!(o)

          within(repo, o[:dynamic_repo], fn ->
            case repo.query(sql, params, log: false) do
              {:ok, %{columns: columns, rows: rows}} ->
                {:ok, Enum.map(rows, fn row -> Map.new(Enum.zip(columns || [], row)) end)}

              {:error, e} ->
                {:error, e}
            end
          end)
      end
    end

    defp query!(o, sql, params) do
      case query(o, sql, params) do
        {:ok, rows} -> rows
        {:error, %{__exception__: true} = e} -> raise e
        {:error, reason} -> raise Error.other(Error.describe(reason), reason)
      end
    end

    defp repo!(o) do
      repo = o[:repo]

      cond do
        not ecto_repo?(repo) ->
          raise Error.invalid("Cronwatch.Sources.PgCron needs :repo, an Ecto repo over Postgres (got #{inspect(repo)})")

        repo.__adapter__() != Ecto.Adapters.Postgres ->
          raise Error.invalid(
                  "Cronwatch.Sources.PgCron needs a Postgres repo: #{inspect(repo)} uses #{inspect(repo.__adapter__())}"
                )

        true ->
          repo
      end
    end

    defp ecto_repo?(repo),
      do: is_atom(repo) and repo != nil and Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0)

    # Runs `fun` with the repo put, from a task when the calling process is
    # inside a transaction of the repo, so the source never reads inside (or
    # aborts) the app's transaction.
    defp within(repo, dyn, fun) do
      previous = if dyn, do: repo.put_dynamic_repo(dyn)

      try do
        if repo.in_transaction?(), do: EctoStore.apart(repo, dyn, fun), else: fun.()
      after
        if dyn, do: repo.put_dynamic_repo(previous)
      end
    end

    # A server setting from pg_settings, or nil when the role may not read
    # it (or the read failed).
    defp setting(o, name) do
      case query(o, @setting_sql, [name]) do
        {:ok, [row | _]} -> text(row["setting"])
        _ -> nil
      end
    rescue
      e in Error -> reraise e, __STACKTRACE__
      _ -> nil
    end

    ## Where the source is between checks

    defmodule State do
      @moduledoc false
      defstruct cursors: %{},
                last_at: %{},
                pending: %{},
                held: %{},
                known: %{},
                declared: %{},
                retired: MapSet.new(),
                scanned: false,
                warned: MapSet.new(),
                failing: MapSet.new()
    end

    @st {__MODULE__, :state}

    defp st, do: Process.get(@st)
    defp put_st(st), do: Process.put(@st, st)
    defp update_st(fun), do: put_st(fun.(st()))

    defp table_key(opts), do: {__MODULE__, opts}

    ## The sync

    @doc """
    Declares the jobs and copies their new runs in, answering the alerts
    recording them sent. A check calls it.
    """
    @impl Cronwatch.Source
    def sync(opts, instance) do
      o = check_options!(opts)
      c = Config.get(instance)
      table = Runs.table(instance, :flags)
      key = table_key(opts)

      state =
        case :ets.lookup(table, key) do
          [{_, s}] -> s
          [] -> %State{}
        end

      put_st(state)

      try do
        {:ok, sync_with(o, c)}
      after
        :ets.insert(table, {key, st()})
        Process.delete(@st)
      end
    end

    defp check_options!(opts) when is_list(opts) do
      case Enum.find(opts, fn {k, _} -> k not in @known end) do
        nil -> :ok
        {k, _} -> raise Error.invalid("Cronwatch.Sources.PgCron: unknown option #{inspect(k)}")
      end

      unless is_function(opts[:query], 2), do: repo!(opts)
      opts
    end

    defp check_options!(other),
      do: raise(Error.invalid("Cronwatch.Sources.PgCron: options must be a keyword list, not #{inspect(other)}"))

    defp warn_once(c, key, message) do
      unless MapSet.member?(st().warned, key) do
        update_st(&%{&1 | warned: MapSet.put(&1.warned, key)})
        Core.report(c, Error.other(message), "source pg_cron")
      end
    end

    defp picks?(o, job) do
      cond do
        is_function(o[:pick], 1) ->
          o[:pick].(job) == true

        o[:jobs] == nil and o[:job_ids] == nil ->
          true

        true ->
          job.job_id in (o[:job_ids] || []) or (job.job_name != nil and job.job_name in (o[:jobs] || []))
      end
    end

    # What a job is declared with: the options of the app's that are not
    # pg_cron's to give.
    defp extra(o, job) do
      extra =
        case o[:options] do
          f when is_function(f, 1) -> f.(job) || []
          nil -> []
          list -> list
        end

      extra = if is_map(extra), do: extra |> Map.to_list() |> Enum.sort(), else: extra
      Enum.reject(extra, fn {k, _} -> k in [:schedule, :timezone, :instance] end)
    end

    defp declare(c, name, options), do: Cronwatch.job(name, options ++ [instance: c.name])

    # The options of a definition that can be declared again, without its
    # schedule: from the options last declared, or from a stored definition.
    @unscheduled [:description, :tags, :grace, :timeout, :max_duration, :budget, :floor, :failures_before_alert]
    @json_keys %{
      "description" => :description,
      "tags" => :tags,
      "grace" => :grace,
      "timeout" => :timeout,
      "maxDuration" => :max_duration,
      "budget" => :budget,
      "floor" => :floor,
      "failuresBeforeAlert" => :failures_before_alert
    }

    defp unscheduled(options) when is_list(options), do: Enum.filter(options, fn {k, _} -> k in @unscheduled end)

    defp unscheduled(%Object{} = definition) do
      Enum.flat_map(Object.to_list(definition), fn {k, v} ->
        case {@json_keys[k], v} do
          {nil, _} -> []
          {:budget, %Object{} = b} -> [budget: Enum.filter(Object.to_list(b), fn {_, n} -> is_number(n) end)]
          {:budget, _} -> []
          {:floor, %Object{} = f} -> [floor: Enum.filter(Object.to_list(f), fn {_, n} -> is_number(n) end)]
          {:floor, _} -> []
          {:tags, tags} when is_list(tags) -> [tags: Enum.filter(tags, &is_binary/1)]
          {:tags, _} -> []
          {:description, d} when is_binary(d) -> [description: d]
          {:description, _} -> []
          {:failures_before_alert, n} when is_number(n) -> [failures_before_alert: JS.normalize(n)]
          {:failures_before_alert, _} -> []
          {key, d} when is_binary(d) or is_number(d) -> [{key, d}]
          _ -> []
        end
      end)
    end

    defp description_of(options) do
      case options |> Keyword.get_values(:description) |> List.last() do
        d when is_binary(d) -> d
        _ -> nil
      end
    end

    # Declares a name this source no longer uses for any job again, without
    # its schedule.
    defp retire(c, name, definition, why) do
      base = unscheduled(definition)
      next = base ++ [description: "#{description_of(base) || "pg_cron job"} (#{why})"]

      case declare(c, name, next) do
        {:ok, _} ->
          update_st(&%{&1 | declared: Map.put(&1.declared, name, next), retired: MapSet.put(&1.retired, name)})

        {:error, e} ->
          Core.report(c, e, "source pg_cron: job #{name}")
      end
    end

    defp sync_with(o, c) do
      now = Core.now(c)
      prefix = o[:prefix] || ""
      id_prefix = "pgcron:#{prefix}"

      timezone =
        case o[:timezone] do
          tz when is_binary(tz) and tz != "" ->
            tz

          _ ->
            tz = setting(o, "cron.timezone")

            if tz == nil do
              warn_once(
                c,
                :tz,
                "could not read cron.timezone; assuming UTC. Grant pg_read_all_settings or give Cronwatch.Sources.PgCron timezone:."
              )
            end

            if tz == nil or ascii_downcase(tz) in ["gmt", "utc", "z"], do: "UTC", else: tz
        end

      recording = setting(o, "cron.log_run") != "off"

      unless recording do
        warn_once(
          c,
          :log_run,
          "cron.log_run is off, so pg_cron records no runs: jobs are watched without their schedules and no run can fail. Turn it on to watch them."
        )
      end

      rows = query!(o, @jobs_sql, [])

      if rows == [] do
        warn_once(
          c,
          :empty,
          "cron.job shows no jobs. pg_cron's row level security shows a role only the jobs it scheduled: connect as that role, or give this one BYPASSRLS."
        )
      end

      all = Enum.map(rows, &job_of/1)

      # Declare each job. A paused one (active = false) keeps its failures
      # but loses its schedule, so it is not missed.
      {order, names, definitions, _used} =
        Enum.reduce(all, {[], %{}, %{}, MapSet.new()}, fn job, acc ->
          case settle(o, job) do
            :skip ->
              update_st(&%{&1 | failing: MapSet.delete(&1.failing, job.job_id)})
              acc

            {:trouble, what} ->
              trouble(c, job, what, acc)

            {:ok, base, extra} ->
              update_st(&%{&1 | failing: MapSet.delete(&1.failing, job.job_id)})
              declare_picked(c, job, {prefix <> base, extra}, {recording, timezone}, acc)
          end
        end)

      # A name this source used for a job that has since been renamed,
      # unscheduled, or dropped from the jobs picked.
      in_use = MapSet.new(Map.values(names))
      update_st(&%{&1 | retired: MapSet.difference(&1.retired, in_use)})

      for {jobid, {previous, definition}} <- Enum.sort(st().known), not MapSet.member?(in_use, previous) do
        why = if names[jobid], do: "renamed to #{names[jobid]}", else: "no longer watched"
        retire(c, previous, definition, why)
      end

      update_st(&%{&1 | known: Map.new(names, fn {jobid, name} -> {jobid, {name, definitions[jobid]}} end)})

      # Once per process, the same for names left scheduled in the store
      # while no process was watching.
      if not st().scanned and rows != [] do
        update_st(&%{&1 | scanned: true})
        scan(c, all, names, in_use, prefix)
      end

      if not recording or names == %{} do
        []
      else
        read_runs(o, c, order, names, id_prefix, now)
      end
    end

    # The app's functions for one job (pick, job_name, options): :skip when
    # it is not picked, else its name before the prefix and its options, or
    # what went wrong when one of them failed.
    defp settle(o, job) do
      with {:ok, picked} <- call_back(fn -> picks?(o, job) end, "the pick function"),
           true <- picked || :skip,
           {:ok, base} <- call_back(fn -> base_name(o, job) end, "job_name"),
           :ok <- if(is_binary(base), do: :ok, else: {:trouble, "job_name returned #{returned(base)}, not a name"}),
           {:ok, extra} <- call_back(fn -> extra(o, job) end, "the options function") do
        {:ok, base, extra}
      end
    end

    defp base_name(o, job), do: if(is_function(o[:job_name], 1), do: o[:job_name].(job), else: default_name(job))

    defp returned(nil), do: "nil"
    defp returned(other), do: inspect(other)

    defp call_back(fun, what) do
      {:ok, fun.()}
    rescue
      e -> {:trouble, "#{what} raised #{inspect(e.__struct__)}: #{Exception.message(e)}"}
    catch
      :throw, value -> {:trouble, "#{what} threw #{inspect(value)}"}
      :exit, reason -> {:trouble, "#{what} exited with #{inspect(reason)}"}
    end

    # A function of the app's that failed fails only its job, as a bad row
    # does: reported once until it works again, and the job carries on as
    # last declared (skipped when it never was, or when another job took its
    # name this sync), so its runs are still copied.
    defp trouble(c, job, what, {order, names, definitions, used} = acc) do
      unless MapSet.member?(st().failing, job.job_id) do
        update_st(&%{&1 | failing: MapSet.put(&1.failing, job.job_id)})

        Core.report(
          c,
          Error.other("pg_cron job #{job.job_id}: #{what}; it keeps its last declaration until that works"),
          "source pg_cron"
        )
      end

      case st().known[job.job_id] do
        {name, definition} ->
          if MapSet.member?(used, name) do
            acc
          else
            {order ++ [job.job_id], Map.put(names, job.job_id, name), Map.put(definitions, job.job_id, definition),
             MapSet.put(used, name)}
          end

        nil ->
          acc
      end
    end

    # Declares a job that was picked, under its name with the prefix.
    defp declare_picked(c, job, {name, extra}, {recording, timezone}, {order, names, definitions, used}) do
      name = if MapSet.member?(used, name), do: "#{name}:#{job.job_id}", else: name
      used = MapSet.put(used, name)
      sched = if job.active and recording, do: schedule_of(job.schedule)
      paused = if job.active, do: "", else: " (paused)"

      unscheduled_options =
        [description: "pg_cron job #{job.job_id} in #{job.database} as #{job.username}#{paused}", tags: ["pg_cron"]] ++
          extra

      options =
        if sched, do: unscheduled_options ++ [schedule: sched, timezone: timezone], else: unscheduled_options

      case declare_job(c, job, name, options, sched, unscheduled_options) do
        {:ok, definition} ->
          {order ++ [job.job_id], Map.put(names, job.job_id, name), Map.put(definitions, job.job_id, definition), used}

        :error ->
          {order, names, definitions, used}
      end
    end

    # Declares one job, answering its definition's options, or :error when
    # it could not be declared. Declared again only when its options changed,
    # or when it was forgotten since (the dashboard's forget), though
    # unchanged: record_run takes runs only of a declared job.
    defp declare_job(c, job, name, options, sched, unscheduled_options) do
      if Map.get(st().declared, name) == options and Runs.job(c.name, name) != nil do
        {:ok, options}
      else
        result =
          case declare(c, name, options) do
            {:ok, _} ->
              {:ok, options}

            {:error, e} when sched != nil ->
              # A schedule CronWatch cannot read: watch the runs, not the
              # cadence.
              Core.report(
                c,
                Error.other("pg_cron job #{job.job_id}: #{Error.describe(e)}; watching it without a schedule"),
                "source pg_cron"
              )

              case declare(c, name, unscheduled_options) do
                {:ok, _} -> {:ok, unscheduled_options}
                {:error, e} -> {:error, e}
              end

            {:error, e} ->
              {:error, e}
          end

        case result do
          {:ok, definition} ->
            update_st(&%{&1 | declared: Map.put(&1.declared, name, options)})
            {:ok, definition}

          {:error, e} ->
            Core.report(c, e, "source pg_cron: job #{job.job_id}")
            :error
        end
      end
    end

    defp scan(c, all, names, in_use, prefix) do
      visible = MapSet.new(all, & &1.job_id)

      stored =
        try do
          Core.store!(c, :list_jobs, [])
        rescue
          e ->
            Core.report(c, e, "source pg_cron")
            []
        end

      # A foreign or damaged definition (not an object, tags not a list) is
      # not one of ours.
      for job <- stored,
          %Object{} = definition <- [job.definition],
          tags = Object.get(definition, "tags"),
          is_list(tags),
          String.starts_with?(job.name, prefix),
          not MapSet.member?(in_use, job.name),
          Object.get(definition, "schedule") not in [nil, ""],
          "pg_cron" in tags,
          jobid = description_job_id(Object.get(definition, "description")),
          jobid != nil do
        current = names[jobid]

        cond do
          not MapSet.member?(visible, jobid) ->
            retire(c, job.name, definition, "no longer in cron.job")

          # Another pg_cron source's name for the same job ends the same way:
          # that one is left alone.
          current != nil and
              not String.ends_with?(
                job.name,
                binary_part(current, byte_size(prefix), byte_size(current) - byte_size(prefix))
              ) ->
            retire(c, job.name, definition, "renamed to #{current}")

          true ->
            :ok
        end
      end
    end

    defp read_runs(o, c, order, names, id_prefix, now) do
      # Where each job left off. Found from the store the first time, so a
      # restart carries on.
      alerts =
        Enum.flat_map(order, fn jobid ->
          if Map.has_key?(st().cursors, jobid), do: [], else: first_sight(o, c, jobid, names, id_prefix, now)
        end)

      # New runs, runs copied while still going (or since marked timeout),
      # and runs not yet started.
      watched = MapSet.union(MapSet.new(Map.values(names)), st().retired)

      for run <- Core.store!(c, :running_runs, []),
          id = run_id_of(run.id, id_prefix),
          id != nil,
          MapSet.member?(watched, run.job) do
        update_st(&%{&1 | pending: Map.put(&1.pending, id, run.job)})
      end

      open = MapSet.new(Map.keys(st().pending) ++ Map.keys(st().held))
      page = %{o: o, c: c, order: order, names: names, id_prefix: id_prefix, now: now}
      {alerts, open, complete} = pages(page, alerts, open, 0)

      # Every row was read and these were not among them: pg_cron no longer
      # has them.
      if complete do
        update_st(fn s ->
          %{s | pending: Map.drop(s.pending, MapSet.to_list(open)), held: Map.drop(s.held, MapSet.to_list(open))}
        end)
      end

      alerts
    end

    defp pages(_p, alerts, open, @max_pages), do: {alerts, open, false}

    defp pages(%{o: o, c: c, order: order, names: names, id_prefix: id_prefix, now: now} = p, alerts, open, page) do
      afters = Enum.map(order, &Map.get(st().cursors, &1, 0))
      params = [array_of(order), array_of(afters), array_of(Enum.sort(MapSet.to_list(open)))]
      found = query!(o, @runs_sql, params)

      {alerts, open} =
        Enum.reduce(found, {alerts, open}, fn row, {alerts, open} ->
          runid = int(row["runid"])
          jobid = int(row["jobid"])
          open = MapSet.delete(open, runid)
          alerts = alerts ++ record(c, names, row, true, now, id_prefix)

          # Held or not, the cursor moves on: a held run is read again by its
          # runid.
          if Map.has_key?(names, jobid) and runid > Map.get(st().cursors, jobid, 0) do
            update_st(&%{&1 | cursors: Map.put(&1.cursors, jobid, runid)})
          end

          {alerts, open}
        end)

      if length(found) < @page,
        do: {alerts, open, true},
        else: pages(p, alerts, open, page + 1)
    end

    defp first_sight(o, c, jobid, names, id_prefix, now) do
      name = names[jobid]

      ours =
        for r <- Core.store!(c, :list_runs, [name, @backfill]),
            id = run_id_of(r.id, id_prefix),
            id != nil,
            do: {id, r}

      if ours != [] do
        pending =
          for {id, r} <- ours, r.status in ["running", "timeout"], into: st().pending, do: {id, r.job}

        cursor = ours |> Enum.map(&elem(&1, 0)) |> Enum.max()
        last = ours |> Enum.map(&elem(&1, 1).started_at) |> Enum.max()

        update_st(
          &%{
            &1
            | pending: pending,
              cursors: Map.put(&1.cursors, jobid, cursor),
              last_at: Map.put(&1.last_at, jobid, last)
          }
        )

        []
      else
        # First sight: copy recent history quietly, and judge only from the
        # newest finished run on. The cursor goes to the newest row read,
        # whatever is held, so history is never judged later.
        ordered = o |> query!(@newest_sql, [jobid]) |> Enum.reverse()

        last_finished =
          ordered
          |> Enum.with_index()
          |> Enum.reduce(-1, fn {r, i}, acc -> if finished?(text(r["status"])), do: i, else: acc end)

        alerts =
          ordered
          |> Enum.with_index()
          |> Enum.flat_map(fn {row, i} ->
            # Already copied under another name (the job was renamed while no
            # process watched): left there.
            if Core.store!(c, :get_run, ["#{id_prefix}#{run_id(row["runid"])}"]),
              do: [],
              else: record(c, names, row, i >= last_finished, now, id_prefix)
          end)

        cursor = if ordered == [], do: 0, else: int(List.last(ordered)["runid"])
        update_st(&%{&1 | cursors: Map.put(&1.cursors, jobid, cursor)})
        alerts
      end
    end

    # Copies one row, answering the alerts recording it sent. A row that
    # cannot be recorded is reported and skipped; it never stops the others.
    defp record(c, names, row, evaluate, now, id_prefix) do
      runid = int(row["runid"])
      jobid = int(row["jobid"])
      name = Map.get(st().pending, runid) || Map.get(names, jobid)

      cond do
        name == nil ->
          update_st(&%{&1 | held: Map.delete(&1.held, runid)})
          []

        # A run copied under a retired name that was then forgotten (the
        # dashboard's forget) has no job to go to: it is let go, never
        # recorded, and never read again.
        name not in Map.values(names) and Runs.job(c.name, name) == nil ->
          update_st(
            &%{
              &1
              | pending: Map.delete(&1.pending, runid),
                held: Map.delete(&1.held, runid),
                retired: MapSet.delete(&1.retired, name)
            }
          )

          []

        time(row["start_time"]) == nil and not finished?(text(row["status"])) ->
          since = Map.get(st().held, runid, now)

          if now - since < @hold_ms do
            update_st(&%{&1 | held: Map.put(&1.held, runid, since)})
            []
          else
            record_run(c, jobid, runid, to_run(Map.put(row, "start_time", since), name, id_prefix, now), evaluate)
          end

        true ->
          fallback = Map.get(st().last_at, jobid, now)
          record_run(c, jobid, runid, to_run(row, name, id_prefix, fallback), evaluate)
      end
    end

    defp record_run(c, jobid, runid, run, evaluate) do
      update_st(&%{&1 | held: Map.delete(&1.held, runid)})

      if run == nil do
        []
      else
        case Cronwatch.record_run(run, instance: c.name, evaluate: evaluate) do
          {:ok, sent} ->
            update_st(fn s ->
              pending =
                if run.status == "running",
                  do: Map.put(s.pending, runid, run.job),
                  else: Map.delete(s.pending, runid)

              last_at =
                if run.started_at > Map.get(s.last_at, jobid, run.started_at - 1),
                  do: Map.put(s.last_at, jobid, run.started_at),
                  else: s.last_at

              %{s | pending: pending, last_at: last_at}
            end)

            sent

          {:error, e} ->
            Core.report(c, e, "source pg_cron: run #{runid}")
            []
        end
      end
    end
  end
end
