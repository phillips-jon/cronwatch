# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/resume_across_clients"

# Runs that span calls: JobHandle#start, #resume and the RunHandle.
# packages/sdk/test/start-finish.test.ts; the SQL stores' resume test is in
# test/active_record/start_finish_test.rb.
class StartFinishTest < Minitest::Test
  include TestHelpers
  include ResumeAcrossClients

  def setup
    @errors = []
  end

  def client(**options)
    make(on_error: ->(error, where) { @errors << [error, where] }, **options)
  end

  def messages
    @errors.map { |error, _| error.message }
  end

  def test_start_records_a_running_run_and_finish_records_it_ok
    cw, clock, capture = client
    job = cw.job("sync", schedule: "@hourly")
    run = job.start(trigger: "queue")
    assert_equal "sync", run.job
    assert run.active?
    stored = cw.get_run(run.id)
    assert_equal :running, stored.status
    assert_equal "queue", stored.trigger
    run.log("imported", 12, "rows")
    run.metric(:rows, 12)
    clock.advance(90_000)
    finished = run.finish
    assert_equal :ok, finished.status
    assert_equal 90_000, finished.duration_ms
    refute run.active?
    recorded = cw.runs("sync").first
    assert_equal :ok, recorded.status
    assert_equal "imported 12 rows", recorded.output
    assert_equal({ "rows" => 12 }, recorded.metrics)
    assert_equal [], capture.types
    assert_equal :healthy, cw.job_summary("sync").health
    assert_equal [], @errors
  end

  def test_fail_and_finish_with_an_error_record_a_failure_and_alert_once
    cw, _clock, capture = client
    job = cw.job("import", failures_before_alert: 2)
    job.start.fail(RuntimeError.new("api down"))
    run = job.start.finish(error: RuntimeError.new("still down"))
    assert_equal :failed, run.status
    assert_match(/\ARuntimeError: still down/, run.error)
    assert_equal [:failed], capture.types
    third = job.start(trigger: "retry")
    third.finish(status: "ok")
    assert_equal %i[failed recovered], capture.types
  end

  def test_a_second_finish_is_ignored_and_reported_not_raised
    cw, _clock, capture = client
    run = cw.job("once").start
    a = run.fail("boom")
    b = run.finish
    assert_equal :failed, a.status
    assert_nil b
    assert_nil run.finish
    assert_equal [:failed], capture.types
    assert_equal :failed, cw.runs("once").first.status
    assert_equal 2, @errors.length
    assert_match(/was already finished by this handle; ignored/, messages[0])
    assert_equal "finishing once", @errors[0][1]
  end

  def test_start_with_an_id_twice_records_one_run_and_returns_a_handle_on_it
    cw, = client
    job = cw.job("inngest-fn")
    one, two = Array.new(2) { Thread.new { job.start(id: "01HX-run") } }.map(&:value)
    assert_equal "01HX-run", one.id
    assert_equal "01HX-run", two.id
    again = job.start(id: "01HX-run", trigger: "ignored")
    assert again.active?
    assert_equal 1, cw.runs("inngest-fn").length
    assert_equal "start", cw.get_run("01HX-run").trigger
    again.finish("done")
    # Finished elsewhere: this handle's finish is a reported no-op.
    assert_nil one.finish
    assert_match(/already finished as ok; ignored/, messages.last)
    late = job.start(id: "01HX-run")
    refute late.active?
    assert_nil late.finish
    assert_equal 1, cw.runs("inngest-fn").length
    error = assert_raises(ArgumentError) { cw.job("other").start(id: "01HX-run") }
    assert_equal 'run "01HX-run" belongs to job "inngest-fn", not "other"', error.message
    error = assert_raises(ArgumentError) { job.start(id: "") }
    assert_equal 'job "inngest-fn": start() needs a run id of 1 to 200 characters (got 0 characters)', error.message
    error = assert_raises(ArgumentError) { job.start(id: "x" * 201) }
    assert_match(/\(got 201 characters\)\z/, error.message)
    error = assert_raises(ArgumentError) { job.resume(42) }
    assert_equal 'job "inngest-fn": resume() needs a run id of 1 to 200 characters (got Integer)', error.message
    # No store could hold a NUL (Postgres refuses it), so such an id is refused wherever one is taken.
    error = assert_raises(ArgumentError) { job.start(id: "01HX\0run") }
    assert_equal 'job "inngest-fn": start() cannot take a run id containing a NUL character', error.message
    error = assert_raises(ArgumentError) { job.resume("01HX\0run") }
    assert_equal 'job "inngest-fn": resume() cannot take a run id containing a NUL character', error.message
    nul = { id: "x\0y", job: "inngest-fn", status: "ok", started_at: 1, finished_at: 2, duration_ms: 1,
            error: nil, output: nil, metrics: {}, trigger: "run" }
    error = assert_raises(ArgumentError) { cw.record_run(nul) }
    assert_equal 'record_run: run ids cannot contain a NUL character (job "inngest-fn")', error.message
    assert_equal 1, cw.runs("inngest-fn").length
  end

  def test_resume_in_a_second_client_on_the_same_store_memory_appends_and_finishes
    store = Cronwatch::Stores::Memory.new
    check_resume_across_clients(store, store)
  end

  def test_resume_of_an_unknown_or_finished_run_returns_a_handle_whose_finish_is_a_reported_no_op
    cw, = client
    job = cw.job("webhook")
    missing = job.resume("nope")
    refute missing.active?
    assert_nil missing.started_at
    missing.log("dropped")
    missing.flush
    assert_nil missing.finish
    assert_equal "run nope of webhook was not found; ignored", messages[0]
    job.run { "done" }
    done = cw.runs("webhook").first
    finished = job.resume(done.id)
    refute finished.active?
    assert_nil finished.fail("late")
    assert_match(/already finished as ok; ignored/, messages[1])
    assert_equal :ok, cw.runs("webhook").first.status
    error = assert_raises(ArgumentError) { cw.resume_run("undeclared", "x") }
    assert_equal 'resume_run: job "undeclared" is not declared; call job first', error.message
  end

  def test_a_run_never_finished_is_marked_stuck_after_the_jobs_timeout
    cw, clock, capture = client
    run = cw.job("callback", timeout: "30m").start
    clock.advance(29 * MIN)
    cw.check
    assert_equal :running, cw.get_run(run.id).status
    clock.advance(2 * MIN)
    cw.check
    stored = cw.get_run(run.id)
    assert_equal :timeout, stored.status
    assert_match(/Still running after 30m/, stored.error)
    assert_equal [:stuck], capture.types
  end

  def test_lines_flushed_while_a_check_marks_earlier_runs_stuck_are_kept_on_the_run_it_marks_next
    sending = Queue.new
    gate = Queue.new
    held = Cronwatch::Alerts::Custom.new("held") do |_alert|
      sending.push(true)
      gate.pop
    end
    cw, clock, = client(alerts: [held])
    first = cw.job("first", timeout: "30m").start
    clock.advance(1000)
    second = cw.job("second", timeout: "30m").start
    second.log("early line")
    second.metric(:rows, 1)
    second.flush
    clock.advance(31 * MIN)
    check = Thread.new { cw.check }
    # The first stuck run's alert is being sent; the second is still running, and flushes.
    sending.pop
    second.log("important progress line")
    second.metric(:rows, 2)
    second.flush
    gate.push(true)
    gate.push(true)
    check.join
    stored = cw.get_run(second.id)
    assert_equal :timeout, stored.status
    assert_equal "early line\nimportant progress line", stored.output
    assert_equal({ "rows" => 2 }, stored.metrics)
    assert_equal :timeout, cw.get_run(first.id).status
  end

  def test_a_late_success_after_a_timeout_mark_closes_stuck_and_recovers_a_late_failure_does_not_count_twice
    cw, clock, capture = client
    job = cw.job("slowpoke", timeout: "10m", failures_before_alert: 2)
    first = job.start
    clock.advance(11 * MIN)
    cw.check
    assert_equal [], capture.types
    failed = first.fail(RuntimeError.new("gave up"))
    assert_equal :failed, failed.status
    assert_equal "RuntimeError: gave up", cw.get_run(first.id).error.split("\n").first, "the run keeps its real error"
    assert_equal [], capture.types, "the late failure did not count as a second one"

    second = job.start
    clock.advance(11 * MIN)
    cw.check
    assert_equal [:stuck], capture.types
    resumed = cw.resume_run("slowpoke", second.id)
    assert resumed.active?, "a run marked timeout can still be finished late"
    late = resumed.finish
    assert_equal :ok, late.status
    assert_equal %i[stuck recovered], capture.types
    assert_nil second.finish, "the handle that started it sees it finished elsewhere"
  end

  # The SDK's test also finishes with a Response of 502 and expects "HTTP 502".
  # Ruby's run has no response type to judge, so neither has finish.
  def test_expect_is_applied_at_finish_to_the_logged_lines_or_the_string_passed
    cw, _clock, capture = client
    job = cw.job("export", expect: /wrote \d+ files/)
    run = job.start.finish(status: "ok", result: "nothing to do")
    assert_equal :failed, run.status
    assert_equal "nothing to do", run.output
    assert_match(/did not match/, run.error)
    assert_equal [:failed], capture.types

    busy = job.start
    busy.log("wrote 3 files")
    busy.flush
    resumed = job.resume(busy.id)
    assert_equal :ok, resumed.finish("uploaded").status, "lines flushed earlier count toward expect"
    assert_equal %i[failed recovered], capture.types
  end

  def test_a_store_failing_during_start_does_not_raise_finish_records_the_run_once_the_store_is_back
    broken = Set[:insert_run]
    cw, clock, capture = client(store: Flaky.new(Cronwatch::Stores::Memory.new, broken))
    job = cw.job("backup", schedule: "@hourly")
    run = job.start
    assert run.active?
    assert_equal "recording backup", @errors[0][1]
    assert_nil cw.get_run(run.id)
    run.log("copied")
    run.flush # nothing stored to append to; kept for finish
    broken.clear
    clock.advance(HOUR / 2)
    finished = run.finish
    assert_equal :ok, finished.status
    stored = cw.get_run(run.id)
    assert_equal :ok, stored.status
    assert_equal "copied", stored.output
    assert_equal HOUR / 2, stored.duration_ms
    assert_equal [], capture.types
  end

  def test_a_store_failing_at_finish_is_reported_not_raised_and_the_handle_can_finish_again
    broken = Set.new
    cw, = client(store: Flaky.new(Cronwatch::Stores::Memory.new, broken))
    run = cw.job("flaky").start
    run.log("working")
    broken << :get_run << :update_run << :update_run_if
    run.flush
    assert_equal "flushing flaky", @errors.last[1]
    assert_nil run.finish, "nothing recorded"
    assert(@errors.any? { |_, where| where == "finishing flaky" })
    assert run.active?, "still active, to finish again"
    # The read works but the write fails: still retryable.
    broken.delete(:get_run)
    assert_nil run.finish
    assert run.active?
    broken.clear
    assert_equal :running, cw.get_run(run.id).status, "nothing written yet"
    finished = run.finish
    assert_equal :ok, finished.status
    assert_equal "working", finished.output, "the lines logged before the failures are kept"
    refute run.active?
    assert_nil run.finish, "finished once only"
  end

  # Not in the SDK's file: a failed flush keeps its lines for finish, ahead of those logged since.
  def test_a_flush_that_cannot_write_keeps_its_lines_for_finish
    broken = Set.new
    cw, = client(store: Flaky.new(Cronwatch::Stores::Memory.new, broken))
    run = cw.job("kept").start
    run.log("first")
    run.metric(:n, 1)
    broken << :update_run_if
    run.flush
    broken.clear
    run.log("second")
    run.metric(:n, 2)
    finished = run.finish
    assert_equal "first\nsecond", finished.output
    assert_equal({ "n" => 2 }, cw.get_run(run.id).metrics)
  end

  # An Interrupt (or Timeout) while finish writes: it is raised, the run is
  # still running, and the handle takes finish again with its lines.
  def test_an_interrupt_mid_finish_leaves_the_handle_retryable
    store = Class.new(Cronwatch::Stores::Memory) do
      attr_accessor :boom

      def update_run_if(run, from_statuses)
        if boom
          self.boom = false
          raise Interrupt
        end
        super
      end
    end.new
    cw, = client(store: store)
    run = cw.job("sync", timeout: "5m").start
    run.log("working")
    store.boom = true
    assert_raises(Interrupt) { run.finish }
    assert run.active?
    assert_equal :running, store.get_run(run.id).status
    finished = run.finish
    assert_equal :ok, finished.status
    assert_equal "working", store.get_run(run.id).output
    refute run.active?
    assert_equal [], @errors
  end

  # A start whose row later reads as missing (written inside a transaction
  # that rolled back) is inserted at finish, as execute inserts a start it
  # could not record.
  def test_a_started_run_gone_from_the_store_is_inserted_at_finish
    inner = Cronwatch::Stores::Memory.new
    cw, = client(store: inner)
    run = cw.job("sync").start
    run.log("done")
    inner.instance_variable_get(:@runs).delete(run.id)
    finished = run.finish
    assert_equal :ok, finished.status
    assert_equal :ok, cw.get_run(run.id).status
    assert_equal "done", cw.get_run(run.id).output
    assert_equal 1, cw.runs("sync").size
  end

  # A resumed run that is gone at finish (its job forgotten, say) is not
  # recreated: only a start this handle made is inserted again.
  def test_a_resumed_run_gone_from_the_store_is_not_recreated
    inner = Cronwatch::Stores::Memory.new
    cw, = client(store: inner)
    job = cw.job("sync")
    job.start(id: "evt-1")
    run = job.resume("evt-1")
    inner.instance_variable_get(:@runs).delete("evt-1")
    run.finish
    assert_nil cw.get_run("evt-1")
  end
end
