# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Reports alerts to Rollbar, one item per job and alert type
    # (https://docs.rollbar.com/reference/create-item). `access_token` needs
    # the post_server_item scope. Recoveries go too, as info items, unless
    # `recovered: false`.
    class Rollbar
      ENDPOINT = "https://api.rollbar.com/api/1/item/"
      private_constant :ENDPOINT

      attr_reader :name

      def initialize(access_token:, environment: nil, recovered: true, link: nil, http: HTTP.default)
        @access_token = Provider.require_credential(access_token, "Cronwatch::Alerts::Rollbar needs an access_token")
        @environment = environment
        @recovered = recovered
        @link = link
        @http = http
        @name = "rollbar"
      end

      def call(alert)
        return if alert.type == :recovered && @recovered == false

        link = Provider.link_for(@link, alert)
        type = alert.type.to_s
        custom = { "job" => alert.job, "type" => type }
        custom["triage"] = alert.triage if Provider.present?(alert.triage)
        custom["link"] = link if link
        custom["details"] = Naming.to_json_value(alert.details)
        custom["run"] = Provider.run_summary(alert)
        item = {
          "data" => {
            "environment" => Provider.cut(@environment.nil? ? "production" : @environment.to_s, 255),
            "level" => Provider.severity(alert.type),
            "timestamp" => alert.at.div(1000),
            "title" => Provider.cut(alert.title, 255),
            # Rollbar hashes a fingerprint longer than 40 characters itself.
            "fingerprint" => "cronwatch:#{alert.job}:#{type}",
            "uuid" => Provider.as_uuid(Provider.alert_id(alert)),
            "body" => { "message" => { "body" => alert.message } },
            "custom" => custom,
            "notifier" => { "name" => "cronwatch" },
          },
        }
        headers = { "content-type" => "application/json", "x-rollbar-access-token" => @access_token }
        Provider.post(@http, "Rollbar", ENDPOINT, headers, JS.json(item), [@access_token])
        nil
      end
    end
  end
end
