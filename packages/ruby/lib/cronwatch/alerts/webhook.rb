# frozen_string_literal: true

require "openssl"

module Cronwatch
  module Alerts
    # POSTs the alert as JSON to any URL. The body is the alert's JSON:
    # { type, run, details, job, definition, title, message, at, triage }.
    # With a secret, each request carries `X-CronWatch-Signature: sha256=<hex>`,
    # the HMAC-SHA256 of the raw body, so the receiver can verify it.
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

      def call(alert)
        body = JS.json(alert.to_h)
        headers = { "content-type" => "application/json", "user-agent" => "cronwatch" }.merge(@headers.transform_keys(&:to_s))
        if @secret && !@secret.empty?
          headers["x-cronwatch-signature"] = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @secret, body)}"
        end
        response = @http.post(@url, body, headers)
        # Only the origin: a webhook URL's path or query often is the credential.
        raise "Webhook #{Webhook.origin(@url)} answered #{response.status}" unless response.ok?
      end

      def self.origin(url)
        uri = URI(url)
        raise URI::InvalidURIError unless uri.scheme && uri.host

        port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
        "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}"
      rescue URI::Error, ArgumentError
        "(invalid URL)"
      end
    end
  end
end
