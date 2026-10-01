# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Sends alerts as email through Resend
    # (https://resend.com/docs/api-reference/emails/send-email).
    #
    #   Cronwatch::Alerts::Resend.new(api_key: ENV.fetch("RESEND_API_KEY"),
    #                                 from: "CronWatch <alerts@example.com>", to: "ops@example.com")
    class Resend
      ENDPOINT = "https://api.resend.com/emails"
      private_constant :ENDPOINT

      attr_reader :name

      def initialize(api_key:, from:, to:, subject_prefix: nil, link: nil, http: HTTP.default)
        @api_key = Provider.require_credential(api_key, "Cronwatch::Alerts::Resend needs an api_key")
        @to = Email.recipients("Resend", from, to)
        @from = from
        @subject_prefix = subject_prefix
        @link = link
        @http = http
        @name = "resend"
      end

      def call(alert)
        email = Email.compose(alert, from: @from, to: @to, subject_prefix: @subject_prefix, link: @link)
        headers = {
          "content-type" => "application/json",
          "authorization" => "Bearer #{@api_key}",
          # The same alert sent twice within 24 hours is delivered once.
          "idempotency-key" => "cronwatch-#{Provider.alert_id(alert)}",
        }
        body = JS.json({ "from" => email.from, "to" => email.to, "subject" => email.subject, "text" => email.text, "html" => email.html })
        Provider.post(@http, "Resend", ENDPOINT, headers, body, [@api_key])
        nil
      end
    end
  end
end
