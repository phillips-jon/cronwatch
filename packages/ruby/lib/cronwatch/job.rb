# frozen_string_literal: true

module Cronwatch
  # Raised by Signal#check! once a signal has aborted.
  class AbortError < StandardError; end

  # A cancellation flag, like an AbortSignal. A job's signal aborts once the
  # job's timeout has passed; triage gets one that aborts when the client
  # stops waiting. Nothing is interrupted: code that can stop early checks it.
  class Signal
    def initialize(timeout_ms = nil)
      @deadline = timeout_ms && (Signal.monotonic + (timeout_ms / 1000.0))
      @aborted = false
      @settled = false
      @lock = Mutex.new
    end

    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def aborted?
      @lock.synchronize do
        @aborted = true if !@aborted && !@settled && @deadline && Signal.monotonic >= @deadline
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

  # What a job's block receives.
  class JobContext
    attr_reader :name, :run_id, :started_at, :signal

    def initialize(run, signal, recorder)
      @name = run.job
      @run_id = run.id
      @started_at = run.started_at
      @signal = signal
      @recorder = recorder
    end

    # Append a line of output. Kept with the run, capped at 16 KB, shown in alerts and the dashboard.
    def log(*parts)
      @recorder.log(parts.map { |part| JobContext.stringify(part) }.join(" "))
      nil
    end

    # Report a number for this run: tokens, cost, rows, anything. Watched against budgets and baselines.
    def metric(name, value)
      unless value.is_a?(Numeric) && value.real? && JS.finite?(value)
        raise ArgumentError, "metric \"#{name}\" must be a finite number"
      end

      @recorder.metric(name.to_s, value)
      nil
    end

    def metrics(values = nil, **more)
      (values || {}).merge(more).each { |k, v| metric(k, v) }
      nil
    end

    # True once the job's timeout has passed. Honour it if the work can stop.
    def aborted?
      @signal.aborted?
    end

    def self.stringify(part)
      case part
      when String then part
      when Symbol then part.to_s
      when Exception then "#{part.class.name || part.class}: #{part.message}"
      when Hash, Array, Numeric, true, false, nil, Struct then JS.json(part)
      else part.to_s
      end
    end
  end

  # A declared job. Keep it, and call #run with a block.
  class JobHandle
    attr_reader :name, :definition

    def initialize(client, definition)
      @client = client
      @definition = definition
      @name = definition.name
    end

    # Run the block now, recording the run. Returns what the block returns and
    # re-raises what it raises, after the run is recorded.
    def run(trigger: "run", &block)
      raise ArgumentError, "run needs a block" unless block

      outcome = @client.execute(@definition, trigger, &block)
      raise outcome.error if outcome.threw

      outcome.result
    end
  end

  # Collects a run's output and metrics while its block runs.
  class RunRecorder
    # Lines are dropped from the front once the output is well past the cap;
    # Output.cap trims it exactly at the end.
    KEEP = 64 * 1024

    attr_reader :context, :signal

    def initialize(run, timeout_ms)
      @lines = []
      @size = 0
      # The first lines logged, up to the cap, and whether any line has been
      # dropped from @lines: what expect_text needs once the output runs long.
      @head = []
      @head_size = 0
      @dropped = false
      @metrics = {}
      @lock = Mutex.new
      @signal = Signal.new(timeout_ms)
      @context = JobContext.new(run, @signal, self)
    end

    def log(line)
      length = JS.length16(line)
      @lock.synchronize do
        if @head_size < Output::CAP
          @head << line
          @head_size += length + 1
        end
        @lines << line
        @size += length + 1
        while @size > KEEP && @lines.length > 1
          @size -= JS.length16(@lines.shift) + 1
          @dropped = true
        end
      end
    end

    def metric(name, value)
      @lock.synchronize { @metrics[name] = value }
    end

    def output
      @lock.synchronize { @lines.empty? ? nil : Output.cap(@lines.join("\n")) }
    end

    # What an expect rule is checked against: everything logged, or when that
    # ran long, the first 16 KB and the last 16 KB. The stored output keeps
    # only the tail, so a "done" line printed early would otherwise be lost.
    def expect_text
      @lock.synchronize do
        next nil if @lines.empty?

        all = @lines.join("\n")
        next all if !@dropped && JS.length16(all) <= 2 * Output::CAP

        "#{JS.head16(@head.join("\n"), Output::CAP)}\n#{JS.tail16(all, Output::CAP)}"
      end
    end

    def metrics
      @lock.synchronize { @metrics.dup }
    end
  end
end
