# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"

module Cronwatch
  # The dashboard and the small JSON API, as a Rack app: the SDK's routes
  # (routes/index.ts) with the same URLs, JSON, auth, CSRF rules and headers,
  # so @cronwatch/mcp works against a Ruby app as it does against a Node one.
  #
  #   # config/routes.rb
  #   mount Cronwatch::Web.new => "/cronwatch"
  #
  #   # config.ru, standalone
  #   run Cronwatch::Web.new(CW)
  #
  # token:     required to reach anything. Send it as `Authorization: Bearer <token>`,
  #            or open the dashboard once with `?token=<token>` and a cookie is set.
  #            Defaults to ENV["CRONWATCH_TOKEN"]; an empty string counts as unset.
  #            With no token while Cronwatch::Environment is development or
  #            test, the app makes a random one and prints a sign-in link to
  #            stdout on its first request; with no token otherwise it answers
  #            503. Pass `token: nil` to opt out and serve it open everywhere,
  #            for example behind your own auth. /api/check also accepts the
  #            client's cron_secret as a bearer, for a platform cron.
  # base_path: where the app is mounted, so links resolve. Defaults to the
  #            mount point (SCRIPT_NAME), which is right under Rails' `mount`.
  class Web
    # Tells "token not given" (read CRONWATCH_TOKEN) from "token: nil" (open on purpose).
    UNSET = Object.new.freeze
    COOKIE = "cronwatch_token"
    DEFAULT_RUNS = 20
    MAX_RUNS = 500
    COOKIE_MAX_AGE = 60 * 60 * 24 * 30

    CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; form-action 'self'; " \
          "frame-ancestors 'none'; base-uri 'none'"
    # same-origin rather than no-referrer: under no-referrer browsers send
    # `Origin: null` on form posts, which the CSRF check would refuse, and the
    # forms redirect back to the page named by the same-origin Referer.
    SECURITY_HEADERS = {
      "x-content-type-options" => "nosniff", "referrer-policy" => "same-origin", "x-robots-tag" => "noindex",
    }.freeze
    BEARER = Regexp.new("\\ABearer[#{JS::WHITESPACE}]+", Regexp::IGNORECASE)
    DECIMAL = /\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/
    RADIX = { "x" => 16, "o" => 8, "b" => 2 }.freeze

    def initialize(client = nil, token: UNSET, base_path: nil)
      @client = client
      @opted_out = token.nil?
      given = token.equal?(UNSET) ? nil : token
      @token = @opted_out ? nil : [given, ENV.fetch("CRONWATCH_TOKEN", nil)].map(&:to_s).find { |t| !t.empty? }
      @base_path = base_path&.to_s&.sub(%r{/+\z}, "")
      # A Rack app cannot reliably tell a local caller from a remote one
      # (proxies, tunnels and a server bound to every interface all look
      # alike), so development gets a token too: made here, and shown only in
      # the server log.
      @generated = @token.nil? && !@opted_out && Client.development?
      @token = Web.development_token if @generated
      @announced = false
      @announce_lock = Mutex.new
    end

    # A token for one app in development, when none is configured: 32 random
    # bytes, base64url (43 characters).
    def self.development_token
      Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
    end

    # The line a development token is announced with, printed once to stdout
    # on the app's first request. `origin` is that request's origin (scheme,
    # host and any port), `base` the base path without a trailing slash (""
    # when mounted at the root).
    def self.development_sign_in_line(origin, base, token)
      "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. " \
        "Sign in: #{origin}#{base}/?token=#{token}"
    end

    # The client given, or Cronwatch.client when none was.
    def client
      @client || Cronwatch.client
    end

    def call(env)
      wants_html = true
      base = @base_path || env["SCRIPT_NAME"].to_s.sub(%r{/+\z}, "")
      begin
        request = Request.new(env)
        path = strip_base(request.pathname, base)
        wants_html = !path.start_with?("/api")
        serve(request, path, wants_html, base)
      rescue StandardError => e
        begin
          client.report(e, "routes")
        rescue StandardError
          # Reporting must not turn a 500 into an exception.
        end
        if wants_html
          html(HTML.message_page("Something went wrong", "The request failed and the error was reported.", base), 500)
        else
          api({ ok: false, error: "Internal error" }, 500)
        end
      end
    end

    private

    def serve(request, path, wants_html, base)
      cw = client
      method = request.verb

      announce(request, base) if @generated && !@announced

      # No token outside development: fail closed.
      if !@token && !@opted_out
        return wants_html ? html(HTML.message_page("CronWatch routes are locked", "Set CRONWATCH_TOKEN (or pass token: to Cronwatch::Web.new), or pass token: nil to serve them open behind your own auth.", base), 503) : api({ ok: false, error: "CRONWATCH_TOKEN is not set" }, 503)
      end

      if method != "GET" && method != "HEAD" && cross_site?(request)
        return wants_html ? html(HTML.message_page("Cross-site request refused", "Changes can only be made from the dashboard itself.", base), 403) : api({ ok: false, error: "Cross-site request refused" }, 403)
      end

      authorization = request.header("authorization")
      bearer = authorization&.sub(BEARER, "")
      if @token
        # ?token= is only the sign-in that moves the token into a cookie.
        query = wants_html && method == "GET" ? request.query("token") : nil
        cookie = read_cookie(request, COOKIE)
        secret = cw.cron_secret
        cron_secret_ok = path == "/api/check" && !bearer.nil? && !secret.nil? && HTTP.constant_time_equal?(bearer, secret)
        token_ok =
          if !bearer.nil? then HTTP.constant_time_equal?(bearer, @token)
          elsif !query.nil? then HTTP.constant_time_equal?(query, @token)
          else !cookie.nil? && HTTP.constant_time_equal?(cookie, cookie_value(@token))
          end
        unless cron_secret_ok || token_ok
          if @generated
            return wants_html ? html(HTML.message_page("Sign in", "CRONWATCH_TOKEN is not set, so this development server made a token. The sign-in link is in the server log: open it once and this browser stays signed in.", base), 401) : api({ ok: false, error: "Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log" }, 401)
          end
          return wants_html ? html(HTML.message_page("Sign in", "Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed in.", base), 401) : api({ ok: false, error: "Unauthorized" }, 401)
        end
        unless query.nil?
          # Move the token from the URL into a cookie so it is not in history or logs.
          secure = request.https? ? "; Secure" : ""
          return redirect(request.pathname + request.search_without("token"),
                          "set-cookie" => "#{COOKIE}=#{cookie_value(@token)}; Path=#{base.empty? ? "/" : base}; HttpOnly; SameSite=Lax; Max-Age=#{COOKIE_MAX_AGE}#{secure}")
        end
      end

      parts = path.split("/").reject(&:empty?).map { |part| safe_decode(part) }
      if parts.include?(nil)
        return wants_html ? html(HTML.message_page("Bad request", "The path is not valid.", base), 400) : api({ ok: false, error: "Bad path" }, 400)
      end

      # HTML
      if method == "GET" && path == "/"
        entries = cw.jobs_with_runs(20)
        runs_by_job = entries.to_h { |entry| [entry.job.name, entry.runs] }
        return html(HTML.dashboard_page(entries.map(&:job), runs_by_job, cw.now, base, nil))
      end
      if method == "GET" && parts[0] == "jobs" && parts.length == 2
        job = cw.job_summary(parts[1])
        return html(HTML.message_page("No such job", "#{parts[1]} is not in the store.", base), 404) unless job

        return html(HTML.job_page(job, cw.runs(job.name, 50), cw.now, base))
      end
      if method == "POST" && path == "/check"
        cw.check
        return redirect_back(request, base)
      end
      if method == "POST" && parts[0] == "jobs" && parts.length == 3
        name = parts[1]
        action = parts[2]
        if action == "forget"
          cw.forget(name)
          return redirect("#{base}/")
        end
        return html(HTML.message_page("Not found", path, base), 404) unless %w[silence unsilence].include?(action)
        return html(HTML.message_page("No such job", "#{name} is not in the store.", base), 404) unless cw.job_summary(name)

        if action == "silence"
          begin
            duration = silence_duration(read_body(request)["for"])
          rescue ArgumentError => e
            return html(HTML.message_page("Not silenced", e.message, base), 400)
          end
          cw.silence(name, duration)
        else
          cw.unsilence(name)
        end
        return redirect_back(request, base)
      end

      return serve_api(request, method, parts.drop(1), bearer) if parts[0] == "api"

      html(HTML.message_page("Not found", path, base), 404)
    end

    def serve_api(request, method, rest, bearer)
      cw = client
      return api({ ok: true, jobs: cw.jobs }) if method == "GET" && rest[0] == "jobs" && rest.length == 1

      if rest[0] == "jobs" && rest.length == 2
        name = rest[1]
        if method == "GET"
          job = cw.job_summary(name)
          return api({ ok: false, error: "No such job" }, 404) unless job

          return api({ ok: true, job: job, runs: cw.runs(name, runs_limit(request.query("runs"))) })
        end
        if method == "DELETE"
          return api({ ok: false, error: "No such job" }, 404) unless cw.job_summary(name)

          cw.forget(name)
          return api({ ok: true })
        end
      end
      if method == "POST" && rest[0] == "jobs" && rest.length == 3
        name = rest[1]
        return api({ ok: false, error: "No such job" }, 404) unless cw.job_summary(name)

        if rest[2] == "silence"
          body = read_body(request)
          begin
            duration = silence_duration(body.key?("for") ? body["for"] : request.query("for"))
          rescue ArgumentError => e
            return api({ ok: false, error: e.message }, 400)
          end
          return api({ ok: true, state: cw.silence(name, duration) })
        end
        return api({ ok: true, state: cw.unsilence(name) }) if rest[2] == "unsilence"
      end
      if rest[0] == "check" && rest.length == 1
        # A page cannot send an Authorization header cross-site, so a GET
        # may only run the check when it carries a bearer (token or cron secret).
        if method == "GET" && bearer.nil?
          return api({ ok: false, error: "Use POST, or GET with an Authorization bearer" }, 405, "allow" => "POST")
        end
        return api({ "ok" => true }.merge(cw.check.to_h)) if %w[GET POST].include?(method)
      end
      if method == "GET" && rest[0] == "runs" && rest.length == 2
        run = cw.get_run(rest[1])
        return run ? api({ ok: true, run: run }) : api({ ok: false, error: "No such run" }, 404)
      end
      api({ ok: false, error: "Not found" }, 404)
    end

    # Prints the development sign-in link, once per app.
    def announce(request, base)
      first = @announce_lock.synchronize do
        next false if @announced

        @announced = true
      end
      return unless first

      $stdout.puts(Web.development_sign_in_line(request.origin, base, @token))
      $stdout.flush
    end

    # The cookie holds a digest of the token, so a leaked cookie does not reveal the bearer token itself.
    def cookie_value(token)
      Digest::SHA256.hexdigest("cronwatch-cookie:#{token}")
    end

    def strip_base(pathname, base)
      path = pathname.start_with?(base) ? pathname[base.length..] : pathname
      path = "/" if path.empty?
      path = path[0...-1] if path.length > 1 && path.end_with?("/")
      path
    end

    def read_cookie(request, name)
      header = request.header("cookie")
      return nil if header.nil? || header.empty?

      header.split(";").each do |part|
        key, *rest = JS.trim(part).split("=", -1)
        # A malformed escape counts as no cookie.
        return safe_decode(rest.join("=")) if key == name
      end
      nil
    end

    # decodeURIComponent, or nil where it would throw: a bad escape, or bytes that are not UTF-8.
    def safe_decode(value)
      return nil if value.match?(/%(?![0-9A-Fa-f]{2})/)

      decoded = value.b.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8)
      decoded.valid_encoding? ? decoded : nil
    end

    # A browser attaches Origin or Sec-Fetch-Site to a cross-site form post, and
    # a page cannot forge either. Non-browser clients send neither.
    def cross_site?(request)
      origin = request.header("origin")
      return true if !origin.nil? && origin != request.origin

      site = request.header("sec-fetch-site")
      !site.nil? && site != "same-origin" && site != "none"
    end

    # The form fields or JSON object of a request, each value as String(value)
    # gives it in JavaScript. The body is read as the SDK's request.json()
    # reads it: bytes that are not UTF-8 become U+FFFD, and a leading byte
    # order mark is dropped.
    def read_body(request)
      type = request.header("content-type") || ""
      if type.include?("application/json")
        data = JSON.parse(Output.utf8(request.body).delete_prefix("﻿"))
        return data.to_h { |k, v| [k.to_s, js_string(v)] } if data.is_a?(Hash)
        return data.each_with_index.to_h { |v, i| [i.to_s, js_string(v)] } if data.is_a?(Array)
      elsif type.include?("application/x-www-form-urlencoded") || type.include?("multipart/form-data")
        return request.form.transform_values { |v| form_value(v) }
      end
      {}
    rescue StandardError
      {}
    end

    # String(value) for a parsed JSON value.
    def js_string(value)
      case value
      when nil then "null"
      when Array then value.map { |v| v.nil? ? "" : js_string(v) }.join(",")
      when Hash then "[object Object]"
      when Numeric then JS.number(value)
      else value.to_s
      end
    end

    # String(value) for a form field Rack parsed: a file is "[object File]".
    def form_value(value)
      case value
      when String then Output.utf8(value)
      when Hash then value.key?(:tempfile) ? "[object File]" : "[object Object]"
      when Array then value.map { |v| form_value(v) }.join(",")
      else js_string(value)
      end
    end

    # Absent means one hour; a number or numeric string is milliseconds. Raises on anything else.
    def silence_duration(value)
      return "1h" if value.nil?

      text = JS.trim(value.to_s)
      duration = text.match?(/\A\d+(\.\d+)?\z/) ? whole(Float(text)) : text
      Duration.parse(duration, "silence duration")
      duration
    end

    def runs_limit(value)
      n = value.nil? || JS.trim(value).empty? ? Float::NAN : js_number(value)
      JS.finite?(n) ? n.truncate.clamp(1, MAX_RUNS) : DEFAULT_RUNS
    end

    # Number(string): decimal, 0x/0o/0b, Infinity, or NaN.
    def js_number(value)
      text = JS.trim(value)
      return 0 if text.empty?
      # Ruby's Float() wants a digit on both sides of the point; JavaScript does not.
      return Float(text.sub(/\A([+-]?)\./, "\\10.").sub(/\.(?=[eE]|\z)/, ".0")) if DECIMAL.match?(text)
      return text.start_with?("-") ? -Float::INFINITY : Float::INFINITY if /\A[+-]?Infinity\z/.match?(text)

      if (m = /\A0([xXoObB])([0-9a-fA-F]+)\z/.match(text))
        return Integer(m[2], RADIX.fetch(m[1].downcase))
      end

      Float::NAN
    rescue ArgumentError
      Float::NAN
    end

    def whole(number)
      number.finite? && number == number.floor ? number.to_i : number
    end

    def redirect_back(request, base)
      referer = request.header("referer") || ""
      redirect(referer.start_with?("#{request.origin}/") ? referer : "#{base}/")
    end

    def api(body, status = 200, headers = {})
      text = JS.json(body)
      [status, {
        "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store",
        "content-length" => text.bytesize.to_s, **SECURITY_HEADERS, **headers,
      }, [text]]
    end

    def redirect(location, headers = {})
      [303, { "location" => location, "cache-control" => "no-store", **SECURITY_HEADERS, **headers }, []]
    end

    def html(body, status = 200)
      [status, {
        "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store",
        "content-security-policy" => CSP, "x-frame-options" => "DENY", "content-length" => body.bytesize.to_s,
        **SECURITY_HEADERS,
      }, [body]]
    end

    # What the routes need from a Rack env, read the way the SDK reads a fetch Request.
    class Request
      attr_reader :env

      def initialize(env)
        @env = env
        @rack = Rack::Request.new(env)
      end

      def verb
        @env["REQUEST_METHOD"].to_s.upcase
      end

      # The path as the browser asked for it, still percent-encoded, mount point included.
      def pathname
        path = "#{@env["SCRIPT_NAME"]}#{@env["PATH_INFO"]}"
        path.empty? ? "/" : path
      end

      def header(name)
        key = name.tr("-", "_").upcase
        key = "HTTP_#{key}" unless %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)
        @env[key]
      end

      # scheme://host[:port], the page's origin.
      def origin
        @rack.base_url
      end

      def https?
        @rack.scheme == "https"
      end

      # URLSearchParams#get: the first value, or nil.
      def query(name)
        pair = Request.parse_query(@env["QUERY_STRING"].to_s).find { |k, _| k == name }
        pair && pair[1]
      end

      # The query string with a parameter removed, "" when nothing is left, as
      # URL#search reads after searchParams.delete.
      def search_without(name)
        pairs = Request.parse_query(@env["QUERY_STRING"].to_s).reject { |k, _| k == name }
        pairs.empty? ? "" : "?#{URI.encode_www_form(pairs)}"
      end

      def body
        input = @env["rack.input"]
        return "" unless input

        input.rewind if input.respond_to?(:rewind)
        text = input.read.to_s
        input.rewind if input.respond_to?(:rewind)
        text.force_encoding(Encoding::UTF_8)
      end

      # The form's fields, as Rack parses them. Rack keeps what it parsed, so
      # a body Rack::MethodOverride (or anything else) already read, which
      # cannot be read twice, still gives its fields.
      def form
        fields = @rack.POST
        fields.each_with_object({}) { |(k, v), out| out[Output.utf8(k)] = v }
      end

      # application/x-www-form-urlencoded parsing as URLSearchParams does it:
      # "+" is a space, and a bad escape is kept as written rather than refused.
      def self.parse_query(text)
        text = text.delete_prefix("?")
        text.split("&").reject(&:empty?).map do |pair|
          key, value = pair.include?("=") ? pair.split("=", 2) : [pair, ""]
          [decode(key), decode(value)]
        end
      end

      def self.decode(text)
        text.tr("+", " ").b.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
