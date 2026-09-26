# frozen_string_literal: true

module Cronwatch
  module Output
    # Output is capped so a chatty job cannot fill the store. The tail is kept.
    # Counted in UTF-16 code units, as the SDK counts it.
    CAP = 16 * 1024

    module_function

    def cap(text)
      return text if JS.length16(text) <= CAP

      "[earlier output trimmed]\n#{JS.tail16(text, CAP)}"
    end

    # "Name: message" and the first five backtrace lines, each written as
    # "    at <line>" like the frames of a JavaScript stack.
    def error_message(error)
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
  end
end
