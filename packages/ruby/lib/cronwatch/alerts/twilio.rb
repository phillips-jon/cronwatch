# frozen_string_literal: true

require "set"

module Cronwatch
  module Alerts
    # Texts alerts through Twilio
    # (https://www.twilio.com/docs/messaging/api/message-resource), form
    # encoded with basic auth, one message per number, to every number at once.
    #
    #   Cronwatch::Alerts::Twilio.new(account_sid: ENV.fetch("TWILIO_ACCOUNT_SID"),
    #                                 auth_token: ENV.fetch("TWILIO_AUTH_TOKEN"),
    #                                 from: "+15005550006", to: ["+15551110000"])
    #
    # Sign with auth_token, or with api_key_sid and api_key_secret (each
    # trimmed of the spaces and newlines a paste leaves). Send from a number,
    # or through messaging_service_sid. Recoveries are not texted unless
    # `recovered: true`: a text is for what needs a person. A message fits in
    # `segments` SMS segments (default 3, 1 to 10).
    #
    # The alert counts as delivered when any number took it; each number that
    # refused it is reported through the client's channel context (on_error).
    # It fails only when every number did.
    class Twilio
      # The GSM 03.38 alphabet: a message in it takes 153 characters a segment
      # (when split), anything else is UCS-2 at 67. The extension table costs two.
      GSM = Set.new("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"\#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿" \
                    "abcdefghijklmnopqrstuvwxyzäöñüà".chars).freeze
      GSM_EXTENDED = Set.new("^{}\\[~]|€\f".chars).freeze
      # The most segments a message may use, which keeps it inside Twilio's 1600 character Body limit.
      MAX_SEGMENTS = 10
      # Twilio refuses a Body longer than this.
      MAX_BODY = 1600
      private_constant :GSM, :GSM_EXTENDED, :MAX_BODY, :MAX_SEGMENTS

      attr_reader :name

      def initialize(account_sid:, to:, auth_token: nil, api_key_sid: nil, api_key_secret: nil, from: nil,
                     messaging_service_sid: nil, recovered: false, segments: 3, link: nil, http: HTTP.default)
        # A pasted credential often carries a stray space or newline, which the Authorization header would refuse or send.
        account_sid = Provider.require_credential(account_sid, "Cronwatch::Alerts::Twilio needs an account_sid")
        api_key_sid = Provider.trimmed(api_key_sid)
        user = api_key_sid.empty? ? account_sid : api_key_sid
        password = Provider.trimmed(api_key_sid.empty? ? auth_token : api_key_secret)
        if password.empty?
          raise ArgumentError, "Cronwatch::Alerts::Twilio needs an auth_token, or an api_key_sid and api_key_secret"
        end
        unless Provider.present?(from) || Provider.present?(messaging_service_sid)
          raise ArgumentError, "Cronwatch::Alerts::Twilio needs a from number or a messaging_service_sid"
        end

        @to = (to.is_a?(Array) ? to : [to]).select { |n| n.is_a?(String) && JS.trim(n) != "" }.map { |n| JS.trim(n) }
        raise ArgumentError, "Cronwatch::Alerts::Twilio needs at least one to number" if @to.empty?

        @url = "https://api.twilio.com/2010-04-01/Accounts/#{Provider.encode_uri_component(account_sid)}/Messages.json"
        @password = password
        @authorization = Provider.basic_auth(user, @password)
        @from = from
        @messaging_service_sid = messaging_service_sid
        @recovered = recovered
        @segments = Twilio.segment_budget(segments)
        @link = link
        @http = http
        # How long to wait for the numbers' requests, each already bounded by its own HTTP deadline.
        @deadline_s = HTTP::TIMEOUT + 1
        @name = "twilio"
      end

      # `context` is the client's channel context: each number that refused
      # the alert, when another took it, is reported through its on_error.
      def call(alert, context = nil)
        return if alert.type == :recovered && !@recovered

        body = Twilio.sms_body(alert, Provider.link_for(@link, alert), @segments)
        errors = send_all(body)
        failed = @to.each_index.filter_map { |i| [@to[i], errors[i]] if errors[i] }
        return if failed.empty?

        if failed.length == @to.length
          message = failed[0][1].message
          raise(@to.length > 1 ? "#{message} (#{failed.length} of #{@to.length} numbers failed)" : message)
        end

        # Delivered to someone: counted as sent, so a retry never texts the numbers that took it again.
        took = @to.length - failed.length
        failed.each do |number, error|
          report = RuntimeError.new("#{error.message} (to #{Twilio.mask_number(number)}; #{took} of #{@to.length} numbers took the alert)")
          if context.respond_to?(:on_error)
            context.on_error(report)
          else
            warn "[cronwatch] alert channel twilio: #{report.message}"
          end
        end
        nil
      end

      # A number with all but its last four digits hidden, for an error message.
      def self.mask_number(number)
        length = JS.length16(number)
        length <= 4 ? number : "#{"*" * [length - 4, 8].min}#{JS.tail16(number, 4)}"
      end

      # A segment count clamped to 1 to MAX_SEGMENTS; 3 for anything not a number.
      def self.segment_budget(segments)
        n = segments.is_a?(Numeric) && segments.real? && JS.finite?(segments) ? segments.floor.to_i : 3
        [MAX_SEGMENTS, [1, n].max].min
      end

      # The segments `text` takes. A character is never split across two: an
      # extension character (two septets) or a surrogate pair (two UCS-2
      # units) that would straddle a boundary starts the next segment, as
      # phones pack them.
      def self.sms_segments(text)
        units = []
        gsm = true
        text.each_char do |ch|
          if GSM.include?(ch) then units << 1
          elsif GSM_EXTENDED.include?(ch) then units << 2
          else
            gsm = false
            break
          end
        end
        single, per, sizes = gsm ? [160, 153, units] : [70, 67, text.each_char.map { |ch| ch.ord > 0xFFFF ? 2 : 1 }]
        return 1 if sizes.sum <= single

        count = 1
        used = 0
        sizes.each do |u|
          if used + u > per
            count += 1
            used = 0
          end
          used += u
        end
        count
      end

      # Whether `text` fits in `segments` SMS segments and Twilio's Body limit.
      def self.fits?(text, segments)
        JS.length16(text) <= MAX_BODY && sms_segments(text) <= segments
      end

      # The title, then as many lines of the message (and the triage) as fit,
      # then the link. The link is kept whole; the text before it is cut to
      # make room. `segments` is clamped to 1 to 10.
      def self.sms_body(alert, link, segments = 3)
        budget = segment_budget(segments)
        tail = Provider.present?(link) ? "\n#{link}" : ""
        lines = [alert.title, *alert.message.split("\n", -1).reject { |l| JS.trim(l) == "" }]
        lines << "Triage: #{alert.triage}" if Provider.present?(alert.triage)
        text = +""
        lines.each do |line|
          following = text.empty? ? line : "#{text}\n#{line}"
          if fits?(following + tail, budget)
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
            if fits?(candidate + tail, budget)
              lo = mid
            else
              hi = mid - 1
            end
          end
          text = (text.empty? ? "" : "#{text}\n") + chars[0, lo].join + "..." if lo.positive?
          break
        end
        # Only a link too long for any budget gets here too long; Twilio would refuse it whole.
        Provider.cut(text + tail, MAX_BODY)
      end

      private

      # Posts to every number at once, each in its own thread. Returns the
      # error for each number, by index, or nil where it took the alert.
      def send_all(body)
        errors = Array.new(@to.length)
        threads = @to.each_with_index.map do |number, i|
          Thread.new do
            Thread.current.report_on_exception = false
            pairs = [["To", number]]
            pairs << (Provider.present?(@messaging_service_sid) ? ["MessagingServiceSid", @messaging_service_sid] : ["From", @from])
            pairs << ["Body", body]
            headers = { "content-type" => "application/x-www-form-urlencoded", "authorization" => @authorization }
            Provider.post(@http, "Twilio", @url, headers, Provider.form(pairs), [@password])
          rescue StandardError => e
            errors[i] = e
          end
        end
        deadline = HTTP.monotonic + @deadline_s
        threads.each_with_index do |thread, i|
          next if thread.join([deadline - HTTP.monotonic, 0].max)

          errors[i] = HTTP::TimeoutError.new
        end
        errors
      end
    end
  end
end
