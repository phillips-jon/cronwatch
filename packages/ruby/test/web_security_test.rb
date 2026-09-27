# frozen_string_literal: true

require_relative "web/helpers"

# The SDK's routes security tests (routes-security.test.ts), against Cronwatch::Web.
class WebSecurityTest < Minitest::Test
  include WebHelpers

  FORM = { "content-type" => "application/x-www-form-urlencoded" }.freeze

  def app(on_error: nil)
    options = on_error ? { on_error: on_error } : {}
    cw, clock, = make(**options)
    web = Cronwatch::Web.new(cw, token: "tok", base_path: "/cronwatch")
    [cw, clock, ->(method, path, headers = {}, body = nil) { send_request(web, method, path, headers, body) }]
  end

  def test_cross_site_writes_are_refused_whatever_the_credentials
    cw, _, send = app
    cw.run("x") { nil }
    foreign = [
      { "origin" => "https://evil.example" },
      { "origin" => "null" },
      { "sec-fetch-site" => "cross-site" },
      { "sec-fetch-site" => "same-site" },
      { "origin" => "http://app.test", "sec-fetch-site" => "cross-site" },
    ]
    foreign.each do |headers|
      assert_equal 403, send.call("POST", "/cronwatch/jobs/x/silence", COOKIE.merge(FORM, headers), "for=1h").status, headers.inspect
      assert_equal 403, send.call("POST", "/cronwatch/api/check", BEARER.merge(headers)).status, headers.inspect
      assert_equal 403, send.call("DELETE", "/cronwatch/api/jobs/x", COOKIE.merge(headers)).status, headers.inspect
    end
    refute_nil cw.job_summary("x")
    assert_nil cw.job_summary("x").silenced_until
  end

  def test_same_origin_forms_and_header_less_api_clients_still_write
    cw, _, send = app
    cw.run("x") { nil }
    same_origin = { "origin" => "http://app.test", "sec-fetch-site" => "same-origin", "referer" => "http://app.test/cronwatch/jobs/x" }
    check = send.call("POST", "/cronwatch/check", COOKIE.merge(same_origin))
    assert_equal 303, check.status, "the dashboard's Run check now button"
    silence = send.call("POST", "/cronwatch/jobs/x/silence", COOKIE.merge(same_origin, FORM), "for=4h")
    assert_equal 303, silence.status
    assert_equal "http://app.test/cronwatch/jobs/x", silence.headers["location"]
    assert_equal 200, send.call("POST", "/cronwatch/api/jobs/x/unsilence", BEARER).status
    assert_equal 200, send.call("POST", "/cronwatch/api/check", BEARER.merge("sec-fetch-site" => "none")).status
  end

  def test_get_api_check_runs_only_for_a_bearer_cookies_must_post
    _, _, send = app
    via_cookie = send.call("GET", "/cronwatch/api/check", COOKIE)
    assert_equal 405, via_cookie.status
    assert_equal "POST", via_cookie.headers["allow"]
    assert_equal 200, send.call("POST", "/cronwatch/api/check", COOKIE).status
    assert_equal 200, send.call("GET", "/cronwatch/api/check", BEARER).status
  end

  def test_token_query_is_only_accepted_on_an_html_get
    cw, _, send = app
    cw.run("x") { nil }
    assert_equal 401, send.call("GET", "/cronwatch/api/jobs?token=tok").status
    assert_equal 401, send.call("GET", "/cronwatch/api/jobs/x?token=tok").status
    assert_equal 401, send.call("POST", "/cronwatch/api/check?token=tok").status
    assert_equal 401, send.call("POST", "/cronwatch/check?token=tok").status
    assert_equal 401, send.call("POST", "/cronwatch/jobs/x/forget?token=tok").status
    refute_nil cw.job_summary("x")
    assert_equal 303, send.call("GET", "/cronwatch/jobs/x?token=tok").status
  end

  def test_malformed_cookies_and_paths_are_answered_not_raised
    _, _, send = app
    assert_equal 401, send.call("GET", "/cronwatch/", { "cookie" => "cronwatch_token=%E0%A4%A" }).status
    assert_equal 401, send.call("GET", "/cronwatch/api/jobs", { "cookie" => "cronwatch_token=%" }).status
    assert_equal 400, send.call("GET", "/cronwatch/jobs/%E0%A4%A", BEARER).status
    api = send.call("GET", "/cronwatch/api/jobs/%zz", BEARER)
    assert_equal 400, api.status
    assert_equal false, api.json["ok"]
    assert_equal 400, send.call("POST", "/cronwatch/api/jobs/%zz/silence", BEARER).status
  end

  def test_runs_query_is_clamped_to_a_whole_number_in_range
    cw, _, send = app
    3.times { cw.run("r") { nil } }
    count = ->(runs) { send.call("GET", "/cronwatch/api/jobs/r?runs=#{runs}", BEARER).json["runs"].length }
    assert_equal 1, count.call("0")
    assert_equal 1, count.call("-5")
    assert_equal 2, count.call("2.7")
    assert_equal 3, count.call("abc")
    assert_equal 3, count.call("")
    assert_equal 3, count.call("1e9")
    assert_equal 3, count.call("Infinity")
    # Number() reads these too.
    assert_equal 2, count.call("0x2")
    assert_equal 1, count.call(".5")
    assert_equal 2, count.call("2.")
  end

  def test_an_unexpected_error_is_a_generic_500_reported_through_on_error
    reported = []
    cw, _, send = app(on_error: ->(error, where) { reported << [error, where] })
    cw.define_singleton_method(:jobs) { raise "secret connection string" }
    cw.define_singleton_method(:jobs_with_runs) { |*| raise "secret connection string" }
    api = send.call("GET", "/cronwatch/api/jobs", BEARER)
    assert_equal 500, api.status
    refute_match(/secret/, api.body)
    assert_equal({ "ok" => false, "error" => "Internal error" }, JSON.parse(api.body))
    page = send.call("GET", "/cronwatch/", BEARER)
    assert_equal 500, page.status
    assert_match(%r{text/html}, page.headers["content-type"])
    refute_match(/secret/, page.body)
    assert_equal 2, reported.length
    assert_equal "routes", reported[0][1]
    assert_match(/secret connection string/, reported[0][0].message)
  end

  def test_a_raising_on_error_still_yields_a_500
    cw, _, send = app(on_error: ->(*) { raise "logger down" })
    cw.define_singleton_method(:jobs) { raise "boom" }
    status = nil
    _, err = capture_io { status = send.call("GET", "/cronwatch/api/jobs", BEARER).status }
    assert_equal 500, status
    assert_match(/logger down/, err)
  end

  def test_silence_durations_strings_are_validated_numbers_are_milliseconds
    cw, clock, send = app
    cw.run("s") { nil }
    json = BEARER.merge("content-type" => "application/json")
    silence = ->(body) { send.call("POST", "/cronwatch/api/jobs/s/silence", json, JSON.generate(body)) }

    ["forever", "2 hours", "", "-5", "1h then some"].each do |bad|
      res = silence.call({ for: bad })
      assert_equal 400, res.status, bad
      body = res.json
      assert_equal false, body["ok"]
      assert_match(/silence duration/, body["error"], bad)
    end
    assert_nil cw.job_summary("s").silenced_until, "a bad duration silences nothing"

    until_ms = ->(body) { silence.call(body).json["state"]["silencedUntil"] - clock.now }
    assert_equal 7_200_000, until_ms.call({ for: 7_200_000 })
    assert_equal 60_000, until_ms.call({ for: "60000" })
    assert_equal 90 * 60_000, until_ms.call({ for: "90m" })
    assert_equal HOUR, until_ms.call({})
    via_query = send.call("POST", "/cronwatch/api/jobs/s/silence?for=forever", BEARER)
    assert_equal 400, via_query.status
  end

  def test_the_silence_form_shows_an_error_for_a_bad_duration_and_404s_a_missing_job
    cw, _, send = app
    cw.run("s") { nil }
    form = COOKIE.merge(FORM)
    bad = send.call("POST", "/cronwatch/jobs/s/silence", form, "for=forever")
    assert_equal 400, bad.status
    assert_match(%r{text/html}, bad.headers["content-type"])
    assert_match(/silence duration &quot;forever&quot;/, bad.body)
    assert_nil cw.job_summary("s").silenced_until
    assert_equal 404, send.call("POST", "/cronwatch/jobs/ghost/silence", form, "for=1h").status
    assert_equal 404, send.call("POST", "/cronwatch/jobs/ghost/unsilence", form).status
    assert_equal 404, send.call("POST", "/cronwatch/jobs/s/explode", form).status
  end

  def test_pages_carry_a_strict_csp_and_security_headers_and_need_no_script_of_their_own
    cw, _, send = app
    cw.run("h") { nil }
    ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope"].each do |path|
      res = send.call("GET", path, BEARER)
      csp = res.headers["content-security-policy"]
      assert_match(/default-src 'none'/, csp)
      assert_match(/frame-ancestors 'none'/, csp)
      assert_match(/form-action 'self'/, csp)
      # Scripts only from the dashboard itself (app.js, which registers the service worker).
      assert_match(/script-src 'self';/, csp)
      refute_match(/unsafe-eval|script-src[^;]*unsafe-inline/, csp)
      assert_equal "DENY", res.headers["x-frame-options"]
      assert_equal "nosniff", res.headers["x-content-type-options"]
      assert_equal "same-origin", res.headers["referrer-policy"]
      assert_equal "no-store", res.headers["cache-control"]
      assert_equal "noindex", res.headers["x-robots-tag"]
      assert_equal ['<script src="/cronwatch/app.js" defer></script>'], res.body.scan(%r{<script[^>]*>[^<]*</script>}i), "one script, external, empty"
      assert_equal 1, res.body.scan(/<script/i).length
      refute_match(/\son[a-z]+=/i, res.body, "no inline event handlers")
    end
    page = send.call("GET", "/cronwatch/jobs/h", BEARER).body
    assert_match(%r{<details class="confirm"><summary>Forget</summary><form}, page, "forget confirms without script")
    api = send.call("GET", "/cronwatch/api/jobs", BEARER)
    assert_equal "nosniff", api.headers["x-content-type-options"]
    assert_equal "no-store", api.headers["cache-control"]
  end

  def test_markup_in_definitions_output_and_metrics_stays_escaped_on_every_page
    cw, _, send = app
    job = cw.job("m", schedule: "0 2 * * *", description: "<img src=x>", tags: ["<t>"], expect: "<e>")
    job.run do |j|
      j.log("<o>")
      j.metric("<k>", 1)
    end
    ["/cronwatch/", "/cronwatch/jobs/m", "/cronwatch/jobs/%3Cx%3E"].each do |path|
      html = send.call("GET", path, BEARER).body
      refute_match(/<img|<t>|<e>|<o>|<k>|<x>/, html, path)
    end
  end

  def test_without_a_token_in_development_nothing_a_request_says_about_itself_lets_it_in
    with_env("RAILS_ENV" => nil, "RACK_ENV" => "development", "CRONWATCH_TOKEN" => nil) do
      cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [Capture.new], cron_secret: nil)
      web = Cronwatch::Web.new(cw, base_path: "/cronwatch")
      before = $stdout
      $stdout = StringIO.new
      begin
        # What the old loopback check let through: all of it can be forged,
        # since a proxy keeps a client's X-Forwarded-For and a tunnel rewrites Host.
        looks_local = [
          {},
          { "host" => "localhost:3000", "x-forwarded-host" => "localhost:3000", "x-forwarded-for" => "::ffff:127.0.0.1" },
          { "host" => "127.0.0.1:3000", "x-forwarded-for" => "::1" },
          { "host" => "[::1]:3000", "forwarded" => 'for="[::1]:51234";host=localhost;proto=http' },
          { "host" => "localhost", "x-real-ip" => "127.0.0.1" },
        ]
        looks_local.each do |headers|
          env = Rack::MockRequest.env_for("http://localhost:3000/cronwatch/api/jobs", "REMOTE_ADDR" => "127.0.0.1")
          headers.each { |name, value| env["HTTP_#{name.tr("-", "_").upcase}"] = value }
          status, _, body = web.call(env)
          assert_equal 401, status, headers.inspect
          assert_equal false, JSON.parse(body.join)["ok"]
        end
        write = Rack::MockRequest.env_for("http://localhost:3000/cronwatch/api/check", method: "POST", "REMOTE_ADDR" => "127.0.0.1")
        assert_equal 401, web.call(write)[0]
      ensure
        $stdout = before
      end
    end
  end
end
