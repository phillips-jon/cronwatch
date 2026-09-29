defmodule CronwatchWebserver do
  @moduledoc """
  Serves the dashboard over HTTP for packages/mcp/test/elixir-web.test.ts,
  which drives `@cronwatch/mcp` against it. Seeded like the MCP tests' own
  end to end case: a `nightly` job with one good run and one failed one, and
  a fixed clock. Forwarded from a `Plug.Router` at `/cronwatch`, so the
  dashboard finds its base path from the mount.

      CRONWATCH_PORT=4000 mix run --no-halt    (in packages/elixir/webserver)

  Alerts are printed as `alert <job> <type>` lines.
  """
  use Application

  # 2026-01-05 02:00:00 UTC.
  @start 1_767_578_400_000

  @impl true
  def start(_type, _args) do
    port =
      case Integer.parse(System.get_env("CRONWATCH_PORT", "")) do
        {port, ""} -> port
        _ -> fail("usage: CRONWATCH_PORT=PORT mix run --no-halt")
      end

    now = :atomics.new(1, signed: true)
    :atomics.put(now, 1, @start)

    alert = fn alert ->
      IO.puts("alert #{alert.job} #{alert.type}")
      :ok
    end

    children = [
      {Cronwatch,
       clock: fn -> :atomics.get(now, 1) end,
       cron_secret: false,
       alerts: [Cronwatch.Alerts.fun("test", alert)],
       jobs: [{"nightly", schedule: "0 2 * * *", timezone: "UTC", grace: "15m"}]}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: CronwatchWebserver.Supervisor)

    Cronwatch.run("nightly", fn job -> Cronwatch.log(job, "step 1") end)
    :atomics.add(now, 1, 60_000)

    try do
      Cronwatch.run("nightly", fn job ->
        Cronwatch.log(job, "step 2")
        raise "db down"
      end)
    rescue
      RuntimeError -> :ok
    end

    {:ok, _} = Supervisor.start_child(sup, {Bandit, plug: CronwatchWebserver.Router, ip: :loopback, port: port})
    IO.puts("serving on #{port}")
    {:ok, sup}
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(2)
  end
end

defmodule CronwatchWebserver.Router do
  @moduledoc false
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/cronwatch", to: Cronwatch.Web, init_opts: [token: "tok"]

  match _ do
    send_resp(conn, 404, "not found")
  end
end
