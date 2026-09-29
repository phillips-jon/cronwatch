defmodule Cronwatch.Store.SQL do
  @moduledoc """
  The SQL store's schema and statements, by dialect. SQLite's and Postgres's
  are `stores/sql.ts`'s text for text, so a Node, Ruby, Python, PHP, Go, Rust
  and Elixir process can share one database and `sqlite_master` reads the same
  whoever made the tables.

  Postgres differs from `sql.ts` in one place, its JSON: Postgrex would encode
  a JSON parameter through the repo's JSON library and decode a `jsonb` column
  into a map, losing the SDK's key order and numbers, so a JSON parameter is
  written `$n::text::jsonb` and a JSON column is read `col::text`. The schema
  does not differ. The Postgres dialect is here for phase 2 and not yet run
  against a server; MySQL (the PHP, Go and Rust ports' dialect) comes then too.
  """

  @typedoc "The database's SQL."
  @type dialect :: :sqlite | :postgres

  @default_prefix "cronwatch_"
  # Postgres truncates identifiers past 63 bytes; the longest name built is
  # the prefix plus "runs_job_started". The SDK holds every dialect to it.
  @max_prefix 63 - byte_size("runs_job_started")

  @doc "The prefix every table name starts with unless one is given: `cronwatch_`."
  @spec default_prefix() :: String.t()
  def default_prefix, do: @default_prefix

  @doc """
  Checks a table prefix: lowercase letters, digits and underscores, not
  starting with a digit, at most 47 characters. Uppercase is refused rather
  than folded, since Postgres lowercases unquoted names. The message is the
  SDK's, word for word.
  """
  @spec table_prefix(term()) :: {:ok, String.t()} | {:error, String.t()}
  def table_prefix(prefix) when is_binary(prefix) do
    if byte_size(prefix) <= @max_prefix and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, prefix) do
      {:ok, prefix}
    else
      {:error, prefix_error(Cronwatch.JS.quote(prefix))}
    end
  end

  def table_prefix(prefix), do: {:error, prefix_error(inspect(prefix))}

  defp prefix_error(quoted) do
    "cronwatch: invalid table prefix #{quoted}. Use lowercase letters, digits and underscores, " <>
      "not starting with a digit, at most #{@max_prefix} characters."
  end

  @doc """
  The tables and indexes, one statement each, run in turn: `sql.ts`'s
  template, whitespace and all, cut into its statements.
  """
  @spec schema(dialect(), String.t()) :: [String.t()]
  def schema(dialect, p) do
    {int, json, seq} =
      case dialect do
        :sqlite -> {"INTEGER", "TEXT", ""}
        :postgres -> {"BIGINT", "JSONB", "\n      seq BIGSERIAL,"}
      end

    """

        CREATE TABLE IF NOT EXISTS #{p}jobs (
          name TEXT PRIMARY KEY,
          definition #{json} NOT NULL,
          created_at #{int} NOT NULL,
          updated_at #{int} NOT NULL
        );
        CREATE TABLE IF NOT EXISTS #{p}runs (#{seq}
          id TEXT PRIMARY KEY,
          job TEXT NOT NULL,
          status TEXT NOT NULL,
          started_at #{int} NOT NULL,
          finished_at #{int},
          duration_ms #{int},
          error TEXT,
          output TEXT,
          metrics #{json} NOT NULL DEFAULT '{}',
          trigger TEXT NOT NULL DEFAULT 'run'
        );
        CREATE INDEX IF NOT EXISTS #{p}runs_job_started ON #{p}runs (job, started_at DESC);
        CREATE INDEX IF NOT EXISTS #{p}runs_running ON #{p}runs (status) WHERE status = 'running';
        CREATE TABLE IF NOT EXISTS #{p}state (
          job TEXT PRIMARY KEY,
          state #{json} NOT NULL
        );
    """
    |> String.split(";")
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  @doc """
  The statements by name, with `?` placeholders on SQLite and `$1`, `$2`, ...
  on Postgres, as `sql.ts` numbers them.
  """
  @spec statements(dialect(), String.t()) :: %{atom() => String.t()}
  def statements(dialect, p) do
    pg = dialect == :postgres
    # Insertion order, to break ties between runs that started in the same
    # millisecond, and byte order for names whatever the collation.
    {seq, by_name} = if pg, do: {"seq", ~s(name COLLATE "C")}, else: {"rowid", "name"}
    # The version inside a state's JSON, 0 when it has none.
    version = fn column ->
      if pg,
        do: "COALESCE((#{column}->>'version')::bigint, 0)",
        else: "COALESCE(json_extract(#{column}, '$.version'), 0)"
    end

    # A JSON parameter, and the columns a row is read as: Postgres casts
    # (see the moduledoc), SQLite takes the text as it is.
    j = if pg, do: "?::text::jsonb", else: "?"

    {jobs_cols, runs_cols, state_col} =
      if pg do
        {"name, definition::text AS definition, created_at, updated_at",
         "id, job, status, started_at, finished_at, duration_ms, error, output, metrics::text AS metrics, trigger",
         "state::text AS state"}
      else
        {"*", "*", "state"}
      end

    %{
      upsert_job: """
      INSERT INTO #{p}jobs (name, definition, created_at, updated_at) VALUES (?, #{j}, ?, ?)
            ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at\
      """,
      get_job: "SELECT #{jobs_cols} FROM #{p}jobs WHERE name = ?",
      list_jobs: "SELECT #{jobs_cols} FROM #{p}jobs ORDER BY #{by_name}",
      delete_runs: "DELETE FROM #{p}runs WHERE job = ?",
      delete_state: "DELETE FROM #{p}state WHERE job = ?",
      delete_job: "DELETE FROM #{p}jobs WHERE name = ?",
      insert_run: """
      INSERT INTO #{p}runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, #{j}, ?)\
      """,
      update_run:
        "UPDATE #{p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = #{j} WHERE id = ?",
      get_run: "SELECT #{runs_cols} FROM #{p}runs WHERE id = ?",
      list_runs: "SELECT #{runs_cols} FROM #{p}runs WHERE job = ? ORDER BY started_at DESC, #{seq} DESC LIMIT ?",
      running_runs: "SELECT #{runs_cols} FROM #{p}runs WHERE status = 'running' ORDER BY started_at, #{seq}",
      get_state: "SELECT #{state_col} FROM #{p}state WHERE job = ?",
      set_state:
        "INSERT INTO #{p}state (job, state) VALUES (?, #{j}) ON CONFLICT (job) DO UPDATE SET state = excluded.state",
      # compareAndSetState. Expecting version 0 also matches a missing row, so
      # that case inserts; any other version must find its row.
      cas_insert: """
      INSERT INTO #{p}state (job, state) VALUES (?, #{j})
            ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE #{version.("#{p}state.state")} = 0\
      """,
      cas_update: "UPDATE #{p}state SET state = #{j} WHERE job = ? AND #{version.("state")} = ?",
      # Each job's newest run is kept whatever its age: without it, a job that
      # runs less often than the retention looks like it never ran.
      prune: """
      DELETE FROM #{p}runs WHERE status <> 'running' AND started_at < ?
            AND started_at < (SELECT MAX(r.started_at) FROM #{p}runs r WHERE r.job = #{p}runs.job)\
      """,
      # Takes back a run only while it is of one job and in one status (the
      # PHP, Go and Rust ports' deleteRunIf).
      delete_run_if: "DELETE FROM #{p}runs WHERE id = ? AND job = ? AND status = ?"
    }
    |> Map.new(fn {k, v} -> {k, if(pg, do: number(v), else: v)} end)
  end

  @doc """
  The run update, only while the stored status is one of `count` statuses.
  Built per count, since the list is bound value by value.
  """
  @spec update_run_if(dialect(), String.t(), pos_integer()) :: String.t()
  def update_run_if(dialect, p, count) do
    j = if dialect == :postgres, do: "?::text::jsonb", else: "?"
    marks = Enum.map_join(1..count, ", ", fn _ -> "?" end)

    text =
      "UPDATE #{p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = #{j} " <>
        "WHERE id = ? AND status IN (#{marks})"

    if dialect == :postgres, do: number(text), else: text
  end

  # `?` placeholders as `$1`, `$2`, ..., as sql.ts writes them for Postgres.
  defp number(text) do
    {parts, _} =
      text
      |> String.split("?")
      |> Enum.map_reduce(0, fn part, n -> {{part, n}, n + 1} end)

    [{first, _} | rest] = parts
    Enum.reduce(rest, first, fn {part, n}, acc -> acc <> "$#{n}" <> part end)
  end
end
