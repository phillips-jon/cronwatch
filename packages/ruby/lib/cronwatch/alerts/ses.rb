# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Sends alerts as email through Amazon SES, API v2 SendEmail
    # (https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html),
    # signed with AWS Signature Version 4 (see SigV4), so no AWS SDK is
    # needed. The from identity must be verified in `region`.
    #
    #   Cronwatch::Alerts::Ses.new(region: "us-east-1", access_key_id: ENV.fetch("AWS_ACCESS_KEY_ID"),
    #                              secret_access_key: ENV.fetch("AWS_SECRET_ACCESS_KEY"),
    #                              from: "alerts@example.com", to: "ops@example.com")
    class Ses
      attr_reader :name

      # now: the clock used to sign requests, a callable returning epoch milliseconds. For tests.
      def initialize(region:, access_key_id:, secret_access_key:, from:, to:, session_token: nil, configuration_set_name: nil,
                     subject_prefix: nil, link: nil, now: nil, http: HTTP.default)
        region = Provider.require_option(region, "Cronwatch::Alerts::Ses needs a region")
        raise ArgumentError, "Cronwatch::Alerts::Ses needs a region like us-east-1" unless /\A[a-z0-9-]+\z/.match?(region)
        # A pasted credential often carries a stray space or newline, which would spoil the signature.
        access_key_id = Provider.trimmed(access_key_id)
        secret_access_key = Provider.trimmed(secret_access_key)
        if access_key_id.empty? || secret_access_key.empty?
          raise ArgumentError, "Cronwatch::Alerts::Ses needs an access_key_id and secret_access_key"
        end

        @to = Email.recipients("Ses", from, to)
        @region = region
        @access_key_id = access_key_id
        @secret_access_key = secret_access_key
        session_token = Provider.trimmed(session_token)
        @session_token = session_token.empty? ? nil : session_token
        @configuration_set_name = configuration_set_name
        @from = from
        @subject_prefix = subject_prefix
        @link = link
        @now = now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
        @url = "https://email.#{region}.amazonaws.com/v2/email/outbound-emails"
        @http = http
        @name = "ses"
      end

      def call(alert)
        email = Email.compose(alert, from: @from, to: @to, subject_prefix: @subject_prefix, link: @link)
        payload = {
          "FromEmailAddress" => email.from,
          "Destination" => { "ToAddresses" => email.to },
          "Content" => {
            "Simple" => {
              "Subject" => { "Data" => email.subject, "Charset" => "UTF-8" },
              "Body" => {
                "Text" => { "Data" => email.text, "Charset" => "UTF-8" },
                "Html" => { "Data" => email.html, "Charset" => "UTF-8" },
              },
            },
          },
        }
        payload["ConfigurationSetName"] = @configuration_set_name if Provider.present?(@configuration_set_name)
        payload["EmailTags"] = [{ "Name" => "source", "Value" => "cronwatch" }]
        body = JS.json(payload)
        headers = SigV4.sign(
          method: "POST", url: @url, headers: { "content-type" => "application/json" }, body: body, region: @region,
          service: "ses", now: @now.call, access_key_id: @access_key_id, secret_access_key: @secret_access_key,
          session_token: @session_token
        )
        Provider.post(@http, "SES", @url, headers, body, [@secret_access_key, @session_token])
        nil
      end
    end
  end
end
