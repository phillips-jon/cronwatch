# frozen_string_literal: true

module Cronwatch
  # @api private
  module Serialize
    module_function

    # How long one expect pattern may take over a run's output, in seconds.
    # Onigmo memoizes most patterns into linear time, but not one with a
    # backreference or a lookaround, which can backtrack for minutes over an
    # output it does not match. A match that times out does not match, so
    # the run fails as the other ports' bounded engines fail it. A pattern
    # with a shorter timeout of its own (or a shorter Regexp.timeout) keeps
    # it.
    PATTERN_TIMEOUT = 1.0

    # A definition as a store can hold it: `expect` becomes a description, and
    # moves to the end, as it does in the SDK.
    def to_stored(definition)
      fields = definition.fields
      # 15.minutes is stored as the milliseconds it means, the unit every
      # reader (this gem, the SDK) takes a plain number in.
      fields.each { |key, value| fields[key] = Duration.parse(value, key.to_s) if Duration.active_support?(value) }
      expect = fields.delete(:expect)
      unless expect.nil?
        fields[:expect] =
          case expect
          when String then "contains #{JS.quote(expect)}"
          when Regexp then "matches #{expect.inspect}"
          else "custom function"
          end
      end
      JobDefinition.new(fields)
    end

    # nil when the output satisfies `expect`, or why it does not. A callable's
    # answer is read with Ruby's truthiness.
    def check_expectation(expect, output)
      return nil if expect.nil?

      text = output || ""
      case expect
      when String
        text.include?(expect) ? nil : "Output did not contain #{JS.quote(expect)}"
      when Regexp
        # match? keeps no position between calls (JavaScript's /g and /y do,
        # which is why the SDK resets lastIndex) and does not touch $~, so
        # every run is checked from the start whatever the flags.
        matches?(expect, text) ? nil : "Output did not match #{expect.inspect}"
      else
        ok = false
        begin
          ok = expect.call(text)
        rescue StandardError => e
          return "Output check threw: #{e.message}"
        end
        ok ? nil : "Output did not pass the expect() check"
      end
    end

    # Whether the pattern matches within PATTERN_TIMEOUT; a timeout is no.
    def matches?(pattern, text)
      limit = [pattern.timeout, Regexp.timeout, PATTERN_TIMEOUT].compact.min
      Regexp.new(pattern, timeout: limit).match?(text)
    rescue Regexp::TimeoutError
      false
    end
  end
end
