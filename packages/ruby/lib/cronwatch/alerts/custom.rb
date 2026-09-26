# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Wraps any block as an alert channel:
    #
    #   Cronwatch::Alerts::Custom.new("pagerduty") do |alert|
    #     next if alert.type == :recovered
    #     PagerDuty.trigger(summary: alert.title, details: alert.message)
    #   end
    class Custom
      attr_reader :name

      def initialize(name, callable = nil, &block)
        @name = name.to_s
        @send = callable || block
        raise ArgumentError, "Cronwatch::Alerts::Custom needs a block" unless @send
      end

      def call(alert)
        @send.call(alert)
        nil
      end
    end
  end
end
