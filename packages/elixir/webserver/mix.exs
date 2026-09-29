defmodule CronwatchWebserver.MixProject do
  use Mix.Project

  # Not published: the seeded dashboard packages/mcp/test/elixir-web.test.ts
  # drives, served by Bandit with Cronwatch.Web forwarded under /cronwatch.
  def project do
    [
      app: :cronwatch_webserver,
      version: "0.0.0",
      elixir: "~> 1.18",
      start_permanent: true,
      deps: [
        {:cronwatch, path: ".."},
        {:plug, "~> 1.16"},
        {:bandit, "~> 1.5"}
      ]
    ]
  end

  def application do
    [mod: {CronwatchWebserver, []}, extra_applications: [:logger]]
  end
end
