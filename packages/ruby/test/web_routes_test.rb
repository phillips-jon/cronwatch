# frozen_string_literal: true

require_relative "web/helpers"

# The SDK's routes tests (routes.test.ts), against Cronwatch::Web.
class WebRoutesTest < Minitest::Test
  include WebHelpers

  def app(token: "tok")
    cw, clock, = make
    [cw, clock, Cronwatch::Web.new(cw, token: token, base_path: "/cronwatch")]
  end

  def test_everything_needs_the_token
    _, _, web = app
    assert_equal 401, send_request(web, "GET", "/cronwatch").status
    assert_equal 401, send_request(web, "GET", "/cronwatch/api/jobs").status
    assert_equal 401, send_request(web, "GET", "/cronwatch/api/jobs", { "authorization" => "Bearer wrong" }).status
    assert_equal 200, send_request(web, "GET", "/cronwatch/api/jobs", BEARER).status
  end

  def test_the_check_endpoint_also_accepts_the_cron_secret_nothing_else_does
    clock = Clock.new
    cw = Cronwatch.new(now: clock.to_proc, alerts: [Capture.new], cron_secret: "cron-s3cret")
    web = Cronwatch::Web.new(cw, token: "tok", base_path: "/cronwatch")
    with_cron = { "authorization" => "Bearer cron-s3cret" }
    assert_equal 200, send_request(web, "GET", "/cronwatch/api/check", with_cron).status
    assert_equal 401, send_request(web, "GET", "/cronwatch/api/jobs", with_cron).status
    assert_equal 401, send_request(web, "GET", "/cronwatch/api/check?token=cron-s3cret").status, "only as a bearer header"
  end

  def test_token_query_sets_a_cookie_and_redirects_to_a_clean_url
    _, _, web = app
    res = send_request(web, "GET", "/cronwatch/?token=tok")
    assert_equal 303, res.status
    assert_equal "/cronwatch/", res.headers["location"]
    cookie = res.headers["set-cookie"]
    assert_equal "cronwatch_token=#{DIGEST}", cookie.split(";")[0], "a digest, not the token"
    assert_match(%r{; Path=/cronwatch; HttpOnly; SameSite=Lax}, cookie)
    refute_match(/Secure/, cookie)
    page = send_request(web, "GET", "/cronwatch/", { "cookie" => "other=1; cronwatch_token=#{DIGEST}" })
    assert_equal 200, page.status
    assert_equal 401, send_request(web, "GET", "/cronwatch/", { "cookie" => "cronwatch_token=tok" }).status, "the raw token is not a cookie"
    assert_match(%r{text/html}, page.headers["content-type"])
    assert_match(/; Secure\z/, send_request(web, "GET", "https://app.test/cronwatch/?token=tok").headers["set-cookie"])
  end

  def test_dashboard_and_job_pages_render_json_api_answers
    cw, clock, web = app
    job = cw.job("nightly-report", schedule: "0 2 * * *", description: "Builds the PDF")
    job.run do |j|
      j.log("built")
      clock.advance(2000)
    end
    assert_raises(RuntimeError) { cw.run("broken") { raise "kaboom <script>" } }

    dash = send_request(web, "GET", "/cronwatch", BEARER).body
    assert_match(/nightly-report/, dash)
    assert_match(/Builds the PDF/, dash)
    assert_match(/healthy/, dash)
    assert_match(/failing/, dash)
    assert_match(%r{<p class="headline">2 jobs, <b>1 needing attention</b>\.</p>}, dash)
    assert_match(%r{<div class="bad"><dt><i class="sq bad" aria-hidden="true"></i>failing</dt><dd>1</dd></div>}, dash, "counts by health")
    assert_match(/<section class="sec" aria-label="Last 24 hours">.*<figure class="timeline day">/m, dash)
    assert_match(/<table class="board">/, dash)
    assert_match(%r{<form class="inline" method="post" action="/cronwatch/check"><button class="primary" type="submit">Run check now</button></form>}, dash)

    page = send_request(web, "GET", "/cronwatch/jobs/broken", BEARER)
    assert_equal 200, page.status
    assert_match(/kaboom &lt;script&gt;/, page.body, "error text is escaped")
    refute_match(/<script>/, page.body)
    assert_match(%r{<h1 class="jobname">broken</h1>}, page.body)
    assert_match(/<figure class="timeline week">/, page.body)
    assert_match(%r{<details class="out error" open><summary>error</summary><pre>[^<]*kaboom &lt;script&gt;}, page.body)

    list = send_request(web, "GET", "/cronwatch/api/jobs", BEARER).json
    assert_equal 2, list["jobs"].length
    one = send_request(web, "GET", "/cronwatch/api/jobs/nightly-report?runs=5", BEARER).json
    assert_equal "healthy", one["job"]["health"]
    assert_equal 1, one["runs"].length
    assert_equal "built", one["runs"][0]["output"]

    assert_equal 404, send_request(web, "GET", "/cronwatch/api/jobs/missing", BEARER).status
    assert_equal 404, send_request(web, "GET", "/cronwatch/jobs/missing", BEARER).status
    assert_equal 404, send_request(web, "GET", "/cronwatch/nope", BEARER).status
  end

  def test_get_api_names_the_library_language_and_version
    _, _, web = app
    %w[/cronwatch/api /cronwatch/api/].each do |path|
      res = send_request(web, "GET", path, BEARER)
      assert_equal 200, res.status
      assert_equal %({"ok":true,"library":"cronwatch","language":"ruby","version":"#{Cronwatch::VERSION}","api":1}), res.body
    end
    assert_equal 401, send_request(web, "GET", "/cronwatch/api", {}).status
    assert_equal 404, send_request(web, "POST", "/cronwatch/api", BEARER.merge("content-type" => "application/json"), "{}").status
  end

  def test_check_silence_unsilence_and_forget_over_the_api
    cw, _, web = app
    cw.run("s") { nil }
    post = lambda do |path, body = nil|
      send_request(web, "POST", path, BEARER.merge("content-type" => "application/json"), body.nil? ? nil : JSON.generate(body))
    end
    check = post.call("/cronwatch/api/check").json
    assert_equal true, check["ok"]
    assert_equal 1, check["jobs"].length
    silenced = post.call("/cronwatch/api/jobs/s/silence", { for: "2h" }).json
    assert_equal %w[ok job], silenced.keys, "the job's summary, not its stored state"
    assert_operator silenced["job"]["silencedUntil"], :>, 0
    assert_equal "silenced", silenced["job"]["health"]
    assert_equal :silenced, cw.job_summary("s").health
    un = post.call("/cronwatch/api/jobs/s/unsilence").json
    assert_nil un["job"]["silencedUntil"]
    assert_equal 404, post.call("/cronwatch/api/jobs/nope/silence", { for: "1h" }).status
    del = send_request(web, "DELETE", "/cronwatch/api/jobs/s", BEARER)
    assert_equal 200, del.status
    assert_nil cw.job_summary("s")
  end

  def test_dashboard_forms_post_and_redirect_back
    cw, _, web = app
    cw.run("f") { nil }
    form = send_request(web, "POST", "/cronwatch/jobs/f/silence",
                        BEARER.merge("content-type" => "application/x-www-form-urlencoded", "referer" => "http://app.test/cronwatch/jobs/f"),
                        "for=4h")
    assert_equal 303, form.status
    assert_equal "http://app.test/cronwatch/jobs/f", form.headers["location"]
    assert_equal :silenced, cw.job_summary("f").health
    elsewhere = send_request(web, "POST", "/cronwatch/jobs/f/unsilence", BEARER.merge("referer" => "https://evil.example/phish"))
    assert_equal "/cronwatch/", elsewhere.headers["location"], "a foreign referer is not followed"
  end

  def unconfigured(token: Cronwatch::Web::UNSET, host: "app.test")
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [Capture.new], cron_secret: nil)
    web = if token.equal?(Cronwatch::Web::UNSET)
            Cronwatch::Web.new(cw, base_path: "/cronwatch")
          else
            Cronwatch::Web.new(cw, token: token, base_path: "/cronwatch")
          end
    ->(path) { send_request(web, "GET", "http://#{host}#{path}") }
  end

  # The lines the block printed to stdout, and its result.
  def printed
    before = $stdout
    $stdout = StringIO.new
    result = yield
    [$stdout.string.lines.map(&:chomp), result]
  ensure
    $stdout = before
  end

  def test_without_a_token_outside_development_the_routes_are_locked
    [nil, "production", "staging", ""].each do |env|
      with_env("RAILS_ENV" => nil, "RACK_ENV" => env, "CRONWATCH_TOKEN" => nil) do
        get = unconfigured(host: "localhost:3000")
        lines, = printed do
          assert_equal 503, get.call("/cronwatch/api/jobs").status, "RACK_ENV=#{env}"
          page = get.call("/cronwatch")
          assert_equal 503, page.status, "RACK_ENV=#{env}"
          assert_includes page.body, "Set CRONWATCH_TOKEN (or pass token: to Cronwatch::Web.new), or pass token: nil to serve them open behind your own auth."
        end
        assert_empty lines, "no token is made outside development"
      end
    end
  end

  # Puma, as a server that sets RACK_ENV=development when nothing names an environment, is running this process.
  def under_puma
    defined = Object.const_defined?(:Puma, false)
    Object.const_set(:Puma, Module.new) unless defined
    Puma.const_set(:Server, Class.new) unless Puma.const_defined?(:Server, false)
    yield
  ensure
    Object.send(:remove_const, :Puma) unless defined
  end

  def test_under_a_server_that_defaults_rack_env_rack_env_development_alone_makes_no_token
    under_puma do
      with_env("RAILS_ENV" => nil, "APP_ENV" => nil, "RACK_ENV" => "development", "CRONWATCH_TOKEN" => nil) do
        get = unconfigured(host: "localhost:3000")
        lines, = printed do
          assert_equal 503, get.call("/cronwatch/api/jobs").status
          assert_equal 503, get.call("/cronwatch").status
        end
        assert_empty lines, "no token in the log of what may be production"
      end
      [{ "APP_ENV" => "development" }, { "RAILS_ENV" => "development" }, { "RACK_ENV" => "test" }].each do |stated|
        with_env({ "RAILS_ENV" => nil, "APP_ENV" => nil, "RACK_ENV" => "development", "CRONWATCH_TOKEN" => nil }.merge(stated)) do
          lines, response = printed { unconfigured(host: "localhost:3000").call("/cronwatch/api/jobs") }
          assert_equal 401, response.status, stated.inspect
          assert_match SIGN_IN, lines[0], "#{stated.inspect} says development"
        end
      end
      with_env("RAILS_ENV" => nil, "APP_ENV" => "production", "RACK_ENV" => "development", "CRONWATCH_TOKEN" => nil) do
        assert_equal 503, unconfigured.call("/cronwatch/api/jobs").status, "APP_ENV=production"
      end
    end
  end

  SIGN_IN = %r{\A\[cronwatch\] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard\. Sign in: http://localhost:3000/cronwatch/\?token=([A-Za-z0-9_-]{43})\z}

  def test_without_a_token_in_development_a_made_up_token_is_printed_once_and_required_from_everyone
    %w[development test].each do |env|
      %w[RAILS_ENV RACK_ENV].each do |var|
        with_env("RAILS_ENV" => nil, "RACK_ENV" => nil, var => env, "CRONWATCH_TOKEN" => nil) do
          cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [Capture.new], cron_secret: nil)
          web = Cronwatch::Web.new(cw, base_path: "/cronwatch/")
          lines, = printed do
            # Every request is refused without the token, whatever it claims about where it came from.
            [
              ["http://localhost:3000/cronwatch/api/jobs", {}],
              ["http://localhost:3000/cronwatch/api/jobs", { "x-forwarded-for" => "127.0.0.1", "x-real-ip" => "127.0.0.1" }],
              ["http://127.0.0.1:3000/cronwatch/", {}],
              ["http://192.168.1.20:3000/cronwatch/api/jobs", {}],
            ].each do |url, headers|
              assert_equal 401, send_request(web, "GET", url, headers).status, "#{url} #{var}=#{env}"
            end
          end
          assert_equal 1, lines.length, "announced once, on the first request"
          match = SIGN_IN.match(lines[0])
          assert match, lines[0]
          token = match[1]

          page = send_request(web, "GET", "http://localhost:3000/cronwatch/")
          assert_equal 401, page.status
          assert_includes page.body, "The sign-in link is in the server log: open it once and this browser stays signed in."
          api = send_request(web, "GET", "http://localhost:3000/cronwatch/api/jobs")
          assert_equal({ "ok" => false, "error" => "Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log" }, api.json)

          sign_in = send_request(web, "GET", "http://localhost:3000/cronwatch/?token=#{token}")
          assert_equal 303, sign_in.status
          assert_equal "/cronwatch/", sign_in.headers["location"]
          cookie = sign_in.headers["set-cookie"].split(";").first
          assert_equal 200, send_request(web, "GET", "http://localhost:3000/cronwatch/", { "cookie" => cookie }).status
          assert_equal 200, send_request(web, "GET", "http://localhost:3000/cronwatch/api/jobs", { "authorization" => "Bearer #{token}" }).status

          other = Cronwatch::Web.new(Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [Capture.new], cron_secret: nil), base_path: "/")
          second, = printed { send_request(other, "GET", "https://dev.example:8443/api/jobs") }
          assert_match %r{Sign in: /\?token=[A-Za-z0-9_-]{43} on this server \(the first request's host is not local, so the link leaves it out\)\z}, second[0], "no host that is not local, and a root mount"
          refute_equal token, second[0][/token=([A-Za-z0-9_-]{43})/, 1], "each app makes its own"

          mounted = Cronwatch::Web.new(Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [Capture.new], cron_secret: nil))
          third, = printed { send_request(mounted, "GET", "http://localhost:3000/admin/cronwatch/api/jobs", script_name: "/admin/cronwatch") }
          assert_match %r{Sign in: http://localhost:3000/admin/cronwatch/\?token=[A-Za-z0-9_-]{43}\z}, third[0], "the mount point, from SCRIPT_NAME"
        end
      end
    end
    with_env("RAILS_ENV" => nil, "RACK_ENV" => "development", "CRONWATCH_TOKEN" => nil) do
      lines, response = printed { unconfigured(token: nil).call("/cronwatch/api/jobs") }
      assert_equal 200, response.status, "token: nil serves open in development too"
      assert_empty lines, "and makes no token"
    end
    with_env("RAILS_ENV" => nil, "RACK_ENV" => "development", "CRONWATCH_TOKEN" => "envtok") do
      lines, response = printed { unconfigured.call("/cronwatch/api/jobs") }
      assert_equal 401, response.status, "a configured token is used in development"
      assert_empty lines
    end
  end

  def test_the_development_token_lets_a_cron_secret_run_the_check
    with_env("RAILS_ENV" => nil, "RACK_ENV" => "development", "CRONWATCH_TOKEN" => nil) do
      cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [Capture.new], cron_secret: "cronsecret")
      web = Cronwatch::Web.new(cw, base_path: "/cronwatch")
      printed do
        assert_equal 200, send_request(web, "GET", "/cronwatch/api/check", { "authorization" => "Bearer cronsecret" }).status
        assert_equal 401, send_request(web, "GET", "/cronwatch/api/jobs", { "authorization" => "Bearer cronsecret" }).status
      end
    end
  end

  def test_an_empty_token_counts_as_unset_nil_opts_out_explicitly
    with_env("RAILS_ENV" => nil, "RACK_ENV" => "production", "CRONWATCH_TOKEN" => "") do
      assert_equal 503, unconfigured.call("/cronwatch/api/jobs").status
      assert_equal 503, unconfigured(token: "").call("/cronwatch/api/jobs").status
      assert_equal 200, unconfigured(token: nil, host: "app.test").call("/cronwatch/api/jobs").status, "token: nil serves open"
    end
    with_env("RAILS_ENV" => nil, "RACK_ENV" => "production", "CRONWATCH_TOKEN" => "envtok") do
      cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [Capture.new], cron_secret: nil)
      web = Cronwatch::Web.new(cw, token: "", base_path: "/cronwatch")
      assert_equal 401, send_request(web, "GET", "/cronwatch/api/jobs").status
      assert_equal 200, send_request(web, "GET", "/cronwatch/api/jobs", { "authorization" => "Bearer envtok" }).status
      assert_equal 200, send_request(Cronwatch::Web.new(cw, base_path: "/cronwatch"), "GET", "/cronwatch/api/jobs", { "authorization" => "Bearer envtok" }).status,
                   "the token defaults to CRONWATCH_TOKEN"
    end
  end

  # Ruby only: mounted in Rails (`mount Cronwatch::Web.new => "/cronwatch"`) the
  # mount point arrives as SCRIPT_NAME, and links, cookies and redirects use it.
  def test_mounted_under_a_script_name_links_and_redirects_use_the_mount_point
    cw, = make
    cw.run("m") { nil }
    web = Cronwatch::Web.new(cw, token: "tok")
    signed_in = send_request(web, "GET", "/admin/cronwatch/jobs/m?token=tok&x=a+b", script_name: "/admin/cronwatch")
    assert_equal 303, signed_in.status
    assert_equal "/admin/cronwatch/jobs/m?x=a+b", signed_in.headers["location"]
    assert_match(%r{; Path=/admin/cronwatch;}, signed_in.headers["set-cookie"])

    page = send_request(web, "GET", "/admin/cronwatch/jobs/m", BEARER, script_name: "/admin/cronwatch")
    assert_equal 200, page.status
    assert_includes page.body, %(action="/admin/cronwatch/jobs/m/silence")
    assert_includes page.body, %(<a href="/admin/cronwatch/"><svg viewBox=)
    root = send_request(web, "GET", "/admin/cronwatch", BEARER, script_name: "/admin/cronwatch")
    assert_equal 200, root.status
    assert_includes root.body, %(<a class="name" href="/admin/cronwatch/jobs/m">m</a>)
    forget = send_request(web, "POST", "/admin/cronwatch/jobs/m/forget", BEARER, script_name: "/admin/cronwatch")
    assert_equal "/admin/cronwatch/", forget.headers["location"]
    assert_equal 200, send_request(web, "GET", "/admin/cronwatch/api/jobs", BEARER, script_name: "/admin/cronwatch").status
  end

  # Ruby only: with no client given, the app uses Cronwatch.client at request time.
  def test_without_a_client_it_serves_cronwatch_client
    previous = Cronwatch.instance_variable_get(:@client)
    cw, = make
    Cronwatch.client = cw
    cw.run("configured") { nil }
    web = Cronwatch::Web.new(token: "tok")
    assert_equal ["configured"], send_request(web, "GET", "/api/jobs", BEARER).json["jobs"].map { |j| j["name"] }
  ensure
    Cronwatch.client = previous
  end

  # Ruby only: a multipart form reads like the SDK's request.formData().
  def test_a_multipart_silence_form_is_read
    cw, clock, web = app
    cw.run("mp") { nil }
    body = "--XyZ\r\ncontent-disposition: form-data; name=\"for\"\r\n\r\n4h\r\n--XyZ--\r\n"
    res = send_request(web, "POST", "/cronwatch/jobs/mp/silence", BEARER.merge("content-type" => "multipart/form-data; boundary=XyZ"), body)
    assert_equal 303, res.status
    assert_equal clock.now + (4 * HOUR), cw.job_summary("mp").silenced_until
  end

  # A Rack 3 input may be read once. Rack::MethodOverride reads a form
  # before the app does; the fields must still arrive.
  class OneShotInput
    def initialize(text) = @io = StringIO.new(text)
    def read(*args) = @io.read(*args)
    def gets = @io.gets
    def each(&block) = @io.each(&block)
    def close = nil
  end

  def test_a_form_body_that_cannot_be_read_twice_is_still_read
    require "rack/method_override"
    cw, clock, web = app
    cw.run("once") { nil }
    forms = {
      "application/x-www-form-urlencoded" => "for=5m",
      "multipart/form-data; boundary=XX" => "--XX\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n5m\r\n--XX--\r\n",
    }
    [web, Rack::MethodOverride.new(web)].each do |handler|
      forms.each do |type, body|
        cw.unsilence("once")
        env = Rack::MockRequest.env_for("http://app.test/cronwatch/api/jobs/once/silence",
                                        method: "POST", "CONTENT_TYPE" => type, "HTTP_AUTHORIZATION" => "Bearer tok",
                                        "CONTENT_LENGTH" => body.bytesize.to_s)
        env["rack.input"] = OneShotInput.new(body)
        status, _, response = handler.call(env)
        assert_equal 200, status
        assert_equal clock.now + (5 * MIN), JSON.parse(response.join)["job"]["silencedUntil"], "#{handler.class} #{type}"
      end
    end
  end

  # What the SDK answers for the same bytes (audit-bugs/web/bytes.mjs): a
  # byte order mark is dropped, bytes that are not UTF-8 become U+FFFD, and a
  # value is String(value), so null is "null".
  def test_a_json_body_is_decoded_as_request_json_decodes_it
    cw, clock, web = app
    cw.run("bytes") { nil }
    post = ->(body) { send_request(web, "POST", "/cronwatch/api/jobs/bytes/silence", BEARER.merge("content-type" => "application/json"), body.b) }
    res = post.call("\xEF\xBB\xBF{\"for\":\"5m\"}")
    assert_equal 200, res.status
    assert_equal clock.now + (5 * MIN), res.json["job"]["silencedUntil"]
    res = post.call("{\"for\":\"5m\xFF\"}")
    assert_equal 400, res.status
    assert_equal "silence duration \"5m\u{FFFD}\" is not a duration like \"15m\", \"1h30m\" or \"90s\"", res.json["error"]
    res = post.call('{"for":null}')
    assert_equal 400, res.status
    assert_equal 'silence duration "null" is not a duration like "15m", "1h30m" or "90s"', res.json["error"]
    res = post.call('{"for":[null,"2h"]}')
    assert_equal 400, res.status
    assert_match(/silence duration ",2h"/, res.json["error"])
  end

  # Ruby only: the app passes Rack::Lint.
  def test_responses_pass_rack_lint
    cw, = make
    cw.run("l") { nil }
    web = Rack::Lint.new(Cronwatch::Web.new(cw, token: "tok", base_path: "/cronwatch"))
    [
      ["GET", "/cronwatch/", BEARER], ["GET", "/cronwatch/jobs/l", BEARER], ["GET", "/cronwatch/api/jobs", BEARER],
      ["GET", "/cronwatch/?token=tok"], ["POST", "/cronwatch/check", BEARER], ["GET", "/cronwatch/api/check", COOKIE],
      ["POST", "/cronwatch/jobs/l/silence", BEARER.merge("content-type" => "application/x-www-form-urlencoded"), "for=1h"],
    ].each do |method, path, headers, body|
      send_request(web, method, path, headers || {}, body)
    end
  end
end
