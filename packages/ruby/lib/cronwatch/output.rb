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
      ].join("|").freeze

      # "=", ":" or a hash rocket, between a name and its value.
      ASSIGN = "(?:=>|[=:])"

      # They apply in this order, each to the text the ones before it left.
      PATTERNS = [
        # A PEM private key, header to footer. Without a footer (the output was
        # trimmed) it runs to the end of the base64 body. A "-" that starts five
        # dashes ends the body, so the footer is never swallowed into it.
        [Regexp.new("-----BEGIN (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----(?:[A-Za-z0-9+/=#{WS},:]|-(?!----)){0,16384}" \
                    "(?:-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----)?"), false],
        # password=..., API_KEY: ..., "client_secret": "...", TOKEN='...', token=...,
        # :password=>"..." (but not max_tokens: 800). A quoted value is blanked to
        # its closing quote, spaces and all, and keeps its quotes.
        [Regexp.new("(?a)\\b([A-Za-z0-9_-]{0,40}(?:#{NAMES})[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])\"?[#{WS}]{0,3}#{ASSIGN}[#{WS}]{0,3})(?:(\")[^\"\\n]{1,4096}\"|(')[^'\\n]{1,4096}'|[\"']?[^#{WS}\"',;&]{1,4096})"), :quoted],
        # Authorization: Basic <base64> and Authorization: Token <token>, also as a JSON or hash entry.
        [Regexp.new("(?a)\\b((?:#{ci("proxy-")})?#{ci("authorization")}[\"']?[#{WS}]{0,3}#{ASSIGN}[#{WS}]{0,3}[\"']?[#{WS}]{0,3}" \
                    "(?:#{ci("basic")}|#{ci("token")})[#{WS}]{1,3})[A-Za-z0-9._~+/=:-]{1,4096}"), true],
        # Credentials inside a URL: postgres://user:password@host. The password
        # runs to the last "@" before a "/" or a space, so one that contains "@"
        # is blanked whole.
        [Regexp.new("(?a)(\\b[A-Za-z][A-Za-z0-9+.-]{0,30}://[^#{WS}/:@]{0,256}:)[^#{WS}/]{1,256}@"), :url],
        # Authorization: Bearer <token>
        [Regexp.new("(?a)\\b(Bearer[#{WS}]{1,3})[A-Za-z0-9._~+/=-]{8,4096}"), true],
        # A bare JWT: three base64url segments, the first starting eyJ.
        [/(?a)\beyJ[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{0,4096}/, false],
        # Incoming webhook URLs carry their secret in the path.
        [Regexp.new("(?a)(\\b#{ci("hooks.slack.com")}/(?:#{ci("services")}|#{ci("workflows")}|#{ci("triggers")})/)[A-Za-z0-9/_-]{1,255}"), true],
        [Regexp.new("(?a)(\\b#{ci("discord")}(?:#{ci("app")})?#{ci(".com/api/")}(?:[Vv][0-9]{1,2}/)?#{ci("webhooks/")})[A-Za-z0-9/_-]{1,255}"), true],
        # Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic, OpenAI and Google style keys.
        [/(?a)\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, false],
        [/(?a)\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\b/, false],
        [/(?a)\bxox[abposr]-[A-Za-z0-9-]{10,255}/, false],
        [/(?a)\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\b/, false],
        [%r{(?a)\bwhsec_[A-Za-z0-9+/=]{16,255}}, false],
        [/(?a)\bsk-[A-Za-z0-9_-]{20,255}/, false],
        [/(?a)\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])/, false],
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

    # Text as valid UTF-8, whatever it was read as: bytes that are not UTF-8
    # (binary output, a C extension's message) become U+FFFD, and text in
    # another encoding is converted. JavaScript strings cannot hold anything
    # else, and the store, the alerts and the redaction all expect UTF-8.
    def utf8(text)
      text = text.to_s
      return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

      if [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(text.encoding)
        text.dup.force_encoding(Encoding::UTF_8).scrub
      else
        text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
    end

    # NUL characters are removed first, since Postgres refuses them in TEXT
    # and JSONB and the whole run row would be lost. The cap then applies to
    # what is left.
    def cap(text)
      text = strip_nul(utf8(text))
      return text if JS.length16(text) <= CAP

      "[earlier output trimmed]\n#{JS.tail16(text, CAP)}"
    end

    # Removes every U+0000.
    def strip_nul(text)
      text.include?("\0") ? text.delete("\0") : text
    end

    # Removes every U+0000 from JSON text, keys and strings alike, by dropping
    # each \u0000 escape (a NUL can appear in JSON no other way). Escapes are
    # read left to right in pairs, so an escaped backslash followed by "u0000"
    # is left as it is.
    def strip_json_nul(json)
      return json unless json.include?("\\u0000")

      json.gsub(/\\(u0000|.)/m) { Regexp.last_match(1) == "u0000" ? "" : Regexp.last_match(0) }
    end

    # "Name: message" and the first five backtrace lines, each written as
    # "    at <line>" like the frames of a JavaScript stack, capped like output.
    # An exception that stops the thread rather than reporting a problem
    # (Interrupt, SystemExit, Sidekiq::Shutdown, a Timeout) is written
    # "Interrupted: <class>", with its message when it says more.
    def error_message(error)
      cap(describe_error(error))
    end

    def describe_error(error)
      if error.is_a?(Exception)
        frames = (error.backtrace || []).first(5).map { |line| "    at #{utf8(line)}" }
        name = error.class.name || error.class.to_s
        message = utf8(error.message)
        header =
          if interruption?(error)
            message.empty? || message == name ? "Interrupted: #{name}" : "Interrupted: #{name}: #{message}"
          else
            "#{name}: #{message}"
          end
        return frames.empty? ? header : "#{header}\n#{frames.join("\n")}"
      end
      return utf8(error) if error.is_a?(String)

      begin
        JS.json(error)
      rescue StandardError
        utf8(error)
      end
    end

    # Outside StandardError, and not a ScriptError (NotImplementedError,
    # LoadError), which is a problem in the code rather than a stop.
    def interruption?(error)
      !error.is_a?(StandardError) && !error.is_a?(ScriptError)
    end

    # The default `redact`: blanks values that look like secrets (key=value
    # pairs with secret-ish names, Authorization headers, URL credentials,
    # bearer tokens, JWTs, PEM private keys, webhook URLs and well-known token
    # formats) before output or an error is stored, shown or sent anywhere. Matches exactly what the SDK's redactSecrets matches.
    def redact_secrets(text)
      astral = !text.ascii_only? && Secrets::ASTRAL.match?(text)
      out = astral ? Secrets.to_units(text) : text
      Secrets::PATTERNS.each do |pattern, keep|
        out = out.gsub(pattern) do
          case keep
          when :url then "#{Regexp.last_match(1)}#{REDACTED}@"
          when :quoted
            quote = Regexp.last_match(2) || Regexp.last_match(3) || ""
            "#{Regexp.last_match(1)}#{quote}#{REDACTED}#{quote}"
          when true then "#{Regexp.last_match(1)}#{REDACTED}"
          else REDACTED
          end
        end
      end
      astral ? Secrets.from_units(out) : out
    end
  end
end
