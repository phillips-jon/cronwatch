# frozen_string_literal: true

require_relative "../test_helper"
require "cronwatch/web"
require "digest"

# Shared by the web tests: requests in the shape of the SDK tests' `new Request(...)`.
module WebHelpers
  include TestHelpers

  DIGEST = Digest::SHA256.hexdigest("cronwatch-cookie:tok")
  COOKIE = { "cookie" => "cronwatch_token=#{DIGEST}" }.freeze
  BEARER = { "authorization" => "Bearer tok" }.freeze

  # A response, read the way the SDK tests read a fetch Response.
  Response = Struct.new(:status, :headers, :body) do
    def json = JSON.parse(body)
  end

  # Sends one request to a Rack app. `url` may be a path on http://app.test.
  def send_request(app, method, url, headers = {}, body = nil, script_name: nil)
    url = "http://app.test#{url}" if url.start_with?("/")
    options = { method: method }
    options[:input] = body unless body.nil?
    # env_for refuses a malformed escape, which some tests send on purpose,
    # so the path and query go into the env as they were written.
    origin, target = url.match(%r{\A([a-z]+://[^/]+)(.*)\z}).captures
    path, query = target.split("?", 2)
    env = Rack::MockRequest.env_for("#{origin}/", options)
    env["PATH_INFO"] = path.empty? ? "/" : path
    env["QUERY_STRING"] = query.to_s
    env.delete("CONTENT_TYPE")
    headers.each do |name, value|
      key = name.to_s.tr("-", "_").upcase
      key = "HTTP_#{key}" unless %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)
      env[key] = value
    end
    if script_name
      env["SCRIPT_NAME"] = script_name
      env["PATH_INFO"] = env["PATH_INFO"].delete_prefix(script_name)
    end
    status, response_headers, response_body = app.call(env)
    text = +""
    response_body.each { |part| text << part }
    response_body.close if response_body.respond_to?(:close)
    Response.new(status, response_headers, text)
  end

  # Sets environment variables for the block and puts them back after. nil unsets.
  def with_env(vars)
    before = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    before.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
