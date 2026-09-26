# frozen_string_literal: true

module Cronwatch
  module Serialize
    module_function

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
        expect.match?(text) ? nil : "Output did not match #{expect.inspect}"
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
  end
end
