# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Sends alerts as email through Mailgun
    # (https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages),
    # form encoded with basic auth. `domain` is the sending domain,
    # "mg.example.com"; `region: "eu"` for a domain in the EU region.
    class Mailgun
      attr_reader :name

      def initialize(api_key:, domain:, from:, to:, region: nil, subject_prefix: nil, link: nil, http: HTTP.default)
        @api_key = Provider.require_credential(api_key, "Cronwatch::Alerts::Mailgun needs an api_key")
        domain = Provider.require_option(domain, "Cronwatch::Alerts::Mailgun needs a domain")
        @to = Email.recipients("Mailgun", from, to)
        @from = from
        host = region.to_s == "eu" ? "https://api.eu.mailgun.net" : "https://api.mailgun.net"
        @url = "#{host}/v3/#{Provider.encode_uri_component(domain)}/messages"
        @subject_prefix = subject_prefix
        @link = link
        @http = http
        @name = "mailgun"
      end

      def call(alert)
        email = Email.compose(alert, from: @from, to: @to, subject_prefix: @subject_prefix, link: @link)
        pairs = [["from", email.from]]
        email.to.each { |address| pairs << ["to", address] }
        pairs.push(["subject", email.subject], ["text", email.text], ["html", email.html], ["o:tag", "cronwatch"])
        headers = { "content-type" => "application/x-www-form-urlencoded", "authorization" => Provider.basic_auth("api", @api_key) }
        Provider.post(@http, "Mailgun", @url, headers, Provider.form(pairs), [@api_key])
        nil
      end
    end
  end
end
