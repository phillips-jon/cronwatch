# frozen_string_literal: true

module Cronwatch
  module Output
    # Output is capped so a chatty job cannot fill the store. The tail is kept.
    # Counted in UTF-16 code units, as the SDK counts it.
    CAP = 16 * 1024

    REDACTED = "[redacted]"

    # The SDK's SECRET_PATTERNS, written so Onigmo matches exactly what
    # JavaScript matches: (?a) keeps \b to ASCII word characters, \s is spelled
    # out as JavaScript's whitespace, and the case-insensitive parts are
    # spelled as [Ss][Ee]... because Ruby's /i also folds "ß" to "ss" and the
    # Kelvin sign to "k", which JavaScript's /i does not. Bounded quantifiers
    # throughout, so a long line cannot make these backtrack.
    module Secrets
      WS = JS::WHITESPACE

      # "secret" as [Ss][Ee][Cc][Rr][Ee][Tt]: ASCII-only case folding.
      def self.ci(word)
        word.chars.map { |c| c.match?(/[a-z]/) ? "[#{c.upcase}#{c}]" : Regexp.escape(c) }.join
      end

      NAMES = [
        ci("secret"), ci("token"), "#{ci("passw")}(?:#{ci("or")})?#{ci("d")}", ci("pwd"),
        "#{ci("api")}[_-]?#{ci("key")}", "#{ci("access")}[_-]?#{ci("key")}", "#{ci("private")}[_-]?#{ci("key")}",
        ci("credential"),
      ].join("|")

      PATTERNS = [
        # password=..., API_KEY: ..., "client_secret": "...", token=... (but not max_tokens: 800)
        [Regexp.new("(?a)\\b([A-Za-z0-9_-]{0,40}(?:#{NAMES})[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])\"?[#{WS}]{0,3}[=:][#{WS}]{0,3}\"?)[^#{WS}\"',;&]{1,4096}"), true],
        # Credentials inside a URL: postgres://user:password@host
        [Regexp.new("(?a)(\\b[A-Za-z][A-Za-z0-9+.-]{0,30}://[^#{WS}/:@]{0,256}:)[^#{WS}/@]{1,256}@"), :url],
        # Authorization: Bearer <token>
        [Regexp.new("(?a)\\b(Bearer[#{WS}]{1,3})[A-Za-z0-9._~+/=-]{8,4096}"), true],
        # Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic and OpenAI style keys.
        [/(?a)\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, false],
        [/(?a)\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\b/, false],
        [/(?a)\bxox[abposr]-[A-Za-z0-9-]{10,255}/, false],
        [/(?a)\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\b/, false],
        [/(?a)\bsk-[A-Za-z0-9_-]{20,255}/, false],
      ].freeze

      # Characters outside the Basic Multilingual Plane.
      ASTRAL = /[\u{10000}-\u{10FFFF}]/
      # Where a UTF-16 surrogate stands while the patterns run: U+10D800 to
      # U+10DFFF, which cannot otherwise appear once every astral character
      # has been split into its two surrogates.
      SURROGATE_BASE = 0x100000
      STANDIN = /[\u{10D800}-\u{10DFFF}]+/

      # JavaScript's patterns (no u flag) see UTF-16 code units, so a
      # character outside the BMP is two characters to a negated class and to
      # a bounded quantifier. Text with such characters is matched with each
      # one written as two stand-ins, then put back together.
      def self.to_units(text)
        text.encode(Encoding::UTF_16LE).unpack("v*").map { |u| (u >= 0xD800 && u <= 0xDFFF ? SURROGATE_BASE + u : u).chr(Encoding::UTF_8) }.join
      end

      # A surrogate a replacement cut from its partner becomes U+FFFD:
      # JavaScript would keep it alone, Ruby's UTF-8 cannot.
      def self.from_units(text)
        text.gsub(STANDIN) do |run|
          units = run.each_char.map { |c| c.ord - SURROGATE_BASE }
          out = +""
          i = 0
          while i < units.length
            high = units[i]
            low = units[i + 1]
            if high <= 0xDBFF && low && low >= 0xDC00
              out << (0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)).chr(Encoding::UTF_8)
              i += 2
            else
              out << 0xFFFD.chr(Encoding::UTF_8)
              i += 1
            end
          end
          out
        end
      end
    end

    module_function

    def cap(text)
      return text if JS.length16(text) <= CAP

      "[earlier output trimmed]\n#{JS.tail16(text, CAP)}"
    end

    # "Name: message" and the first five backtrace lines, each written as
    # "    at <line>" like the frames of a JavaScript stack, capped like output.
    def error_message(error)
      cap(describe_error(error))
    end

    def describe_error(error)
      if error.is_a?(Exception)
        frames = (error.backtrace || []).first(5).map { |line| "    at #{line}" }
        header = "#{error.class.name || error.class}: #{error.message}"
        return frames.empty? ? header : "#{header}\n#{frames.join("\n")}"
      end
      return error if error.is_a?(String)

      begin
        JS.json(error)
      rescue StandardError
        error.to_s
      end
    end

    # The default `redact`: blanks values that look like secrets (key=value
    # pairs with secret-ish names, URL credentials, bearer tokens and
    # well-known token formats) before output or an error is stored, shown or
    # sent anywhere. Matches exactly what the SDK's redactSecrets matches.
    def redact_secrets(text)
      astral = !text.ascii_only? && Secrets::ASTRAL.match?(text)
      out = astral ? Secrets.to_units(text) : text
      Secrets::PATTERNS.each do |pattern, keep|
        out = out.gsub(pattern) do
          case keep
          when :url then "#{Regexp.last_match(1)}#{REDACTED}@"
          when true then "#{Regexp.last_match(1)}#{REDACTED}"
          else REDACTED
          end
        end
      end
      astral ? Secrets.from_units(out) : out
    end
  end
end
