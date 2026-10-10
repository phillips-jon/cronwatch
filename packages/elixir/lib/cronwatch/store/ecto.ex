if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Cronwatch.Store.Ecto do
    @moduledoc """
    Keeps CronWatch's jobs, runs, and state in the app's own database through
    the app's Ecto repo: the SDK's three tables (`stores/sql.ts`), the same
    names, columns, and statements, and the SDK's JSON in the JSON columns
    byte for byte, so an Elixir process shares a database with a Node, Ruby,
    Python, PHP, Go, or Rust one.

        {Cronwatch, store: {Cronwatch.Store.Ecto, repo: MyApp.Repo}}

    Options:

      * `:repo` (required): the app's Ecto repo. Its adapter picks the
        dialect: SQLite (`Ecto.Adapters.SQLite3`), Postgres
        (`Ecto.Adapters.Postgres`), or MySQL 8.0.13 and MariaDB 10.6 or newer
        (`Ecto.Adapters.MyXQL`).
      * `:prefix`: what every table name starts with, lowercase letters,
        digits, and underscores. Default `"cronwatch_"`.
      * `:dynamic_repo`: a repo started with `name: nil` (its pid) or under
        another name, put with `put_dynamic_repo/1` around each statement.

    Every statement is the SDK's, run with
    `Ecto.Adapters.SQL.query/4`; nothing uses Ecto's schemas. The tables are
    made by `c:Cronwatch.Store.init/1` on the instance's first use (`CREATE
    TABLE IF NOT EXISTS`), so a Node process and an Elixir process can make
    them in either order; an app that wants them in its migrations can run
    `create_statements/1` from one.

    A store call made inside the app's own transaction (`repo.in_transaction?()`
    in the calling process) runs from a task, on a connection of its own, so
    a run is recorded even when the app's transaction is rolled back.

    On SQLite, keep the repo's `journal_mode: :wal` (ecto_sqlite3's default)
    and a `busy_timeout` of at least 5000, as the SDK's store sets them. An
    in-memory database is one per connection, so a `database: ":memory:"`
    repo needs `pool_size: 1`.

    On Postgres the tables and statements are the SDK's (`JSONB` for the
    JSON, `BIGINT` times, names sorted `COLLATE "C"`), and many processes can
    start at once: `c:Cronwatch.Store.init/1` makes the tables under an
    advisory lock per prefix. On MySQL and MariaDB the dialect is the PHP, Go,
    and Rust ports': the JSON columns are `LONGTEXT` holding the SDK's bytes
    (never MySQL's `JSON` type, which rewrites them), names compare by byte
    (`utf8mb4_bin`), and a run's trigger is cut to 255 characters.
    """

    @behaviour Cronwatch.Store

    alias Cronwatch.JobState
    alias Cronwatch.JS
    alias Cronwatch.JS.Object
    alias Cronwatch.Metrics
    alias Cronwatch.Run
    alias Cronwatch.Store.SQL
    alias Cronwatch.Store.Text
    alias Cronwatch.StoredJob

    @enforce_keys [:repo, :prefix, :dialect, :sql]
    defstruct [:repo, :prefix, :dialect, :sql, dynamic_repo: nil]

    @type t :: %__MODULE__{
            repo: module(),
            prefix: String.t(),
            dialect: :sqlite | :postgres | :mysql,
            sql: %{atom() => String.t()},
            dynamic_repo: pid() | atom() | nil
          }

    @min_int -9_223_372_036_854_775_808
    @max_int 9_223_372_036_854_775_807

    @doc """
    Checks the options and answers the store's handle: `repo:` a loaded Ecto
    repo over a supported adapter, `prefix:` the SDK's rule.
    """
    @impl Cronwatch.Store
    @spec new(keyword(), atom()) :: {:ok, t()} | {:error, String.t()}
    def new(opts, _instance \\ nil) do
      with {:ok, repo} <- repo(opts[:repo]),
           {:ok, dialect} <- dialect(repo),
           {:ok, prefix} <- SQL.table_prefix(Keyword.get(opts, :prefix, SQL.default_prefix())),
           :ok <- memory_pool(repo, opts[:dynamic_repo]) do
        {:ok,
         %__MODULE__{
           repo: repo,
           prefix: prefix,
           dialect: dialect,
           sql: SQL.statements(dialect, prefix),
           dynamic_repo: opts[:dynamic_repo]
         }}
      end
    end

    defp repo(repo) when is_atom(repo) and repo != nil do
      if Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0),
        do: {:ok, repo},
        else: {:error, "Cronwatch.Store.Ecto needs :repo to be an Ecto repo, not #{inspect(repo)}"}
    end

    defp repo(other), do: {:error, "Cronwatch.Store.Ecto needs :repo, an Ecto repo (got #{inspect(other)})"}

    defp dialect(repo) do
      case repo.__adapter__() do
        Ecto.Adapters.SQLite3 -> {:ok, :sqlite}
        Ecto.Adapters.Postgres -> {:ok, :postgres}
        Ecto.Adapters.MyXQL -> {:ok, :mysql}
        other -> {:error, "Cronwatch.Store.Ecto does not support the #{inspect(other)} adapter"}
      end
    end

    # An in-memory SQLite database is one per connection: a pool of several
    # would give each statement a database of its own.
    defp memory_pool(repo, nil) do
      config = repo.config()

      if config[:database] == ":memory:" and Keyword.get(config, :pool_size, 5) != 1 do
        {:error,
         "Cronwatch.Store.Ecto: #{inspect(repo)} is an in-memory SQLite database, which is one per connection; " <>
           "give it pool_size: 1"}
      else
        :ok
      end
    end

    defp memory_pool(_repo, _dynamic), do: :ok

    @doc """
    The statements that make the store's tables, in order, for an app that
    wants them in a migration: `Enum.each(Cronwatch.Store.Ecto.create_statements(repo: MyApp.Repo), &execute/1)`.
    """
    @spec create_statements(keyword()) :: [String.t()]
    def create_statements(opts) do
      {:ok, h} = new(opts)
      SQL.schema(h.dialect, h.prefix)
    end

    ## Running statements

    # Runs `fun` with the store's repo put, from a task when the calling
    # process is inside a transaction of the repo, so the store's writes
    # never join (and are never rolled back with) the app's transaction.
    defp within(%__MODULE__{repo: repo, dynamic_repo: dyn}, fun) do
      previous = if dyn, do: repo.put_dynamic_repo(dyn)

      try do
        if repo.in_transaction?(), do: apart(repo, dyn, fun), else: fun.()
      after
        if dyn, do: repo.put_dynamic_repo(previous)
      end
    end

    @doc false
    # Runs `fun` in a task, on a connection of its own, and hands back what
    # it answered, or raises in the caller what it raised: a raise in a
    # linked task would otherwise take the caller (a job's own process) down
    # with it, where the same raise outside a transaction is a store error
    # the client reports.
    def apart(repo, dyn, fun) do
      task =
        Task.async(fn ->
          if dyn, do: repo.put_dynamic_repo(dyn)

          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end
        end)

      case Task.await(task, :infinity) do
        {:ok, value} -> value
        {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      end
    end

    defp query(h, sql, params) do
      within(h, fn -> raw(h, sql, params) end)
    end

    # Through the repo's own query/3, which runs on the dynamic repo put in
    # this process.
    defp raw(h, sql, params) do
      case h.repo.query(sql, params, log: false) do
        {:ok, result} -> {:ok, result}
        {:error, e} -> {:error, e}
      end
    end

    defp changed(h, sql, params) do
      with {:ok, %{num_rows: n}} <- query(h, sql, params), do: {:ok, n || 0}
    end

    defp exec(h, sql, params) do
      with {:ok, _} <- query(h, sql, params), do: :ok
    end

    # Each row read by `fun`, which reads any row leniently and never fails.
    defp rows(h, sql, params, fun) do
      with {:ok, %{columns: columns, rows: rows}} <- query(h, sql, params) do
        keys = Enum.map(columns, &String.downcase/1)
        {:ok, Enum.map(rows, &fun.(Enum.zip(keys, &1)))}
      end
    end

    defp first(h, sql, params, fun) do
      with {:ok, list} <- rows(h, sql, params, fun), do: {:ok, List.first(list)}
    end

    # Statements in one transaction of the store's own; on Postgres, under
    # an advisory lock per prefix first when `lock` is given.
    defp transaction(h, statements, params, lock \\ nil) do
      within(h, fn ->
        result =
          h.repo.transaction(fn ->
            if lock do
              case raw(h, "SELECT pg_advisory_xact_lock(hashtext($1))", [lock]) do
                {:ok, _} -> :ok
                {:error, e} -> h.repo.rollback(e)
              end
            end

            Enum.each(statements, fn sql ->
              case raw(h, sql, params) do
                {:ok, _} -> :ok
                {:error, e} -> h.repo.rollback(e)
              end
            end)
          end)

        case result do
          {:ok, _} -> :ok
          {:error, e} -> {:error, e}
        end
      end)
    end

    ## Reading rows as the SDK reads them

    # A column as text, nil for NULL. Text that is not UTF-8 reads with
    # U+FFFD, as the SDK reads it, rather than failing every read its row is
    # part of.
    defp text(row, key) do
      case List.keyfind(row, key, 0) do
        {_, nil} -> nil
        {_, v} when is_binary(v) -> JS.scrub(v)
        {_, v} when is_integer(v) -> Integer.to_string(v)
        {_, v} when is_float(v) -> JS.format_number(JS.normalize(v))
        {_, v} -> to_string(v)
        nil -> nil
      end
    end

    # Rows are read leniently: a foreign, hand-edited, or damaged row (SQLite
    # keeps whatever type it is given, in any column) must affect only its
    # own job, never every read. JSON text that does not parse reads as nil,
    # which the client takes as no state, or as an unreadable definition it
    # reports.
    defp json(row, key) do
      case text(row, key) do
        nil ->
          nil

        t ->
          case JS.parse(t) do
            {:ok, v} -> v
            {:error, _} -> nil
          end
      end
    end

    # A column that holds text: a string as it is (a blob too, which the
    # driver hands over as one), anything else nil.
    defp string(row, key) do
      case List.keyfind(row, key, 0) do
        {_, v} when is_binary(v) -> JS.scrub(v)
        _ -> nil
      end
    end

    # A time, or a count of milliseconds, as a whole number, or nil when it
    # is not a finite number: text is read as JavaScript's Number() reads it
    # (Postgres's BIGINT can arrive as text), a fraction is cut to its whole
    # part, and anything past 64 bits is held at the ends.
    defp time(row, key) do
      case List.keyfind(row, key, 0) do
        {_, v} when is_integer(v) ->
          v |> max(@min_int) |> min(@max_int)

        {_, v} when is_float(v) ->
          JS.to_int(v)

        {_, v} when is_binary(v) ->
          t = JS.trim(v)

          case Integer.parse(t) do
            {n, ""} ->
              n |> max(@min_int) |> min(@max_int)

            _ ->
              n = if t == "", do: :nan, else: Cronwatch.Evaluate.js_number(t)
              if JS.finite?(n), do: JS.to_int(n)
          end

        _ ->
          nil
      end
    end

    # A job's row. Its definition is as stored, or nil when its text does not
    # parse; the client reads the rest (Cronwatch.Serialize.read_stored_job).
    # A time that is not a finite number reads as 0.
    defp job_of(row) do
      %StoredJob{
        name: text(row, "name") || "",
        definition: json(row, "definition"),
        created_at: time(row, "created_at") || 0,
        updated_at: time(row, "updated_at") || 0
      }
    end

    # A run's row. A start that is not a finite number reads as 0, a finish
    # or duration as nil; an error or output that is not text as nil;
    # metrics that do not parse to an object as {} (and an object keeps the
    # values that are numbers); a trigger that is not text as "run".
    defp run_of(row) do
      metrics =
        case json(row, "metrics") do
          %Object{} = v ->
            case Metrics.from_value(v) do
              {:ok, m} -> m
              {:error, _} -> Metrics.lenient(v)
            end

          _ ->
            Object.new()
        end

      %Run{
        id: text(row, "id") || "",
        job: text(row, "job") || "",
        status: text(row, "status") || "",
        started_at: time(row, "started_at") || 0,
        finished_at: time(row, "finished_at"),
        duration_ms: time(row, "duration_ms"),
        error: string(row, "error"),
        output: string(row, "output"),
        metrics: metrics,
        trigger: string(row, "trigger") || "run"
      }
    end

    # A state's row, or nil (no state) when its text does not parse or is
    # not an object; each field is read leniently (JobState.from_value).
    defp state_of(row) do
      case JobState.from_value(json(row, "state")) do
        {:ok, s} -> s
        {:error, _} -> nil
      end
    end

    ## Parameters, in statement order, so every dialect binds the same values

    defp insert_params(%Run{} = r) do
      [
        r.id,
        r.job,
        r.status,
        r.started_at,
        r.finished_at,
        r.duration_ms,
        r.error,
        r.output,
        JS.stringify(r.metrics),
        r.trigger
      ]
    end

    defp update_params(%Run{} = r) do
      [r.status, r.finished_at, r.duration_ms, r.error, r.output, JS.stringify(r.metrics), r.id]
    end

    ## The store

    @doc """
    Makes the tables. On Postgres many processes starting at once would race
    `CREATE TABLE IF NOT EXISTS`, so they take turns under an advisory lock
    per prefix, in one transaction of the store's own.
    """
    @impl Cronwatch.Store
    def init(%__MODULE__{dialect: :postgres} = h) do
      transaction(h, SQL.schema(:postgres, h.prefix), [], "cronwatch:#{h.prefix}")
    end

    def init(%__MODULE__{} = h) do
      Enum.reduce_while(SQL.schema(h.dialect, h.prefix), :ok, fn sql, :ok ->
        case exec(h, sql, []) do
          :ok -> {:cont, :ok}
          e -> {:halt, e}
        end
      end)
    end

    @impl Cronwatch.Store
    def upsert_job(h, %Object{} = definition, now) do
      name = Object.get(definition, "name")
      exec(h, h.sql.upsert_job, [name, Text.json(definition), now, now])
    end

    @impl Cronwatch.Store
    def get_job(h, name), do: first(h, h.sql.get_job, [name], &job_of/1)

    @impl Cronwatch.Store
    def list_jobs(h), do: rows(h, h.sql.list_jobs, [], &job_of/1)

    @doc "Removes the job, its runs, and its state, in one transaction."
    @impl Cronwatch.Store
    def delete_job(h, name) do
      transaction(h, [h.sql.delete_runs, h.sql.delete_state, h.sql.delete_job], [name])
    end

    @impl Cronwatch.Store
    def insert_run(h, %Run{} = run) do
      run = Text.run(run)

      # MySQL's trigger column is VARCHAR(255), which refuses anything longer
      # (the others are TEXT): a long trigger is cut to fit rather than lose
      # the whole run.
      run =
        with :mysql <- h.dialect,
             points when length(points) > 255 <- String.codepoints(run.trigger) do
          %{run | trigger: points |> Enum.take(255) |> Enum.join()}
        else
          _ -> run
        end

      exec(h, h.sql.insert_run, insert_params(run))
    end

    @impl Cronwatch.Store
    def update_run(h, %Run{} = run), do: exec(h, h.sql.update_run, update_params(Text.run(run)))

    @impl Cronwatch.Store
    def update_run_if(_h, _run, []), do: {:ok, false}

    def update_run_if(h, %Run{} = run, from) do
      run = Text.run(run)
      sql = SQL.update_run_if(h.dialect, h.prefix, length(from))

      with {:ok, n} <- changed(h, sql, update_params(run) ++ from) do
        if n > 0 or h.dialect != :mysql, do: {:ok, n > 0}, else: landed_run(h, run, from)
      end
    end

    # A MySQL connection that counts only the rows an UPDATE changed answers
    # 0 for a row that already held these values (and matched): it was
    # written all the same. MyXQL asks for found rows, so this is for a
    # server or proxy that does not honour it.
    defp landed_run(h, run, from) do
      case get_run(h, run.id) do
        {:ok, %Run{} = stored} -> {:ok, stored.status in from and written(stored) == written(run)}
        {:ok, nil} -> {:ok, false}
        {:error, _} = e -> e
      end
    end

    # What an update of a run writes, compared whatever order a JSON column
    # gave an object's keys back in.
    defp written(%Run{} = r) do
      {r.status, r.finished_at, r.duration_ms, r.error, r.output, canonical(r.metrics), r.id}
    end

    defp canonical(%Object{} = o),
      do: o |> Object.to_list() |> Enum.map(fn {k, v} -> {k, canonical(v)} end) |> Enum.sort()

    defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
    defp canonical(n) when is_number(n), do: JS.stringify(n)
    defp canonical(other), do: other

    @doc "Deletes a run only while it is of `job` and in `status`, in one statement."
    @impl Cronwatch.Store
    def delete_run_if(h, id, job, status) do
      with {:ok, n} <- changed(h, h.sql.delete_run_if, [id, job, status]), do: {:ok, n > 0}
    end

    @impl Cronwatch.Store
    def get_run(h, id), do: first(h, h.sql.get_run, [id], &run_of/1)

    @impl Cronwatch.Store
    def list_runs(h, job, limit), do: rows(h, h.sql.list_runs, [job, min(limit, @max_int)], &run_of/1)

    @impl Cronwatch.Store
    def last_run(h, job), do: first(h, h.sql.list_runs, [job, 1], &run_of/1)

    @impl Cronwatch.Store
    def running_runs(h), do: rows(h, h.sql.running_runs, [], &run_of/1)

    @impl Cronwatch.Store
    def get_state(h, job), do: first(h, h.sql.get_state, [job], &state_of/1)

    @impl Cronwatch.Store
    def set_state(h, %JobState{} = state) do
      exec(h, h.sql.set_state, [state.job, Text.state_json(state)])
    end

    @impl Cronwatch.Store
    def compare_and_set_state(%__MODULE__{dialect: :mysql} = h, %JobState{} = state, 0) do
      body = Text.state_json(state)

      # Version 0 on MySQL is a row at version 0 (or with none), or no row at
      # all.
      case changed(h, h.sql.cas_from_zero, [body, state.job]) do
        {:ok, n} when n > 0 ->
          {:ok, true}

        {:ok, 0} ->
          case changed(h, h.sql.cas_insert, [state.job, body]) do
            {:ok, _} ->
              {:ok, true}

            {:error, _} = e ->
              # A row is there: another process wrote first, unless it holds
              # exactly what this write sent, when the write landed and only
              # its answer was lost (a row at version 0 that already held
              # these values, which a connection counting changed rows
              # answers 0 for, or a connection dropped after the commit), as
              # the PHP port's stateLanded() reads it. Counting that as
              # refused would have the client work the change out again over
              # its own write, and the alert the first attempt opened would
              # never go out.
              case get_state(h, state.job) do
                {:ok, %JobState{} = stored} -> {:ok, JobState.to_json(stored) == body}
                _ -> e
              end
          end

        {:error, _} = e ->
          e
      end
    end

    def compare_and_set_state(h, %JobState{} = state, 0) do
      with {:ok, n} <- changed(h, h.sql.cas_insert, [state.job, Text.state_json(state)]), do: {:ok, n > 0}
    end

    def compare_and_set_state(h, %JobState{} = state, expected) do
      with {:ok, n} <- changed(h, h.sql.cas_update, [Text.state_json(state), state.job, expected]),
           do: {:ok, n > 0}
    end

    @impl Cronwatch.Store
    def prune(h, before), do: changed(h, h.sql.prune, [before])

    @doc "Nothing to let go of: the repo and its pool are the app's."
    @impl Cronwatch.Store
    def close(_h), do: :ok
  end
end
