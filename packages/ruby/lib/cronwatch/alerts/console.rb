# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Writes alerts to the console: recoveries to standard output, the rest to
    # standard error. The default channel.
    class Console
      attr_reader :name

      def initialize(out: $stdout, err: $stderr)
        @name = "console"
        @out = out
        @err = err
      end

      def call(alert)
        line = "[cronwatch] #{alert.title}\n#{alert.message}#{alert.triage ? "\nTriage: #{alert.triage}" : ""}"
        (alert.type == :recovered ? @out : @err).puts(line)
      end
    end
  end
end
