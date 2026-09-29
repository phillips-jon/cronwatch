defmodule CrontabExample.MixProject do
  use Mix.Project

  # Not published: a job a crontab runs, and the check a second line of the
  # same crontab runs, both on one SQLite file (see lib/crontab_example.ex).
  def project do
    [
      app: :crontab_example,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      releases: [crontab_example: [include_executables_for: [:unix]]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:cronwatch, path: "../.."},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"}
    ]
  end
end
