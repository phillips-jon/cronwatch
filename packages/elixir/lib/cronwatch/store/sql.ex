defmodule Cronwatch.Store.SQL do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # The SQL store's schema and statements, by dialect. SQLite's and Postgres's
  # are `stores/sql.ts`'s text for text, so a Node, Ruby, Python, PHP, Go, Rust,
  # and Elixir process can share one database and `sqlite_master` reads the same
  # whoever made the tables.
  #
  # Postgres differs from `sql.ts` in one place, its JSON: Postgrex would encode
  # a JSON parameter through the repo's JSON library and decode a `jsonb` column
  # into a map, losing the SDK's key order and numbers, so a JSON parameter is
  # written `$n::text::jsonb` and a JSON column is read `col::text`. The schema
  # does not differ.
  #
  # MySQL (and MariaDB) has a dialect of its own, the PHP, Go, and Rust ports'
  # (`packages/go/sqlstore/sql.go`), since it has no `ON CONFLICT`, no partial
  # index, and no `TEXT` primary key: the same tables, columns, and values, with
  # the JSON columns as `LONGTEXT` holding the SDK's JSON byte for byte, never
  # MySQL's `JSON` type, which would rewrite it. It needs MySQL 8.0.13 or
  # MariaDB 10.6 or newer.

  @typedoc "The database's SQL."
  @type dialect :: :sqlite | :postgres | :mysql

  @default_prefix "cronwatch_"
  # Postgres truncates identifiers past 63 bytes; the longest name built is
  # the prefix plus "runs_job_started". The SDK holds every dialect to it.
  @max_prefix 63 - byte_size("runs_job_started")

  @doc "The prefix every table name starts with unless one is given: `cronwatch_`."
  @spec default_prefix() :: String.t()
  def default_prefix, do: @default_prefix

  @doc """
  Checks a table prefix: lowercase letters, digits, and underscores, not
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
    "cronwatch: invalid table prefix #{quoted}. Use lowercase letters, digits, and underscores, " <>
      "not starting with a digit, at most #{@max_prefix} characters."
  end

  @doc """
  The tables and indexes, one statement each, run in turn: `sql.ts`'s
  template, whitespace and all, cut into its statements.
  """
  @spec schema(dialect(), String.t()) :: [String.t()]
  def schema(:mysql, p), do: mysql_schema(p)

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

  # MySQL's tables (the PHP, Go, and Rust ports'): VARCHAR(255) keys, BIGINT
  # times, LONGTEXT JSON, utf8mb4_bin so names compare and sort by byte, seq
  # for insertion order, and a plain index where the others have a partial
  # one.
  defp mysql_schema(p) do
    table = "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"

    [
      """
      CREATE TABLE IF NOT EXISTS #{p}jobs (
            name VARCHAR(255) NOT NULL,
            definition LONGTEXT NOT NULL,
            created_at BIGINT NOT NULL,
            updated_at BIGINT NOT NULL,
            PRIMARY KEY (name)
          ) #{table}\
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}runs (
            seq BIGINT NOT NULL AUTO_INCREMENT,
            id VARCHAR(255) NOT NULL,
            job VARCHAR(255) NOT NULL,
            status VARCHAR(255) NOT NULL,
            started_at BIGINT NOT NULL,
            finished_at BIGINT,
            duration_ms BIGINT,
            error MEDIUMTEXT,
            output MEDIUMTEXT,
            metrics LONGTEXT NOT NULL DEFAULT ('{}'),
            `trigger` VARCHAR(255) NOT NULL DEFAULT 'run',
            PRIMARY KEY (id),
            UNIQUE KEY #{p}runs_seq (seq),
            KEY #{p}runs_job_started (job, started_at DESC),
            KEY #{p}runs_running (status)
          ) #{table}\
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}state (
            job VARCHAR(255) NOT NULL,
            state LONGTEXT NOT NULL,
            PRIMARY KEY (job)
          ) #{table}\
      """
    ]
  end

  @doc """
  The statements by name, with `?` placeholders on SQLite and MySQL and `$1`,
  `$2`, ... on Postgres, as `sql.ts` numbers them.
  """
  @spec statements(dialect(), String.t()) :: %{atom() => String.t()}
  def statements(:mysql, p), do: mysql_statements(p)

  def statements(dialect, p) do
    pg = dialect == :postgres
    # Insertion order, to break ties between runs that started in the same
    # millisecond, and byte order for names whatever the collation.
    {seq, by_name} = if pg, do: {"seq", ~s(name COLLATE "C")}, else: {"rowid", "name"}
    # The version inside a state's JSON, as JobState.counted_version/1 reads
    # it: a whole number from 0 to 2^53 - 1, else 0 (none, or a foreign row's
    # 1.5 or "x", which must neither fail the statement nor refuse every
    # write for good). Each CASE tests the JSON type before any cast.
    version = fn column ->
      if pg do
        v = "(#{column}->>'version')::numeric"

        "CASE WHEN jsonb_typeof(#{column}->'version') <> 'number' THEN 0 " <>
          "WHEN #{v} % 1 = 0 AND #{v} BETWEEN 0 AND 9007199254740991 THEN #{v}::bigint ELSE 0 END"
      else
        v = "json_extract(#{column}, '$.version')"

        "CASE WHEN NOT json_valid(#{column}) THEN 0 " <>
          "WHEN json_type(#{column}, '$.version') NOT IN ('integer', 'real') THEN 0 " <>
          "WHEN #{v} = CAST(#{v} AS INTEGER) AND #{v} BETWEEN 0 AND 9007199254740991 THEN CAST(#{v} AS INTEGER) ELSE 0 END"
      end
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
        # A time SQLite holds as an infinite REAL (text such as "1e400" in
        # an INTEGER column becomes one) reads as NULL, since the driver
        # cannot hand it over; it is not a finite number either way.
        finite = fn c ->
          "CASE WHEN typeof(#{c}) <> 'real' THEN #{c} WHEN abs(#{c}) > 1.7976931348623157e308 THEN NULL ELSE #{c} END AS #{c}"
        end

        {"name, definition, #{finite.("created_at")}, #{finite.("updated_at")}",
         "id, job, status, #{finite.("started_at")}, #{finite.("finished_at")}, #{finite.("duration_ms")}, " <>
           "error, output, metrics, trigger", "state"}
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
      # PHP, Go, and Rust ports' deleteRunIf).
      delete_run_if: "DELETE FROM #{p}runs WHERE id = ? AND job = ? AND status = ?"
    }
    |> Map.new(fn {k, v} -> {k, if(pg, do: number(v), else: v)} end)
  end

  # MySQL's statements, the PHP, Go, and Rust ports' text.
  defp mysql_statements(p) do
    # The version inside a state's JSON text, read as on SQLite and Postgres:
    # a whole number from 0 to 2^53 - 1, else 0. MySQL's JSON_EXTRACT answers
    # JSON and MariaDB's text; plus 0, both are a number, and the JSON type
    # is tested first, so a string is never converted. The column is text,
    # which may hold text that is not JSON at all (a damaged row's): that
    # counts as 0, tested before JSON_EXTRACT, which fails on it.
    version = fn column ->
      v = "JSON_EXTRACT(#{column}, '$.version') + 0"

      "CASE WHEN NOT JSON_VALID(#{column}) THEN 0 WHEN JSON_TYPE(JSON_EXTRACT(#{column}, '$.version')) NOT IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 " <>
        "WHEN #{v} = FLOOR(#{v}) AND #{v} BETWEEN 0 AND 9007199254740991 THEN CAST(#{v} AS SIGNED) ELSE 0 END"
    end

    %{
      upsert_job: """
      INSERT INTO #{p}jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE definition = VALUES(definition), updated_at = VALUES(updated_at)\
      """,
      get_job: "SELECT * FROM #{p}jobs WHERE name = ?",
      list_jobs: "SELECT * FROM #{p}jobs ORDER BY name",
      delete_runs: "DELETE FROM #{p}runs WHERE job = ?",
      delete_state: "DELETE FROM #{p}state WHERE job = ?",
      delete_job: "DELETE FROM #{p}jobs WHERE name = ?",
      insert_run: """
      INSERT INTO #{p}runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, `trigger`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)\
      """,
      update_run:
        "UPDATE #{p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?",
      get_run: "SELECT * FROM #{p}runs WHERE id = ?",
      list_runs: "SELECT * FROM #{p}runs WHERE job = ? ORDER BY started_at DESC, seq DESC LIMIT ?",
      running_runs: "SELECT * FROM #{p}runs WHERE status = 'running' ORDER BY started_at, seq",
      get_state: "SELECT state FROM #{p}state WHERE job = ?",
      set_state: "INSERT INTO #{p}state (job, state) VALUES (?, ?) ON DUPLICATE KEY UPDATE state = VALUES(state)",
      # compareAndSetState from version 0, in two steps that each decide
      # alone: a row at version 0 (or without one) is updated, and failing
      # that the row is inserted, which a row already there refuses. Neither
      # leans on how the connection counts affected rows.
      cas_from_zero: "UPDATE #{p}state SET state = ? WHERE job = ? AND #{version.("state")} = 0",
      cas_insert: "INSERT INTO #{p}state (job, state) VALUES (?, ?)",
      cas_update: "UPDATE #{p}state SET state = ? WHERE job = ? AND #{version.("state")} = ?",
      # MySQL refuses a subquery on the table a DELETE deletes from, so the
      # newest start per job is a derived table joined in (grouped, so it is
      # materialized rather than merged).
      prune: """
      DELETE r FROM #{p}runs r
            JOIN (SELECT job, MAX(started_at) AS newest FROM #{p}runs GROUP BY job) n ON n.job = r.job
            WHERE r.status <> 'running' AND r.started_at < ? AND r.started_at < n.newest\
      """,
      delete_run_if: "DELETE FROM #{p}runs WHERE id = ? AND job = ? AND status = ?"
    }
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
