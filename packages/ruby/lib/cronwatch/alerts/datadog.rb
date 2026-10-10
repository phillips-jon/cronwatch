# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Posts alerts to the Datadog event stream (Events API v1), aggregated per
    # job and alert type. `site` is your Datadog site: "datadoghq.com" (the
    # default), "datadoghq.eu", "us3.datadoghq.com", "us5.datadoghq.com",
    # "ap1.datadoghq.com", "ddog-gov.com". Every event is tagged cronwatch,
    # job:<name>, and alert:<type>, then `tags`.
    class Datadog
      ALERT_TYPE = {
        missed: "error", failed: "error", stuck: "error", slow: "warning", over_budget: "warning", under_floor: "warning",
        recovered: "success",
      }.freeze
      private_constant :ALERT_TYPE

      attr_reader :name

      def initialize(api_key:, site: nil, tags: nil, host: nil, link: nil, http: HTTP.default)
        @api_key = Provider.require_credential(api_key, "Cronwatch::Alerts::Datadog needs an api_key")
        site = (site.nil? ? "datadoghq.com" : site.to_s).sub(%r{\Ahttps?://}, "").sub(/\A(api|app)\./, "").sub(%r{/+\z}, "")
        raise ArgumentError, "Cronwatch::Alerts::Datadog needs a site like datadoghq.com" unless /\A[a-z0-9.-]+\z/i.match?(site)

        @url = "https://api.#{site}/api/v1/events"
        @tags = tags || []
        @host = host
        @link = link
        @http = http
        @name = "datadog"
      end

      def call(alert)
        link = Provider.link_for(@link, alert)
        event = {
          "title" => Provider.cut(alert.title, 500),
          "text" => Provider.cut(Provider.plain_text(alert, link), 4000),
          "alert_type" => ALERT_TYPE[alert.type.to_sym],
          "aggregation_key" => Datadog.aggregation_key(alert),
          "date_happened" => alert.at.div(1000),
          "priority" => "normal",
          "tags" => ["cronwatch", "job:#{alert.job}", "alert:#{alert.type}", *@tags],
        }
        event["host"] = @host if Provider.present?(@host)
        headers = { "content-type" => "application/json", "accept" => "application/json", "dd-api-key" => @api_key }
        Provider.post(@http, "Datadog", @url, headers, JS.json(event), [@api_key])
        nil
      end

      # "cronwatch:<job>:<type>", or a hash of it when that passes Datadog's 100 characters.
      def self.aggregation_key(alert)
        key = "cronwatch:#{alert.job}:#{alert.type}"
        JS.length16(key) <= 100 ? key : "cronwatch:#{Provider.sha256_hex(key)[0, 40]}"
      end
    end
  end
end
