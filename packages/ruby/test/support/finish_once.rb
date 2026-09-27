# frozen_string_literal: true

require_relative "../test_helper"

# packages/sdk/test/finish-once.test.ts: a run is judged once, however many
# processes finish it. These race several clients over one database, against
# the memory store (test/finish_once_test.rb) and the ActiveRecord store on
# SQLite and Postgres (test/active_record/finish_once_test.rb). The including
# class defines `open_store`, a store over the same database each call.
module FinishOnceAcrossProcesses
  include TestHelpers

  # A store whose run reads take a moment, as over a network, so processes
  # racing to finish a run all read it before any of them writes (as the
  # SDK's promises interleave), rather than one thread finishing first.
  class SlowRunReads
    def initialize(store)
      @store = store
    end

    def respond_to_missing?(name, include_private = false) = @store.respond_to?(name, include_private)

    def method_missing(name, *args, &block)
      return super unless @store.respond_to?(name)

      result = @store.public_send(name, *args, &block)
      sleep 0.02 if name == :get_run
      result
    end
  end

  def process(store, clock)
    capture = Capture.new
    errors = []
    lock = Mutex.new
    cw = Cronwatch.new(store: SlowRunReads.new(store), now: clock.to_proc, alerts: [capture], cron_secret: nil,
                       on_error: ->(e, _where) { lock.synchronize { errors << e.message } })
    { cw: cw, alerts: capture, errors: errors }
  end

  def failed_run(id, job, started_at)
    { id: id, job: job, status: "failed", started_at: started_at, finished_at: started_at + 1000, duration_ms: 1000,
      error: "ERROR: deadlock detected", output: nil, metrics: {}, trigger: "pg_cron" }
  end

  # Each block in a thread of its own, all at once; their values in order.
  def at_once(*blocks)
    blocks.map { |block| Thread.new(&block) }.map(&:value)
  end

  def test_two_processes_finishing_one_run_one_records_and_judges_it_the_other_reports_it_already_finished
    clock = Clock.new
    one, two = [process(open_store, clock), process(open_store, clock)]
    jobs = [one, two].map { |p| p[:cw].job("webhook-ingest", failures_before_alert: 2) }
    jobs[0].start(id: "delivery-1")
    h1, h2 = at_once(-> { one[:cw].resume_run("webhook-ingest", "delivery-1") }, -> { two[:cw].resume_run("webhook-ingest", "delivery-1") })
    clock.advance(MIN)
    results = at_once(-> { h1.fail(RuntimeError.new("upstream 502")) }, -> { h2.fail(RuntimeError.new("upstream 502")) })
    assert_equal 1, results.compact.length, "one finish recorded"
    assert((one[:errors] + two[:errors]).any? { |e| e.include?("already finished as failed; ignored") }, (one[:errors] + two[:errors]).inspect)
    assert_equal 1, one[:cw].runs("webhook-ingest").length
    assert_equal 1, one[:cw].store.get_state("webhook-ingest").consecutive_failures, "the failure counted once"
    assert_equal [], one[:alerts].types + two[:alerts].types, "one failure is below failures_before_alert 2"
  end

  def test_two_processes_recording_one_finished_run_from_a_source_it_is_judged_once
    clock = Clock.new
    one, two = [process(open_store, clock), process(open_store, clock)]
    [one, two].each { |p| p[:cw].job("db:rollup", failures_before_alert: 2) }
    t = T0 - MIN
    one[:cw].record_run(failed_run("pgcron:9", "db:rollup", t).merge(status: "running", finished_at: nil, duration_ms: nil, error: nil))
    two[:cw].jobs
    done = failed_run("pgcron:9", "db:rollup", t)
    at_once(-> { one[:cw].record_run(done) }, -> { two[:cw].record_run(done) })
    assert_equal 1, one[:cw].store.get_state("db:rollup").consecutive_failures
    assert_equal [], one[:alerts].types + two[:alerts].types
    # Threads really race here, unlike the SDK's Promise.all: the second
    # process either collides with the first write and reports it, or reads
    # the run after it finished and skips it quietly. Both judge it once.
    errors = one[:errors] + two[:errors]
    assert(errors.all? { |e| e.include?("pgcron:9 of db:rollup was already finished as failed; ignored") }, errors.inspect)
    assert_operator errors.length, :<=, 1, errors.inspect
  end

  def test_many_processes_starting_and_finishing_one_id_exactly_one_finish_is_recorded
    clock = Clock.new
    clients = Array.new(6) { process(open_store, clock) }
    jobs = clients.map { |p| p[:cw].job("ingest") }
    clients[0][:cw].check
    5.times do |k|
      id = "evt_#{k}"
      handles = at_once(*jobs.map { |j| -> { j.start(id: id) } })
      finished = at_once(*handles.each_with_index.map { |h, i| -> { h.finish("worker #{i}") } })
      assert_equal 1, finished.compact.length, "#{id}: one finish recorded"
    end
    runs = clients[0][:cw].runs("ingest", 500)
    assert_equal 5, runs.length
    assert_equal [:ok], runs.map(&:status).uniq
    unexpected = clients.flat_map { |p| p[:errors] }.reject { |e| e.include?("already finished") }
    assert_equal [], unexpected
  end
end
