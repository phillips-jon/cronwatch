# frozen_string_literal: true

require "ipaddr"

module Cronwatch
  class Web
    # Reads the `origin` option as the SDK's `new URL(value).origin` does:
    # whitespace around it and tabs or line breaks in it are dropped, slashes
    # after the scheme may be missing or backslashes, credentials are
    # ignored, the host is lowercased (percent escapes decoded, IPv4 numbers
    # written out, IPv6 compressed, a non-ASCII host converted to punycode)
    # and a default port is left out. A port outside 1 to 65535 is refused.
    module Origin
      ABSOLUTE = "routes: origin must be an absolute URL such as \"https://app.example.com\", got %s"
      FORBIDDEN_HOST = /[\x00-\x20#%\/:<>?@\[\\\]^|\x7F]/
      DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze

      module_function

      # scheme://host[:port], or nil for nil or "". Raises ArgumentError otherwise.
      def parse(value)
        return nil if value.nil? || value == ""
        raise ArgumentError, format(ABSOLUTE, JS.json(value)) unless value.is_a?(String)

        text = value.sub(/\A[\x00-\x20]+/, "").sub(/[\x00-\x20]+\z/, "").delete("\t\n\r")
        match = text.match(/\A([A-Za-z][A-Za-z0-9+.\-]*):(.*)\z/m)
        raise ArgumentError, format(ABSOLUTE, JS.json(value)) unless match

        scheme = match[1].downcase
        unless DEFAULT_PORTS.key?(scheme)
          raise ArgumentError, "routes: origin must be http or https, got #{JS.json(value)}"
        end

        authority = match[2].sub(%r{\A[/\\]*}, "")[%r{\A[^/\\?#]*}]
        authority = authority.split("@", -1).last.to_s
        host, port = split_port(authority, value)
        host = read_host(host, value)
        port = port.nil? || port == DEFAULT_PORTS[scheme] ? "" : ":#{port}"
        "#{scheme}://#{host}#{port}"
      end

      # [host, port] with the scheme's default port when none is given.
      def split_port(authority, value)
        if authority.start_with?("[")
          close = authority.index("]") or raise ArgumentError, format(ABSOLUTE, JS.json(value))
          host = authority[0..close]
          rest = authority[(close + 1)..]
        else
          host, colon, rest = authority.rpartition(":")
          host, rest = rest, "" if colon.empty?
          rest = ":#{rest}" unless colon.empty?
        end
        return [host, nil] if rest.empty? || rest == ":"
        raise ArgumentError, format(ABSOLUTE, JS.json(value)) unless rest.match?(/\A:[0-9]+\z/)

        port = rest[1..].to_i
        unless port.between?(1, 65_535)
          raise ArgumentError, "routes: origin has a port outside 1 to 65535, got #{JS.json(value)}"
        end

        [host, port]
      end

      def read_host(host, value)
        invalid = -> { raise ArgumentError, format(ABSOLUTE, JS.json(value)) }
        invalid.call if host.empty?
        if host.start_with?("[")
          invalid.call unless host.end_with?("]")
          address = begin
            IPAddr.new(host[1..-2])
          rescue IPAddr::Error
            invalid.call
          end
          invalid.call unless address.ipv6?
          return "[#{address}]"
        end

        decoded = host.b.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8)
        invalid.call unless decoded.valid_encoding?
        decoded = to_ascii(decoded, value) unless decoded.ascii_only?
        decoded = decoded.downcase
        invalid.call if decoded.empty? || decoded.match?(FORBIDDEN_HOST)
        ipv4 = ipv4(decoded, invalid)
        ipv4 || decoded
      end

      # WHATWG's IPv4 parser, for a host whose last label is a number:
      # "127.1" and "0x7f.1" are 127.0.0.1. nil for a host that is a name.
      def ipv4(host, invalid)
        parts = host.split(".", -1)
        parts.pop if parts.length > 1 && parts.last.empty?
        return nil unless number?(parts.last)

        invalid.call if parts.length > 4
        numbers = parts.map { |part| number(part) || invalid.call }
        last = numbers.pop
        invalid.call if numbers.any? { |n| n > 255 } || last >= 256**(4 - numbers.length)
        address = numbers.each_with_index.sum { |n, i| n * (256**(3 - i)) } + last
        [24, 16, 8, 0].map { |shift| (address >> shift) & 255 }.join(".")
      end

      def number?(part)
        part.match?(/\A[0-9]+\z/) || part.match?(/\A0[xX][0-9A-Fa-f]*\z/)
      end

      def number(part)
        return nil if part.empty?
        return (part.length == 2 ? 0 : part[2..].hex) if part.match?(/\A0[xX][0-9A-Fa-f]*\z/)
        return part.to_i(8) if part.match?(/\A0[0-7]+\z/)

        part.match?(/\A[0-9]+\z/) && !part.match?(/\A0[0-9]+\z/) ? part.to_i : nil
      end

      # A non-ASCII host in punycode, through URI::IDNA when this Ruby has it,
      # else the simpleidn gem, else Addressable's (already loaded by many apps).
      def to_ascii(host, value)
        normalized = host.unicode_normalize(:nfc).downcase
        return URI::IDNA.to_ascii(normalized) if defined?(URI::IDNA) && URI::IDNA.respond_to?(:to_ascii)

        begin
          require "simpleidn" unless defined?(::SimpleIDN)
        rescue LoadError
          nil
        end
        return ::SimpleIDN.to_ascii(normalized) if defined?(::SimpleIDN)
        return ::Addressable::IDNA.to_ascii(normalized) if defined?(::Addressable::IDNA)

        raise ArgumentError, "routes: origin has a host that is not ASCII, got #{JS.json(value)}; write it in punycode " \
                             "(xn--...) or add the simpleidn gem"
      end
    end
  end
end
