# frozen_string_literal: true

module Cronwatch
  # "15m", "1h30m", "90s", "2d", or a number of milliseconds.
  module Duration
    UNIT_MS = { "ms" => 1, "s" => 1000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000, "w" => 604_800_000 }.freeze
    PART = Regexp.new("(\\d+(?:\\.\\d+)?)[#{JS::WHITESPACE}]*(ms|s|m|h|d|w)")

    module_function

    # An ActiveSupport::Duration (15.minutes), when ActiveSupport is loaded.
    def active_support?(value)
      defined?(::ActiveSupport::Duration) && value.instance_of?(::ActiveSupport::Duration)
    end

    # "15m" -> 900000. Accepts a plain number of milliseconds, and compound
    # strings such as "1h30m". Whitespace between parts is fine. An
    # ActiveSupport::Duration (15.minutes) is read as what it says.
    def parse(value, label = "duration")
      if active_support?(value)
        return JS.round(value.to_f * 1000)
      end
      if value.is_a?(Numeric)
        raise ArgumentError, "#{label} must be a non-negative number of milliseconds" if !JS.finite?(value) || value.negative?

        return value
      end
      unless value.is_a?(String)
        raise ArgumentError, "#{label} \"#{value}\" is not a duration like \"15m\", \"1h30m\" or \"90s\""
      end

      text = JS.trim(value).downcase
      raise ArgumentError, "#{label} is empty" if text.empty?

      total = 0
      consumed = +""
      text.scan(PART) do
        match = Regexp.last_match
        total += Float(match[1]) * UNIT_MS.fetch(match[2])
        consumed << match[0]
      end
      if consumed.gsub(JS::SPACES, "") != text.gsub(JS::SPACES, "")
        raise ArgumentError, "#{label} \"#{value}\" is not a duration like \"15m\", \"1h30m\" or \"90s\""
      end

      JS.round(total)
    end

    # 90000 -> "1m 30s". For messages, not for parsing back.
    def format(ms)
      return "?" unless JS.finite?(ms)
      return "#{JS.round(ms)}ms" if ms < 1000

      parts = []
      rest = JS.round(ms / 1000.0)
      [["d", 86_400], ["h", 3_600], ["m", 60], ["s", 1]].each do |unit, size|
        if rest >= size
          n = rest.div(size)
          rest -= n * size
          parts << "#{n}#{unit}"
        end
        break if parts.length == 2
      end
      parts.empty? ? "0s" : parts.join(" ")
    end

    # "5m ago", "in 2h". Relative to `now`.
    def relative(at, now)
      diff = at - now
      abs = diff.abs
      return "now" if abs < 5_000

      text = format(abs)
      diff.negative? ? "#{text} ago" : "in #{text}"
    end
  end
end
