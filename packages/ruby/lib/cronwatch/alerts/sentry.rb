# frozen_string_literal: true

require "uri"

module Cronwatch
  module Alerts
    # Sends alerts to Sentry as events through the envelope endpoint, one
    # issue per job and alert type. Recoveries go too, as info events, unless
    # `recovered: false`.
    #
    #   Cronwatch::Alerts::Sentry.new(dsn: ENV.fetch("SENTRY_DSN"), environment: "production")
    #
    # Envelopes: https://develop.sentry.dev/sdk/data-model/envelopes/
    # Event payload: https://develop.sentry.dev/sdk/data-model/event-payloads/
    class Sentry
      Dsn = Struct.new(:endpoint, :public_key, keyword_init: true)

      attr_reader :name

      def initialize(dsn:, environment: nil, release: nil, recovered: true, link: nil, http: HTTP.default)
        dsn = Provider.require_option(dsn, "Cronwatch::Alerts::Sentry needs a dsn")
        parsed = Sentry.parse_dsn(dsn)
        @endpoint = parsed.endpoint
        @public_key = parsed.public_key
        @environment = environment
        @release = release
        @recovered = recovered
        @link = link
        @http = http
        @name = "sentry"
      end

      # "https://<key>@<host>/<project>" as the envelope endpoint and the public key.
      def self.parse_dsn(dsn)
        uri = begin
          URI.parse(dsn.to_s)
        rescue URI::Error
          nil
        end
        raise ArgumentError, "Cronwatch::Alerts::Sentry needs a valid dsn" unless uri&.scheme && uri.host

        segments = uri.path.to_s.split("/").reject(&:empty?)
        project = segments.pop
        user = uri.user
        if user.nil? || user.empty? || project.nil? || !/\A\d+\z/.match?(project)
          raise ArgumentError, "Cronwatch::Alerts::Sentry needs a dsn like https://<key>@<host>/<project>"
        end

        prefix = segments.empty? ? "" : "/#{segments.join("/")}"
        Dsn.new(endpoint: "#{uri.scheme.downcase}://#{SigV4.host(uri).downcase}#{prefix}/api/#{project}/envelope/",
                public_key: URI.decode_uri_component(user))
      end

      def call(alert)
        return if alert.type == :recovered && @recovered == false

        event_id = Provider.alert_id(alert)
        link = Provider.link_for(@link, alert)
        event = {
          "event_id" => event_id,
          "timestamp" => alert.at / 1000.0,
          "platform" => "other",
          "level" => Provider.severity(alert.type),
          "logger" => "cronwatch",
          "transaction" => alert.job,
          "environment" => @environment.nil? ? "production" : @environment,
        }
        event["release"] = @release if Provider.present?(@release)
        # The first line is the issue title.
        event["logentry"] = { "formatted" => Provider.cut("#{alert.title}\n\n#{alert.message}", 8192) }
        event["fingerprint"] = ["cronwatch", alert.job, alert.type.to_s]
        event["tags"] = { "job" => Provider.cut(alert.job, 199), "type" => alert.type.to_s }
        extra = {}
        extra["triage"] = alert.triage if Provider.present?(alert.triage)
        extra["link"] = link if link
        extra["details"] = Naming.to_json_value(alert.details)
        extra["run"] = Provider.run_summary(alert)
        event["extra"] = extra
        payload = JS.json(event)
        envelope = [
          JS.json({ "event_id" => event_id }),
          JS.json({ "type" => "event", "content_type" => "application/json", "length" => payload.bytesize }),
          payload,
        ].join("\n") + "\n"
        headers = {
          "content-type" => "application/x-sentry-envelope",
          "x-sentry-auth" => "Sentry sentry_version=7, sentry_key=#{@public_key}, sentry_client=cronwatch",
        }
        Provider.post(@http, "Sentry", @endpoint, headers, envelope, [@public_key])
        nil
      end
    end
  end
end
