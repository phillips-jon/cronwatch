# frozen_string_literal: true

module Cronwatch
  # A run recorded by JobHandle#start or found by JobHandle#resume, to finish
  # later, perhaps in another process. Lines and metrics wait in the handle
  # until #flush or #finish. Store failures go to on_error; none of these
  # methods raises for them.
  #
  #   run = SYNC.start(id: event_id)
  #   # later, perhaps elsewhere
  #   run = SYNC.resume(event_id)
  #   run.log("sent 40 emails")
  #   run.finish                  # or run.fail(error)
  class RunHandle
    # Raised by the client's side of finish when the store failed part way
    # and nothing was recorded (already reported): the handle stays active.
    #
    # @api private
    class Retry < StandardError; end

    # `started_at` is nil when a resumed run could not be read.
    attr_reader :id, :job, :started_at

    # Made by the client (Client#run_handle), not by apps. `finish` and
    # `flush` are the client's side of each; `inactive` says why finish has
    # nothing to do, or is nil.
    #
    # @api private
    def initialize(id:, job:, started_at:, inactive:, finish:, flush:, ignored:)
      @id = id
      @job = job
      @started_at = started_at
      @inactive = inactive
      @finish = finish
      @flush = flush
      @ignored = ignored
      # @state guards the flags and which recorder is current; @turn keeps
      # flush and finish in order, one at a time.
      @state = Mutex.new
      @turn = Mutex.new
      @recorder = fresh_recorder
      @finished = !inactive.nil?
      @finish_called = false
      # The first Output::CAP characters of every line flushed from this
      # handle, unredacted, or nil before the first flush. The stored output
      # keeps only the tail, so without it an expect rule at finish would
      # miss a line logged early, which run would have seen.
      @head = nil
    end

    # False once finished, and from the start for a resumed run that already
    # finished or does not exist.
    def active?
      @state.synchronize { !@finished }
    end

    # Add a line of output, as JobContext#log does. Kept in the handle until flush or finish.
    def log(*parts)
      @state.synchronize { @recorder.context.log(*parts) }
    end

    # Report a number for this run. A later value for the same name replaces an earlier one.
    def metric(name, value)
      @state.synchronize { @recorder.context.metric(name, value) }
    end

    def metrics(values = nil, **more)
      @state.synchronize { @recorder.context.metrics(values, **more) }
    end

    # Append the lines and metrics added so far to the stored run, which must
    # still be running and belong to this job. Output is redacted as it is
    # written. A read, change and write of the run's row, written only while
    # it is still running: two processes appending to one run at the same
    # moment can lose one's lines, but a flush never undoes a finish. When
    # the write fails the lines stay here for finish. The first 16 KB of
    # everything flushed stay in the handle, so an expect rule at finish
    # sees an early line as run would.
    def flush
      @turn.synchronize do
        next if @flush.nil? || @state.synchronize { @finished }

        # Lines logged while this waits on the store go to a new recorder.
        taken = @state.synchronize do
          current = @recorder
          @recorder = fresh_recorder
          current
        end
        lines = taken.output
        values = taken.metrics
        next if lines.nil? && values.empty?

        if @flush.call(lines, values)
          keep_head(taken.expect_text)
        else
          put_back(taken)
        end
      end
      nil
    end

    # Finish the run, judge it like any other and send what that produces.
    #
    #   finish                        # ok
    #   finish(status: "ok")          # ok
    #   finish(error: e)              # failed, recorded like an error run caught
    #   finish("text")                # like run's return value: the output when
    #   finish(result: "text")        # nothing was logged, checked by expect
    #
    # Returns the run as recorded, or nil when nothing was: the run was
    # already finished (here or elsewhere), was not found, or belongs to
    # another job, which is reported to on_error. When several processes
    # finish one run, only the one whose write lands judges it. A store that
    # fails is reported, nothing is recorded, and the handle stays active so
    # finish can be called again.
    def finish(outcome = nil)
      was_inactive = nil
      again = @state.synchronize do
        next true if @finish_called

        @finish_called = true
        was_inactive = @finished
        @finished = true
        false
      end
      if again
        @ignored.call("was already finished by this handle")
        return nil
      end

      @turn.synchronize do
        if was_inactive
          @ignored.call(@inactive)
          next nil
        end

        begin
          @finish.call(@state.synchronize { @recorder }, outcome, @head)
        rescue Retry
          reopen
          nil
        rescue Exception # rubocop:disable Lint/RescueException
          # An Interrupt or Timeout mid-finish: the run may still be running,
          # so the handle stays open (lines kept) for finish to be called again.
          reopen
          raise
        end
      end
    end

    # finish(error: error).
    def fail(error)
      finish({ error: error })
    end

    # [failed, result, error] from what finish was given. A Hash with an
    # :error key is a failure; a String, or a Hash's :result, is the result.
    #
    # @api private
    def self.read_outcome(outcome)
      case outcome
      when String then [false, outcome, nil]
      when Hash
        key = [:error, "error"].find { |k| outcome.key?(k) }
        return [true, nil, outcome[key]] if key

        [false, outcome.key?(:result) ? outcome[:result] : outcome["result"], nil]
      else [false, nil, nil]
      end
    end

    private

    def fresh_recorder
      RunRecorder.new(Run.new(id: @id, job: @job, started_at: @started_at || 0), nil)
    end

    # A flush that could not write: its lines go back ahead of any logged since.
    def put_back(taken)
      @state.synchronize do
        later = @recorder
        @recorder = fresh_recorder
        [taken.expect_text, later.expect_text].each { |text| @recorder.log(text) unless text.nil? }
        taken.metrics.merge(later.metrics).each { |name, value| @recorder.metric(name, value) }
      end
    end

    # A finish that recorded nothing leaves the handle active, to be finished again.
    def reopen
      @state.synchronize do
        @finish_called = false
        @finished = false
      end
    end

    # Keeps the start of what a flush wrote, up to the cap, for expect at finish.
    def keep_head(text)
      return if text.nil? || (!@head.nil? && JS.length16(@head) >= Output::CAP)

      @head = JS.head16(@head.nil? || @head.empty? ? text : "#{@head}\n#{text}", Output::CAP)
    end
  end
end
