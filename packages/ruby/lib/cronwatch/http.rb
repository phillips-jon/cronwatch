# frozen_string_literal: true

require "net/http"
require "uri"

module Cronwatch
  # POSTs for the alert channels. Anything with `post(url, body, headers)`
  # returning a Response can stand in for it, which is how the tests run.
  module HTTP
    TIMEOUT = 10

    Response = Struct.new(:status, :body, keyword_init: true) do
      def ok? = status >= 200 && status < 300
    end

    class NetHTTP
      def post(url, body, headers)
        uri = URI(url)
        request = Net::HTTP::Post.new(uri.request_uri)
        headers.each { |k, v| request[k] = v }
        request.body = body
        response = connection(uri).request(request)
        Response.new(status: response.code.to_i, body: response.body.to_s)
      end

      # A connection that gives up after ten seconds, as the SDK's requests do.
      def connection(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT
        http.write_timeout = TIMEOUT
        http
      end
    end

    module_function

    def default
      @default ||= NetHTTP.new
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
