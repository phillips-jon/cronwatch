# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# packages/sdk/test/channels-hardening.test.ts: secrets cut out of error
# bodies before the cut, no redirect followed, Twilio texting every number at
# once, SMS and subject cuts, and trimmed credentials.
class ChannelsHardeningTest < Minitest::Test
  include TestHelpers

  A = Cronwatch::Alerts

  class FakeHTTP
    attr_reader :requests

    def initialize(&answer)
      @answer = answer || ->(_url, _body, _headers) { [200, "{}"] }
      @requests = []
      @lock = Mutex.new
    end

    def post(url, body, headers)
      @lock.synchronize { @requests << { url: url, body: body, headers: headers } }
      status, text = @answer.call(url, body, headers)
      Cronwatch::HTTP::Response.new(status: status, body: text)
    end
  end

  def failed(title: nil, message: nil)
    alert = Cronwatch::Format.compose_alert(
      Cronwatch::AlertDraft.new(type: :failed, run: nil, details: { consecutive_failures: 1, threshold: 1 }),
      Cronwatch::JobDefinition.new(name: "nightly"), T0,
    )
    alert.title = title unless title.nil?
    alert.message = message unless message.nil?
    alert
  end

  EMAIL = { from: "a@b.c", to: "d@e.f" }.freeze

  def test_a_secret_that_straddles_the_cut_in_a_providers_error_body_is_still_cut_out
    key = "key-0123456789abcdef0123456789abcdef"
    http = FakeHTTP.new { [401, "#{"x" * 180}invalid key #{key}"] }
    error = assert_raises(RuntimeError) { A::Mailgun.new(api_key: key, domain: "mg.example.com", **EMAIL, http: http).call(failed) }
    (0..(key.length - 6)).each { |i| refute_includes error.message, key[i, 6], "a piece of the key survives: #{error.message}" }
    assert_match(/: x{180}invalid key \[redacte\z/, error.message, "cut to 200 after the key was taken out")
    assert_equal "a" * 199, A::Provider.error_body("#{"a" * 199}\u{1F600}tail"), "never half a surrogate pair"
    assert_equal "short", A::Provider.error_body("short")
    assert_equal "#{"y" * 10}[redacted]", A::Provider.error_body("#{"y" * 10}sekret#{"z" * 300}", ["sekret"])[0, 20]
    assert_equal 200, A::Provider.error_body("z" * 300, ["sekret"]).length
  end

  # A server on 127.0.0.1 answering each request with `status` and
  # `headers`, recording what it was sent. Returns [url, requests, server].
  def local_server(status, headers = {})
    server = TCPServer.new("127.0.0.1", 0)
    seen = Queue.new
    Thread.new do
      loop do
        client = server.accept
        head = +""
        head << client.gets until head.end_with?("\r\n\r\n")
        client.read(head[/content-length: (\d+)/i, 1].to_i)
        seen << head
        extra = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
        client.write("HTTP/1.1 #{status} X\r\n#{extra}Content-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      rescue IOError, SystemCallError
        break
      end
    end
    ["http://127.0.0.1:#{server.addr[1]}", seen, server]
  end

  # Net::HTTP never follows a redirect, so a 307 is an answer outside 2xx:
  # an error, and the credentials go nowhere else. The SDK asks fetch for
  # the same with redirect: "error".
  def test_no_channel_follows_a_redirect_so_its_credentials_never_reach_another_origin
    evil_url, evil_seen, evil = local_server(202)
    provider_url, provider_seen, provider = local_server(307, "Location" => "#{evil_url}/steal")
    net = Cronwatch::HTTP::NetHTTP.new(timeout: 5)
    # Every channel's request goes to the redirecting server, whatever its URL.
    http = Object.new
    http.define_singleton_method(:post) { |_url, body, headers| net.post("#{provider_url}/in", body, headers) }
    channels = [
      A::Datadog.new(api_key: "dd-secret-key-123", http: http),
      A::Resend.new(api_key: "re_secret", **EMAIL, http: http),
      A::Postmark.new(server_token: "pm-secret", **EMAIL, http: http),
      A::Sendgrid.new(api_key: "SG.secret", **EMAIL, http: http),
      A::Mailgun.new(api_key: "key-secret", domain: "mg.example.com", **EMAIL, http: http),
      A::Ses.new(region: "us-east-1", access_key_id: "AKIDEXAMPLE", secret_access_key: "sekret-sekret", **EMAIL, http: http),
      A::Twilio.new(account_sid: "AC1", auth_token: "tw-secret", from: "+1", to: "+2", http: http),
      A::Sentry.new(dsn: "https://pubkey@o1.ingest.sentry.io/42", http: http),
      A::Honeybadger.new(api_key: "hb-secret", http: http),
      A::Rollbar.new(access_token: "rb-secret", http: http),
      A::Bugsnag.new(api_key: "bs-secret", http: http),
      A::NewRelic.new(account_id: "1", api_key: "nr-secret", http: http),
      A::Webhook.new(url: "#{provider_url}/in", headers: { "authorization" => "Bearer wh-secret" }, secret: "s", http: http),
      A::Slack.new(webhook_url: "#{provider_url}/in", http: http),
      A::Discord.new(webhook_url: "#{provider_url}/in", http: http),
    ]
    channels.each do |channel|
      error = assert_raises(RuntimeError, "#{channel.name} followed the redirect") { channel.call(failed) }
      assert_match(/answered 307/, error.message)
    end
    assert_equal channels.length, provider_seen.size
    assert_equal 0, evil_seen.size, "nothing reached the other origin"
  ensure
    evil&.close
    provider&.close
  end

  def test_twilio_texts_every_number_at_once_one_taking_it_is_a_delivery_and_the_refusals_are_reported
    sent = []
    http = FakeHTTP.new do |_url, body, _headers|
      to = URI.decode_www_form(body).to_h.fetch("To")
      next [400, '{"code":21211,"message":"Invalid To"}'] if to == "+15550000000"

      sent << to
      [201, "{}"]
    end
    clock = Clock.new(Time.utc(2026, 1, 1).to_i * 1000)
    errors = []
    cw = Cronwatch.new(now: clock.to_proc, cron_secret: nil, on_error: ->(e, where) { errors << "#{where}: #{e.message}" },
                       alerts: [A::Twilio.new(account_sid: "AC1", auth_token: "tok", from: "+15551112222",
                                              to: %w[+15553334444 +15550000000], http: http)])
    cw.job("nightly", schedule: "0 * * * *")
    cw.check
    6.times do
      clock.advance(70 * MIN)
      cw.check
    end
    assert_equal ["+15553334444"], sent, "one SMS for one open missed condition, never resent"
    assert_equal 1, errors.length, errors.inspect
    assert_match(%r{\Aalert channel twilio: Twilio https://api\.twilio\.com answered 400: .*Invalid To.* \(to \*+0000; 1 of 2 numbers took the alert\)\z},
                 errors[0])

    # Every number refusing it is a failure, retried at the next check.
    all_fail = FakeHTTP.new { [500, "no"] }
    error = assert_raises(RuntimeError) do
      A::Twilio.new(account_sid: "AC1", auth_token: "tok", from: "+1", to: %w[+2 +3], http: all_fail).call(failed)
    end
    assert_match(/\(2 of 2 numbers failed\)\z/, error.message)
  end

  def test_twilio_without_a_context_warns_for_each_refusal
    http = FakeHTTP.new { |_url, body, _headers| URI.decode_www_form(body).to_h["To"] == "+15550000000" ? [400, "no"] : [201, "{}"] }
    channel = A::Twilio.new(account_sid: "AC1", auth_token: "tok", from: "+1", to: %w[+15553334444 +15550000000], http: http)
    _, err = capture_io { channel.call(failed) }
    assert_match(/\[cronwatch\] alert channel twilio: Twilio .* \(to \*+0000; 1 of 2 numbers took the alert\)/, err)
  end

  def test_sms_bodies_stay_inside_twilios_1600_characters_and_pack_segments_as_phones_do
    long = failed(title: "j failed", message: "x" * 3000)
    assert_operator A::Twilio.sms_body(long, nil, 12).length, :<=, 1530, "segments capped at 10"
    assert_operator A::Twilio.sms_body(long, nil, Float::NAN).length, :<=, 459, "not a number: the default 3"
    assert_operator A::Twilio.sms_body(long, nil, "5").length, :<=, 459, "not a number: the default 3"
    assert_equal 1, A::Twilio.sms_segments("a" * 160)
    assert_equal 2, A::Twilio.sms_segments("a" * 161)
    assert_equal 3, A::Twilio.sms_segments("#{"a" * 152}{#{"a" * 152}"), "an escape pair never straddles a segment"
    packed = failed(title: "t", message: "#{"a" * 152}{" * 3)
    assert_operator A::Twilio.sms_segments(A::Twilio.sms_body(packed, nil, 3)), :<=, 3
    assert_equal 1, A::Twilio.sms_segments("\u{1F600}" * 35)
    assert_equal 3, A::Twilio.sms_segments("#{"a" * 66}\u{1F600}#{"a" * 66}"), "a surrogate pair never straddles a segment"
    huge = A::Twilio.sms_body(failed(message: "m"), "https://example.com/#{"p" * 2000}", 10)
    assert_operator Cronwatch::JS.length16(huge), :<=, 1600
  end

  def test_text_cut_for_a_subject_never_leaves_half_a_surrogate_pair
    email = A::Email.compose(failed(title: "#{"a" * 249}\u{1F600}"), from: "a@b.c", to: ["d@e.f"])
    assert_equal "a" * 249, email.subject
  end

  def test_credentials_are_trimmed_before_they_go_in_a_header
    http = FakeHTTP.new
    A::Resend.new(api_key: " re_secret\n", **EMAIL, http: http).call(failed)
    A::Postmark.new(server_token: "\tpm-secret ", **EMAIL, http: http).call(failed)
    A::Sendgrid.new(api_key: "SG.secret\n", **EMAIL, http: http).call(failed)
    A::Mailgun.new(api_key: " key-secret ", domain: "mg.example.com", **EMAIL, http: http).call(failed)
    A::Datadog.new(api_key: "dd-secret\n", http: http).call(failed)
    A::Honeybadger.new(api_key: " hb-secret", http: http).call(failed)
    A::Rollbar.new(access_token: "rb-secret \n", http: http).call(failed)
    A::Bugsnag.new(api_key: "bs-secret\n", http: http).call(failed)
    A::NewRelic.new(account_id: "1", api_key: " nr-secret", http: http).call(failed)
    A::Sentry.new(dsn: " https://pubkey@o1.ingest.sentry.io/42\n", http: http).call(failed)
    A::Twilio.new(account_sid: " AC1 ", auth_token: "tok\n", from: "+1", to: "+2", http: http).call(failed)
    A::Ses.new(region: "us-east-1", access_key_id: " AKIDEXAMPLE", secret_access_key: "sekret\n", **EMAIL, http: http).call(failed)
    A::Webhook.new(url: "https://hooks.example.com/in", headers: { "authorization" => " Bearer wh-secret\n" }, http: http).call(failed)
    http.requests.each do |request|
      request[:headers].each { |name, value| assert_equal value.strip, value, "#{name} has spaces around it" }
    end
    headers = http.requests.map { |r| r[:headers] }
    assert_equal "Bearer re_secret", headers[0]["authorization"]
    assert_equal "pm-secret", headers[1]["x-postmark-server-token"]
    assert_equal "dd-secret", headers[4]["dd-api-key"]
    assert_equal "bs-secret", JSON.parse(http.requests[7][:body])["apiKey"]
    assert_equal "https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json", http.requests[10][:url]
    assert_equal "Basic #{["AC1:tok"].pack("m0")}", headers[10]["authorization"]
    assert_match(%r{\AAWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/}, headers[11]["authorization"])
    assert_equal "Bearer wh-secret", headers[12]["authorization"]
    assert_raises(ArgumentError) { A::Resend.new(api_key: "  ", **EMAIL) }
  end

  # The client hands each channel a context whose on_error reaches its own
  # on_error; a custom channel written for call(alert) alone still works.
  def test_channels_get_a_context_and_one_argument_channels_still_work
    errors = []
    seen = []
    two = A::Custom.new("two") do |alert, context|
      seen << alert.type
      context.on_error(RuntimeError.new("one recipient refused it"))
    end
    one = A::Custom.new("one") { |alert| seen << alert.type }
    plain = Class.new do
      def name = "plain"

      def call(alert)
        (@got ||= []) << alert.type
      end

      attr_reader :got
    end.new
    clock = Clock.new
    cw = Cronwatch.new(now: clock.to_proc, cron_secret: nil, alerts: [two, one, plain], on_error: ->(e, where) { errors << "#{where}: #{e.message}" })
    assert_raises(RuntimeError) { cw.run("j") { raise "boom" } }
    assert_equal %i[failed failed], seen
    assert_equal [:failed], plain.got
    assert_equal ["alert channel two: one recipient refused it"], errors
  end
end
