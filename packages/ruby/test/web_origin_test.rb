# frozen_string_literal: true

require_relative "web/helpers"
require "stringio"

# The SDK's routes origin tests (routes-origin.test.ts), against
# Cronwatch::Web's `origin:`. The SDK's trustProxy has no counterpart: Rack
# already reads X-Forwarded-Proto and X-Forwarded-Host into the request's
# origin, as Rails does, and `origin:` pins it.
class WebOriginTest < Minitest::Test
  include WebHelpers

  FORM = { "content-type" => "application/x-www-form-urlencoded" }.freeze
  INTERNAL = "http://10.0.0.5:8080"

  # An app that sees its requests on an internal URL, as it does behind a proxy.
  def app(internal = INTERNAL, **options)
    cw, clock, = make
    web = Cronwatch::Web.new(cw, token: "tok", base_path: "/cronwatch", **options)
    send = ->(method, path, headers = {}, body = nil) { send_request(web, method, "#{internal}#{path}", headers, body) }
    [cw, clock, send]
  end

  def silenced?(cw)
    !cw.job_summary("x").silenced_until.nil?
  end

  def test_by_default_the_requests_origin_is_the_origin
    cw, _, send = app
    cw.run("x") { nil }
    refused = send.call("POST", "/cronwatch/jobs/x/silence", COOKIE.merge(FORM, "origin" => "https://app.example.com"), "for=1h")
    assert_equal 403, refused.status
    refute silenced?(cw)
    ok = send.call("POST", "/cronwatch/jobs/x/silence", COOKIE.merge(FORM, "origin" => INTERNAL), "for=1h")
    assert_equal 303, ok.status
    sign_in = send.call("GET", "/cronwatch/?token=tok")
    refute_match(/Secure/, sign_in.headers["set-cookie"])
  end

  def test_origin_replaces_the_requests_origin_for_writes_sign_in_and_redirects
    cw, clock, send = app(origin: "https://app.example.com/ignored/path")
    cw.run("x") { nil }
    internal = send.call("POST", "/cronwatch/jobs/x/silence", COOKIE.merge(FORM, "origin" => INTERNAL), "for=1h")
    assert_equal 403, internal.status, "the internal origin is now foreign"
    refute silenced?(cw)

    referer = "https://app.example.com/cronwatch/jobs/x"
    ok = send.call("POST", "/cronwatch/jobs/x/silence", COOKIE.merge(FORM, "origin" => "https://app.example.com", "referer" => referer), "for=2h")
    assert_equal 303, ok.status
    assert_equal referer, ok.headers["location"], "the Referer on the public origin is followed back"
    assert_equal clock.now + (2 * HOUR), cw.job_summary("x").silenced_until

    back = send.call("POST", "/cronwatch/check", COOKIE.merge("origin" => "https://app.example.com", "referer" => "#{INTERNAL}/cronwatch/jobs/x"))
    assert_equal 303, back.status
    assert_equal "/cronwatch/", back.headers["location"], "a Referer on the internal origin is not followed"

    sign_in = send.call("GET", "/cronwatch/jobs/x?token=tok")
    assert_equal 303, sign_in.status
    assert_equal "/cronwatch/jobs/x", sign_in.headers["location"]
    assert_match(/; Secure\z/, sign_in.headers["set-cookie"], "the public origin is https, so the cookie is Secure")
  end

  def test_an_http_origin_leaves_the_cookie_without_secure_on_an_https_request
    _, _, send = app("https://app.test", origin: "http://app.example.com")
    refute_match(/Secure/, send.call("GET", "/cronwatch/?token=tok").headers["set-cookie"])
  end

  # Rack follows X-Forwarded-Proto and X-Forwarded-Host by default; origin: pins the origin whatever they say.
  def test_origin_takes_precedence_over_forwarded_headers
    cw, _, send = app
    cw.run("x") { nil }
    forwarded = { "x-forwarded-proto" => "https", "x-forwarded-host" => "other.example" }
    assert_equal 303, send.call("POST", "/cronwatch/check", COOKIE.merge(forwarded, "origin" => "https://other.example")).status,
                 "without origin:, Rack's reading of the forwarded headers is the origin"

    cw, _, send = app(origin: "https://app.example.com")
    cw.run("x") { nil }
    assert_equal 403, send.call("POST", "/cronwatch/check", COOKIE.merge(forwarded, "origin" => "https://other.example")).status
    assert_equal 303, send.call("POST", "/cronwatch/check", COOKIE.merge(forwarded, "origin" => "https://app.example.com")).status
    back = send.call("POST", "/cronwatch/check", COOKIE.merge(forwarded, "origin" => "https://app.example.com", "referer" => "https://other.example/cronwatch/jobs/x"))
    assert_equal "/cronwatch/", back.headers["location"], "a Referer on the forwarded origin is not followed"
    sign_in = send.call("GET", "/cronwatch/?token=tok", { "x-forwarded-proto" => "http" })
    assert_match(/; Secure\z/, sign_in.headers["set-cookie"])
  end

  def test_an_origin_that_is_not_an_http_or_https_url_raises_when_the_app_is_made
    cw, = make
    error = assert_raises(ArgumentError) { Cronwatch::Web.new(cw, token: "tok", origin: "app.example.com") }
    assert_equal 'routes: origin must be an absolute URL such as "https://app.example.com", got "app.example.com"', error.message
    error = assert_raises(ArgumentError) { Cronwatch::Web.new(cw, token: "tok", origin: "ftp://app.example.com") }
    assert_equal 'routes: origin must be http or https, got "ftp://app.example.com"', error.message
    assert_raises(ArgumentError) { Cronwatch::Web.new(cw, token: "tok", origin: "https://") }
    assert_raises(ArgumentError) { Cronwatch::Web.new(cw, token: "tok", origin: "https://bad host") }
    Cronwatch::Web.new(cw, token: "tok", origin: "")
    Cronwatch::Web.new(cw, token: "tok", origin: nil)
  end

  def test_the_origin_is_normalised_to_scheme_host_and_port
    {
      "https://App.Example.com/cronwatch?x=1#y" => "https://app.example.com",
      "HTTPS://app.example.com:443/" => "https://app.example.com",
      "http://app.example.com:80" => "http://app.example.com",
      "http://localhost:3000/" => "http://localhost:3000",
      "https://app.example.com:8443" => "https://app.example.com:8443",
    }.each do |given, expected|
      assert_equal expected, Cronwatch::Web.configured_origin(given), given
    end
    assert_nil Cronwatch::Web.configured_origin("")
  end

  def test_the_development_sign_in_line_uses_the_public_origin
    lines = []
    with_env("RAILS_ENV" => nil, "RACK_ENV" => "development", "CRONWATCH_TOKEN" => nil) do
      cw, = make
      forwarded = { "x-forwarded-proto" => "https", "x-forwarded-host" => "proxied.example" }
      [{ origin: "https://app.example.com" }, {}, {}].zip([{}, forwarded, {}]).each do |options, headers|
        before = $stdout
        $stdout = StringIO.new
        begin
          send_request(Cronwatch::Web.new(cw, base_path: "/cronwatch", **options), "GET", "#{INTERNAL}/cronwatch/", headers)
          lines << $stdout.string.chomp
        ensure
          $stdout = before
        end
      end
    end
    assert_match(%r{Sign in: https://app\.example\.com/cronwatch/\?token=}, lines[0])
    assert_match(%r{Sign in: https://proxied\.example/cronwatch/\?token=}, lines[1], "Rack's forwarded origin, without origin:")
    assert_match(%r{Sign in: http://10\.0\.0\.5:8080/cronwatch/\?token=}, lines[2])
  end
end
