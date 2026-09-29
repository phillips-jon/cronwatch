defmodule Cronwatch.Audit.OutboundHTTPTest do
  @moduledoc """
  The default transport (`Cronwatch.Transport.HTTP`) under `Post`, against
  servers that misbehave: an answer of any status read to 1 MiB as it
  arrives (with a length, chunked, or up to the close), chunks and heads
  that are not HTTP, a body still arriving at the deadline, interim
  answers, framing headers an app gave, and TLS to an IP address. Also the
  audit's other outbound findings: an IPv6 zone refused as fetch refuses
  it, and options given the wrong way never quoted.
  """
  use ExUnit.Case, async: true

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Slack
  alias Cronwatch.Alerts.Webhook
  alias Cronwatch.Test.HTTPServer
  alias Cronwatch.Transport
  alias Cronwatch.Transport.HTTP
  alias Cronwatch.Triage.Anthropic

  @mib 1_048_576

  # A server that reads the request, then hands the socket to `answer`,
  # which writes what it likes; `sent` counts the bytes it got out before
  # the client went away.
  defp raw(answer) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    sent = :counters.new(1, [])

    start_supervised!(
      {Task,
       fn ->
         {:ok, s} = :gen_tcp.accept(listen)
         {:ok, _} = :gen_tcp.recv(s, 0, 5000)

         put = fn data ->
           case :gen_tcp.send(s, data) do
             :ok -> :counters.add(sent, 1, IO.iodata_length(data))
             e -> throw(e)
           end
         end

         try do
           answer.(put)
         catch
           _ -> :ok
         end

         :gen_tcp.close(s)
         Process.sleep(:infinity)
       end},
      id: make_ref()
    )

    %{url: "http://127.0.0.1:#{port}", sent: sent}
  end

  defp mib_chunk, do: :binary.copy("x", @mib)

  test "an answer of any status ending at the close is read to 1 MiB as it arrives" do
    for status <- [200, 404, 500] do
      server =
        raw(fn put ->
          put.("HTTP/1.1 #{status} X\r\nconnection: close\r\n\r\n")
          for _ <- 1..400, do: put.(mib_chunk())
        end)

      assert {:ok, %{status: ^status, body: body}} = Post.fetch(nil, 5000, server.url <> "/x", [], "{}")
      assert byte_size(body) == @mib
      Process.sleep(100)
      # The client let go at the cap, not after reading the 400 MiB.
      assert :counters.get(server.sent, 1) < 64 * @mib
    end
  end

  test "a chunked answer of any status is read to 1 MiB, however long" do
    for status <- [200, 500] do
      server =
        raw(fn put ->
          put.("HTTP/1.1 #{status} X\r\ntransfer-encoding: chunked\r\n\r\n")
          for _ <- 1..400, do: put.(["100000;ext=1\r\n", mib_chunk(), "\r\n"])
        end)

      assert {:ok, %{status: ^status, body: body}} = Post.fetch(nil, 5000, server.url, [], "{}")
      assert byte_size(body) == @mib
      Process.sleep(100)
      assert :counters.get(server.sent, 1) < 64 * @mib
    end

    small =
      raw(fn put -> put.("HTTP/1.1 400 X\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n") end)

    assert Post.fetch(nil, 5000, small.url, [], "{}") == {:ok, %{status: 400, body: "abcde"}}
  end

  test "a body that is not HTTP is read as none, its status kept" do
    for body <- [
          "zz\r\nabc\r\n0\r\n\r\n",
          "3\r\nabcXX2\r\nde\r\n0\r\n\r\n",
          String.duplicate("1", 5000),
          "10000000000000000\r\nx"
        ] do
      server = raw(fn put -> put.(["HTTP/1.1 502 X\r\ntransfer-encoding: chunked\r\n\r\n", body]) end)
      assert Post.fetch(nil, 5000, server.url, [], "{}") == {:ok, %{status: 502, body: ""}}, inspect(body)
    end

    # A length the connection closes short of.
    short = raw(fn put -> put.("HTTP/1.1 500 X\r\ncontent-length: 100\r\n\r\nabc") end)
    assert Post.fetch(nil, 5000, short.url, [], "{}") == {:ok, %{status: 500, body: ""}}
  end

  test "a head that is not HTTP fails the request" do
    for {head, reason} <- [
          {"HTTP/1.1 500 X\r\ncontent-length: 1\r\ncontent-length: 2\r\n\r\nab", "invalid_response"},
          {"HTTP/1.1 500 X\r\ncontent-length: -1\r\n\r\n", "invalid_response"},
          {"ICY 200 OK\r\n\r\n", "invalid_response"},
          {"HTTP/1.1 20 X\r\n\r\n", "invalid_response"},
          {"HTTP/1.1 101 Switching\r\n\r\n", "invalid_response"},
          {"HTTP/1.1 200 OK\r\ncontent-le", "invalid_response"},
          {"", "socket_closed_remotely"}
        ] do
      server = raw(fn put -> if head != "", do: put.(head) end)
      {:error, e} = Post.fetch(nil, 5000, server.url <> "/secret/path", [], "{}")
      assert Exception.message(e) == "#{server.url}: #{reason}", inspect(head)
    end
  end

  test "a head past 64 KiB or 256 lines is refused before it grows" do
    long =
      raw(fn put ->
        put.("HTTP/1.1 500 X\r\n")
        for i <- 1..100_000, do: put.("x-h#{i}: #{String.duplicate("a", 100)}\r\n")
      end)

    {:error, e} = Post.fetch(nil, 5000, long.url, [], "{}")
    assert Exception.message(e) == "#{long.url}: header_too_long"
    Process.sleep(100)
    assert :counters.get(long.sent, 1) < 8 * @mib

    many = raw(fn put -> put.(["HTTP/1.1 200 X\r\n", for(i <- 1..300, do: "x#{i}: y\r\n"), "\r\n"]) end)
    {:error, e} = Post.fetch(nil, 5000, many.url, [], "{}")
    assert Exception.message(e) == "#{many.url}: header_too_long"
  end

  test "an answer of any status still arriving at the deadline is its status with no body" do
    for status <- [200, 500] do
      drip = HTTPServer.start(fn _ -> {:drip, status, [], List.duplicate("x", 100), 50} end)
      assert Post.fetch(nil, 300, drip.url, [], "{}") == {:ok, %{status: status, body: ""}}
    end

    refute_received _
  end

  test "interim answers are passed over" do
    server =
      raw(fn put ->
        put.("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nlink: </x>\r\n\r\n")
        put.("HTTP/1.1 201 Created\r\ncontent-length: 2\r\n\r\nok")
      end)

    assert Post.fetch(nil, 5000, server.url, [], "{}") == {:ok, %{status: 201, body: "ok"}}

    endless = raw(fn put -> for _ <- 1..50, do: put.("HTTP/1.1 103 Early Hints\r\n\r\n") end)
    {:error, e} = Post.fetch(nil, 5000, endless.url, [], "{}")
    assert Exception.message(e) == "#{endless.url}: invalid_response"
  end

  test "an answer with no body has none, and the connection is not left open" do
    for status <- [204, 304] do
      server = raw(fn put -> put.("HTTP/1.1 #{status} X\r\n\r\n") end)
      assert Post.fetch(nil, 5000, server.url, [], "{}") == {:ok, %{status: status, body: ""}}
    end
  end

  test "headers that frame the request are the transport's own, whatever an app gives" do
    server = HTTPServer.start(fn _ -> {200, [], ""} end)

    headers = [
      {"host", "evil.example"},
      {"transfer-encoding", "chunked"},
      {"content-length", "0"},
      {"connection", "keep-alive"},
      {"authorization", "Bearer t"}
    ]

    assert :ok = Webhook.send(elem(Webhook.init(url: server.url <> "/in", headers: headers), 1), sample(), nil)
    [req] = HTTPServer.requests(server)
    names = Enum.map(req.headers, &elem(&1, 0))
    assert names == ~w(host content-type user-agent authorization content-length connection)
    assert {"host", String.trim_leading(server.url, "http://")} in req.headers
    assert {"connection", "close"} in req.headers
    assert req.body =~ ~s("job":"nightly")
  end

  test "TLS to an IP address checks the certificate against the address, with no SNI" do
    server = HTTPServer.start(fn _ -> {200, [], "fine"} end, tls: true, san: [iPAddress: [127, 0, 0, 1]])
    url = String.replace(server.url, "localhost", "127.0.0.1")
    assert {:ok, %{status: 200, body: "fine"}} = Post.fetch({HTTP, cacerts: [server.ca]}, 5000, url, [], "{}")

    # The same certificate does not pass for a name it does not hold.
    {:error, e} = Post.fetch({HTTP, cacerts: [server.ca]}, 5000, server.url <> "/x", [], "{}")
    assert Exception.message(e) =~ ~r/hostname|certificate|handshake/i
    refute Exception.message(e) =~ "/x"

    # A certificate no root here signed, for the right address, is refused.
    {:error, e} = Post.fetch(nil, 5000, url, [], "{}")
    assert Exception.message(e) =~ ~r/unknown ca|certificate/i
  end

  test "a host with no address fails with the resolver's reason, naming only the origin" do
    {:error, e} = Post.fetch(nil, 5000, "http://no-such-host.invalid/secret", [], "{}")
    assert Exception.message(e) == "http://no-such-host.invalid: nxdomain"
  end

  test "an IPv6 host with a zone is refused, as fetch refuses it" do
    for raw <- ["http://[fe80::1%25en0]/x", "http://[fe80::1%en0]/x"] do
      {:error, e} = Post.postable(raw)
      assert Exception.message(e) == "only http and https URLs can be posted to, not this URL"
    end
  end

  test "options given the wrong way are refused without being quoted" do
    url = "https://hooks.slack.com/services/T0/B0/" <> "not" <> "areal" <> "secret"

    for {module, opts} <- [{Slack, url}, {Webhook, %{"url" => url}}, {Anthropic, "sk-ant-" <> "notareal"}] do
      assert {:error, message} = module.init(opts)
      refute message =~ "areal", message
    end

    assert {:error, message} = Transport.check("http://user:" <> "pw" <> "@proxy", "X")
    refute message =~ "pw@"
  end

  defp sample do
    %Cronwatch.Alert{
      type: "failed",
      details: %{consecutive_failures: 1, threshold: 1},
      job: "nightly",
      title: "nightly failed",
      message: "boom",
      at: 1_700_000_000_000
    }
  end
end
