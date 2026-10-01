defmodule Cronwatch.Web.ServerTest do
  @moduledoc """
  The dashboard and a job's handler behind real servers: a `Plug.Router`
  under Bandit and a Phoenix endpoint, whose routers compile their options
  (`Cronwatch.Test.WebRouter` and `Cronwatch.Test.PhoenixRouter`, for the
  instance `Cronwatch.Test.GoldenWeb`). The base path is found from the
  mount, a body is read or refused as it comes over the wire, and a body a
  Phoenix endpoint cannot parse is its own to answer.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Test.Client
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Endpoint
  alias Cronwatch.Test.HTTP

  @inst Cronwatch.Test.GoldenWeb
  @t0 Clock.t0()
  @hour 3_600_000

  setup do
    start_supervised!({Cronwatch, name: @inst, clock: Clock.fun(Clock.new(@t0)), alerts: [], cron_secret: false})
    Cronwatch.run("x", fn _ -> :ok end, instance: @inst)
    %{plug: HTTP.serve(Cronwatch.Test.WebRouter), phoenix: Endpoint.serve()}
  end

  defp get(port, path, headers \\ []), do: HTTP.request(port, "GET", path, [{"host", "app.test"} | headers])

  defp manifest_id(port, path) do
    {200, _, body} = get(port, path)
    body |> JS.parse!() |> Object.get("id")
  end

  test "the base path is found from where a router mounted the dashboard", %{plug: plug, phoenix: phoenix} do
    assert manifest_id(plug, "/cronwatch/manifest.webmanifest") == "/cronwatch/", "a Plug.Router forward"
    assert manifest_id(plug, "/ops/cron/manifest.webmanifest") == "/ops/cron/", "a longer mount"
    assert manifest_id(plug, "/t/acme/cw/manifest.webmanifest") == "/t/acme/cw/", "under a path parameter"
    assert manifest_id(phoenix, "/cronwatch/manifest.webmanifest") == "/cronwatch/", "a Phoenix forward"
    assert manifest_id(phoenix, "/admin/cw/manifest.webmanifest") == "/admin/cw/", "in a Phoenix scope"

    # The pages link under the base found, and the job links resolve.
    for {port, base} <- [{plug, "/ops/cron"}, {phoenix, "/admin/cw"}] do
      {200, _, body} = get(port, base <> "/")
      assert body =~ ~s(href="#{base}/jobs/x"), base
      assert elem(get(port, base <> "/jobs/x"), 0) == 200, "the job page under #{base}"
      assert elem(get(port, base), 0) == 200, "the mount itself, #{base}"
    end
  end

  test "writes go through both servers, Phoenix's parsers or not", %{plug: plug, phoenix: phoenix} do
    for {port, label} <- [{plug, "plug"}, {phoenix, "phoenix"}] do
      headers = [
        {"host", "app.test"},
        {"authorization", "Bearer tok"},
        {"content-type", "application/x-www-form-urlencoded"},
        {"referer", "http://app.test/cronwatch/jobs/x"}
      ]

      {status, res, _} = HTTP.request(port, "POST", "/cronwatch/jobs/x/silence", headers, "for=4h")
      assert status == 303, label
      assert {"location", "http://app.test/cronwatch/jobs/x"} in res
      assert Cronwatch.job_summary!("x", instance: @inst).silenced_until == @t0 + 4 * @hour, label

      json = [{"host", "app.test"}, {"authorization", "Bearer tok"}, {"content-type", "application/json"}]
      {200, _, body} = HTTP.request(port, "POST", "/cronwatch/api/jobs/x/silence", json, ~s({"for":"2h"}))
      assert body |> JS.parse!() |> Object.get("job") |> Object.get("silencedUntil") == @t0 + 2 * @hour, label

      if label == "phoenix" do
        # Phoenix's parsers read the body first, under the endpoint's own
        # limit. (The plug's own cap, over the wire, is the next test's.)
        pad = String.duplicate("x", 1_048_576)
        {200, _, _} = HTTP.request(port, "POST", "/cronwatch/api/jobs/x/silence", json, ~s({"for":"2h","pad":"#{pad}"}))
      end
    end
  end

  test "a body past the cap is refused by its length", %{plug: plug} do
    headers = [
      {"host", "app.test"},
      {"authorization", "Bearer tok"},
      {"content-type", "application/json"},
      {"content-length", "2000000"}
    ]

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", plug, [:binary, active: false], 5_000)
    head = Enum.map([{"connection", "close"} | headers], fn {k, v} -> [k, ": ", v, "\r\n"] end)
    # Only the head is sent: the answer comes before the body is read, and
    # a body left unread when the server closes would reset the connection.
    :ok = :gen_tcp.send(socket, ["POST /cronwatch/api/jobs/x/silence HTTP/1.1\r\n", head, "\r\n"])
    {:ok, answer} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    assert answer =~ "HTTP/1.1 413"
    assert Cronwatch.job_summary!("x", instance: @inst).silenced_until == nil
  end

  # The Go port's audit: a body cut short was read as far as it came, so
  # for=7d silenced the job for 7 ms. The SDK reads a body it cannot read as
  # none.
  test "a body cut short over the wire is read as none", %{plug: plug} do
    headers = [
      {"host", "app.test"},
      {"authorization", "Bearer tok"},
      {"content-type", "application/x-www-form-urlencoded"},
      {"content-length", "6"}
    ]

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", plug, [:binary, active: false], 5_000)
    head = Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end)
    :ok = :gen_tcp.send(socket, ["POST /cronwatch/api/jobs/x/silence HTTP/1.1\r\n", head, "\r\n", "for=7"])
    :ok = :gen_tcp.shutdown(socket, :write)
    # Bandit closes the connection without an answer, having nothing to
    # write to; the plug has run by then or runs soon after.
    _ = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    # The default hour, not 7 ms.
    Client.eventually(fn ->
      Cronwatch.job_summary!("x", instance: @inst).silenced_until == @t0 + @hour
    end)
  end

  test "a JSON body Phoenix cannot parse is Phoenix's to answer", %{phoenix: phoenix} do
    json = [{"host", "app.test"}, {"authorization", "Bearer tok"}, {"content-type", "application/json"}]
    {status, _, _} = HTTP.request(phoenix, "POST", "/cronwatch/api/jobs/x/silence", json, "{")
    assert status == 400
    assert Cronwatch.job_summary!("x", instance: @inst).silenced_until == nil
  end

  test "a job's handler behind a real server", %{plug: plug} do
    headers = [{"host", "app.test"}, {"authorization", "Bearer s3cret"}]
    {200, _, body} = HTTP.request(plug, "POST", "/cron/served", headers, "over the wire")
    assert body =~ ~r/\A\{"ok":true,"job":"served","run":"[0-9a-f-]{36}","status":"ok","durationMs":0\}\z/
    [run] = Cronwatch.runs!("served", 5, instance: @inst)
    assert run.output == "POST /cron/served over the wire"
    assert run.trigger == "handler"
    {401, _, _} = HTTP.request(plug, "POST", "/cron/served", [{"host", "app.test"}], "x")
  end
end
