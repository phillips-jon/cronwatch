# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Reports alerts to Bugsnag (Error Reporting API, payload version 5),
    # grouped per job and alert type
    # (https://developer.smartbear.com/bugsnag/docs/reporting-events-and-sessions).
    # Recoveries are not sent unless `recovered: true`, since each one is an
    # event on an error.
    class Bugsnag
      attr_reader :name

      # endpoint: another notify endpoint, for on-premise installs.
      # now:      the clock for the Bugsnag-Sent-At header, a callable returning epoch milliseconds. For tests.
      def initialize(api_key:, release_stage: nil, endpoint: nil, recovered: false, now: nil, link: nil, http: HTTP.default)
        @api_key = Provider.require_option(api_key, "Cronwatch::Alerts::Bugsnag needs an api_key")
        @url = endpoint.nil? ? "https://notify.bugsnag.com/" : endpoint.to_s
        @release_stage = release_stage
        @recovered = recovered
        @now = now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
        @link = link
        @http = http
        @name = "bugsnag"
      end

      def call(alert)
        return if alert.type == :recovered && !@recovered

        link = Provider.link_for(@link, alert)
        type = alert.type.to_s
        meta = { "job" => alert.job, "type" => type }
        meta["triage"] = alert.triage if Provider.present?(alert.triage)
        meta["link"] = link if link
        meta["details"] = Naming.to_json_value(alert.details)
        meta["run"] = Provider.run_summary(alert)
        payload = {
          "apiKey" => @api_key,
          "payloadVersion" => "5",
          # The notifier's own version, not the gem's; Bugsnag asks for one.
          "notifier" => { "name" => "cronwatch", "version" => "1.0.0", "url" => "https://cronwatch.dev" },
          "events" => [
            {
              "exceptions" => [{
                "errorClass" => "CronWatch #{type}", "message" => Provider.cut("#{alert.title}\n#{alert.message}", 8000),
                "stacktrace" => [], "type" => "nodejs",
              }],
              "severity" => Provider.severity(alert.type),
              "unhandled" => false,
              "severityReason" => { "type" => "handledException" },
              "context" => alert.job,
              "groupingHash" => "cronwatch:#{alert.job}:#{type}",
              "metaData" => { "cronwatch" => meta },
              "app" => { "releaseStage" => @release_stage.nil? ? "production" : @release_stage },
              "device" => { "time" => JS.iso(alert.at) },
            },
          ],
        }
        headers = {
          "content-type" => "application/json",
          "bugsnag-api-key" => @api_key,
          "bugsnag-payload-version" => "5",
          "bugsnag-sent-at" => JS.iso(@now.call),
        }
        Provider.post(@http, "Bugsnag", @url, headers, JS.json(payload), [@api_key])
        nil
      end
    end
  end
end
