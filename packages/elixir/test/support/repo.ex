defmodule Cronwatch.Test.Repo do
  @moduledoc """
  The tests' Ecto repo on ecto_sqlite3. Each test starts one on a file of
  its own with `start/1`, unnamed, and hands its pid to the store as
  `dynamic_repo:`, so two stores on two files can be open at once.
  """
  use Ecto.Repo, otp_app: :cronwatch, adapter: Ecto.Adapters.SQLite3

  @doc "A directory of its own under the system's temporary directory, removed when the test ends."
  def tmp_dir do
    dir = Path.join(System.tmp_dir!(), "cronwatch-ex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc "Starts a repo over the SQLite file `path`, under the running test, and answers its pid."
  def start(path, opts \\ []) do
    spec = %{
      id: {__MODULE__, path, System.unique_integer()},
      start: {__MODULE__, :start_link, [Keyword.merge([name: nil, database: path, pool_size: 1, log: false], opts)]}
    }

    ExUnit.Callbacks.start_supervised!(spec)
  end

  @doc "A `Cronwatch.Store.Ecto` store over a repo started on `path`."
  def store(path, prefix \\ "cronwatch_") do
    pid = start(path)
    {:ok, handle} = Cronwatch.Store.Ecto.new(repo: __MODULE__, prefix: prefix, dynamic_repo: pid)
    {Cronwatch.Store.Ecto, handle}
  end

  @doc "Runs raw SQL on the repo `pid`."
  def sql(pid, text, params \\ []) do
    previous = put_dynamic_repo(pid)

    try do
      query!(text, params, log: false)
    after
      put_dynamic_repo(previous)
    end
  end
end
