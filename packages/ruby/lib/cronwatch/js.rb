# frozen_string_literal: true

module Cronwatch
  # The few places JavaScript and Ruby disagree about text and numbers,
  # settled the JavaScript way. The SDK writes the stored rows, alert text and
  # webhook bodies, so the gem reproduces them byte for byte: Math.round,
  # String(number), JSON.stringify, String.prototype.trim and lengths counted
  # in UTF-16 code units.
  module JS
    # What JavaScript's \s and trim() treat as whitespace.
    WHITESPACE = "\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff"
    SPACE = Regexp.new("[#{WHITESPACE}]")
    SPACES = Regexp.new("[#{WHITESPACE}]+")
    LEADING = Regexp.new("\\A[#{WHITESPACE}]+")
    TRAILING = Regexp.new("[#{WHITESPACE}]+\\z")
    NOT_SPACE = Regexp.new("[^#{WHITESPACE}]+")

    ESCAPES = { '"' => '\\"', "\\" => "\\\\", "\b" => "\\b", "\f" => "\\f", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }.freeze
    # An array index is a canonical integer below 2**32 - 1; JavaScript lists those keys first.
    INDEX_KEY = /\A(?:0|[1-9]\d{0,9})\z/

    module_function

    def trim(text)
      text.sub(LEADING, "").sub(TRAILING, "")
    end

    def trim_end(text)
      text.sub(TRAILING, "")
    end

    # Math.round: halves go up, toward positive infinity.
    def round(value)
      return value if value.is_a?(Integer)
      return value unless value.finite?

      floor = value.floor
      value - floor >= 0.5 ? floor + 1 : floor
    end

    def finite?(value)
      value.is_a?(Integer) || (value.is_a?(Numeric) && value.real? && value.to_f.finite?)
    end

    # Number.isInteger.
    def integer?(value)
      value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.floor)
    end

    # String(number), the text a template literal or JSON.stringify gives a number.
    def number(value)
      return value.to_s if value.is_a?(Integer)

      value = value.to_f
      return "NaN" if value.nan?
      return (value.positive? ? "Infinity" : "-Infinity") if value.infinite?
      return "0" if value.zero?

      digits, point = decimal(value.abs)
      k = digits.length
      text =
        if k <= point && point <= 21 then digits + ("0" * (point - k))
        elsif point.positive? && point <= 21 then "#{digits[0, point]}.#{digits[point..]}"
        elsif point > -6 && point <= 0 then "0.#{"0" * -point}#{digits}"
        else
          exponent = point - 1
          mantissa = k == 1 ? digits : "#{digits[0]}.#{digits[1..]}"
          "#{mantissa}e#{exponent.negative? ? "-" : "+"}#{exponent.abs}"
        end
      value.negative? ? "-#{text}" : text
    end

    # The shortest digits that round-trip, and where the decimal point goes:
    # value = 0.DIGITS * 10**point. Ruby's Float#to_s already finds the digits.
    def decimal(value)
      text = value.to_s
      if text.include?("e")
        mantissa, exponent = text.split("e")
        digits = mantissa.delete(".")
        point = exponent.to_i + 1
      else
        whole, fraction = text.split(".")
        if whole == "0"
          stripped = fraction.sub(/\A0+/, "")
          point = -(fraction.length - stripped.length)
          digits = stripped
        else
          digits = whole + fraction.to_s
          point = whole.length
        end
      end
      digits = digits.sub(/0+\z/, "")
      [digits.empty? ? "0" : digits, point]
    end

    # Length in UTF-16 code units, which is what String#length is in JavaScript.
    def length16(text)
      return text.length if text.ascii_only?

      text.each_char.sum { |c| c.ord > 0xFFFF ? 2 : 1 }
    end

    # The first `units` UTF-16 code units. A character that would be cut in
    # half is left out; JavaScript would keep a lone surrogate, Ruby cannot.
    def head16(text, units)
      return text[0, units] if text.ascii_only?

      out = +""
      used = 0
      text.each_char do |c|
        size = c.ord > 0xFFFF ? 2 : 1
        break if used + size > units

        out << c
        used += size
      end
      out
    end

    # The last `units` UTF-16 code units, the same way.
    def tail16(text, units)
      return text[[text.length - units, 0].max..] if text.ascii_only?

      chars = []
      used = 0
      text.each_char.reverse_each do |c|
        size = c.ord > 0xFFFF ? 2 : 1
        break if used + size > units

        chars << c
        used += size
      end
      chars.reverse.join
    end

    # JSON.stringify for plain data: hashes, arrays, strings, numbers, true,
    # false and nil, and anything with a to_h (the gem's Structs) or as_json.
    def json(value)
      case value
      when nil then "null"
      when true then "true"
      when false then "false"
      when String then quote(value)
      when Symbol then quote(value.to_s)
      when Integer then value.to_s
      when Float then value.finite? ? number(value) : "null"
      when Hash then "{#{object_keys(value).map { |k| "#{quote(k.to_s)}:#{json(value[k])}" }.join(",")}}"
      when Array then "[#{value.map { |v| json(v) }.join(",")}]"
      when Time then quote(iso(value))
      when Numeric then json(value.to_f)
      else
        if value.respond_to?(:as_json) && !value.is_a?(Struct) then json(value.as_json)
        elsif value.respond_to?(:to_h) then json(value.to_h)
        else quote(value.to_s)
        end
      end
    end

    def quote(text)
      text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless text.encoding == Encoding::UTF_8 && text.valid_encoding?
      text = text.scrub unless text.valid_encoding?
      escaped = text.gsub(/["\\\u0000-\u001f]/) { |c| ESCAPES[c] || format("\\u%04x", c.ord) }
      "\"#{escaped}\""
    end

    # Property order: array-index keys ascending, then the rest as inserted.
    def object_keys(hash)
      keys = hash.keys
      indexes = keys.select { |k| INDEX_KEY.match?(k.to_s) && k.to_s.to_i < 4_294_967_295 }
      return keys if indexes.empty?

      indexes.sort_by { |k| k.to_s.to_i } + (keys - indexes)
    end

    # Date#toISOString for epoch milliseconds or a Time.
    def iso(at)
      time = at.is_a?(Time) ? at.utc : Time.at(at.div(1000), at % 1000, :millisecond).utc
      time.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    # JSON.parse. Ruby's parser keeps key order, as JavaScript does.
    def parse(text)
      ::JSON.parse(text)
    end
  end
end
