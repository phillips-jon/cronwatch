# frozen_string_literal: true

require "set"

module Cronwatch
  module Alerts
    # Texts alerts through Twilio
    # (https://www.twilio.com/docs/messaging/api/message-resource), form
    # encoded with basic auth, one message per number.
    #
    #   Cronwatch::Alerts::Twilio.new(account_sid: ENV.fetch("TWILIO_ACCOUNT_SID"),
    #                                 auth_token: ENV.fetch("TWILIO_AUTH_TOKEN"),
    #                                 from: "+15005550006", to: ["+15551110000"])
    #
    # Sign with auth_token, or with api_key_sid and api_key_secret. Send from
    # a number, or through messaging_service_sid. Recoveries are not texted
    # unless `recovered: true`: a text is for what needs a person. A message
    # fits in `segments` SMS segments (default 3).
    class Twilio
      # The GSM 03.38 alphabet: a message in it takes 153 characters a segment
      # (when split), anything else is UCS-2 at 67. The extension table costs two.
      GSM = Set.new("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"\#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿" \
                    "abcdefghijklmnopqrstuvwxyzäöñüà".chars).freeze
      GSM_EXTENDED = Set.new("^{}\\[~]|€\f".chars).freeze

      attr_reader :name

      def initialize(account_sid:, to:, auth_token: nil, api_key_sid: nil, api_key_secret: nil, from: nil,
                     messaging_service_sid: nil, recovered: false, segments: 3, link: nil, http: HTTP.default)
        account_sid = Provider.require_option(account_sid, "Cronwatch::Alerts::Twilio needs an account_sid")
        user = Provider.present?(api_key_sid) ? api_key_sid.to_s : account_sid
        password = Provider.present?(api_key_sid) ? api_key_secret : auth_token
        unless Provider.present?(password)
          raise ArgumentError, "Cronwatch::Alerts::Twilio needs an auth_token, or an api_key_sid and api_key_secret"
        end
        unless Provider.present?(from) || Provider.present?(messaging_service_sid)
          raise ArgumentError, "Cronwatch::Alerts::Twilio needs a from number or a messaging_service_sid"
        end

        @to = (to.is_a?(Array) ? to : [to]).select { |n| n.is_a?(String) && JS.trim(n) != "" }.map { |n| JS.trim(n) }
        raise ArgumentError, "Cronwatch::Alerts::Twilio needs at least one to number" if @to.empty?

        @url = "https://api.twilio.com/2010-04-01/Accounts/#{Provider.encode_uri_component(account_sid)}/Messages.json"
        @password = password.to_s
        @authorization = Provider.basic_auth(user, @password)
        @from = from
        @messaging_service_sid = messaging_service_sid
        @recovered = recovered
        @segments = [1, (segments.nil? ? 3 : segments).floor].max
        @link = link
        @http = http
        @name = "twilio"
      end

      def call(alert)
        return if alert.type == :recovered && !@recovered

        body = Twilio.sms_body(alert, Provider.link_for(@link, alert), @segments)
        first = nil
        failed = 0
        # Every number is tried; one bad number does not stop the others.
        @to.each do |number|
          pairs = [["To", number]]
          pairs << (Provider.present?(@messaging_service_sid) ? ["MessagingServiceSid", @messaging_service_sid] : ["From", @from])
          pairs << ["Body", body]
          headers = { "content-type" => "application/x-www-form-urlencoded", "authorization" => @authorization }
          begin
            Provider.post(@http, "Twilio", @url, headers, Provider.form(pairs), [@password])
          rescue StandardError => e
            failed += 1
            first ||= e
          end
        end
        return unless first

        raise(@to.length > 1 ? "#{first.message} (#{failed} of #{@to.length} numbers failed)" : first.message)
      end

      # The GSM-7 length of `text`, or nil when it needs UCS-2.
      def self.gsm_length(text)
        n = 0
        text.each_char do |ch|
          if GSM.include?(ch) then n += 1
          elsif GSM_EXTENDED.include?(ch) then n += 2
          else return nil
          end
        end
        n
      end

      # Whether `text` fits in `segments` SMS segments, as GSM-7 when it can be and UCS-2 when not.
      def self.fits?(text, segments)
        gsm = gsm_length(text)
        return gsm <= (segments == 1 ? 160 : 153 * segments) if gsm

        JS.length16(text) <= (segments == 1 ? 70 : 67 * segments)
      end

      # The title, then as many lines of the message (and the triage) as fit,
      # then the link. The link is kept whole; the text before it is cut to make room.
      def self.sms_body(alert, link, segments = 3)
        tail = Provider.present?(link) ? "\n#{link}" : ""
        lines = [alert.title, *alert.message.split("\n", -1).reject { |l| JS.trim(l) == "" }]
        lines << "Triage: #{alert.triage}" if Provider.present?(alert.triage)
        text = +""
        lines.each do |line|
          following = text.empty? ? line : "#{text}\n#{line}"
          if fits?(following + tail, segments)
            text = following
            next
          end
          # Part of this line, cut on a code point and marked.
          chars = line.chars
          lo = 0
          hi = chars.length
          while lo < hi
            mid = (lo + hi + 1) / 2
            candidate = (text.empty? ? "" : "#{text}\n") + chars[0, mid].join + "..."
            if fits?(candidate + tail, segments)
              lo = mid
            else
              hi = mid - 1
            end
          end
          text = (text.empty? ? "" : "#{text}\n") + chars[0, lo].join + "..." if lo.positive?
          break
        end
        text + tail
      end
    end
  end
end
