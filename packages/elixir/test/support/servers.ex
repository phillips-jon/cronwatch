defmodule Cronwatch.Test.PgRepo do
  @moduledoc "The tests' Postgres repo, started unnamed per test by `Cronwatch.Test.Servers`."
  use Ecto.Repo, otp_app: :cronwatch, adapter: Ecto.Adapters.Postgres
end

defmodule Cronwatch.Test.MyRepo do
  @moduledoc "The tests' MySQL and MariaDB repo, started unnamed per test by `Cronwatch.Test.Servers`."
  use Ecto.Repo, otp_app: :cronwatch, adapter: Ecto.Adapters.MyXQL
end

defmodule Cronwatch.Test.Servers do
  @moduledoc """
  The database servers the tests run against when their variables are set:
  `CRONWATCH_TEST_PG` (Postgres), `CRONWATCH_TEST_MYSQL` (MySQL),
  `CRONWATCH_TEST_MARIADB` (MariaDB) and `CRONWATCH_TEST_PGCRON` (a Postgres
  with pg_cron), each a URL such as `postgres://postgres:pw@127.0.0.1:5432/cw`
  or `mysql://root:pw@127.0.0.1:3306/cw`, as the Go and Rust ports read them.

  Each test starts a repo of its own over the server, unnamed, and uses
  tables of its own prefix, dropped when the test ends, so tests on one
  server can run at once.
  """

  alias Cronwatch.Store.Ecto, as: EctoStore

  @vars %{
    pg: "CRONWATCH_TEST_PG",
    mysql: "CRONWATCH_TEST_MYSQL",
    mariadb: "CRONWATCH_TEST_MARIADB",
    pgcron: "CRONWATCH_TEST_PGCRON"
  }

  @doc "The variable naming a server."
  def var(kind), do: Map.fetch!(@vars, kind)

  @doc "The server's URL, or nil when its variable is unset or empty."
  def url(kind) do
    case System.get_env(var(kind)) do
      nil -> nil
      "" -> nil
      url -> url
    end
  end

  @doc "The repo module for a server."
  def repo(kind) when kind in [:pg, :pgcron], do: Cronwatch.Test.PgRepo
  def repo(kind) when kind in [:mysql, :mariadb], do: Cronwatch.Test.MyRepo

  @doc """
  The `@moduletag` a test module puts on itself to skip, saying why, when
  the server's variable is unset: `@moduletag Servers.skip_unless(:pg)`.
  """
  def skip_unless(kind) do
    if url(kind), do: [], else: [skip: "#{var(kind)} is not set"]
  end

  @doc "A table prefix no other test uses."
  def prefix, do: "cwt#{System.unique_integer([:positive])}_"

  @doc "Starts a repo over the server, under the running test, and answers its pid."
  def start(kind, opts \\ []) do
    repo = repo(kind)

    config =
      Keyword.merge([name: nil, url: url(kind) || raise("#{var(kind)} is not set"), pool_size: 4, log: false], opts)

    spec = %{id: {repo, System.unique_integer()}, start: {repo, :start_link, [config]}}
    ExUnit.Callbacks.start_supervised!(spec)
  end

  @doc """
  A `Cronwatch.Store.Ecto` store over a repo started on the server, on
  tables of a prefix of its own (or `prefix`), dropped when the test ends.
  """
  def store(kind, prefix \\ prefix()) do
    pid = start(kind)
    {:ok, handle} = EctoStore.new(repo: repo(kind), prefix: prefix, dynamic_repo: pid)
    drop_at_exit(kind, prefix)
    {EctoStore, handle}
  end

  @doc "Drops the tables of `prefix` when the test ends, over a connection of its own."
  def drop_at_exit(kind, prefix) do
    ExUnit.Callbacks.on_exit(fn -> drop(kind, prefix) end)
  end

  @doc "Drops the store's three tables of `prefix`."
  def drop(kind, prefix) do
    repo = repo(kind)
    {:ok, pid} = repo.start_link(name: nil, url: url(kind), pool_size: 1, log: false)

    try do
      for table <- ~w(runs state jobs), do: sql(repo, pid, "DROP TABLE IF EXISTS #{prefix}#{table}")
    after
      Supervisor.stop(pid)
    end
  end

  @doc "Runs raw SQL on the repo `pid` of `kind` (or of the repo module given)."
  def sql(kind_or_repo, pid, text, params \\ [])

  def sql(kind, pid, text, params) when kind in [:pg, :pgcron, :mysql, :mariadb],
    do: sql(repo(kind), pid, text, params)

  def sql(repo, pid, text, params) do
    previous = repo.put_dynamic_repo(pid)

    try do
      repo.query!(text, params, log: false)
    after
      repo.put_dynamic_repo(previous)
    end
  end
end
