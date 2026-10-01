# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# The SDK's channel tests (alerts.test.ts), plus the real Net::HTTP path
# against a local socket.
class AlertsTest < Minitest::Test
  include TestHelpers

  # Stands in for Net::HTTP, recording each request.
  class FakeHTTP
    attr_reader :calls

    def initialize(status = 200, body = "")
      @status = status
      @body = body
      @calls = []
    end

    def post(url, body, headers)
      # Ruby's parser refuses a lone surrogate, which JSON.stringify writes.
      json = begin
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
      @calls << { url: url, body: body, json: json, headers: headers }
      Cronwatch::HTTP::Response.new(status: @status, body: @body)
    end
  end

  RUN = Cronwatch::Run.new(
    id: "r1", job: "j", status: :failed, started_at: T0, finished_at: T0 + 1000, duration_ms: 1000, error: "Error: boom",
    output: "before\n```\n@everyone <!channel> [click](https://evil.example)", metrics: {}, trigger: "run",
  )

  def alert(triage: nil)
    draft = Cronwatch::AlertDraft.new(type: :failed, run: RUN, details: { consecutive_failures: 1, threshold: 1 })
    Cronwatch::Format.compose_alert(draft, Cronwatch::JobDefinition.new(name: "j"), T0 + 2000).tap { |a| a.triage = triage }
  end

  def test_discord_keeps_job_output_inside_its_code_block_and_pings_no_one
    http = FakeHTTP.new
    Cronwatch::Alerts::Discord.new(webhook_url: "https://discord.example/api/webhooks/1/secret", http: http)
                              .call(alert(triage: "See [the docs](https://evil.example) *now*"))
    body = http.calls[0][:json]
    assert_equal({ "parse" => [] }, body["allowed_mentions"])
    description = body["embeds"][0]["description"]
    assert_equal 2, description.scan("```").length, "only the block's own fences"
    assert_includes description, '**Triage:** See \\[the docs\\]\\(https://evil.example\\) \\*now\\*'
    assert_equal %w[content allowed_mentions embeds], body.keys
    assert_equal %w[title description color timestamp], body["embeds"][0].keys
    assert_equal "2026-01-05T09:30:02.000Z", body["embeds"][0]["timestamp"]
    assert_equal 0xc62828, body["embeds"][0]["color"]
    assert_equal "application/json", http.calls[0][:headers]["content-type"]
  end

  def test_discord_holds_the_whole_description_to_4096_cutting_the_message_and_keeping_the_triage
    http = FakeHTTP.new
    message = "Error: long\n#{"```" * 1200}#{"x" * 400}#{"\u{1F600}" * 200}"
    triage = "*_`~|[]()<>\\" * 100
    long = alert(triage: triage).tap { |a| a.message = message }
    Cronwatch::Alerts::Discord.new(webhook_url: "https://discord.example/api/webhooks/1/secret", http: http).call(long)
    embed = http.calls[0][:json]["embeds"][0]
    description = embed["description"]
    assert_equal 4096, Cronwatch::JS.length16(description)
    assert description.end_with?("\n**Triage:** #{triage[0, 1000].gsub(/[\\`*_~|\[\]()<>]/) { |c| "\\#{c}" }}"), "the triage is whole"
    assert description.start_with?("```\nError: long\n")
    assert_equal 2, description.scan("```").length, "only the block's own fences"
    assert_operator Cronwatch::JS.length16(embed["title"]) + 4096, :<=, 6000
  end

  # String#slice keeps the high half of a pair it cuts, and JSON.stringify
  # writes it as \ud83d, so the gem sends that too.
  def test_discord_keeps_the_lone_high_surrogate_where_its_caps_cut_a_pair_as_the_sdk_does
    http = FakeHTTP.new
    channel = Cronwatch::Alerts::Discord.new(webhook_url: "https://discord.example/w", http: http)
    channel.call(alert.tap { |a| a.message = "#{"a" * 3799}\u{1F600}" })
    assert_includes http.calls[0][:body], "\"description\":\"```\\n#{"a" * 3799}\\ud83d\\n```\""
    channel.call(alert(triage: "#{"b" * 999}\u{1F600}x").tap { |a| a.message = "m" })
    assert_includes http.calls[1][:body], "\"description\":\"```\\nm\\n```\\n**Triage:** #{"b" * 999}\\ud83d\""
    # A message long enough to be cut again for the triage's room loses the lone half there, as the SDK's cut does.
    channel.call(alert(triage: "t" * 1000).tap { |a| a.message = "#{"a" * 3799}\u{1F600}" })
    description = http.calls[2][:json]["embeds"][0]["description"]
    assert_equal "```\n#{"a" * (4096 - 8 - 1013)}\n```\n**Triage:** #{"t" * 1000}", description
  end

  def test_discord_adds_the_link_and_reports_a_refusal
    http = FakeHTTP.new(400, "x" * 500)
    channel = Cronwatch::Alerts::Discord.new(webhook_url: "https://discord.example/w", link: ->(a) { "https://app.example/#{a.job}" }, http: http)
    error = assert_raises(RuntimeError) { channel.call(alert) }
    assert_equal "Discord webhook answered 400: #{"x" * 200}", error.message
    assert_equal "https://app.example/j", http.calls[0][:json]["embeds"][0]["url"]
  end

  def test_slack_escapes_control_characters_and_fences_in_the_blocks_and_the_fallback_text
    http = FakeHTTP.new
    Cronwatch::Alerts::Slack.new(webhook_url: "https://hooks.slack.example/T/B/secret", http: http).call(alert(triage: "<b> & co"))
    body = http.calls[0][:json]
    refute_match(/<!channel>/, body["text"])
    block = body["blocks"][1]["text"]["text"]
    assert_equal 2, block.scan("```").length
    assert_match(/&lt;!channel&gt;/, block)
    assert_match(/```\z/, block)
    assert_equal "_Triage:_ &lt;b&gt; &amp; co", body["blocks"][2]["text"]["text"]
    assert_equal ":x: *j failed*", body["blocks"][0]["text"]["text"]
  end

  def test_slack_link_and_failure
    http = FakeHTTP.new(500, "no")
    channel = Cronwatch::Alerts::Slack.new(webhook_url: "https://hooks.slack.example/x", link: ->(_) { "https://app.example/j" }, http: http)
    assert_equal "Slack webhook answered 500: no", assert_raises(RuntimeError) { channel.call(alert) }.message
    assert_equal ":x: *j failed* (<https://app.example/j|open>)", http.calls[0][:json]["blocks"][0]["text"]["text"]
  end

  def test_webhook_failures_name_the_origin_not_the_secret_path
    http = FakeHTTP.new(500)
    error = assert_raises(RuntimeError) do
      Cronwatch::Alerts::Webhook.new(url: "https://hooks.example.com/services/s3cret-token?key=abc", http: http).call(alert)
    end
    assert_equal "Webhook https://hooks.example.com answered 500", error.message
    assert_equal "http://localhost:8080", Cronwatch::Alerts::Webhook.origin("http://user:pw@LOCALHOST:8080/x")
    assert_equal "(invalid URL)", Cronwatch::Alerts::Webhook.origin("not a url")
  end

  def test_webhook_signs_the_raw_body_and_sends_the_alert_as_the_sdk_does
    http = FakeHTTP.new
    Cronwatch::Alerts::Webhook.new(url: "https://hooks.example.com/cw", secret: "s3cret", headers: { "x-team" => "billing" }, http: http)
                              .call(alert(triage: "db"))
    call = http.calls[0]
    assert_equal "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "s3cret", call[:body])}", call[:headers]["x-cronwatch-signature"]
    assert_equal "sha256=#{Cronwatch::Alerts::Webhook.signature("s3cret", call[:body])}", call[:headers]["x-cronwatch-signature"]
    assert_equal "cronwatch", call[:headers]["user-agent"]
    assert_equal "billing", call[:headers]["x-team"]
    assert_equal %w[schema type run details job definition title message at triage], call[:json].keys
    assert_equal 1, call[:json]["schema"]
    assert_equal({ "consecutiveFailures" => 1, "threshold" => 1 }, call[:json]["details"])
    assert_equal call[:body], Cronwatch::JS.json({ "schema" => 1 }.merge(alert(triage: "db").to_h))
  end

  def test_channels_need_their_url
    assert_raises(ArgumentError) { Cronwatch::Alerts::Slack.new(webhook_url: "") }
    assert_raises(ArgumentError) { Cronwatch::Alerts::Discord.new(webhook_url: nil) }
    assert_raises(ArgumentError) { Cronwatch::Alerts::Webhook.new(url: "") }
    assert_raises(ArgumentError) { Cronwatch::Alerts::Custom.new("x") }
  end

  def test_console_writes_recoveries_to_stdout_and_the_rest_to_stderr
    out = StringIO.new
    err = StringIO.new
    console = Cronwatch::Alerts::Console.new(out: out, err: err)
    console.call(alert(triage: "db"))
    recovered = Cronwatch::Format.compose_alert(Cronwatch::AlertDraft.new(type: :recovered, run: nil, details: { after: [:failed] }),
                                                Cronwatch::JobDefinition.new(name: "j"), T0)
    console.call(recovered)
    assert_equal "[cronwatch] j failed\n#{alert.message}\nTriage: db\n", err.string
    assert_equal "[cronwatch] j recovered\nA run just now succeeded after: failed.\n", out.string
  end

  # One request to a real socket: Net::HTTP, the headers and the body as sent.
  def test_the_default_http_adapter_posts_to_a_real_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    received = Queue.new
    thread = Thread.new do
      client = server.accept
      head = +""
      head << client.gets until head.end_with?("\r\n\r\n")
      length = head[/content-length: (\d+)/i, 1].to_i
      received << [head, client.read(length)]
      client.write("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
      client.close
    end
    Cronwatch::Alerts::Webhook.new(url: "http://127.0.0.1:#{port}/hook?key=abc", secret: "k").call(alert)
    head, body = received.pop
    assert_match(%r{\APOST /hook\?key=abc HTTP/1\.1\r\n}, head)
    assert_match(/^content-type: application\/json\r$/i, head)
    assert_match(/^x-cronwatch-signature: sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "k", body)}\r$/i, head)
    assert_equal Cronwatch::JS.json({ "schema" => 1 }.merge(alert.to_h)).b, body
  ensure
    thread&.join(1)
    server&.close
  end

  def test_the_default_http_adapter_gives_up_after_ten_seconds
    http = Cronwatch::HTTP::NetHTTP.new.connection(URI("https://hooks.example.com/x"))
    assert_equal 10, http.open_timeout
    assert_equal 10, http.read_timeout
    assert_equal 10, http.write_timeout
    assert http.use_ssl?
  end

  # A local server that answers `head` and then drips `bytes` one every `every` seconds.
  def dripping_server(head, bytes, every)
    server = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      client = server.accept
      client.readpartial(4096)
      client.write(head)
      bytes.times do
        sleep every
        client.write("x")
      end
      client.close
    rescue StandardError
      nil
    end
    server
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # The deadline is the whole request's, as AbortSignal.timeout(10_000) is:
  # a body dripping in under each read timeout still stops at the deadline,
  # and the status is kept with an empty body, as the SDK reads it.
  def test_the_default_http_adapter_has_a_whole_request_deadline
    server = dripping_server("HTTP/1.1 500 Oops\r\nContent-Length: 30\r\nConnection: close\r\n\r\n", 30, 0.2)
    response = nil
    took = elapsed { response = Cronwatch::HTTP::NetHTTP.new(timeout: 1).post("http://127.0.0.1:#{server.addr[1]}/", "{}", {}) }
    assert_operator took, :<, 2.5
    assert_equal 500, response.status
    assert_equal "", response.body
  ensure
    server&.close
  end

  # A server that answers `status` and then sends body bytes as fast as it
  # can, without end, until the client goes.
  def flooding_server(status)
    server = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      client = server.accept
      client.readpartial(4096)
      client.write("HTTP/1.1 #{status} X\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n")
      chunk = "x" * 65_536
      loop { client.write(chunk) }
    rescue StandardError
      nil
    ensure
      client&.close
    end
    server
  end

  # A hostile or broken endpoint that never stops sending cannot fill the
  # worker's memory or hold it until the deadline: an answer outside 2xx is
  # read to MAX_BODY (1 MiB) and no further, and a 2xx answer's body is not
  # read at all, since no channel needs it.
  def test_the_default_http_adapter_caps_the_body_it_reads_and_skips_a_2xx_body
    [[500, Cronwatch::HTTP::MAX_BODY], [200, 0]].each do |status, size|
      server = flooding_server(status)
      response = nil
      took = elapsed { response = Cronwatch::HTTP::NetHTTP.new(timeout: 8).post("http://127.0.0.1:#{server.addr[1]}/", "{}", {}) }
      assert_operator took, :<, 4, "#{status}: stops reading long before the deadline"
      assert_equal status, response.status
      assert_equal size, response.body.bytesize, status.to_s
    ensure
      server&.close
    end
    assert_equal 1_048_576, Cronwatch::HTTP::MAX_BODY
  end

  def test_the_default_http_adapter_raises_when_no_answer_comes_before_the_deadline
    server = TCPServer.new("127.0.0.1", 0)
    held = []
    thread = Thread.new { loop { held << server.accept } }
    error = nil
    took = elapsed do
      error = assert_raises(Cronwatch::HTTP::TimeoutError) do
        Cronwatch::HTTP::NetHTTP.new(timeout: 0.5).post("http://127.0.0.1:#{server.addr[1]}/", "{}", {})
      end
    end
    assert_operator took, :<, 2
    assert_equal "The operation was aborted due to timeout", error.message
  ensure
    thread&.kill
    held&.each(&:close)
    server&.close
  end

  # fetch trims the whitespace around a header value; a credential read with
  # a trailing newline must not make every send raise.
  def test_the_default_http_adapter_trims_header_values
    server = TCPServer.new("127.0.0.1", 0)
    received = Queue.new
    thread = Thread.new do
      client = server.accept
      head = +""
      head << client.gets until head.end_with?("\r\n\r\n")
      received << head
      client.write("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
      client.close
    end
    response = Cronwatch::HTTP.default.post("http://127.0.0.1:#{server.addr[1]}/", "{}",
                                            { "authorization" => " Bearer abc\n", "x-key" => "\tk\r\n" })
    assert_equal 204, response.status
    head = received.pop
    assert_match(/^authorization: Bearer abc\r$/i, head)
    assert_match(/^x-key: k\r$/i, head)
  ensure
    thread&.join(1)
    server&.close
  end
end
