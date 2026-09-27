# frozen_string_literal: true

require_relative "test_helper"

# The provider channels beside the conformance replay (which checks every
# request byte for byte): SigV4 against the AWS test suite, SMS fitting, the
# options each channel refuses, and failures that never name a secret.
class ProviderChannelsTest < Minitest::Test
  include TestHelpers

  A = Cronwatch::Alerts

  class FakeHTTP
    attr_reader :requests

    def initialize(status = 200, body = "")
      @status = status
      @body = body
      @requests = []
    end

    def post(url, body, headers)
      @requests << { url: url, body: body, headers: headers }
      Cronwatch::HTTP::Response.new(status: @status, body: @body)
    end
  end

  def failed(message: "Error: boom", triage: nil)
    run = Cronwatch::Run.new(id: "r1", job: "nightly", status: :failed, started_at: T0, finished_at: T0 + 1000, duration_ms: 1000,
                             error: message, output: nil, metrics: {}, trigger: "run")
    alert = Cronwatch::Format.compose_alert(Cronwatch::AlertDraft.new(type: :failed, run: run, details: { consecutive_failures: 1, threshold: 1 }),
                                            Cronwatch::JobDefinition.new(name: "nightly"), T0 + 2000)
    alert.message = message
    alert.triage_result = triage unless triage.nil?
    alert
  end

  def recovered
    alert = failed
    alert.type = :recovered
    alert
  end

  # ---------------------------------------------------------------- SigV4

  # Cases from the AWS Signature Version 4 test suite, as packages/sdk/test/sigv4.test.ts has them.
  SCOPE = "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request"
  STS_TOKEN = "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/" \
              "qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+" \
              "scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA=="
  SIGV4_CASES = [
    ["get-vanilla", "GET", "https://example.amazonaws.com/", {}, nil,
     "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"],
    ["post-vanilla", "POST", "https://example.amazonaws.com/", {}, nil,
     "SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"],
    ["get-vanilla-query-order-key-case", "GET", "https://example.amazonaws.com/?Param2=value2&Param1=value1", {}, nil,
     "SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"],
    ["post-header-value-case", "POST", "https://example.amazonaws.com/", { "My-Header1" => "VALUE1" }, nil,
     "SignedHeaders=host;my-header1;x-amz-date, Signature=cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d"],
    ["post-sts-header-before", "POST", "https://example.amazonaws.com/", {}, STS_TOKEN,
     "SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead"],
  ].freeze

  def test_sigv4_matches_the_aws_test_suite
    now = Time.utc(2015, 8, 30, 12, 36).to_i * 1000
    SIGV4_CASES.each do |name, method, url, headers, token, authz|
      signed = A::SigV4.sign(method: method, url: url, headers: headers, body: "", region: "us-east-1", service: "service", now: now,
                             access_key_id: "AKIDEXAMPLE", secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", session_token: token)
      assert_equal "AWS4-HMAC-SHA256 #{SCOPE}, #{authz}", signed["authorization"], name
      assert_equal "20150830T123600Z", signed["x-amz-date"], name
      refute signed.key?("host"), "Net::HTTP sets Host itself"
      assert_equal token, signed["x-amz-security-token"] if token
    end
  end

  # ---------------------------------------------------------------- SMS

  def test_sms_bodies_fit_their_segments_and_keep_the_link_whole
    gsm = A::Twilio.sms_body(failed(message: "x" * 2000), "https://app.example/j")
    assert_operator gsm.length, :<=, 459
    assert gsm.end_with?("...\nhttps://app.example/j")
    ucs = A::Twilio.sms_body(failed(message: "\u{1F600}" * 500), nil)
    assert_operator Cronwatch::JS.length16(ucs), :<=, 201
    assert ucs.valid_encoding?
    assert_equal "nightly failed\none\ntwo", A::Twilio.sms_body(failed(message: "one\ntwo"), nil)
    assert_equal "nightly failed\none\nTriage: db down", A::Twilio.sms_body(failed(message: "one", triage: "db down"), nil)
    # The extension table counts two: 80 braces are 160 septets, one segment; 81 are not.
    assert A::Twilio.fits?("{" * 80, 1)
    refute A::Twilio.fits?("{" * 81, 1)
    assert A::Twilio.fits?("é" * 160, 1)
    refute A::Twilio.fits?("ê" * 71, 1), "a character outside GSM-7 makes the message UCS-2"
  end

  def test_twilio_tries_every_number_and_reports_how_many_failed_without_the_token
    http = FakeHTTP.new(400, "tw-token rejected")
    channel = A::Twilio.new(account_sid: "AC123", auth_token: "tw-token", from: "+1", to: ["+2", "+3"], http: http)
    error = assert_raises(RuntimeError) { channel.call(failed) }
    assert_equal "Twilio https://api.twilio.com answered 400: [redacted] rejected (2 of 2 numbers failed)", error.message
    assert_equal 2, http.requests.length
    assert_nil A::Twilio.new(account_sid: "AC1", auth_token: "t", from: "+1", to: "+2", http: http).call(recovered)
    assert_equal 2, http.requests.length, "recoveries are not texted by default"
  end

  # ---------------------------------------------------------------- email

  def test_email_content_and_addresses
    email = A::Email.compose(failed(message: "a <b>\n\"q\""), from: "a@b.c", to: ["x@y.z"], subject_prefix: "[p]\n",
                                                                  link: ->(_a) { "javascript:alert(1)" })
    assert_equal "[p]  nightly failed", email.subject, "one line"
    refute_includes email.html, "javascript:"
    assert_includes email.html, "a &lt;b&gt;\n&quot;q&quot;"
    assert_equal({ "email" => "ops@example.com", "name" => "Ops Team" }, A::Email.parse_address('"Ops Team" <ops@example.com>'))
    assert_equal({ "email" => "ops@example.com" }, A::Email.parse_address(" ops@example.com "))
    assert_equal({ "email" => "ops@example.com" }, A::Email.parse_address("<ops@example.com>"))
  end

  def test_channels_refuse_what_they_cannot_send_with
    {
      -> { A::Resend.new(api_key: "", from: "a@b.c", to: "x@y.z") } => /needs an api_key/,
      -> { A::Resend.new(api_key: "k", from: nil, to: "x@y.z") } => /needs a from address/,
      -> { A::Postmark.new(server_token: "t", from: "a@b.c", to: [" ", nil]) } => /needs at least one to address/,
      -> { A::Mailgun.new(api_key: "k", domain: "", from: "a@b.c", to: "x@y.z") } => /needs a domain/,
      -> { A::Ses.new(region: "US East", access_key_id: "a", secret_access_key: "b", from: "a@b.c", to: "x@y.z") } => /region like us-east-1/,
      -> { A::Ses.new(region: "us-east-1", access_key_id: "a", secret_access_key: "", from: "a@b.c", to: "x@y.z") } => /secret_access_key/,
      -> { A::Twilio.new(account_sid: "AC1", from: "+1", to: "+2") } => /auth_token/,
      -> { A::Twilio.new(account_sid: "AC1", auth_token: "t", to: "+2") } => /from number/,
      -> { A::Sentry.new(dsn: "https://o1.ingest.sentry.io/42") } => /dsn like/,
      -> { A::Sentry.new(dsn: "not a url") } => /valid dsn/,
      -> { A::Datadog.new(api_key: "k", site: "evil.com/x?y") } => /site like/,
      -> { A::NewRelic.new(account_id: "12a", api_key: "k") } => /numeric account_id/,
      -> { A::Rollbar.new(access_token: nil) } => /access_token/,
    }.each do |make, message|
      assert_match message, assert_raises(ArgumentError, message.inspect, &make).message
    end
  end

  def test_sentry_reads_a_dsn
    dsn = A::Sentry.parse_dsn("https://pub@o1.ingest.sentry.io/42")
    assert_equal ["https://o1.ingest.sentry.io/api/42/envelope/", "pub"], [dsn.endpoint, dsn.public_key]
    dsn = A::Sentry.parse_dsn("https://p%40b@sentry.example.com:9000/prefix/7")
    assert_equal ["https://sentry.example.com:9000/prefix/api/7/envelope/", "p@b"], [dsn.endpoint, dsn.public_key]
  end

  def test_the_alert_id_is_stable_and_every_failure_hides_the_secret
    assert_equal Cronwatch::Alerts::Provider.alert_id(failed), Cronwatch::Alerts::Provider.alert_id(failed(message: "other"))
    http = FakeHTTP.new(401, "bad key hb-secret given")
    error = assert_raises(RuntimeError) { A::Honeybadger.new(api_key: "hb-secret", http: http).call(failed) }
    assert_equal "Honeybadger https://api.honeybadger.io answered 401: bad key [redacted] given", error.message
  end

  def test_a_channel_sends_through_the_client_like_any_other
    http = FakeHTTP.new
    client, clock, = make(alerts: [A::Datadog.new(api_key: "dd", http: http)])
    job = client.job("nightly")
    assert_raises(RuntimeError) { job.run { raise "boom" } }
    clock.advance(1)
    assert_equal 1, http.requests.length
    assert_equal "https://api.datadoghq.com/api/v1/events", http.requests[0][:url]
    assert_equal "error", Cronwatch::JS.parse(http.requests[0][:body])["alert_type"]
  end
end
