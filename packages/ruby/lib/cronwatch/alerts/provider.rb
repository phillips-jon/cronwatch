# frozen_string_literal: true

require "digest"
require "openssl"
require "uri"

module Cronwatch
  module Alerts
    # What the provider channels (email, SMS, error trackers) share, as the
    # SDK's alerts/shared.ts: the POST that names the provider and the URL's
    # origin on failure with every secret cut out, the stable alert id, and
    # the run summary trackers attach. Standard library only.
    module Provider
      module_function

      # Severity for trackers that have levels. Recovered is informational.
      def severity(type)
        case type.to_sym
        when :recovered then "info"
        when :slow, :over_budget then "warning"
        else "error"
        end
      end

      # The scheme, host and port only. A URL's path or query can hold a credential.
      def origin(url)
        Webhook.origin(url)
      end

      # POSTs and raises on a non-2xx answer. The error names the provider and
      # the URL's origin, plus the start of the response body with every
      # secret the channel holds cut out, in case a provider echoes one back.
      def post(http, provider, url, headers, body, secrets = [])
        response = http.post(url, body, headers)
        return response if response.ok?

        # response.text() drops a leading byte order mark.
        text = JS.head16(Output.utf8(response.body.to_s).delete_prefix("\u{FEFF}"), 200)
        secrets.each do |secret|
          next if secret.nil? || JS.length16(secret.to_s) < 4

          text = text.split(secret.to_s, -1).join("[redacted]")
        end
        raise "#{provider} #{origin(url)} answered #{response.status}#{text.empty? ? "" : ": #{text}"}"
      end

      # Base64 of UTF-8, on one line.
      def base64(text)
        [text.to_s.b].pack("m0")
      end

      def basic_auth(user, password)
        "Basic #{base64("#{user}:#{password}")}"
      end

      def sha256_hex(text)
        Digest::SHA256.hexdigest(text.to_s)
      end

      # A stable 32 hex character id for one alert: the same job, type and
      # time always give the same id, so a provider that deduplicates on it
      # drops a resend of an alert it already took.
      def alert_id(alert)
        sha256_hex("#{alert.job}\n#{alert.type}\n#{JS.number(alert.at)}")[0, 32]
      end

      # The same id laid out as a UUID, for APIs that ask for one.
      def as_uuid(id)
        "#{id[0, 8]}-#{id[8, 4]}-#{id[12, 4]}-#{id[16, 4]}-#{id[20, 12]}"
      end

      # At most `max` UTF-16 units, without splitting a surrogate pair.
      def cut(text, max)
        JS.head16(text, max)
      end

      # The run fields worth attaching to a tracker event.
      def run_summary(alert)
        run = alert.run
        return nil unless run

        {
          "id" => run.id, "status" => run.status.to_s, "startedAt" => JS.iso(run.started_at),
          "durationMs" => run.duration_ms, "trigger" => run.trigger,
        }
      end

      # Title, message, triage and link as one plain text block, the way every channel reads.
      def plain_text(alert, link)
        lines = [alert.title, "", alert.message]
        lines.push("", "Triage: #{alert.triage}") if present?(alert.triage)
        lines.push("", "Open: #{link}") if present?(link)
        lines.join("\n")
      end

      # JavaScript's truthiness for an optional string: nil and "" are absent.
      def present?(text)
        !text.nil? && text != ""
      end

      # The link option's answer for this alert, or nil.
      def link_for(link, alert)
        value = link&.call(alert)
        present?(value) ? value.to_s : nil
      end

      # encodeURIComponent.
      def encode_uri_component(text)
        text.to_s.b.gsub(/[^A-Za-z0-9\-_.!~*'()]/n) { |c| format("%%%02X", c.ord) }.force_encoding(Encoding::UTF_8)
      end

      # URLSearchParams#toString for these pairs: application/x-www-form-urlencoded.
      def form(pairs)
        pairs.map { |k, v| "#{URI.encode_www_form_component(k)}=#{URI.encode_www_form_component(v.to_s)}" }.join("&")
      end

      # A required option, as a string: raises when it is missing or empty.
      def require_option(value, message)
        raise ArgumentError, message if value.nil? || value.to_s.empty?

        value.to_s
      end

      # The recovered option. `default` is what the SDK does when it is not given.
      def recovered?(option, default)
        option.nil? ? default : option != false
      end
    end
  end
end
