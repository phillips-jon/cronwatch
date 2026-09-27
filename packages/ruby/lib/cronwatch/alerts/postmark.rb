# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Sends alerts as email through Postmark
    # (https://postmarkapp.com/developer/api/email-api). `message_stream`
    # defaults to "outbound", the transactional stream.
    class Postmark
      ENDPOINT = "https://api.postmarkapp.com/email"

      attr_reader :name

      def initialize(server_token:, from:, to:, message_stream: nil, subject_prefix: nil, link: nil, http: HTTP.default)
        @server_token = Provider.require_credential(server_token, "Cronwatch::Alerts::Postmark needs a server_token")
        @to = Email.recipients("Postmark", from, to)
        @from = from
        @message_stream = message_stream
        @subject_prefix = subject_prefix
        @link = link
        @http = http
        @name = "postmark"
      end

      def call(alert)
        email = Email.compose(alert, from: @from, to: @to, subject_prefix: @subject_prefix, link: @link)
        headers = { "content-type" => "application/json", "accept" => "application/json", "x-postmark-server-token" => @server_token }
        body = JS.json({
          "From" => email.from,
          "To" => email.to.join(", "),
          "Subject" => email.subject,
          "TextBody" => email.text,
          "HtmlBody" => email.html,
          "MessageStream" => @message_stream.nil? ? "outbound" : @message_stream,
          "Tag" => "cronwatch",
        })
        Provider.post(@http, "Postmark", ENDPOINT, headers, body, [@server_token])
        nil
      end
    end
  end
end
