# frozen_string_literal: true

require_relative "abort_signal"

module Cronwatch
  class Client
    # Calls the block after `first` seconds, then every `interval` seconds
    # counted from the start, in a background thread, until stopped.
    #
    # @api private
    class Ticker
      def initialize(interval, first, &tick)
        @lock = Mutex.new
        @wake = ConditionVariable.new
        @stopped = false
        started = AbortSignal.monotonic
        @thread = Thread.new do
          Thread.current.name = "cronwatch-check" if Thread.current.respond_to?(:name=)
          Thread.current.report_on_exception = false
          first_at = started + first
          next_at = started + interval
          loop do
            due = first_at ? [first_at, next_at].min : next_at
            break unless wait_until(due)

            clock = AbortSignal.monotonic
            if first_at && clock >= first_at
              first_at = nil
            else
              next_at += interval while next_at <= clock
            end
            tick.call
          end
        end
      end

      def stop
        @lock.synchronize do
          @stopped = true
          @wake.broadcast
        end
      end

      # False once the thread has ended: stopped, or killed from outside.
      def alive?
        @thread.alive?
      end

      # Waits for the thread to end: once stopped, after the tick under way.
      # Returns at once when called from the thread itself.
      def join
        @thread.join unless Thread.current.equal?(@thread)
        nil
      end

      private

      # False once stopped.
      def wait_until(due)
        @lock.synchronize do
          loop do
            return false if @stopped

            left = due - AbortSignal.monotonic
            return true if left <= 0

            @wake.wait(@lock, left)
          end
        end
      end
    end
  end
end
