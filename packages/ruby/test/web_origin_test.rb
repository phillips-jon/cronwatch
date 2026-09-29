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

  # What `new URL(value).origin` gives for each, in Node 24.
  def test_the_origin_is_read_as_the_url_parser_reads_it
    {
      " https://app.example.com " => "https://app.example.com",
      "\thttps://a.example\n" => "https://a.example",
      "https://app.exa\tmple.com" => "https://app.example.com",
      "https://APP.example.com." => "https://app.example.com.",
      "https://user:pw@app.example.com" => "https://app.example.com",
      "https://app.example.com:" => "https://app.example.com",
      "https:app.example.com" => "https://app.example.com",
      "https:/app.example.com" => "https://app.example.com",
      "https:\\\\app.example.com" => "https://app.example.com",
      "https://[::1]:8080" => "https://[::1]:8080",
      "https://[0:0::1]" => "https://[::1]",
      "https://127.1" => "https://127.0.0.1",
      "https://0x7f.1" => "https://127.0.0.1",
      "https://app.example.com:0080" => "https://app.example.com:80",
      "https://a_b.example.com" => "https://a_b.example.com",
      "https://%61pp.example" => "https://app.example",
      "https://xn--bcher-kva.example" => "https://xn--bcher-kva.example",
      "https://65535.example:65535" => "https://65535.example:65535",
    }.each do |given, expected|
      assert_equal expected, Cronwatch::Web.configured_origin(given), given.inspect
    end
  end

  def test_an_origin_with_a_port_outside_1_to_65535_or_a_bad_host_raises
    ["https://app.example.com:0", "https://app.example.com:65536", "https://app.example.com:99999999999"].each do |given|
      error = assert_raises(ArgumentError, given) { Cronwatch::Web.configured_origin(given) }
      assert_equal "routes: origin has a port outside 1 to 65535, got #{Cronwatch::JS.json(given)}", error.message
    end
    ["https://ex ample.com", "https://app.example.com:8x", "https://[::1", "https://[nope]", "https://256.1.1.1", "https://1.2.3.4.5",
     "https://%zz.example", "https://%ff.example", "http://", "https:", "https://@", "https://a<b"].each do |given|
      error = assert_raises(ArgumentError, given) { Cronwatch::Web.configured_origin(given) }
      assert_match(/\Aroutes: origin must be an absolute URL/, error.message, given)
    end
    assert_raises(ArgumentError) { Cronwatch::Web.configured_origin(:sym) }
  end

  # A non-ASCII host becomes punycode through URI::IDNA, the simpleidn gem
  # or Addressable, whichever is there; with none of them it raises clearly.
  def test_a_non_ascii_host_is_converted_to_punycode_or_refused_clearly
    idna = Cronwatch::Web::Origin
    if defined?(::SimpleIDN) || defined?(::Addressable::IDNA) || defined?(URI::IDNA)
      assert_equal "https://xn--bcher-kva.example", Cronwatch::Web.configured_origin("https://Bücher.example")
    else
      stub = Module.new do
        def self.to_ascii(host) = host == "bücher.example" ? "xn--bcher-kva.example" : raise("unexpected #{host}")
      end
      Object.const_set(:SimpleIDN, stub)
      begin
        assert_equal "https://xn--bcher-kva.example", Cronwatch::Web.configured_origin("https://Bücher.example")
      ensure
        Object.send(:remove_const, :SimpleIDN)
      end
      # As in an app without the simpleidn gem.
      idna.define_singleton_method(:require) { |_name| raise LoadError }
      begin
        error = assert_raises(ArgumentError) { Cronwatch::Web.configured_origin("https://bücher.example") }
        assert_equal 'routes: origin has a host that is not ASCII, got "https://bücher.example"; write it in punycode ' \
                     "(xn--...) or add the simpleidn gem", error.message
      ensure
        idna.singleton_class.send(:remove_method, :require)
      end
    end
  end

  # Rack's base_url keeps the Host header's case; browsers send Origin lowercased.
  def test_a_mixed_case_host_matches_the_browsers_lowercase_origin
    cw, _, send = app("http://App.Example.com")
    cw.run("x") { nil }
    ok = send.call("POST", "/cronwatch/check", COOKIE.merge("origin" => "http://app.example.com", "host" => "App.Example.com"))
    assert_equal 303, ok.status
    forwarded = { "x-forwarded-proto" => "https", "x-forwarded-host" => "App.Example.com" }
    ok = send.call("POST", "/cronwatch/check", COOKIE.merge(forwarded, "origin" => "https://app.example.com"))
    assert_equal 303, ok.status
  end

  def test_the_development_sign_in_line_uses_the_public_origin_when_set_or_loopback_and_otherwise_leaves_the_host_out
    lines = []
    spoofed = { "x-forwarded-proto" => "https", "x-forwarded-host" => "attacker.example" }
    with_env("RAILS_ENV" => nil, "RACK_ENV" => "development", "CRONWATCH_TOKEN" => nil) do
      cw, = make
      [
        [{ origin: "https://app.example.com" }, "#{INTERNAL}/cronwatch/", {}],
        [{ origin: "https://app.example.com" }, "#{INTERNAL}/cronwatch/", spoofed],
        [{}, "http://localhost:3000/cronwatch/", {}],
        [{}, "http://app.localhost:3000/cronwatch/", {}],
        [{}, "http://127.0.0.1:3000/cronwatch/", {}],
        [{}, "http://127.8.9.10/cronwatch/", {}],
        [{}, "http://[::1]:3000/cronwatch/", {}],
        [{}, "#{INTERNAL}/cronwatch/", { "x-forwarded-host" => "localhost:5173" }],
        [{}, "#{INTERNAL}/cronwatch/", {}],
        [{}, "https://app.example.com/cronwatch/", {}],
        [{}, "http://localhost:3000/cronwatch/", spoofed],
        [{}, "http://localhost.example/cronwatch/", {}],
        [{}, "http://128.0.0.1/cronwatch/", {}],
        [{ base_path: "/" }, "http://attacker.example/", {}],
      ].each do |options, url, headers|
        before = $stdout
        $stdout = StringIO.new
        begin
          send_request(Cronwatch::Web.new(cw, base_path: "/cronwatch", **options), "GET", url, headers)
          lines << $stdout.string.chomp
        ensure
          $stdout = before
        end
      end
    end
    intro = "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: "
    hostless = " on this server (the first request's host is not local, so the link leaves it out)"
    expected = [
      ["https://app.example.com/cronwatch", ""],
      ["https://app.example.com/cronwatch", ""],
      ["http://localhost:3000/cronwatch", ""],
      ["http://app.localhost:3000/cronwatch", ""],
      ["http://127.0.0.1:3000/cronwatch", ""],
      ["http://127.8.9.10/cronwatch", ""],
      ["http://[::1]:3000/cronwatch", ""],
      ["http://localhost:5173/cronwatch", ""],
      ["/cronwatch", hostless],
      ["/cronwatch", hostless],
      ["/cronwatch", hostless],
      ["/cronwatch", hostless],
      ["/cronwatch", hostless],
      ["", hostless],
    ]
    assert_equal expected.length, lines.length
    expected.each_with_index do |(link, tail), i|
      token = lines[i][/token=([A-Za-z0-9_-]{43})/, 1]
      assert token, lines[i]
      assert_equal "#{intro}#{link}/?token=#{token}#{tail}", lines[i], "line #{i}"
    end
  end
end
