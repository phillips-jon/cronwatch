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

    page = send_request(web, "GET", "/cronwatch/jobs/broken", BEARER)
    assert_equal 200, page.status
    assert_match(/kaboom &lt;script&gt;/, page.body, "error text is escaped")
    refute_match(/<script>/, page.body)

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
    assert_operator silenced["state"]["silencedUntil"], :>, 0
    assert_equal :silenced, cw.job_summary("s").health
    un = post.call("/cronwatch/api/jobs/s/unsilence").json
    assert_nil un["state"]["silencedUntil"]
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

  def unconfigured(token: Cronwatch::Web::UNSET, host: "localhost")
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [Capture.new], cron_secret: nil)
    web = if token.equal?(Cronwatch::Web::UNSET)
            Cronwatch::Web.new(cw, base_path: "/cronwatch")
          else
            Cronwatch::Web.new(cw, token: token, base_path: "/cronwatch")
          end
    ->(path) { send_request(web, "GET", "http://#{host}#{path}") }
  end

  def test_without_a_token_open_only_to_localhost_in_development_and_test_locked_otherwise
    [nil, "production", "staging", ""].each do |env|
      with_env("RAILS_ENV" => nil, "RACK_ENV" => env, "CRONWATCH_TOKEN" => nil) do
        get = unconfigured
        assert_equal 503, get.call("/cronwatch/api/jobs").status, "RACK_ENV=#{env}"
        assert_equal 503, get.call("/cronwatch").status, "RACK_ENV=#{env}"
      end
    end
    %w[development test].each do |env|
      %w[RAILS_ENV RACK_ENV].each do |var|
        with_env("RAILS_ENV" => nil, "RACK_ENV" => nil, var => env, "CRONWATCH_TOKEN" => nil) do
          assert_equal 200, unconfigured.call("/cronwatch/api/jobs").status, "#{var}=#{env}"
          assert_equal 200, unconfigured(host: "127.0.0.1:3000").call("/cronwatch/api/jobs").status, "#{var}=#{env}"
          assert_equal 200, unconfigured(host: "[::1]:3000").call("/cronwatch/api/jobs").status, "#{var}=#{env}"
          assert_equal 503, unconfigured(host: "192.168.1.20:3000").call("/cronwatch/api/jobs").status, "a LAN address, #{var}=#{env}"
          assert_equal 503, unconfigured(host: "evil.example").call("/cronwatch/api/jobs").status, "a rebinding host, #{var}=#{env}"
        end
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
    assert_includes page.body, %(<a href="/admin/cronwatch/">CronWatch</a>)
    root = send_request(web, "GET", "/admin/cronwatch", BEARER, script_name: "/admin/cronwatch")
    assert_equal 200, root.status
    assert_includes root.body, %(<a href="/admin/cronwatch/jobs/m">m</a>)
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
