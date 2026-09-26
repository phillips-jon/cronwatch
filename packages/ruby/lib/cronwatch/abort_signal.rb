# frozen_string_literal: true

module Cronwatch
  # Raised by AbortSignal#check! once a signal has aborted.
  class AbortError < StandardError; end

  # A cancellation flag, like JavaScript's AbortSignal. A job's signal aborts
  # once the job's timeout has passed; triage gets one that aborts when the
  # client stops waiting. Nothing is interrupted: code that can stop early
  # checks it.
  class AbortSignal
    def initialize(timeout_ms = nil)
      @deadline = timeout_ms && (AbortSignal.monotonic + (timeout_ms / 1000.0))
      @aborted = false
      @settled = false
      @lock = Mutex.new
    end

    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def aborted?
      @lock.synchronize do
        @aborted = true if !@aborted && !@settled && @deadline && AbortSignal.monotonic >= @deadline
        @aborted
      end
    end

    def abort!
      @lock.synchronize { @aborted = true unless @settled }
    end

    # Raises AbortError when aborted, for a loop that should stop there.
    def check!
      raise AbortError, "This operation was aborted" if aborted?
    end

    # Called when the work is over: a timeout that passes later no longer aborts it.
    def settle!
      aborted?
      @lock.synchronize { @settled = true }
    end
  end
end
