# frozen_string_literal: true

require "openssl"

module Cronwatch
  module Alerts
    # POSTs the alert as JSON to any URL. The body is `"schema": 1` and then
    # the alert's JSON: { schema, type, run, details, job, definition, title,
    # message, at, triage }, described by https://cronwatch.dev/schemas/webhook/1.json.
    # With a secret, each request carries `X-CronWatch-Signature: sha256=<hex>`,
    # the HMAC-SHA256 of the raw body (Webhook.signature), so the receiver can verify it. Header
    # values are trimmed. A redirect is an error, not followed (the headers
    # and the signature would go with it): point the url at where the
    # receiver really is.
    class Webhook
      attr_reader :name

      def initialize(url:, headers: {}, secret: nil, http: HTTP.default)
        raise ArgumentError, "Cronwatch::Alerts::Webhook needs a url" if url.nil? || url.to_s.empty?

        @name = "webhook"
        @url = url
        @headers = headers || {}
        @secret = secret
        @http = http
      end

      # The version of the body's shape, its first key. It goes up only in a
      # major release; fields are added within one.
      SCHEMA = 1

      # The HMAC-SHA256 of `body` with `secret`, as lowercase hex, without the
      # `sha256=` the header puts before it. A receiver compares it with the
      # header in constant time (Rack::Utils.secure_compare).
      def self.signature(secret, body)
        OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, body.to_s)
      end

      def call(alert)
        body = JS.json({ "schema" => SCHEMA }.merge(alert.to_h))
        headers = { "content-type" => "application/json", "user-agent" => "cronwatch" }
        # A pasted Authorization value often carries a stray space or newline, which a header would refuse.
        @headers.each { |name, value| headers[name.to_s] = value.is_a?(String) ? JS.trim(value) : value }
        if @secret && !@secret.empty?
          headers["x-cronwatch-signature"] = "sha256=#{Webhook.signature(@secret, body)}"
        end
        response = @http.post(@url, body, headers)
        # Only the origin: a webhook URL's path or query often is the credential.
        raise "Webhook #{Webhook.origin(@url)} answered #{response.status}" unless response.ok?
      end

      def self.origin(url)
        uri = URI(HTTP.clean_url(url))
        raise URI::InvalidURIError unless uri.scheme && uri.host

        port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
        "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}"
      rescue URI::Error, ArgumentError
        "(invalid URL)"
      end
    end
  end
end
