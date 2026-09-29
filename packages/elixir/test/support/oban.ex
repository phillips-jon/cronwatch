defmodule Cronwatch.Test.ObanLite do
  @moduledoc "The Oban tests' repo on SQLite, for Oban's Lite engine: one file per test, named."
  use Ecto.Repo, otp_app: :cronwatch, adapter: Ecto.Adapters.SQLite3
end

defmodule Cronwatch.Test.ObanPg do
  @moduledoc "The Oban tests' repo on Postgres (`CRONWATCH_TEST_PG`), for Oban's Basic engine."
  use Ecto.Repo, otp_app: :cronwatch, adapter: Ecto.Adapters.Postgres
end

defmodule Cronwatch.Test.ObanMigration do
  @moduledoc "Oban's own tables, as an app's migration makes them."
  use Ecto.Migration

  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down()
end

defmodule Cronwatch.Test.Oban do
  @moduledoc "Starting Oban for the integration tests, on SQLite always and on Postgres when CRONWATCH_TEST_PG is set."

  import ExUnit.Callbacks

  alias Cronwatch.Test.ObanLite
  alias Cronwatch.Test.ObanPg
  alias Cronwatch.Test.Repo

  @doc "The engines the tests run on: `:lite` always, `:postgres` when CRONWATCH_TEST_PG names a server."
  def engines do
    case System.get_env("CRONWATCH_TEST_PG") do
      url when is_binary(url) and url != "" -> [:lite, :postgres]
      _ -> [:lite]
    end
  end

  @doc """
  Starts a repo and Oban on `engine` under the running test, Oban's tables
  made fresh, and answers Oban's name. `opts` are Oban's own (`crontab`,
  `queues`, `plugins`); the Cron plugin never inserts on its own (the node
  is not the leader), so the tests insert and drain.
  """
  def start(engine, opts \\ []) do
    repo = repo(engine)
    name = Module.concat(Cronwatch.Test.Oban, "O#{System.unique_integer([:positive])}")

    oban_opts =
      [name: name, repo: repo, queues: [], peer: {Oban.Peers.Isolated, [leader?: false]}] ++ engine_opts(engine)

    start_supervised!({Oban, Keyword.merge(oban_opts, opts)}, id: name)
    name
  end

  defp engine_opts(:lite), do: [engine: Oban.Engines.Lite]
  defp engine_opts(:postgres), do: [engine: Oban.Engines.Basic, notifier: Oban.Notifiers.PG]

  # A repo per test: a SQLite file of its own, or the Postgres database.
  defp repo(:lite) do
    path = Path.join(Repo.tmp_dir(), "oban.db")
    start_supervised!({ObanLite, database: path, pool_size: 1, log: false, journal_mode: :wal, busy_timeout: 5000})
    migrate(ObanLite)
    ObanLite
  end

  defp repo(:postgres) do
    start_supervised!({ObanPg, url: System.fetch_env!("CRONWATCH_TEST_PG"), pool_size: 5, log: false})
    # Oban's tables are made once (its migration brings them to the version
    # it needs), and emptied for each test.
    migrate(ObanPg)
    ObanPg.query!("TRUNCATE oban_jobs", [], log: false)
    ObanPg
  end

  defp migrate(repo) do
    # Numbered by the release of Oban, whose migration brings the tables to
    # the version it needs.
    [major, minor, patch] =
      :oban |> Application.spec(:vsn) |> to_string() |> String.split(".") |> Enum.map(&String.to_integer/1)

    Ecto.Migrator.up(repo, major * 10_000 + minor * 100 + patch, Cronwatch.Test.ObanMigration, log: false)
  end
end
