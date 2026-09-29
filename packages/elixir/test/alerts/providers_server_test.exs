defmodule Cronwatch.Alerts.ProvidersServerTest do
  # The provider channels against real local servers through :httpc (the
  # Rust port's hardening_tests.rs, the providers' part): Twilio texting
  # every number at once and reporting the refusals, credentials trimmed on
  # the wire, and a secret that straddles the error's cut still cut out.
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client

  alias Cronwatch.Alert
  alias Cronwatch.Alerts
  alias Cronwatch.ChannelContext
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.HTTPServer

  defmodule ToServer do
    @moduledoc false
    # Sends each request to the test's local server, keeping its path and
    # query, through the default :httpc transport.
    @behaviour Cronwatch.Transport

    alias Cronwatch.Transport.Httpc

    @impl true
    def post(base, request) do
      uri = URI.parse(request.url)
      path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
      Httpc.post([], %{request | url: base <> path})
    end
  end

  defp to(server), do: {ToServer, server.url}
  defp quiet, do: %ChannelContext{on_error: fn _ -> :ok end}

  defp sample do
    %Alert{
      type: "failed",
      details: %{consecutive_failures: 1, threshold: 1},
      job: "nightly",
      title: "nightly failed",
      message: "Error: boom",
      at: 1_767_605_402_000
    }
  end

  defp email, do: [from: "CronWatch <alerts@example.com>", to: "ops@example.com"]

  test "Twilio texts every number at once, and reports each refusal once without sending again" do
    server =
      HTTPServer.start(fn req ->
        if req.body =~ "To=%2B15550000000",
          do: {400, [{"content-type", "application/json"}], ~s({"code":21211,"message":"Invalid To"})},
          else: {201, [{"content-type", "application/json"}], "{}"}
      end)

    sms =
      {Alerts.Twilio,
       account_sid: "AC1",
       auth_token: "tok",
       from: "+15551112222",
       to: ["+15553334444", "+15550000000"],
       transport: to(server)}

    %{cw: cw, clock: clock, errors: errors} = make(alerts: [sms])
    Cronwatch.job!("nightly", schedule: "0 * * * *", instance: cw)
    {:ok, _} = Cronwatch.check(instance: cw)

    for _ <- 1..6 do
      Clock.advance(clock, 70 * 60_000)
      {:ok, _} = Cronwatch.check(instance: cw)
    end

    sent =
      server
      |> HTTPServer.requests()
      |> Enum.map(fn r -> r.body |> URI.decode_query() |> Map.get("To") end)
      |> Enum.frequencies()

    assert sent == %{"+15553334444" => 1, "+15550000000" => 1},
           "one SMS a number for one open missed condition, never resent"

    [request | _] = HTTPServer.requests(server)
    assert request.target == "/2010-04-01/Accounts/AC1/Messages.json"
    assert {"authorization", "Basic QUMxOnRvaw=="} in request.headers

    assert [message] = messages(errors)
    assert message =~ "Twilio https://api.twilio.com answered 400: "
    assert message =~ "Invalid To"
    assert String.ends_with?(message, " (to ********0000; 1 of 2 numbers took the alert)")
    assert wheres(errors) == ["alert channel twilio"]
  end

  test "Twilio fails when every number refuses, and the alert is retried at the next check" do
    server = HTTPServer.start(fn _ -> {500, [], "no"} end)

    {:ok, s} =
      Alerts.Twilio.init(account_sid: "AC1", auth_token: "tok", from: "+1", to: ["+2", "+3"], transport: to(server))

    assert {:error, e} = Alerts.Twilio.send(s, sample(), quiet())
    assert Cronwatch.Error.describe(e) == "Twilio https://api.twilio.com answered 500: no (2 of 2 numbers failed)"
    assert length(HTTPServer.requests(server)) == 2
  end

  test "credentials go out trimmed, and every header without spaces around it" do
    server = HTTPServer.start(fn _ -> {200, [], "{}"} end)
    t = to(server)

    channels = [
      {Alerts.Resend, [api_key: " re_secret\n", transport: t] ++ email()},
      {Alerts.Postmark, [server_token: "\tpm-secret ", transport: t] ++ email()},
      {Alerts.SendGrid, [api_key: "SG.secret\n", transport: t] ++ email()},
      {Alerts.Mailgun, [api_key: " key-secret ", domain: "mg.example.com", transport: t] ++ email()},
      {Alerts.Datadog, api_key: "dd-secret\n", transport: t},
      {Alerts.Honeybadger, api_key: " hb-secret", transport: t},
      {Alerts.Rollbar, access_token: "rb-secret \n", transport: t},
      {Alerts.Bugsnag, api_key: "bs-secret\n", transport: t},
      {Alerts.NewRelic, account_id: "1", api_key: " nr-secret", transport: t},
      {Alerts.Sentry, dsn: " https://pubkey@o1.ingest.sentry.io/42\n", transport: t},
      {Alerts.Twilio, account_sid: " AC1 ", auth_token: "tok\n", from: "+1", to: ["+2"], transport: t},
      {Alerts.SES,
       [region: "us-east-1", access_key_id: " AKIDEXAMPLE", secret_access_key: "sekret\n", transport: t] ++ email()}
    ]

    for {module, opts} <- channels do
      {:ok, s} = module.init(opts)
      assert module.send(s, sample(), quiet()) == :ok, inspect(module)
    end

    got = HTTPServer.requests(server)
    assert length(got) == length(channels)

    for r <- got, {name, value} <- r.headers do
      assert value == String.trim(value), "#{name} has spaces around it"
    end

    header = fn i, name -> got |> Enum.at(i) |> Map.fetch!(:headers) |> List.keyfind(name, 0) |> elem(1) end
    assert header.(0, "authorization") == "Bearer re_secret"
    assert header.(1, "x-postmark-server-token") == "pm-secret"
    assert header.(2, "authorization") == "Bearer SG.secret"
    assert header.(3, "authorization") == "Basic " <> Base.encode64("api:key-secret")
    assert header.(4, "dd-api-key") == "dd-secret"
    assert header.(5, "x-api-key") == "hb-secret"
    assert header.(6, "x-rollbar-access-token") == "rb-secret"
    assert Enum.at(got, 7).body =~ ~s("apiKey":"bs-secret")
    assert header.(8, "api-key") == "nr-secret"
    assert header.(9, "x-sentry-auth") =~ "sentry_key=pubkey,"
    assert Enum.at(got, 10).target == "/2010-04-01/Accounts/AC1/Messages.json"
    assert header.(10, "authorization") == "Basic QUMxOnRvaw=="
    assert header.(11, "authorization") =~ ~r/\AAWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\//
  end

  test "every provider refuses to follow a redirect, so its credentials never go where it points" do
    elsewhere = HTTPServer.start(fn _ -> {200, [], "{}"} end)
    server = HTTPServer.start(fn _ -> {307, [{"location", elsewhere.url <> "/stolen"}], ""} end)
    t = to(server)

    channels = [
      {Alerts.Resend, [api_key: "re_secret", transport: t] ++ email()},
      {Alerts.Postmark, [server_token: "pm-secret", transport: t] ++ email()},
      {Alerts.SendGrid, [api_key: "SG.secret", transport: t] ++ email()},
      {Alerts.Mailgun, [api_key: "key-secret", domain: "mg.example.com", transport: t] ++ email()},
      {Alerts.SES,
       [region: "us-east-1", access_key_id: "AKIDEXAMPLE", secret_access_key: "sekret", transport: t] ++ email()},
      {Alerts.Twilio, account_sid: "AC1", auth_token: "tok", from: "+1", to: ["+2"], transport: t},
      {Alerts.Sentry, dsn: "https://pubkey@o1.ingest.sentry.io/42", transport: t},
      {Alerts.Honeybadger, api_key: "hb-secret", transport: t},
      {Alerts.Datadog, api_key: "dd-secret", transport: t},
      {Alerts.Rollbar, access_token: "rb-secret", transport: t},
      {Alerts.Bugsnag, api_key: "bs-secret", transport: t},
      {Alerts.NewRelic, account_id: "1", api_key: "nr-secret", transport: t}
    ]

    for {module, opts} <- channels do
      {:ok, s} = module.init(opts)
      assert {:error, e} = module.send(s, sample(), quiet()), inspect(module)
      assert Cronwatch.Error.describe(e) =~ ~r/ https:\/\/[a-z0-9.-]+ answered 307\z/, inspect(module)
    end

    assert length(HTTPServer.requests(server)) == length(channels)
    assert HTTPServer.requests(elsewhere) == []
  end

  test "a secret that straddles the error's cut is still cut out" do
    key = ["key", "0123456789abcdef", "0123456789abcdef"] |> Enum.join("-") |> binary_part(0, 36)
    server = HTTPServer.start(fn _ -> {401, [], String.duplicate("x", 180) <> "invalid key " <> key} end)

    {:ok, s} = Alerts.Mailgun.init([api_key: key, domain: "mg.example.com", transport: to(server)] ++ email())
    assert {:error, e} = Alerts.Mailgun.send(s, sample(), quiet())
    err = Cronwatch.Error.describe(e)

    for i <- 0..(byte_size(key) - 6) do
      refute err =~ binary_part(key, i, 6), "a piece of the key survives: #{err}"
    end

    assert String.ends_with?(err, ": " <> String.duplicate("x", 180) <> "invalid key [redacte")
  end

  test "an email's subject is one line, and a link that is not http or https is left out" do
    {:ok, email} =
      Alerts.Email.options(Alerts.Resend,
        from: "a@b.c",
        to: "d@e.f",
        subject_prefix: "[prod]",
        link: fn _ -> "javascript:alert(1)" end
      )

    a = %{sample() | title: "line one\r\nline two <b>", triage: ~s(check the "db")}
    m = Alerts.Email.compose(a, email)
    assert m.subject == "[prod] line one line two <b>"
    refute m.html =~ "javascript:"
    refute m.text =~ "javascript:"
    assert m.html =~ "line two &lt;b&gt;"
    assert m.html =~ "check the &quot;db&quot;"
  end

  test "SMS bodies stay inside Twilio's limits" do
    long = %{sample() | title: "j failed", message: String.duplicate("x", 3000)}
    assert Cronwatch.JS.len16(Alerts.Twilio.sms_body(long, "", 12)) <= 1530, "segments capped at 10"
    assert Cronwatch.JS.len16(Alerts.Twilio.sms_body(long, "", :nan)) <= 459, "not a number is the default 3"

    for {text, want} <- [
          {String.duplicate("a", 160), 1},
          {String.duplicate("a", 161), 2},
          {String.duplicate("a", 152) <> "{" <> String.duplicate("a", 152), 3},
          {String.duplicate("\u{1F600}", 35), 1},
          {String.duplicate("a", 66) <> "\u{1F600}" <> String.duplicate("a", 66), 3}
        ] do
      assert Alerts.Twilio.sms_segments(text) == want
    end

    packed = %{sample() | title: "t", message: String.duplicate(String.duplicate("a", 152) <> "{", 3)}
    assert Alerts.Twilio.sms_segments(Alerts.Twilio.sms_body(packed, "", 3)) <= 3
    short = %{sample() | message: "m"}

    assert Cronwatch.JS.len16(Alerts.Twilio.sms_body(short, "https://example.com/" <> String.duplicate("p", 2000), 10)) <=
             1600
  end
end
