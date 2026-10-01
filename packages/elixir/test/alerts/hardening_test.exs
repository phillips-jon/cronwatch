defmodule Cronwatch.Alerts.HardeningTest do
  @moduledoc """
  The channels and their POST against real local servers (the Rust port's
  hardening tests): a redirect refused by every channel, one deadline for
  the whole request, the answer read to 1 MiB at most, URLs and headers
  refused without quoting them, only the origin in an error, TLS verified,
  a secret straddling the cut, and a cut body keeping its lone surrogate.
  Not async: one test shortens the POST deadline for the whole package.
  """
  use ExUnit.Case, async: false

  alias Cronwatch.Alert
  alias Cronwatch.Alerts.Discord
  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Slack
  alias Cronwatch.Alerts.URL
  alias Cronwatch.Alerts.Webhook
  alias Cronwatch.ChannelContext
  alias Cronwatch.Config
  alias Cronwatch.JS
  alias Cronwatch.Test.Conformance
  alias Cronwatch.Test.EveryChannel
  alias Cronwatch.Test.HTTPServer
  alias Cronwatch.Test.RecordingTransport, as: Rec
  alias Cronwatch.Test.RewriteTransport
  alias Cronwatch.Transport.HTTP
  alias Cronwatch.Transport.Request
  alias Cronwatch.Triage.Anthropic

  defp sample do
    f = Conformance.fixture("channels")
    {:ok, a} = f |> Conformance.list("alerts") |> hd() |> Conformance.field("alert") |> Alert.from_value()
    a
  end

  defp quiet, do: %ChannelContext{on_error: fn _ -> :ok end}

  defp send!({module, opts}, alert \\ sample()) do
    {:ok, state} = module.init(opts)
    module.send(state, alert, quiet())
  end

  defp message({:error, e}), do: Exception.message(e)
  defp message(other), do: flunk("expected an error, got #{inspect(other)}")

  # A path that stands for a webhook's credential, built so it does not
  # look like one.
  defp secret, do: "not" <> "areal" <> "secret"

  test "every channel refuses to follow a redirect" do
    evil = HTTPServer.start(fn _ -> {202, [], ""} end)
    target = evil.url <> "/steal"
    provider = HTTPServer.start(fn _ -> {307, [{"location", target}], ""} end)
    channels = EveryChannel.started(provider.url <> "/in", RewriteTransport.spec(provider))
    assert length(channels) == 15

    for {module, state} <- channels do
      err = message(module.send(state, sample(), quiet()))
      assert err =~ "answered 307", "#{inspect(module)} followed the redirect or failed otherwise: #{err}"
    end

    assert HTTPServer.requests(evil) == [], "the other origin was reached"
    seen = HTTPServer.requests(provider)
    assert length(seen) == length(channels)
    assert Enum.any?(seen, &({"authorization", "Bearer wh-secret"} in &1.headers))
  end

  test "one deadline for the whole request" do
    assert Post.timeout() == 10_000
    hang = HTTPServer.start(fn _ -> :hang end)
    started = System.monotonic_time(:millisecond)
    {:error, e} = Post.fetch(nil, 300, hang.url <> "/T/B/secret", [], "{}")
    assert Exception.message(e) == "The operation was aborted due to timeout"
    assert e.reason == :timeout
    assert System.monotonic_time(:millisecond) - started < 5_000

    # A streamed answer whose body is still arriving at the deadline is the
    # answer with no body.
    drip = HTTPServer.start(fn _ -> {:drip, 200, [], List.duplicate("x", 100), 50} end)
    assert Post.fetch(nil, 300, drip.url, [], "{}") == {:ok, %{status: 200, body: ""}}

    refused = Post.refused("Rollbar", "https://api.rollbar.com/api/1/item/", %{status: 500, body: ""}, [])
    assert Exception.message(refused) == "Rollbar https://api.rollbar.com answered 500"

    # Nothing is left in the caller's mailbox.
    refute_received _
  end

  test "a channel stops waiting at its deadline" do
    Application.put_env(:cronwatch, :post_timeout, 300)
    on_exit(fn -> Application.delete_env(:cronwatch, :post_timeout) end)
    hang = HTTPServer.start(fn _ -> :hang end)
    err = message(send!({Slack, webhook_url: hang.url <> "/T/B/secret"}))
    assert err == "The operation was aborted due to timeout"
  end

  test "an answer is read to one mebibyte at most" do
    mib = Post.max_body()
    big = String.duplicate("x", 3 * mib)

    # Whatever the status: 1 MiB either way.
    ok = HTTPServer.start(fn _ -> {200, [], big} end)
    assert {:ok, %{status: 200, body: body}} = Post.fetch(nil, 10_000, ok.url, [], "{}")
    assert byte_size(body) == mib

    refused = HTTPServer.start(fn _ -> {500, [], big} end)
    assert {:ok, %{status: 500, body: body}} = Post.fetch(nil, 10_000, refused.url, [], "{}")
    assert byte_size(body) == mib

    # A refusal far past the cap is read to the cap, not refused whole.
    huge = HTTPServer.start(fn _ -> {500, [], String.duplicate("x", 9 * mib)} end)
    assert {:ok, %{status: 500, body: body}} = Post.fetch(nil, 10_000, huge.url <> "/p", [], "{}")
    assert byte_size(body) == mib

    err = message(send!({Slack, webhook_url: refused.url <> "/T/B/x"}))
    assert JS.len16(err) <= byte_size("Slack webhook answered 500: ") + 200
  end

  test "a URL that cannot be posted to is refused without quoting it" do
    rec = Rec.start()
    path = Enum.join(["services", "T0", "B0", secret()], "/")

    cases = [
      {"hooks.example.com/#{path}", "this URL"},
      {"ftp://hooks.example.com/#{path}", "ftp:"},
      {"https://user:pw@hooks.example.com/#{path}", "this URL"},
      {"https://hooks.example.com:99999/#{path}", "this URL"},
      {"javascript:alert(1)", "javascript:"}
    ]

    for {raw, shown} <- cases,
        spec <- [
          {Slack, webhook_url: raw, transport: Rec.spec(rec)},
          {Discord, webhook_url: raw, transport: Rec.spec(rec)},
          {Webhook, url: raw, transport: Rec.spec(rec)}
        ] do
      assert message(send!(spec)) == "only http and https URLs can be posted to, not #{shown}", raw
    end

    assert Rec.taken(rec) == []

    # A stray newline or space around a pasted URL, or a tab inside it, is
    # dropped, as fetch drops it; a space inside is encoded.
    for {raw, posted} <- [
          {"  https://hooks.exa\tmple.com/#{path}\n", "https://hooks.example.com/#{path}"},
          {"https://hooks.example.com/#{path} x", "https://hooks.example.com/#{path}%20x"}
        ] do
      assert send!({Slack, webhook_url: raw, transport: Rec.spec(rec)}) == :ok
      assert List.last(Rec.taken(rec)).url == posted
    end

    for {raw, want} <- [
          {"https://hooks.example.com/#{path}\n", "https://hooks.example.com"},
          {"HTTPS://Hooks.Example.com:443/x", "https://hooks.example.com"},
          {"http://hooks.example.com:8080/x", "http://hooks.example.com:8080"},
          {"not a url", "(invalid URL)"}
        ] do
      assert Post.origin(raw) == want, raw
    end
  end

  test "an error names only the origin" do
    # Nothing listens on port 1: the transport's own reason is kept, the
    # URL's path is not.
    err = message(send!({Webhook, url: "http://127.0.0.1:1/hooks/#{secret()}?token=#{secret()}"}))
    assert err == "http://127.0.0.1:1: econnrefused"

    refuse = HTTPServer.start(fn _ -> {403, [], ""} end)
    err = message(send!({Webhook, url: "#{refuse.url}/services/#{secret()}?key=#{secret()}"}))
    assert err == "Webhook #{refuse.url} answered 403"
  end

  defmodule Quoting do
    @moduledoc false
    # An app's transport that fails the way a wrapper around a client of
    # its own does: with its own text quoting the URL, whole or decoded.
    @behaviour Cronwatch.Transport

    @impl true
    def post(_, request) do
      {:ok, u} = URL.parse(request.url)
      {:error, "giving up on #{request.url} (#{Post.percent_decode(u.path)}) after 3 tries"}
    end
  end

  defmodule Raising do
    @moduledoc false
    @behaviour Cronwatch.Transport
    @impl true
    def post(_, _), do: raise("transport broke")
  end

  test "an error names only the origin, whatever the transport quotes" do
    url = "https://hooks.example.com/services/#{secret()}%20x?token=#{secret()}"
    err = message(send!({Webhook, url: url, transport: Quoting}))
    refute err =~ secret()
    refute err =~ "/services"
    assert String.starts_with?(err, "https://hooks.example.com: ")

    # A transport that raises fails the send; it crashes nothing.
    err = message(send!({Webhook, url: url, transport: Raising}))
    assert err == "https://hooks.example.com: transport broke"
  end

  test "TLS is verified" do
    server = HTTPServer.start(fn _ -> {200, [], ""} end, tls: true)
    assert String.starts_with?(server.url, "https://localhost:")
    err = message(send!({Slack, webhook_url: server.url <> "/T/B/secret"}))
    assert err =~ ~r/unknown ca|certificate/i, "a certificate no one trusts was accepted: #{err}"
    refute err =~ "/T/B/secret"
    assert String.starts_with?(err, server.url <> ": ")
    assert HTTPServer.requests(server) == []

    # Trusting the server's root, the same request goes through, its host
    # checked against the certificate.
    ok =
      send!({Slack, webhook_url: server.url <> "/T/B/secret", transport: {HTTP, cacerts: [server.ca]}})

    assert ok == :ok
    assert [%{target: "/T/B/secret"}] = HTTPServer.requests(server)

    # A certificate for another name is refused even from a trusted root.
    other = String.replace(server.url, "localhost", "127.0.0.1")
    err = message(send!({Slack, webhook_url: other <> "/x", transport: {HTTP, cacerts: [server.ca]}}))
    assert err =~ ~r/hostname|certificate|handshake/i, err
  end

  test "headers are checked and credentials trimmed" do
    rec = Rec.start()

    for value <- ["Bearer a\r\nX-Evil: 1", "Bearer a\nb", "a" <> <<0>> <> "b"] do
      spec =
        {Webhook, url: "https://hooks.example.com/in", headers: [{"authorization", value}], transport: Rec.spec(rec)}

      assert message(send!(spec)) == "the authorization header's value may not contain a line break"
    end

    spec =
      {Webhook, url: "https://hooks.example.com/in", headers: [{"bad name", "x"}], transport: Rec.spec(rec)}

    assert message(send!(spec)) =~ "a header name must be a token"
    assert Rec.taken(rec) == []

    spec =
      {Webhook,
       url: "https://hooks.example.com/in",
       headers: [{"authorization", " Bearer wh-secret\n"}],
       transport: Rec.spec(rec)}

    assert send!(spec) == :ok
    assert {"authorization", "Bearer wh-secret"} in hd(Rec.taken(rec)).headers
  end

  test "the headers the default transport sends, in the order it sends them" do
    server = HTTPServer.start(fn _ -> {200, [], ""} end)
    spec = {Webhook, url: server.url <> "/in", headers: [{"authorization", "Bearer t"}], secret: "s"}
    assert send!(spec) == :ok
    [req] = HTTPServer.requests(server)
    names = Enum.map(req.headers, &elem(&1, 0))
    assert names == ~w(host content-type user-agent authorization x-cronwatch-signature content-length connection)
    assert {"user-agent", "cronwatch"} in req.headers
    refute "accept-encoding" in names
  end

  test "a secret that straddles the cut is still cut out" do
    key = binary_part("key-0123456789abcdef-0123456789abcdef", 0, 36)
    server = HTTPServer.start(fn _ -> {401, [], String.duplicate("x", 180) <> "invalid key " <> key} end)
    {:error, e} = Post.post(nil, "Mailgun", server.url <> "/v3/x", [], "{}", [key])
    err = Exception.message(e)

    for i <- 0..(byte_size(key) - 6) do
      refute err =~ binary_part(key, i, 6), "a piece of the key survives: #{err}"
    end

    assert String.ends_with?(err, ": " <> String.duplicate("x", 180) <> "invalid key [redacte")
    assert Post.error_body(String.duplicate("a", 199) <> "😀tail", []) == String.duplicate("a", 199)
    cut = Post.error_body(String.duplicate("y", 10) <> "sekret" <> String.duplicate("z", 300), ["sekret"])
    assert String.starts_with?(cut, String.duplicate("y", 10) <> "[redacted]")
  end

  test "a JSON body cut through a surrogate pair keeps the lone half" do
    rec = Rec.start()
    a = %{sample() | message: String.duplicate("a", 2899) <> "😀 and on", triage: String.duplicate("b", 2989) <> "😀"}

    assert send!(
             {Slack, webhook_url: "https://hooks.slack.example/T/B/secret", transport: Rec.spec(rec)},
             a
           ) == :ok

    [%{body: body}] = Rec.taken(rec)
    assert body =~ String.duplicate("a", 2899) <> "\\ud83d```"
    assert body =~ String.duplicate("b", 2989) <> "\\ud83d\""
    assert {:ok, %JS.Object{}} = JS.parse(body)

    Rec.answer_with(rec, 204, "")
    # The message's block and a full triage do not both fit in Discord's
    # 4096, so each half is sent on its own.
    discord = {Discord, webhook_url: "https://discord.example/api/webhooks/1/x", transport: Rec.spec(rec)}
    assert send!(discord, %{a | message: String.duplicate("c", 3799) <> "😀", triage: nil}) == :ok
    [%{body: body}] = Rec.taken(rec)
    assert body =~ String.duplicate("c", 3799) <> "\\ud83d\\n```"

    Rec.answer_with(rec, 204, "")
    assert send!(discord, %{a | message: "c", triage: String.duplicate("d", 999) <> "😀"}) == :ok
    [%{body: body}] = Rec.taken(rec)
    assert body =~ String.duplicate("d", 999) <> "\\ud83d\""
  end

  test "the instance's transport reaches a channel given none" do
    rec = Rec.start()
    name = :"cw_transport_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Cronwatch,
       name: name,
       cron_secret: false,
       transport: Rec.spec(rec),
       alerts: [{Slack, webhook_url: "https://hooks.slack.example/T/B/secret"}],
       jobs: [{"nightly", failures_before_alert: 1}]}
    )

    Cronwatch.run("nightly", fn _ -> {:error, "boom"} end, instance: name)
    assert [%{url: "https://hooks.slack.example/T/B/secret"}] = Rec.taken(rec)

    assert {:error, %Cronwatch.Error{message: "Cronwatch: Nope is not a Cronwatch.Transport"}} =
             Config.new(transport: Nope)
  end

  test "a transport's options, which may hold a credential, are never inspected" do
    transport = {Rec, [proxy: "http://user:proxy-pass@proxy.example", passphrase: "tls-pass"]}

    states =
      EveryChannel.started("https://h.example/x", transport) ++
        [{Anthropic, elem(Anthropic.init(api_key: "k", transport: transport), 1)}]

    {:ok, config} = Config.new(transport: transport)
    ctx = %ChannelContext{on_error: fn _ -> :ok end, transport: transport}

    for value <- Enum.map(states, &elem(&1, 1)) ++ [config, ctx] do
      shown = inspect(value)
      refute shown =~ "proxy-pass", shown
      refute shown =~ "tls-pass", shown
    end
  end

  test "a transport given as an option is checked" do
    assert Slack.init(webhook_url: "https://h.example/x", transport: Nope) ==
             {:error, "Cronwatch.Alerts.Slack: Nope is not a Cronwatch.Transport"}

    assert inspect(%Request{
             url: "https://h.example/secret",
             headers: [{"x-api-key", "k"}],
             body: "{}"
           }) ==
             ~s(#Cronwatch.Transport.Request<origin: "https://h.example", headers: ["x-api-key"], body: 2 bytes>)
  end
end
