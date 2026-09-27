# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Records alerts as New Relic custom events through the Event API
    # (https://docs.newrelic.com/docs/data-apis/ingest-apis/event-api/introduction-event-api/).
    # Each alert is one event of type CronWatchAlert (or `event_type`),
    # queryable with NRQL: SELECT * FROM CronWatchAlert WHERE job = 'nightly'.
    # `api_key` is a license key; `region: "eu"` for an EU account.
    class NewRelic
      attr_reader :name

      def initialize(account_id:, api_key:, region: nil, event_type: nil, link: nil, http: HTTP.default)
        @api_key = Provider.require_credential(api_key, "Cronwatch::Alerts::NewRelic needs an api_key")
        account = account_id.nil? ? "" : account_id.to_s
        raise ArgumentError, "Cronwatch::Alerts::NewRelic needs a numeric account_id" unless /\A\d+\z/.match?(account)

        host = region.to_s == "eu" ? "https://insights-collector.eu01.nr-data.net" : "https://insights-collector.newrelic.com"
        @url = "#{host}/v1/accounts/#{account}/events"
        @event_type = event_type.nil? ? "CronWatchAlert" : event_type.to_s
        @link = link
        @http = http
        @name = "newrelic"
      end

      def call(alert)
        link = Provider.link_for(@link, alert)
        run = alert.run
        # Flat attributes only, strings under 4096 characters.
        event = {
          "eventType" => @event_type,
          "timestamp" => alert.at,
          "job" => Provider.cut(alert.job, 4095),
          "alertType" => alert.type.to_s,
          "severity" => Provider.severity(alert.type),
          "title" => Provider.cut(alert.title, 4095),
          "message" => Provider.cut(alert.message, 4095),
        }
        event["triage"] = Provider.cut(alert.triage, 4095) if Provider.present?(alert.triage)
        event["link"] = Provider.cut(link, 4095) if link
        if run
          event["runId"] = run.id
          event["runStatus"] = run.status.to_s
          event["durationMs"] = run.duration_ms unless run.duration_ms.nil?
        end
        headers = { "content-type" => "application/json", "api-key" => @api_key }
        Provider.post(@http, "New Relic", @url, headers, JS.json([event]), [@api_key])
        nil
      end
    end
  end
end
