# frozen_string_literal: true

require_relative "web/helpers"

# The SDK's web app tests (routes-pwa.test.ts), against Cronwatch::Web. The
# service worker and app.js are the SDK's text byte for byte (the golden
# fixture compares them), so their behaviour is tested there, in a VM.
class WebPWATest < Minitest::Test
  include WebHelpers

  CSP = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; " \
        "manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"

  def app(token: "tok", base_path: "/cronwatch")
    cw, = make
    [cw, Cronwatch::Web.new(cw, token: token, base_path: base_path)]
  end

  def test_the_manifest_describes_the_app_at_its_base_path_without_the_token
    _, web = app
    res = send_request(web, "GET", "/cronwatch/manifest.webmanifest")
    assert_equal 200, res.status
    assert_equal "application/manifest+json", res.headers["content-type"]
    assert_equal "nosniff", res.headers["x-content-type-options"]
    manifest = res.json
    assert_equal "CronWatch", manifest["name"]
    assert_equal "CronWatch", manifest["short_name"]
    assert_equal "/cronwatch/", manifest["id"]
    assert_equal "/cronwatch/", manifest["start_url"]
    assert_equal "/cronwatch/", manifest["scope"]
    assert_equal "standalone", manifest["display"]
    assert_equal "#f4f4f5", manifest["background_color"]
    assert_equal "#ffffff", manifest["theme_color"]
    assert_equal [
      ["/cronwatch/icons/icon.svg", "any", "image/svg+xml", "any"],
      ["/cronwatch/icons/maskable.svg", "any", "image/svg+xml", "maskable"],
      ["/cronwatch/icons/icon-192.png", "192x192", "image/png", "any"],
      ["/cronwatch/icons/icon-512.png", "512x512", "image/png", "any"],
      ["/cronwatch/icons/maskable-512.png", "512x512", "image/png", "maskable"],
    ], manifest["icons"].map { |i| i.values_at("src", "sizes", "type", "purpose") }
  end

  def test_the_manifest_follows_the_base_path_and_the_mount_point
    [["", "", ""], ["/", "", ""], ["/ops/cron/", "/ops/cron", "/ops/cron"]].each do |base_path, prefix, base|
      _, web = app(base_path: base_path)
      manifest = send_request(web, "GET", "#{prefix}/manifest.webmanifest").json
      assert_equal "#{base}/", manifest["start_url"], base_path
      assert_equal "#{base}/", manifest["scope"], base_path
      assert_equal "#{base}/", manifest["id"], base_path
      assert_equal "#{base}/icons/icon.svg", manifest["icons"][0]["src"], base_path
      assert_equal "#{base}/", send_request(web, "GET", "#{prefix}/sw.js").headers["service-worker-allowed"], base_path
    end
    # Mounted with Rails' `mount`, the base comes from SCRIPT_NAME.
    cw, = make
    web = Cronwatch::Web.new(cw, token: "tok")
    res = send_request(web, "GET", "/admin/cron/manifest.webmanifest", script_name: "/admin/cron")
    assert_equal "/admin/cron/", res.json["start_url"]
    assert_equal "/admin/cron/icons/icon-192.png", res.json["icons"][2]["src"]
    sw = send_request(web, "GET", "/admin/cron/sw.js", script_name: "/admin/cron")
    assert_equal "/admin/cron/", sw.headers["service-worker-allowed"]
    page = send_request(web, "GET", "/admin/cron/", BEARER, script_name: "/admin/cron").body
    assert_includes page, '<link rel="manifest" href="/admin/cron/manifest.webmanifest">'
    assert_includes page, '<script src="/admin/cron/app.js" defer></script>'
  end

  def test_icons_are_served_with_their_types_a_long_cache_and_no_token
    _, web = app
    { "icon-192.png" => 192, "icon-512.png" => 512, "maskable-512.png" => 512, "apple-touch-icon.png" => 180 }.each do |name, size|
      res = send_request(web, "GET", "/cronwatch/icons/#{name}")
      assert_equal 200, res.status, name
      assert_equal "image/png", res.headers["content-type"], name
      assert_equal "public, max-age=31536000, immutable", res.headers["cache-control"], name
      assert_equal "nosniff", res.headers["x-content-type-options"], name
      assert_nil res.headers["set-cookie"], name
      bytes = res.body.b
      assert_equal "\x89PNG\r\n\x1A\n".b, bytes[0, 8], name
      assert_equal [size, size], bytes[16, 8].unpack("NN"), name
      assert_equal bytes.bytesize.to_s, res.headers["content-length"], name
      assert_operator bytes.bytesize, :<, 10_000, name
    end
    %w[icon.svg maskable.svg].each do |name|
      res = send_request(web, "GET", "/cronwatch/icons/#{name}")
      assert_equal "image/svg+xml", res.headers["content-type"], name
      assert_equal "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'", res.headers["content-security-policy"], name
      assert_match(/<circle cx="20" cy="20" r="10.5"[^>]*stroke-width="2"/, res.body, name)
      assert_match(/<path d="M20 12.5V20h6"[^>]*stroke-linecap="round"/, res.body, name)
      refute_match(/<script|\son[a-z]+=/i, res.body, name)
    end
    assert_equal 401, send_request(web, "GET", "/cronwatch/icons/nope.png").status, "anything else under /icons needs the token"
  end

  def test_the_app_shell_is_public_even_when_locked_or_opened_and_says_nothing_about_jobs
    with_env("CRONWATCH_TOKEN" => nil, "RACK_ENV" => "production", "RAILS_ENV" => "production", "APP_ENV" => "production") do
      cw, web = app(token: Cronwatch::Web::UNSET)
      cw.run("secret-job") { nil }
      assert_equal 503, send_request(web, "GET", "/cronwatch/").status
      %w[/cronwatch/manifest.webmanifest /cronwatch/sw.js /cronwatch/app.js /cronwatch/offline /cronwatch/icons/icon.svg].each do |path|
        res = send_request(web, "GET", path)
        assert_equal 200, res.status, path
        refute_match(/secret-job/, res.body, path)
      end
    end
    _, open = app(token: nil)
    assert_equal 200, send_request(open, "GET", "/cronwatch/manifest.webmanifest").status
  end

  def test_only_get_and_head_reach_the_app_shell
    _, web = app
    assert_equal 200, send_request(web, "HEAD", "/cronwatch/sw.js").status
    assert_equal 401, send_request(web, "POST", "/cronwatch/sw.js").status
    assert_equal 404, send_request(web, "POST", "/cronwatch/manifest.webmanifest", BEARER).status
  end

  def test_pages_link_the_manifest_icons_and_app_js_under_the_base
    cw, web = app(base_path: "/ops/cron")
    cw.run("h") { nil }
    ["/ops/cron/", "/ops/cron/jobs/h", "/ops/cron/nope", "/ops/cron/offline"].each do |path|
      html = send_request(web, "GET", path, BEARER).body
      assert_includes html, '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">', path
      assert_includes html, '<link rel="manifest" href="/ops/cron/manifest.webmanifest">', path
      assert_includes html, '<link rel="icon" href="/ops/cron/icons/icon.svg" type="image/svg+xml">', path
      assert_includes html, '<link rel="apple-touch-icon" href="/ops/cron/icons/apple-touch-icon.png">', path
      assert_includes html, '<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">', path
      assert_includes html, '<meta name="theme-color" content="#111113" media="(prefers-color-scheme: dark)">', path
      assert_includes html, '<meta name="mobile-web-app-capable" content="yes">', path
      assert_includes html, '<meta name="apple-mobile-web-app-capable" content="yes">', path
      assert_includes html, '<meta name="apple-mobile-web-app-title" content="CronWatch">', path
      assert_equal ['<script src="/ops/cron/app.js" defer></script>'], html.scan(%r{<script[^>]*>[^<]*</script>}), path
      assert_match(/@media\(display-mode:standalone\)\{\n\.top\{position:sticky;top:0/, html, path)
    end
  end

  def test_the_page_csp_allows_exactly_the_app_shell_and_data_stays_uncacheable
    cw, web = app
    cw.run("h") { nil }
    ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope", "/cronwatch/offline"].each do |path|
      assert_equal CSP, send_request(web, "GET", path, BEARER).headers["content-security-policy"], path
    end
    ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/api/jobs", "/cronwatch/api/jobs/h"].each do |path|
      assert_equal "no-store", send_request(web, "GET", path, BEARER).headers["cache-control"], path
    end
    assert_equal "no-store", send_request(web, "GET", "/cronwatch/").headers["cache-control"], "the sign-in page too"
  end

  def test_the_offline_page_is_public_plain_and_says_why
    _, web = app
    res = send_request(web, "GET", "/cronwatch/offline")
    assert_equal 200, res.status
    assert_equal "no-cache", res.headers["cache-control"]
    assert_equal "DENY", res.headers["x-frame-options"]
    assert_includes res.body, "<h1>You are offline</h1><p>CronWatch shows live data from your app, so it needs a connection.</p>"
  end

  def test_app_js_and_the_worker_are_the_minimal_scripts
    _, web = app
    app_js = send_request(web, "GET", "/cronwatch/app.js")
    assert_equal "text/javascript; charset=utf-8", app_js.headers["content-type"]
    assert_includes app_js.body, "navigator.serviceWorker.register("
    refute_match(/fetch|cookie|Storage|XMLHttpRequest|innerHTML|eval|import/, app_js.body)
    sw = send_request(web, "GET", "/cronwatch/sw.js")
    assert_equal "text/javascript; charset=utf-8", sw.headers["content-type"]
    assert_equal "no-cache", sw.headers["cache-control"]
    refute_match(/\.put\(/, sw.body, "nothing is added after install")
    assert_includes sw.body, 'credentials: "omit"'
  end

  def test_the_sign_in_cookie_is_scoped_to_the_base
    _, web = app(base_path: "/ops/cron")
    res = send_request(web, "GET", "/ops/cron/?token=tok")
    assert_match(%r{; Path=/ops/cron; HttpOnly; SameSite=Lax}, res.headers["set-cookie"])
  end

  def test_the_sign_in_page_takes_the_token_in_a_form
    _, web = app(base_path: "/ops/cron")
    page = send_request(web, "GET", "/ops/cron/jobs/x")
    assert_equal 401, page.status
    assert_match(%r{<form class="signin" method="get" action="/ops/cron/"><label for="token">Token</label><input id="token" name="token" type="password" autocomplete="current-password"[^>]*required><button class="primary" type="submit">Sign in</button></form>}, page.body)
    res = send_request(web, "GET", "/ops/cron/?token=tok")
    assert_equal 303, res.status
    assert_equal "/ops/cron/", res.headers["location"]
    refute_match(/class="signin"/, send_request(web, "GET", "/ops/cron/offline").body)
  end
end
