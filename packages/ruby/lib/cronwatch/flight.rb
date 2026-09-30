# frozen_string_literal: true

module Cronwatch
  class Client
    # One shared check: the first caller runs it, the others wait for its result.
    class Flight
      # The thread running the check.
      attr_reader :owner

      def initialize
        @owner = Thread.current
        @lock = Mutex.new
        @done = ConditionVariable.new
        @finished = false
      end

      def resolve(value)
        settle(value, nil)
      end

      def reject(error)
        settle(nil, error)
      end

      def value
        @lock.synchronize do
          @done.wait(@lock) until @finished
          raise @error if @error

          @value
        end
      end

      private

      def settle(value, error)
        @lock.synchronize do
          @value = value
          @error = error
          @finished = true
          @done.broadcast
        end
      end
    end
  end
end
