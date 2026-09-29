defmodule Cronwatch.MixProject do
  use Mix.Project

  # The release's version, the one place it lives; scripts/release.mjs bumps it.
  @version "0.7.0"
  @source_url "https://github.com/phillips-jon/cronwatch"

  def project do
    [
      app: :cronwatch,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description:
        "Know when your cron jobs fail, run late or never run. " <>
          "The library behind cronwatch.dev, for Elixir and Erlang services.",
      package: package(),
      source_url: @source_url,
      homepage_url: "https://cronwatch.dev",
      docs: [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"],
      dialyzer: [
        plt_local_path: "_build/plts",
        plt_core_path: "_build/plts",
        plt_add_apps: [:ex_unit, :ecto, :ecto_sql, :db_connection, :inets, :ssl, :public_key]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :public_key]
    ]
  end

  def cli do
    [preferred_envs: [dialyzer: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:tz, "~> 0.28"},
      {:telemetry, "~> 1.0"},
      {:ecto_sql, "~> 3.12", optional: true},
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:postgrex, "~> 0.19", only: :test},
      {:myxql, "~> 0.7", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # The fixtures are made with TZ=UTC, and a schedule without a zone is read
  # in the process's own, so the tests always run in UTC (test_helper.exs
  # refuses to start otherwise).
  defp aliases do
    [test: [fn _ -> System.put_env("TZ", "UTC") end, "test"]]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Website" => "https://cronwatch.dev", "Source" => @source_url},
      files: ~w(lib mix.exs .formatter.exs README.md LICENSE)
    ]
  end
end
