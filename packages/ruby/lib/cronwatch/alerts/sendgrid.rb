# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Sends alerts as email through SendGrid
    # (https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send).
    # `region: "eu"` for an EU regional subuser.
    class Sendgrid
      attr_reader :name

      def initialize(api_key:, from:, to:, region: nil, subject_prefix: nil, link: nil, http: HTTP.default)
        @api_key = Provider.require_credential(api_key, "Cronwatch::Alerts::Sendgrid needs an api_key")
        @to = Email.recipients("Sendgrid", from, to)
        @from = from
        @url = region.to_s == "eu" ? "https://api.eu.sendgrid.com/v3/mail/send" : "https://api.sendgrid.com/v3/mail/send"
        @subject_prefix = subject_prefix
        @link = link
        @http = http
        @name = "sendgrid"
      end

      def call(alert)
        email = Email.compose(alert, from: @from, to: @to, subject_prefix: @subject_prefix, link: @link)
        body = JS.json({
          "personalizations" => [{ "to" => email.to.map { |a| Email.parse_address(a) } }],
          "from" => Email.parse_address(email.from),
          "subject" => email.subject,
          # text/plain must come before text/html.
          "content" => [
            { "type" => "text/plain", "value" => email.text },
            { "type" => "text/html", "value" => email.html },
          ],
          "categories" => ["cronwatch"],
        })
        headers = { "content-type" => "application/json", "authorization" => "Bearer #{@api_key}" }
        Provider.post(@http, "SendGrid", @url, headers, body, [@api_key])
        nil
      end
    end
  end
end
