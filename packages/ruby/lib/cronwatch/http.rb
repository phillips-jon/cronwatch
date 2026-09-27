# frozen_string_literal: true

require "net/http"
require "timeout"
require "uri"

module Cronwatch
  # POSTs for the alert channels. Anything with `post(url, body, headers)`
  # returning a Response can stand in for it, which is how the tests run.
  module HTTP
    TIMEOUT = 10

    Response = Struct.new(:status, :body, keyword_init: true) do
      def ok? = status >= 200 && status < 300
    end

    # The request took longer than its deadline. fetch's message for it.
    class TimeoutError < ::Timeout::Error
      def initialize(message = "The operation was aborted due to timeout")
        super
      end
    end

    class NetHTTP
      # The deadline is the whole request's, as fetch's
      # AbortSignal.timeout(10_000) is; `timeout` is for tests.
      def initialize(timeout: TIMEOUT)
        @timeout = timeout
      end

      # Header values are sent with the whitespace around them trimmed, as
      # fetch trims them, so a credential read with a trailing newline still
      # sends. Past the deadline before an answer, raises HTTP::TimeoutError;
      # past it while the body is still arriving, returns the answer with an
      # empty body, as the SDK's channels treat a body they could not read.
      def post(url, body, headers)
        uri = URI(url)
        deadline = HTTP.monotonic + @timeout
        request = Net::HTTP::Post.new(uri.request_uri)
        headers.each { |k, v| request[k] = HTTP.trim_header(v) }
        request.body = body
        http = connection(uri)
        http.open_timeout = HTTP.remaining(deadline)
        http.start do |conn|
          remaining = HTTP.remaining(deadline)
          conn.read_timeout = remaining
          conn.write_timeout = remaining
          conn.request(request) do |response|
            return Response.new(status: response.code.to_i, body: read_body(conn, response, deadline))
          end
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
        raise TimeoutError
      end

      # A connection that gives up after ten seconds, as the SDK's requests do.
      def connection(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout
        http
      end

      private

      # The body, read in chunks until the deadline; "" when it passes first.
      def read_body(conn, response, deadline)
        chunks = []
        conn.read_timeout = HTTP.remaining(deadline)
        response.read_body do |chunk|
          raise TimeoutError if HTTP.monotonic >= deadline

          chunks << chunk
          conn.read_timeout = HTTP.remaining(deadline)
        end
        chunks.join.b
      rescue Net::ReadTimeout, TimeoutError
        ""
      end
    end

    module_function

    def default
      @default ||= NetHTTP.new
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Seconds left before `deadline`, never quite zero (Net::HTTP reads 0 as no wait).
    def remaining(deadline)
      [deadline - monotonic, 0.001].max
    end

    # A header value without the spaces, tabs and line breaks around it, as fetch sends it.
    def trim_header(value)
      value.to_s.gsub(/\A[ \t\r\n]+|[ \t\r\n]+\z/, "")
    end

    # Compares two secrets without stopping at the first differing character.
    def constant_time_equal?(a, b)
      return false unless a.bytesize == b.bytesize

      diff = 0
      a.bytes.zip(b.bytes) { |x, y| diff |= x ^ y }
      diff.zero?
    end
  end
end
