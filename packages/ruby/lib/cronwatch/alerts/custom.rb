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

      # `context` is the client's Client::ChannelContext: a block taking a
      # second argument gets it, to report a problem that did not stop the
      # alert going out (context.on_error(error)).
      def call(alert, context = nil)
        if Client.takes_context?(@send)
          @send.call(alert, context)
        else
          @send.call(alert)
        end
        nil
      end
    end
  end
end
