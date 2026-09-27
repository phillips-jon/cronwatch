# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Reports alerts to Honeybadger as error notices, one error per job and
    # alert type (https://docs.honeybadger.io/api/reporting-exceptions/). Not
    # Check-ins, a separate product. Recoveries are not sent unless
    # `recovered: true`: Honeybadger has no levels, so one would read as an error.
    class Honeybadger
      CLASS = {
        missed: "CronWatch::Missed", failed: "CronWatch::Failed", stuck: "CronWatch::Stuck", slow: "CronWatch::Slow",
        over_budget: "CronWatch::OverBudget", recovered: "CronWatch::Recovered",
      }.freeze

      attr_reader :name

      # endpoint: another API host, "https://eu-api.honeybadger.io" say.
      def initialize(api_key:, environment: nil, endpoint: nil, recovered: false, link: nil, http: HTTP.default)
        @api_key = Provider.require_option(api_key, "Cronwatch::Alerts::Honeybadger needs an api_key")
        @url = "#{(endpoint.nil? ? "https://api.honeybadger.io" : endpoint.to_s).sub(%r{/+\z}, "")}/v1/notices"
        @environment = environment
        @recovered = recovered
        @link = link
        @http = http
        @name = "honeybadger"
      end

      def call(alert)
        return if alert.type == :recovered && !@recovered

        link = Provider.link_for(@link, alert)
        type = alert.type.to_s
        request = { "component" => "cronwatch", "action" => alert.job }
        request["url"] = link if link
        context = { "job" => alert.job, "type" => type }
        context["triage"] = alert.triage if Provider.present?(alert.triage)
        context["details"] = Naming.to_json_value(alert.details)
        context["run"] = Provider.run_summary(alert)
        request["context"] = context
        notice = {
          "notifier" => { "name" => "cronwatch", "url" => "https://cronwatch.dev" },
          "error" => {
            "class" => CLASS[alert.type.to_sym],
            "message" => Provider.cut("#{alert.title}\n#{alert.message}", 8000),
            # No code ran here; one frame naming the job keeps the notice well formed.
            "backtrace" => [{ "number" => "0", "file" => "cronwatch/#{alert.job}", "method" => type }],
            "fingerprint" => "cronwatch:#{alert.job}:#{type}",
            "tags" => ["cronwatch", type],
          },
          "request" => request,
          "server" => { "environment_name" => @environment.nil? ? "production" : @environment },
        }
        headers = { "content-type" => "application/json", "accept" => "application/json", "x-api-key" => @api_key }
        Provider.post(@http, "Honeybadger", @url, headers, JS.json(notice), [@api_key])
        nil
      end
    end
  end
end
