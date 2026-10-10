defmodule Cronwatch.MixProject do
  use Mix.Project

  # The release's version, the one place it lives; scripts/release.mjs bumps it.
  @version "0.12.3"
  @source_url "https://github.com/cronwatchdev/cronwatch"

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
      docs: [
        main: "readme",
        extras: ["README.md"],
        source_ref: "v#{@version}"
      ],
      dialyzer: [
        plt_local_path: "_build/plts",
        plt_core_path: "_build/plts",
        plt_add_apps: [:ex_unit, :mix, :ecto, :ecto_sql, :db_connection, :ssl, :public_key]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :public_key]
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
      {:ecto_sql, pinned(:ecto_sql, "~> 3.12"), optional: true},
      {:plug, pinned(:plug, "~> 1.16"), optional: true},
      {:oban, pinned(:oban, "~> 2.20"), optional: true},
      {:quantum, pinned(:quantum, "~> 3.5"), optional: true},
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:postgrex, "~> 0.19", only: :test},
      {:myxql, "~> 0.7", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:bandit, "~> 1.5", only: :test},
      {:phoenix, "~> 1.7", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  # An optional dependency at the release CRONWATCH_PIN_<NAME> names
  # (CRONWATCH_PIN_OBAN=2.20.0), for the CI entry that tests the oldest
  # release each requirement claims, since Mix has no minimal-versions
  # resolver; the requirement as written otherwise.
  defp pinned(dep, requirement) do
    case System.get_env("CRONWATCH_PIN_" <> String.upcase(to_string(dep))) do
      version when is_binary(version) and version != "" -> "== " <> version
      _ -> requirement
    end
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
