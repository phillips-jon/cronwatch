defmodule Cronwatch.Alerts.ProvidersTest do
  # The provider channels' own rules, ported from the Rust port's unit tests
  # and tests/alerts.rs: SigV4 against the AWS test suite, DSNs, Datadog
  # sites, addresses, every option refused with its message, and no
  # credential in what Inspect prints.
  use ExUnit.Case, async: true

  alias Cronwatch.Alert
  alias Cronwatch.Alerts
  alias Cronwatch.Alerts.Email
  alias Cronwatch.Alerts.SigV4
  alias Cronwatch.ChannelContext
  alias Cronwatch.JS
  alias Cronwatch.Test.RecordingTransport

  # Cases from the AWS Signature Version 4 test suite, as the SDK's
  # sigv4.test.ts has them: service "service", region us-east-1, the example
  # credentials, 2015-08-30T12:36:00Z.
  test "signatures match the AWS test suite" do
    scope = "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request"

    token =
      "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA=="

    cases = [
      {"GET", "https://example.amazonaws.com/", [], "", "host;x-amz-date",
       "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"},
      {"POST", "https://example.amazonaws.com/", [], "", "host;x-amz-date",
       "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"},
      {"GET", "https://example.amazonaws.com/?Param2=value2&Param1=value1", [], "", "host;x-amz-date",
       "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"},
      {"POST", "https://example.amazonaws.com/", [{"My-Header1", "VALUE1"}], "", "host;my-header1;x-amz-date",
       "cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d"},
      {"POST", "https://example.amazonaws.com/", [], token, "host;x-amz-date;x-amz-security-token",
       "85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead"}
    ]

    for {method, url, headers, session, signed, signature} <- cases do
      credentials = %{
        access_key_id: "AKIDEXAMPLE",
        # Joined here, so the example key does not sit whole in the source.
        secret_access_key: Enum.join(["wJalrXUtnFEMI", "K7MDENG+bPxRfiCYEXAMPLEKEY"], "/"),
        session_token: session
      }

      request = %{
        method: method,
        url: url,
        headers: headers,
        body: "",
        region: "us-east-1",
        service: "service",
        now: 1_440_938_160_000
      }

      {:ok, got} = SigV4.sign(request, credentials)
      get = fn name -> List.keyfind(got, name, 0) |> then(&(&1 && elem(&1, 1))) end

      assert get.("authorization") ==
               "AWS4-HMAC-SHA256 #{scope}, SignedHeaders=#{signed}, Signature=#{signature}",
             "#{method} #{url}"

      assert get.("x-amz-date") == "20150830T123600Z"
      assert get.("host") == nil, "host is signed, not returned; the HTTP client sets it"
      if session != "", do: assert(get.("x-amz-security-token") == session)
    end

    assert SigV4.sign(%{url: "no url", method: "POST", headers: [], body: "", region: "r", service: "s", now: 0}, %{}) ==
             {:error, "cannot sign a request to an invalid URL"}
  end

  test "DSNs are read as the SDK reads them" do
    assert Alerts.Sentry.parse_dsn("https://pub%20key@sentry.example.com:9000/a/b/7") ==
             {:ok, "https://sentry.example.com:9000/a/b/api/7/envelope/", "pub key"}

    assert {:ok, "https://o1.ingest.sentry.io/api/42/envelope/", "k"} =
             Alerts.Sentry.parse_dsn("https://k@o1.ingest.sentry.io:443/42")

    assert Alerts.Sentry.parse_dsn("not a url") == {:error, "Cronwatch.Alerts.Sentry needs a valid :dsn"}

    assert Alerts.Sentry.parse_dsn("https://o1.ingest.sentry.io/42") ==
             {:error, "Cronwatch.Alerts.Sentry needs a :dsn like https://<key>@<host>/<project>"}

    assert {:error, _} = Alerts.Sentry.parse_dsn("https://k@o1.ingest.sentry.io/x")
  end

  test "Datadog sites are read as the SDK reads them" do
    assert Alerts.Datadog.clean_site("https://app.datadoghq.eu/") == "datadoghq.eu"
    assert Alerts.Datadog.clean_site("api.us5.datadoghq.com") == "us5.datadoghq.com"
    assert Alerts.Datadog.clean_site("HTTPS://datadoghq.com") == "HTTPS://datadoghq.com"

    assert Alerts.Datadog.init(api_key: "k", site: "evil.example/x?") ==
             {:error, ~s(Cronwatch.Alerts.Datadog needs :site like "datadoghq.com")}
  end

  test "addresses split as the SDK splits them" do
    json = &JS.stringify(Email.parse_address(&1))
    assert json.("ops@example.com") == ~s({"email":"ops@example.com"})
    assert json.(" Ops <ops@example.com> ") == ~s({"email":"ops@example.com","name":"Ops"})
    assert json.(~s("Ops, Team" <ops@example.com>)) == ~s({"email":"ops@example.com","name":"Ops, Team"})
    assert json.("<ops@example.com>") == ~s({"email":"ops@example.com"})
    assert json.("a <b> <c@d>") == ~s({"email":"c@d","name":"a <b>"})
    assert json.("x\ny <c@d>") == ~s({"email":"x\\ny <c@d>"})
    assert Email.one_line("a\r\n\nb\rc") == "a b c"
    assert Email.safe_link("HTTPS://x") == "HTTPS://x"
    assert Email.safe_link("javascript:alert(1)") == ""
  end

  test "every option the SDK refuses is refused, with its message" do
    email = [from: "a@example.com", to: "b@example.com"]
    refused = fn module, opts -> elem(module.init(opts), 1) end

    assert refused.(Alerts.Resend, email) == "Cronwatch.Alerts.Resend needs :api_key"
    assert refused.(Alerts.Resend, [api_key: " \n"] ++ email) == "Cronwatch.Alerts.Resend needs :api_key"
    assert refused.(Alerts.Resend, api_key: "k", to: "b@example.com") == "Cronwatch.Alerts.Resend needs a :from address"
    assert refused.(Alerts.Resend, api_key: "k", from: "a@x", to: [" ", nil]) =~ "needs at least one :to address"
    assert refused.(Alerts.Postmark, email) == "Cronwatch.Alerts.Postmark needs :server_token"
    assert refused.(Alerts.SendGrid, email) == "Cronwatch.Alerts.SendGrid needs :api_key"
    assert refused.(Alerts.Mailgun, email) == "Cronwatch.Alerts.Mailgun needs :api_key"
    assert refused.(Alerts.Mailgun, [api_key: "k"] ++ email) == "Cronwatch.Alerts.Mailgun needs :domain"
    assert refused.(Alerts.SES, email) == "Cronwatch.Alerts.SES needs :region"
    assert refused.(Alerts.SES, [region: "US East"] ++ email) == ~s(Cronwatch.Alerts.SES needs :region like "us-east-1")

    assert refused.(Alerts.SES, [region: "us-east-1", access_key_id: "a"] ++ email) ==
             "Cronwatch.Alerts.SES needs :access_key_id and :secret_access_key"

    assert refused.(Alerts.Twilio, []) == "Cronwatch.Alerts.Twilio needs :account_sid"

    assert refused.(Alerts.Twilio, account_sid: "AC1", api_key_sid: "SK1", auth_token: "t") ==
             "Cronwatch.Alerts.Twilio needs :auth_token, or :api_key_sid and :api_key_secret"

    assert refused.(Alerts.Twilio, account_sid: "AC1", auth_token: "t") ==
             "Cronwatch.Alerts.Twilio needs a :from number or a :messaging_service_sid"

    assert refused.(Alerts.Twilio, account_sid: "AC1", auth_token: "t", from: "+1", to: ["", " "]) ==
             "Cronwatch.Alerts.Twilio needs at least one :to number"

    assert refused.(Alerts.Sentry, []) == "Cronwatch.Alerts.Sentry needs :dsn"
    assert refused.(Alerts.Honeybadger, []) == "Cronwatch.Alerts.Honeybadger needs :api_key"
    assert refused.(Alerts.Datadog, []) == "Cronwatch.Alerts.Datadog needs :api_key"
    assert refused.(Alerts.Rollbar, []) == "Cronwatch.Alerts.Rollbar needs :access_token"
    assert refused.(Alerts.Bugsnag, []) == "Cronwatch.Alerts.Bugsnag needs :api_key"
    assert refused.(Alerts.NewRelic, []) == "Cronwatch.Alerts.NewRelic needs :api_key"

    assert refused.(Alerts.NewRelic, api_key: "k", account_id: "12a") ==
             "Cronwatch.Alerts.NewRelic needs a numeric :account_id"

    assert refused.(Alerts.NewRelic, api_key: "k") == "Cronwatch.Alerts.NewRelic needs a numeric :account_id"
    assert refused.(Alerts.Rollbar, access_token: "t", recovered: "no") =~ "needs :recovered to be true or false"
    assert refused.(Alerts.Rollbar, access_token: "t", link: "https://x") =~ "needs :link to be a function"
    assert refused.(Alerts.Bugsnag, api_key: "k", now: 5) =~ "needs :now to be a function"

    assert refused.(Alerts.Rollbar, %{access_token: "secret-token"}) ==
             "Cronwatch.Alerts.Rollbar takes a keyword list of options"

    assert refused.(Alerts.Rollbar, access_token: "t", transport: "x") =~ "transport"

    # An instance refuses the channel when it starts, with the same message.
    assert {:error, %Cronwatch.Error{kind: :invalid, message: "Cronwatch.Alerts.Resend needs :api_key"}} =
             Cronwatch.Config.new(alerts: [{Alerts.Resend, email}])
  end

  test "nothing a channel holds prints a credential" do
    email = [from: "a@example.com", to: "b@example.com"]

    channels = [
      {Alerts.Resend, [api_key: "re_hidden_1"] ++ email},
      {Alerts.Postmark, [server_token: "pm_hidden_1"] ++ email},
      {Alerts.SendGrid, [api_key: "sg_hidden_1"] ++ email},
      {Alerts.Mailgun, [api_key: "mg_hidden_1", domain: "mg.example.com"] ++ email},
      {Alerts.SES,
       [
         region: "us-east-1",
         access_key_id: "AKIDEXAMPLE",
         secret_access_key: "ses_hidden_1",
         session_token: "st_hidden_1"
       ] ++
         email},
      {Alerts.Twilio, account_sid: "AC1", auth_token: "tw_hidden_1", from: "+15005550006", to: "+15551110000"},
      {Alerts.Sentry, dsn: "https://sn_hidden_1@o0.ingest.example.com/7"},
      {Alerts.Honeybadger, api_key: "hb_hidden_1"},
      {Alerts.Datadog, api_key: "dd_hidden_1"},
      {Alerts.Rollbar, access_token: "rb_hidden_1"},
      {Alerts.Bugsnag, api_key: "bs_hidden_1"},
      {Alerts.NewRelic, api_key: "nr_hidden_1", account_id: 12_345}
    ]

    for {module, opts} <- channels do
      {:ok, state} = module.init(opts)
      printed = inspect(state, limit: :infinity, printable_limit: :infinity)
      refute printed =~ "hidden", "#{inspect(module)} printed a credential: #{printed}"
    end

    # Twilio's basic auth holds the token too, base64'd.
    {:ok, twilio} = Alerts.Twilio.init(account_sid: "AC1", auth_token: "tw_hidden_1", from: "+1", to: "+1")
    refute inspect(twilio) =~ Base.encode64("AC1:tw_hidden_1")
  end

  test "credentials are trimmed of what a paste leaves" do
    rec = RecordingTransport.start()
    {:ok, s} = Alerts.Rollbar.init(access_token: " \trb-token\n", transport: RecordingTransport.spec(rec))
    :ok = Alerts.Rollbar.send(s, alert("failed"), %ChannelContext{on_error: & &1})
    [request] = RecordingTransport.taken(rec)
    assert List.keyfind(request.headers, "x-rollbar-access-token", 0) == {"x-rollbar-access-token", "rb-token"}
  end

  test "recoveries follow each channel's default and the recovered option" do
    rec = RecordingTransport.start()
    t = RecordingTransport.spec(rec)
    ctx = %ChannelContext{on_error: & &1}

    sent? = fn module, opts ->
      RecordingTransport.answer_with(rec, 200, "")
      {:ok, s} = module.init(opts ++ [transport: t])
      :ok = module.send(s, alert("recovered"), ctx)
      RecordingTransport.taken(rec) != []
    end

    assert sent?.(Alerts.Sentry, dsn: "https://k@o0.ingest.example.com/7")
    refute sent?.(Alerts.Sentry, dsn: "https://k@o0.ingest.example.com/7", recovered: false)
    assert sent?.(Alerts.Rollbar, access_token: "t")
    refute sent?.(Alerts.Rollbar, access_token: "t", recovered: false)
    refute sent?.(Alerts.Honeybadger, api_key: "k")
    assert sent?.(Alerts.Honeybadger, api_key: "k", recovered: true)
    refute sent?.(Alerts.Bugsnag, api_key: "k")
    assert sent?.(Alerts.Bugsnag, api_key: "k", recovered: true)
    refute sent?.(Alerts.Twilio, account_sid: "AC1", auth_token: "t", from: "+1", to: "+2")
    assert sent?.(Alerts.Twilio, account_sid: "AC1", auth_token: "t", from: "+1", to: "+2", recovered: true)
    assert sent?.(Alerts.Datadog, api_key: "k")
    assert sent?.(Alerts.NewRelic, api_key: "k", account_id: "1")
  end

  test "email options may be given under email:, and the channel sends them" do
    rec = RecordingTransport.start()

    {:ok, s} =
      Alerts.Resend.init(
        api_key: "k",
        email: [from: "a@example.com", to: ["b@example.com"], subject_prefix: "[x]"],
        transport: RecordingTransport.spec(rec)
      )

    :ok = Alerts.Resend.send(s, alert("failed"), %ChannelContext{on_error: & &1})
    [request] = RecordingTransport.taken(rec)
    body = JS.parse!(IO.iodata_to_binary(request.body))
    assert JS.Object.get(body, "subject") == "[x] nightly failed"
  end

  test "Twilio fails with every number's refusal counted, and a raise in the transport is that number's failure" do
    defmodule Raising do
      @behaviour Cronwatch.Transport
      @impl true
      def post(_opts, request) do
        if IO.iodata_to_binary(request.body) =~ "To=%2B2",
          do: raise("boom"),
          else: {:ok, %Cronwatch.Transport.Response{status: 201, body: "{}"}}
      end
    end

    {:ok, reported} = Agent.start_link(fn -> [] end)
    ctx = %ChannelContext{on_error: fn e -> Agent.update(reported, &[Cronwatch.Error.describe(e) | &1]) end}

    {:ok, s} = Alerts.Twilio.init(account_sid: "AC1", auth_token: "t", from: "+1", to: ["+1", "+2"], transport: Raising)
    assert Alerts.Twilio.send(s, alert("failed"), ctx) == :ok
    assert [message] = Agent.get(reported, & &1)
    assert message =~ "boom"
    assert message =~ "(to +2; 1 of 2 numbers took the alert)"

    rec = RecordingTransport.start()
    RecordingTransport.answer_with(rec, 500, "no")

    {:ok, s} =
      Alerts.Twilio.init(
        account_sid: "AC1",
        auth_token: "t",
        from: "+1",
        to: ["+15551110000", "+15552220000"],
        transport: RecordingTransport.spec(rec)
      )

    assert {:error, e} = Alerts.Twilio.send(s, alert("failed"), ctx)
    assert Cronwatch.Error.describe(e) == "Twilio https://api.twilio.com answered 500: no (2 of 2 numbers failed)"
  end

  test "SMS bodies keep the link whole and fit the segments" do
    a = %{alert("failed") | message: String.duplicate("line of output\n", 200)}
    body = Alerts.Twilio.body_of(a, "https://app.example/j", 2)
    assert String.ends_with?(body, "\nhttps://app.example/j")
    assert Alerts.Twilio.segments_of(body) <= 2
    assert Alerts.Twilio.segments_of("") == 1
    assert Alerts.Twilio.segments_of(String.duplicate("a", 160)) == 1
    assert Alerts.Twilio.segments_of(String.duplicate("a", 161)) == 2
    assert Alerts.Twilio.segments_of(String.duplicate("é", 70)) == 1
    assert Alerts.Twilio.segments_of(String.duplicate("ж", 71)) == 2
    # Through apply/3: max_segments/0 is deprecated, internal to the channel.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    assert apply(Alerts.Twilio, :max_segments, []) == 10
  end

  defp alert(type) do
    details =
      case type do
        "recovered" -> %{after: ["failed"], reason: nil, since: nil}
        _ -> %{consecutive_failures: 1, threshold: 1}
      end

    %Alert{
      type: type,
      details: details,
      job: "nightly",
      title: "nightly #{type}",
      message: "Started 2026-01-05 09:30:00 UTC",
      at: 1_767_605_402_000
    }
  end
end
