defmodule Cronwatch.Test.HTTP do
  @moduledoc """
  A small HTTP/1.1 client over `:gen_tcp` for the tests that go through a
  real server: it sends the request target exactly as given (`%zz` and all),
  the headers in order, and reads the answer to the connection's close.
  """

  @doc "Sends one request and answers `{status, headers, body}`, header names lowercase."
  def request(port, method, target, headers, body \\ nil) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)
    body = body || ""

    length =
      if body != "" or method in ["POST", "PUT", "DELETE"], do: [{"content-length", "#{byte_size(body)}"}], else: []

    head =
      Enum.map([{"connection", "close"} | headers] ++ length, fn {k, v} -> [k, ": ", v, "\r\n"] end)

    :ok = :gen_tcp.send(socket, [method, " ", target, " HTTP/1.1\r\n", head, "\r\n", body])
    data = read_all(socket, [])
    :gen_tcp.close(socket)
    parse(data)
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} -> read_all(socket, [acc, data])
      {:error, :closed} -> IO.iodata_to_binary(acc)
    end
  end

  defp parse(data) do
    [head, body] = :binary.split(data, "\r\n\r\n")
    [status_line | lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.map(lines, fn line ->
        [k, v] = :binary.split(line, ":")
        {String.downcase(k), String.trim(v)}
      end)

    body = if {"transfer-encoding", "chunked"} in headers, do: dechunk(body, []), else: body
    {String.to_integer(status), headers, body}
  end

  defp dechunk(data, acc) do
    [size, rest] = :binary.split(data, "\r\n")

    case String.to_integer(size, 16) do
      0 ->
        IO.iodata_to_binary(acc)

      n ->
        <<chunk::binary-size(^n), "\r\n", rest::binary>> = rest
        dechunk(rest, [acc, chunk])
    end
  end

  @doc "Starts `plug` under Bandit on a free loopback port, as a test's child, and answers the port."
  def serve(plug) do
    pid = ExUnit.Callbacks.start_supervised!({Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end
end

defmodule Cronwatch.Test.WebRouter do
  @moduledoc """
  A `Plug.Router` with the dashboard forwarded under `/cronwatch` (its base
  path found from the mount) and a job's handler under `/cron/served`, for
  the golden replay's instance, `Cronwatch.Test.GoldenWeb`. Its options are
  read when this module compiles, as a router's are.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/cronwatch", to: Cronwatch.Web, init_opts: [instance: Cronwatch.Test.GoldenWeb, token: "tok"])
  forward("/ops/cron", to: Cronwatch.Web, init_opts: [instance: Cronwatch.Test.GoldenWeb, token: false])

  forward("/t/:tenant/cw", to: Cronwatch.Web, init_opts: [instance: Cronwatch.Test.GoldenWeb, token: false])

  forward("/cron/served",
    to: Cronwatch.Handler,
    init_opts: [
      instance: Cronwatch.Test.GoldenWeb,
      job: "served",
      run: {Cronwatch.Test.Jobs, :served, []},
      secret: "s3cret"
    ]
  )

  match _ do
    send_resp(conn, 404, "not the dashboard")
  end
end

defmodule Cronwatch.Test.Jobs do
  @moduledoc "Functions the handler tests run, given the run's context and the conn."

  def served(job, conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Cronwatch.log(job, "#{conn.method} #{conn.request_path} #{body}")
    :ok
  end
end

defmodule Cronwatch.Test.PhoenixRouter do
  @moduledoc "A Phoenix router with the dashboard forwarded outside any pipeline."
  use Phoenix.Router

  scope "/" do
    forward("/cronwatch", Cronwatch.Web, instance: Cronwatch.Test.GoldenWeb, token: "tok")
  end

  scope "/admin" do
    forward("/cw", Cronwatch.Web, instance: Cronwatch.Test.GoldenWeb, token: false)
  end
end

defmodule Cronwatch.Test.Endpoint do
  @moduledoc """
  A minimal Phoenix endpoint: `Plug.Parsers` reads a form or JSON body before
  the router, as every Phoenix app's endpoint does, so the dashboard is
  handed a body already read.
  """
  use Phoenix.Endpoint, otp_app: :cronwatch

  plug(Plug.Parsers, parsers: [:urlencoded, :multipart, :json], pass: ["*/*"], json_decoder: JSON)
  plug(Cronwatch.Test.PhoenixRouter)

  @doc "Starts the endpoint on a free loopback port, as a test's child, and answers the port."
  def serve do
    Application.put_env(:cronwatch, __MODULE__,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: 0],
      server: true,
      secret_key_base: String.duplicate("k", 64),
      render_errors: [formats: [json: Cronwatch.Test.ErrorJSON]]
    )

    ExUnit.Callbacks.start_supervised!(__MODULE__)
    {:ok, {_ip, port}} = __MODULE__.server_info(:http)
    port
  end
end

defmodule Cronwatch.Test.ErrorJSON do
  @moduledoc "The endpoint's error page, for a body Plug.Parsers refuses."
  def render(template, _assigns), do: %{error: template}
end
