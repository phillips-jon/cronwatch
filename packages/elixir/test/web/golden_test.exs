defmodule Cronwatch.Web.GoldenTest do
  @moduledoc """
  Replays packages/ruby/test/web/golden.json, the SDK routes' answers to a
  fixed seed (written by golden.mjs), against `Cronwatch.Web` seeded the same
  way, and compares status, headers and body byte for byte, three ways:
  straight into the plug with `Plug.Test`, through a `Plug.Router` forward
  under a real Bandit server (its base path found from the mount), and
  through a Phoenix endpoint and router, whose `Plug.Parsers` has read the
  forms and JSON before the dashboard sees them. Run ids are random on both
  sides, so each becomes `<id:N>` in order of first appearance. The gem and
  the Python, PHP, Go and Rust ports replay the same file.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Plug.Test

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.HTTP

  @inst Cronwatch.Test.GoldenWeb
  @t0 Clock.t0()
  @min 60_000
  @hour 3_600_000
  @day 24 * @hour

  # What Bandit adds to every answer: its date, the connection's close (the
  # test's client asks for it), and the vary its response compression
  # sends.
  @server_headers ["date", "connection", "vary"]

  @golden Path.expand("../../../ruby/test/web/golden.json", __DIR__)
  @external_resource @golden

  defp captures do
    golden = JS.parse!(File.read!(@golden))
    assert Object.get(golden, "t0") == @t0, "golden.json's t0"
    captures = Object.get(golden, "captures")
    assert length(captures) == 57, "golden.json's captures"

    Enum.map(captures, fn c ->
      %{
        method: Object.get(c, "method"),
        path: Object.get(c, "path"),
        headers: Object.to_list(Object.get(c, "headers")),
        body: Object.get(c, "body"),
        status: Object.get(c, "status"),
        response_headers: Object.to_list(Object.get(c, "responseHeaders")),
        response_body: Object.get(c, "responseBody")
      }
    end)
  end

  # The seed in golden.mjs, step for step.
  defp seed do
    clock = Clock.new(@t0)

    start_supervised!(
      {Cronwatch, name: @inst, clock: Clock.fun(clock), alerts: [Capture.channel(Capture.new())], cron_secret: false}
    )

    inst = [instance: @inst]

    nightly =
      Cronwatch.job!(
        "nightly-report",
        [
          schedule: "0 2 * * *",
          timezone: "UTC",
          grace: "15m",
          max_duration: "10m",
          budget: [cost: 2],
          expect: "Report written",
          failures_before_alert: 2,
          description: "Builds the <b>PDF</b>",
          tags: ["reports", "<t>"]
        ] ++ inst
      )

    [2000, 2500, 90_000, 3100, 1800]
    |> Enum.with_index()
    |> Enum.each(fn {d, i} ->
      Clock.set(clock, @t0 - (5 - i) * @day - 7 * @hour - 30 * @min)

      Cronwatch.run(nightly, fn job ->
        Cronwatch.log(job, "#{if i == 3, do: "Wrote nothing", else: "Report written:"} report-#{i}.pdf")
        Cronwatch.metric(job, "cost", if(i == 4, do: 2.5, else: 1.2))
        Cronwatch.metric(job, "rows", 40 + i)
        Cronwatch.metric(job, "2", 0.123456)
        Clock.advance(clock, d)
        :ok
      end)
    end)

    broken = Cronwatch.job!("broken", [expect: "done"] ++ inst)
    Clock.set(clock, @t0 - 2 * @hour)

    Cronwatch.run(broken, fn job ->
      Cronwatch.log(job, "half way <script>alert(1)</script>")
      Clock.advance(clock, 450)
      :ok
    end)

    sync = Cronwatch.job!("sync-users", [schedule: "*/15 * * * *", grace: 60_000, timeout: "5m"] ++ inst)
    Clock.set(clock, @t0 - 3 * @hour)
    Cronwatch.run(sync, fn _ -> Clock.advance(clock, 12_345) end)

    Cronwatch.job!("never-ran", [schedule: "0 * * * *"] ++ inst)
    Clock.set(clock, @t0)
  end

  # Puts the id of the Nth newest run of a job where the path says
  # {run:JOB:N}.
  defp resolve(path) do
    case Regex.run(~r/\{run:([^:}]+):(\d+)\}/, path) do
      nil ->
        path

      [whole, job, n] ->
        runs = Cronwatch.runs!(job, 50, instance: @inst)
        String.replace(path, whole, Enum.at(runs, String.to_integer(n)).id)
    end
  end

  # Numbers run ids in order of first appearance, as golden.mjs does.
  defp number_ids(text, ids) do
    Regex.split(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, text, include_captures: true)
    |> Enum.map_reduce(ids, fn part, ids ->
      if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, part) do
        ids = Map.put_new(ids, part, "<id:#{map_size(ids)}>")
        {ids[part], ids}
      else
        {part, ids}
      end
    end)
    |> then(fn {parts, ids} -> {Enum.join(parts), ids} end)
  end

  # Checks one answer against its capture, and answers the ids seen so far.
  # `ignored` names headers the server in front adds (the SDK leaves
  # Content-Length to it).
  defp compare(c, status, headers, body, ids, ignored) do
    label = "#{c.method} #{c.path}"

    got =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
      |> Enum.reject(fn {k, _} -> k == "content-length" or k in ignored end)
      |> Enum.reduce([], fn {k, v}, acc ->
        case List.keyfind(acc, k, 0) do
          nil -> acc ++ [{k, v}]
          {_, old} -> List.keyreplace(acc, k, 0, {k, old <> ", " <> v})
        end
      end)

    {text, ids} =
      if List.keyfind(got, "content-type", 0) == {"content-type", "image/png"},
        do: {"base64:" <> Base.encode64(body), ids},
        else: number_ids(body, ids)

    assert status == c.status, "#{label}: status #{status}, want #{c.status}"

    assert Enum.sort(got) == Enum.sort(c.response_headers),
           "#{label}: headers\n got #{inspect(Enum.sort(got))}\nwant #{inspect(Enum.sort(c.response_headers))}"

    if text != c.response_body do
      at =
        Enum.zip(:binary.bin_to_list(text), :binary.bin_to_list(c.response_body))
        |> Enum.find_index(fn {a, b} -> a != b end) || min(byte_size(text), byte_size(c.response_body))

      from = max(at - 120, 0)
      slice = fn s -> binary_part(s, min(from, byte_size(s)), min(320, max(byte_size(s) - from, 0))) end

      flunk(
        "#{label}: the body differs at byte #{at}:\n got #{inspect(slice.(text))}\nwant #{inspect(slice.(c.response_body))}"
      )
    end

    ids
  end

  test "the SDK's captures, straight into the plug" do
    captures = captures()
    seed()
    opts = Cronwatch.Web.init(instance: @inst, token: "tok", base_path: "/cronwatch")

    Enum.reduce(captures, %{}, fn c, ids ->
      conn =
        Enum.reduce(c.headers, conn(c.method, resolve(c.path), c.body), fn {k, v}, conn ->
          Plug.Conn.put_req_header(conn, k, v)
        end)

      # Plug.Test keeps the host out of the headers, as HTTP/2 does.
      conn = Cronwatch.Web.call(%{conn | host: "app.test"}, opts)
      compare(c, conn.status, conn.resp_headers, conn.resp_body, ids, [])
    end)
  end

  test "the SDK's captures, through a Plug.Router forward under Bandit" do
    captures = captures()
    seed()
    port = HTTP.serve(Cronwatch.Test.WebRouter)

    Enum.reduce(captures, %{}, fn c, ids ->
      {status, headers, body} =
        HTTP.request(port, c.method, resolve(c.path), [{"host", "app.test"} | c.headers], c.body)

      compare(c, status, headers, body, ids, @server_headers)
    end)
  end

  test "the SDK's captures, through a Phoenix endpoint and router" do
    captures = captures()
    seed()
    port = Cronwatch.Test.Endpoint.serve()

    Enum.reduce(captures, %{}, fn c, ids ->
      {status, headers, body} =
        HTTP.request(port, c.method, resolve(c.path), [{"host", "app.test"} | c.headers], c.body)

      compare(c, status, headers, body, ids, @server_headers)
    end)
  end
end
