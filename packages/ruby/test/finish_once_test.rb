# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/finish_once"

# packages/sdk/test/finish-once.test.ts against the memory store.
class FinishOnceTest < Minitest::Test
  include FinishOnceAcrossProcesses

  def setup
    @shared = Cronwatch::Stores::Memory.new
  end

  # The memory store is one process's; every "process" here shares it.
  def open_store = @shared

  def client(store, clock = Clock.new)
    process(store, clock)
  end

  # A store that hides update_run_if, as a custom store written before it would.
  class WithoutUpdateRunIf
    def initialize(store)
      @store = store
    end

    def respond_to_missing?(name, include_private = false)
      name != :update_run_if && @store.respond_to?(name, include_private)
    end

    def method_missing(name, *args, &block)
      return super if name == :update_run_if || !@store.respond_to?(name)

      @store.public_send(name, *args, &block)
    end
  end

  def test_a_store_without_update_run_if_falls_back_to_a_read_and_a_write
    p = client(WithoutUpdateRunIf.new(Cronwatch::Stores::Memory.new))
    job = p[:cw].job("plain")
    h = job.start(id: "p1")
    assert_equal :ok, h.finish("done").status
    assert_nil job.resume("p1").finish("again")
    assert(p[:errors].any? { |e| e.include?("already finished") })
  end

  def test_record_run_a_run_a_check_marked_timeout_takes_its_late_finish_as_a_handles_would
    clock = Clock.new(Time.utc(2026, 1, 1, 3).to_i * 1000)
    p = client(Cronwatch::Stores::Memory.new, clock)
    cw = p[:cw]
    cw.job("db:vacuum", schedule: "0 3 * * *", timeout: "30m")
    base = { id: "pgcron:77", job: "db:vacuum", started_at: clock.now, error: nil, output: nil, metrics: {}, trigger: "pg_cron" }
    cw.record_run(base.merge(status: "running", finished_at: nil, duration_ms: nil))
    clock.advance(45 * MIN)
    cw.check
    assert_equal :timeout, cw.get_run("pgcron:77").status
    clock.advance(15 * MIN)
    cw.record_run(base.merge(status: "ok", finished_at: clock.now - (5 * MIN), duration_ms: 55 * MIN, output: "VACUUM"))
    cw.check
    run = cw.get_run("pgcron:77")
    assert_equal [:ok, "VACUUM"], [run.status, run.output]
    assert_equal :healthy, cw.job_summary("db:vacuum").health
    assert_equal %i[stuck recovered], p[:alerts].types

    # A late failure is written but not counted twice.
    other = base.merge(id: "pgcron:78", started_at: clock.now)
    cw.record_run(other.merge(status: "running", finished_at: nil, duration_ms: nil))
    clock.advance(45 * MIN)
    cw.check
    cw.record_run(other.merge(status: "failed", finished_at: clock.now, duration_ms: 45 * MIN, error: "ERROR: canceled"))
    assert_equal :failed, cw.get_run("pgcron:78").status
    assert_equal 1, cw.store.get_state("db:vacuum").consecutive_failures
    assert_equal %i[stuck recovered stuck], p[:alerts].types
  end

  def test_record_run_leaves_a_stored_run_of_another_job_alone_and_reports_it
    p = client(Cronwatch::Stores::Memory.new)
    cw = p[:cw]
    a = cw.job("webhook-job")
    cw.job("db:nightly")
    h = a.start(id: "run-43")
    sent = cw.record_run({ id: "run-43", job: "db:nightly", status: "ok", started_at: T0 - 1000, finished_at: T0, duration_ms: 1000,
                           error: nil, output: nil, metrics: {}, trigger: "pg_cron" })
    assert_equal [], sent
    stored = cw.get_run("run-43")
    assert_equal ["webhook-job", :running], [stored.job, stored.status]
    assert(p[:errors].any? { |e| e.include?('run-43 of db:nightly belongs to job "webhook-job"; ignored') }, p[:errors].inspect)
    assert_equal :ok, h.finish.status
    assert_equal [], p[:alerts].types
  end

  def test_start_and_resume_refuse_ids_in_the_pg_cron_sources_namespace
    cw = client(Cronwatch::Stores::Memory.new)[:cw]
    job = cw.job("webhook-job")
    message = 'job "webhook-job": start() cannot take a run id starting with "pgcron:", which the pg_cron source uses for its runs'
    assert_equal message, assert_raises(ArgumentError) { job.start(id: "pgcron:42") }.message
    assert_match(/resume\(\) cannot take a run id starting with "pgcron:"/, assert_raises(ArgumentError) { job.resume("pgcron:42") }.message)
    assert_match(/pgcron:/, assert_raises(ArgumentError) { cw.resume_run("webhook-job", "pgcron:db:42") }.message)
    assert job.start(id: "pgcron-42").active?, "only the prefix with its colon is reserved"
  end

  def test_start_with_an_id_another_job_holds_fails_the_same_whether_its_start_is_in_flight_or_done
    cw = client(Cronwatch::Stores::Memory.new)[:cw]
    a = cw.job("import-a")
    b = cw.job("import-b")
    outcomes = at_once(*[a, b].map do |j|
      lambda do
        j.start(id: "evt_123")
      rescue ArgumentError => e
        e
      end
    end)
    errors = outcomes.grep(ArgumentError)
    assert_equal 1, errors.length, "one start records the run; the other job's fails"
    owner = cw.get_run("evt_123").job
    other = owner == "import-a" ? "import-b" : "import-a"
    assert_match(/belongs to job "#{owner}", not "#{other}"/, errors[0].message)
    loser = owner == "import-a" ? b : a
    assert_match(/belongs to job "#{owner}", not "#{other}"/, assert_raises(ArgumentError) { loser.start(id: "evt_123") }.message)
    # The same job at once still records one run.
    x, y = at_once(-> { a.start(id: "evt_9") }, -> { a.start(id: "evt_9") })
    assert_equal x.id, y.id
    assert_equal 1, cw.runs("import-a").count { |r| r.id == "evt_9" }
  end

  # get_run fails once, when told to.
  class BlipStore < Cronwatch::Stores::Memory
    attr_accessor :fail

    def get_run(id)
      if fail
        self.fail = false
        raise "blip"
      end
      super
    end
  end

  def test_a_handle_resumed_while_the_store_failed_cannot_finish_or_flush_another_jobs_run
    store = BlipStore.new
    p = client(store)
    cw = p[:cw]
    billing = cw.job("billing")
    webhook = cw.job("webhook")
    billing.start(id: "run-7")
    store.fail = true
    h = webhook.resume("run-7")
    assert h.active?, "unknown yet: the read failed"
    h.log("attacker line")
    h.flush
    assert(p[:errors].any? { |e| e.include?('run run-7 of webhook belongs to job "billing"; ignored') }, p[:errors].inspect)
    assert_nil h.finish("ok")
    stored = store.get_run("run-7")
    assert_equal ["billing", :running, nil], [stored.job, stored.status, stored.output]
  end

  def test_expect_at_finish_sees_an_early_line_even_after_flushes_as_run_would
    cw = client(Cronwatch::Stores::Memory.new)[:cw]
    job = cw.job("export", expect: "connected to warehouse")
    job.run do |ctx|
      ctx.log("connected to warehouse")
      400.times { |i| ctx.log("row batch #{i} ".ljust(60, ".")) }
    end
    assert_equal :ok, cw.runs("export")[0].status
    h = job.start
    h.log("connected to warehouse")
    400.times do |i|
      h.log("row batch #{i} ".ljust(60, "."))
      h.flush if i % 100 == 99
    end
    run = h.finish
    assert_equal :ok, run.status, run.error.to_s
    refute_includes run.output, "connected to warehouse", "the stored output kept only the tail"
  end

  # Runs a callback once, right after the next get_run has read.
  class FinishFirstStore < Cronwatch::Stores::Memory
    attr_accessor :finish_first

    def get_run(id)
      run = super
      if finish_first
        callback = finish_first
        self.finish_first = nil
        callback.call
      end
      run
    end
  end

  def test_a_flush_never_undoes_a_finish_written_while_it_read
    store = FinishFirstStore.new
    cw = client(store)[:cw]
    job = cw.job("sync")
    h = job.start(id: "s1")
    h.log("halfway")
    other = job.resume("s1")
    store.finish_first = -> { other.finish("done elsewhere") }
    h.flush
    stored = store.get_run("s1")
    assert_equal [:ok, "done elsewhere"], [stored.status, stored.output], "still finished"
  end

  # Runs a callback once, right after the next running_runs has read.
  class RaceStore < Cronwatch::Stores::Memory
    attr_accessor :race

    def running_runs
      runs = super
      if race
        callback = race
        self.race = nil
        callback.call
      end
      runs
    end
  end

  def test_a_run_finished_while_a_check_marks_it_timeout_is_judged_once
    clock = Clock.new
    store = RaceStore.new
    p = client(store, clock)
    cw = p[:cw]
    job = cw.job("long", timeout: "5m")
    h = job.start
    clock.advance(10 * MIN)
    store.race = -> { h.finish("finally") }
    cw.check
    assert_equal :ok, cw.get_run(h.id).status
    assert_equal [], p[:alerts].types, "not marked stuck over a finish"
  end
end
