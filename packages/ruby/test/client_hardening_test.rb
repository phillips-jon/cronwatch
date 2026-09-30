# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# The SDK's client-hardening.test.ts and concurrency.test.ts: triage tried
# once per alert, the retry queue's order, budget and trimming, jobs that
# cannot be evaluated, a broken redact, and two processes sharing one store.
class ClientHardeningTest < Minitest::Test
  include TestHelpers

  # A channel that fails while `down` is set.
  class Flappy
    attr_accessor :down
    attr_reader :name, :sent

    def initialize
      @name = "flaky"
      @down = true
      @sent = []
    end

    def call(alert)
      raise "down" if @down

      @sent << alert
    end
  end

  # A store whose state reads take a while, as over a network: two processes
  # reading at about the same time both get the old state before either
  # writes. `without_cas` hides compare_and_set_state, as a custom store
  # written before it existed would.
  class SlowReads
    def initialize(store, without_cas: false)
      @store = store
      @without_cas = without_cas
    end

    def respond_to_missing?(name, include_private = false)
      return false if name == :compare_and_set_state && @without_cas

      @store.respond_to?(name, include_private)
    end

    def method_missing(name, *args, &block)
      return super unless respond_to_missing?(name)

      result = @store.public_send(name, *args, &block)
      sleep 0.025 if name == :get_state
      result
    end
  end

  # A store that refuses every conditional write, as if another process
  # wrote between every read and write.
  class Contested < SlowReads
    def compare_and_set_state(_state, _expected_version) = false
  end

  # A job's failure queued by a deliver: :check process, so a check elsewhere must triage and send it.
  def queued(store, clock, name = "backup")
    recorder = Cronwatch.new(store: store, now: clock.to_proc, deliver: :check, cron_secret: nil)
    assert_raises(RuntimeError) { recorder.run(name) { raise "disk full" } }
    recorder
  end

  def test_a_diagnosis_made_on_a_retry_is_kept_with_the_queued_alert_and_triage_runs_once_per_alert
    clock = Clock.new
    store = Cronwatch::Stores::Memory.new
    queued(store, clock)
    asked = 0
    channel = Flappy.new
    server = Cronwatch.new(store: store, now: clock.to_proc, alerts: [channel], cron_secret: nil, on_error: ->(*) {},
                           triage: lambda { |_|
                             asked += 1
                             "The disk is full."
                           })
    server.check
    assert_equal 1, asked
    assert_equal "The disk is full.", store.get_state("backup").undelivered[0].triage, "the stored copy has it"
    server.check
    server.check
    assert_equal 1, asked, "not asked again on later retries"
    channel.down = false
    server.check
    assert_equal [[:failed, "The disk is full."]], channel.sent.map { |a| [a.type, a.triage] }
  end

  def test_a_triage_that_raises_or_answers_nothing_is_tried_once_recorded_as_null
    [-> { raise "api down" }, -> { "" }, -> {}].each do |triage|
      clock = Clock.new
      store = Cronwatch::Stores::Memory.new
      queued(store, clock)
      asked = 0
      server = Cronwatch.new(store: store, now: clock.to_proc, cron_secret: nil, on_error: ->(*) {},
                             alerts: [Cronwatch::Alerts::Custom.new("down") { raise "down" }],
                             triage: lambda { |_|
                               asked += 1
                               triage.call
                             })
      3.times { server.check }
      assert_equal 1, asked
      alert = store.get_state("backup").undelivered[0]
      assert_nil alert.triage
      assert alert.triage_tried?
      assert_includes alert.to_json, '"triage":null'
    end
  end

  def test_retries_stop_once_a_check_has_spent_its_budget_and_the_rest_wait
    clock = Clock.new
    store = Cronwatch::Stores::Memory.new
    %w[a b c].each { |name| queued(store, clock, name) }
    tried = []
    # Each attempt takes 60% of the budget and fails.
    slow = Cronwatch::Alerts::Custom.new("slow") do |alert|
      tried << alert.job
      sleep 0.12
      raise "timed out"
    end
    server = Cronwatch.new(store: store, now: clock.to_proc, alerts: [slow], cron_secret: nil, on_error: ->(*) {})
    server.instance_variable_set(:@retry_budget_ms, 200)
    server.check
    assert_equal %w[a b], tried, "the budget covers two attempts"
    assert_equal 1, store.get_state("c").undelivered.length, "c is still queued"
    tried.clear
    server.check
    assert_equal %w[a b], tried, "each check has a fresh budget"
  end

  def test_an_alert_whose_condition_closed_is_dropped_from_the_retry_queue_a_recovery_is_sent
    channel = Flappy.new
    cw, clock, = make(alerts: [channel], on_error: ->(*) {})
    assert_raises(RuntimeError) { cw.run("s") { raise "x" } }
    clock.advance(MIN)
    cw.run("s") { nil }
    assert_equal %i[failed recovered], cw.store.get_state("s").undelivered.map(&:type)
    last_alert_at = cw.store.get_state("s").last_alert_at
    channel.down = false
    clock.advance(MIN)
    cw.check
    assert_equal ["recovered@#{T0 + MIN}"], channel.sent.map { |a| "#{a.type}@#{a.at}" }, "the failure is over, so only its recovery goes"
    state = cw.store.get_state("s")
    assert_empty state.undelivered
    refute_equal last_alert_at, state.last_alert_at, "the recovery was delivered"
  end

  def test_an_alert_whose_condition_opened_again_is_dropped_and_so_is_a_recovery_it_undoes
    channel = Flappy.new
    cw, clock, = make(alerts: [channel], on_error: ->(*) {})
    assert_raises(RuntimeError) { cw.run("s") { raise "x" } }
    clock.advance(MIN)
    cw.run("s") { nil }
    clock.advance(MIN)
    assert_raises(RuntimeError) { cw.run("s") { raise "again" } }
    assert_equal %i[failed recovered failed], cw.store.get_state("s").undelivered.map(&:type)
    channel.down = false
    clock.advance(MIN)
    cw.check
    assert_equal ["failed@#{T0 + (2 * MIN)}"], channel.sent.map { |a| "#{a.type}@#{a.at}" }
  end

  def test_dropped_alerts_leave_the_queue_without_moving_last_alert_at
    channel = Flappy.new
    cw, clock, = make(alerts: [channel], on_error: ->(*) {})
    assert_raises(RuntimeError) { cw.run("s") { raise "x" } }
    clock.advance(MIN)
    cw.store.set_state(cw.store.get_state("s").tap { |s| s.open = {} })
    cw.check
    state = cw.store.get_state("s")
    assert_empty state.undelivered
    assert_nil state.last_alert_at
    assert_empty channel.sent
  end

  def test_a_job_that_cannot_be_evaluated_is_reported_and_shown_as_failing_and_the_others_are_checked
    errors = []
    cw, clock, alerts = make(on_error: ->(_e, where) { errors << where })
    good = cw.job("good", schedule: "every 1h")
    good.run { nil }
    cw.store.upsert_job(Cronwatch::JobDefinition.from_h("name" => "bad", "schedule" => "not a schedule"), T0)
    cw.store.upsert_job(Cronwatch::JobDefinition.from_h("name" => "odd", "timeout" => "soon"), T0)
    cw.store.insert_run(Cronwatch::Run.new(id: "hung", job: "odd", status: :running, started_at: T0, finished_at: nil, duration_ms: nil,
                                           error: nil, output: nil, metrics: {}, trigger: "run"))
    clock.advance(2 * HOUR)
    result = cw.check
    assert_equal ["good:missed"], result.alerts.map { |a| "#{a.job}:#{a.type}" }
    assert_equal({ "bad" => :failing, "good" => :late, "odd" => :failing }, result.jobs.to_h { |j| [j.name, j.health] })
    assert_equal ["checking odd", "checking bad", "checking odd"], errors
    assert_equal [:missed], alerts.types

    errors.clear
    jobs = cw.jobs
    assert_equal [["bad", :failing, true], ["good", :late, false], ["odd", :failing, true]],
                 jobs.map { |j| [j.name, j.health, j.next_expected_at.nil?] }
    assert_equal ["reading bad", "reading odd"], errors
    assert_equal :failing, cw.job_summary("bad").health
    cw.silence("bad", "1h")
    assert_equal :silenced, cw.job_summary("bad").health
  end

  def test_trimming_the_undelivered_queue_past_twenty_is_reported
    errors = []
    cw, = make(deliver: :check, on_error: ->(e, where) { errors << [where, e.message] })
    10.times do
      assert_raises(RuntimeError) { cw.run("q") { raise "x" } }
      cw.run("q") { nil }
    end
    assert_equal 20, cw.store.get_state("q").undelivered.length
    assert_empty errors
    assert_raises(RuntimeError) { cw.run("q") { raise "x" } }
    assert_equal 20, cw.store.get_state("q").undelivered.length
    assert_equal [["alert queue for q", "1 undelivered alert for q dropped: only the newest 20 are kept for retry"]], errors
  end

  def test_start_with_deliver_check_says_once_that_another_process_must_send
    before = $stderr
    $stderr = StringIO.new
    cw, = make(deliver: :check)
    cw.start
    cw.stop
    cw.start
    cw.stop
    lines = $stderr.string.lines.map(&:chomp)
    assert_equal ['[cronwatch] start() was called with deliver: "check", so these checks send no alerts. ' \
                  'Another process must run checks with deliver: "now" (the default) to send them.'], lines
    delivering, = make
    delivering.start
    delivering.stop
    assert_equal 1, $stderr.string.lines.length, "a delivering client says nothing"
  ensure
    $stderr = before
  end

  def test_a_redact_that_raises_or_returns_something_else_is_reported_and_the_default_used
    [->(_) { raise "broken" }, ->(_) {}, ->(_) { 42 }].each do |redact|
      errors = []
      cw, = make(redact: redact, on_error: ->(e, where) { errors << [where, e.class] })
      cw.run("r") { |job| job.log("password=hunter2") }
      assert_equal "password=[redacted]", cw.runs("r").first.output
      assert_equal ["redact"], errors.map(&:first)
    end
    errors = []
    raising = ->(_e, where) { errors << where and raise "on_error broke" }
    cw, = make(redact: ->(_) { raise "broken" }, on_error: raising)
    before = $stderr
    $stderr = StringIO.new
    begin
      cw.run("r") { |job| job.log("token=abc") }
    ensure
      $stderr = before
    end
    assert_equal "token=[redacted]", cw.runs("r").first.output, "an on_error that raises changes nothing"
  end

  def test_nuls_are_stripped_from_output_and_error_even_after_a_custom_redact
    cw, = make(redact: ->(text) { "#{text}\0" })
    cw.run("n") { |job| job.log("a\0b") }
    assert_equal "ab", cw.runs("n").first.output
    assert_raises(RuntimeError) { cw.run("n") { raise "bad\0byte" } }
    refute_includes cw.runs("n").first.error, "\0"
    assert cw.runs("n").first.error.start_with?("RuntimeError: badbyte")
  end

  # ---------------------------------------------------------------- two processes

  # Two clients, as two processes sharing one store, each failing the job once at the same time.
  def race(store_a, store_b)
    clock = Clock.new
    a = Capture.new
    b = Capture.new
    one = Cronwatch.new(store: store_a, now: clock.to_proc, alerts: [a], cron_secret: nil)
    two = Cronwatch.new(store: store_b, now: clock.to_proc, alerts: [b], cron_secret: nil)
    one.run("shared", failures_before_alert: 2) { nil }
    [[one, "one"], [two, "two"]].map do |client, message|
      Thread.new do
        client.run("shared", failures_before_alert: 2) { raise message }
      rescue RuntimeError
        nil
      end
    end.each(&:join)
    [store_a.get_state("shared"), a.types + b.types]
  end

  def test_two_processes_failing_a_job_at_once_both_failures_count_and_the_alert_goes_out_once
    store = Cronwatch::Stores::Memory.new
    state, types = race(SlowReads.new(store), SlowReads.new(store))
    assert_equal 2, state.consecutive_failures, "neither failure was lost"
    assert_equal [:failed], state.open.keys, "the condition opened"
    assert_equal [:failed], types, "one alert, from whichever process counted the second failure"
    assert_operator state.version, :>=, 3, "every write bumped the version"
  end

  def test_a_custom_store_without_compare_and_set_state_still_works_but_cannot_keep_two_processes_apart
    store = Cronwatch::Stores::Memory.new
    state, types = race(SlowReads.new(store, without_cas: true), SlowReads.new(store, without_cas: true))
    # The documented caveat: the later write wins, so one failure is lost.
    assert_equal 1, state.consecutive_failures
    assert_empty types
  end

  def test_a_silence_made_by_one_process_survives_another_processes_run
    store = Cronwatch::Stores::Memory.new
    clock = Clock.new
    runner = Cronwatch.new(store: SlowReads.new(store), now: clock.to_proc, alerts: [Capture.new], cron_secret: nil)
    admin = Cronwatch.new(store: SlowReads.new(store), now: clock.to_proc, alerts: [Capture.new], cron_secret: nil)
    runner.run("s") { nil }
    threads = [
      Thread.new { assert_raises(RuntimeError) { runner.run("s") { raise "x" } } },
      Thread.new { admin.silence("s", "1h") },
    ]
    threads.each(&:join)
    state = store.get_state("s")
    refute_nil state.silenced_until, "the silence was not overwritten"
    assert_equal 1, state.consecutive_failures, "nor was the failure"
  end

  def test_an_update_that_keeps_losing_gives_up_and_reports_and_the_run_still_finishes
    errors = []
    store = Cronwatch::Stores::Memory.new
    cw = Cronwatch.new(store: Contested.new(store), alerts: [Capture.new], cron_secret: nil,
                       on_error: ->(e, where) { errors << [where, e.message] })
    assert_raises(RuntimeError) { cw.run("busy") { raise "x" } }
    assert_equal [["evaluating busy", "the state of busy changed under 10 attempts in a row to update it; gave up"]], errors
    assert_equal :failed, cw.runs("busy").first.status
  end

  # ---------------------------------------------------------------- a job declared again

  # A store whose first write of a job's definition waits until it is let
  # go, so a test can declare the job again, or ask for another write, while
  # that one is under way.
  class HeldUpsert
    # `after_write`: the first write lands, then waits.
    def initialize(store, after_write: false)
      @store = store
      @after_write = after_write
      @entered = Queue.new
      @gate = Queue.new
      @lock = Mutex.new
      @held = false
    end

    # Returns once the first write is under way.
    def wait = @entered.pop

    def release = @gate.push(true)

    def upsert_job(definition, now)
      first = @lock.synchronize { @held ? false : (@held = true) }
      @store.upsert_job(definition, now) if @after_write
      if first
        @entered.push(true)
        @gate.pop
      end
      @store.upsert_job(definition, now) unless @after_write
    end

    def respond_to_missing?(name, include_private = false)
      @store.respond_to?(name, include_private)
    end

    def method_missing(name, *args, &block)
      return super unless @store.respond_to?(name)

      @store.public_send(name, *args, &block)
    end
  end

  def test_a_handle_kept_from_an_earlier_declaration_writes_the_one_that_stands_not_its_own
    store = Cronwatch::Stores::Memory.new
    cw = Cronwatch.new(store: store, alerts: [Capture.new], cron_secret: nil)
    earlier = cw.job("a")
    cw.job("a", schedule: "every 5m")
    earlier.run { nil }
    assert_equal "every 5m", store.get_job("a").definition.schedule
    cw.check
    assert_equal "every 5m", store.get_job("a").definition.schedule
  end

  def test_a_handle_whose_job_was_forgotten_writes_its_own_definition
    store = Cronwatch::Stores::Memory.new
    cw = Cronwatch.new(store: store, alerts: [Capture.new], cron_secret: nil)
    handle = cw.job("a", schedule: "every 5m")
    cw.forget("a")
    handle.run { nil }
    assert_equal "every 5m", store.get_job("a").definition.schedule
  end

  def test_a_forget_that_lands_while_a_jobs_first_write_is_under_way_leaves_it_to_be_written_on_its_next_run
    inner = Cronwatch::Stores::Memory.new
    # The write lands, then waits: the forget deletes the row it wrote.
    store = HeldUpsert.new(inner, after_write: true)
    cw = Cronwatch.new(store: store, alerts: [Capture.new], cron_secret: nil)
    handle = cw.job("nightly", schedule: "every 5m")
    first = Thread.new { handle.run { nil } }
    store.wait
    cw.forget("nightly")
    store.release
    first.join
    assert_nil inner.get_job("nightly"), "forgotten after it was written"
    handle.run { nil }
    assert_equal "every 5m", inner.get_job("nightly").definition.schedule, "its next run brings it back"
    assert_equal ["nightly"], cw.jobs.map(&:name)
  end

  def test_a_job_forgotten_by_another_process_comes_back_in_a_long_lived_one_that_still_declares_it
    store = Cronwatch::Stores::Memory.new
    worker = Cronwatch.new(store: store, alerts: [Capture.new], cron_secret: nil)
    web = Cronwatch.new(store: store, alerts: [Capture.new], cron_secret: nil)
    nightly = worker.job("nightly", schedule: "every 5m")
    nightly.run { nil }
    forgotten = lambda do
      web.forget("nightly")
      assert_nil store.get_job("nightly")
    end

    # Its next run writes it again, so the run is not left without its job.
    forgotten.call
    nightly.run { nil }
    assert_equal "every 5m", store.get_job("nightly").definition.schedule
    assert_equal 1, web.runs("nightly").length

    # So does a started run, a check, the board and the job's page in the process that declares it.
    forgotten.call
    handle = nightly.start
    assert store.get_job("nightly")
    handle.finish
    forgotten.call
    worker.check
    assert store.get_job("nightly")
    forgotten.call
    assert_equal ["nightly"], worker.jobs.map(&:name)
    forgotten.call
    assert_equal "every 5m", worker.job_summary("nightly").definition.schedule

    # A process that never declared it does not bring it back.
    forgotten.call
    web.check
    assert_equal [], web.jobs
  end

  def test_a_declaration_made_while_the_earlier_one_is_being_written_is_still_to_be_written
    inner = Cronwatch::Stores::Memory.new
    store = HeldUpsert.new(inner)
    cw = Cronwatch.new(store: store, alerts: [Capture.new], cron_secret: nil)
    earlier = cw.job("a")
    run = Thread.new { earlier.run { nil } }
    store.wait
    cw.job("a", schedule: "every 5m")
    store.release
    run.join
    cw.check
    assert_equal "every 5m", inner.get_job("a").definition.schedule
  end

  def test_a_declarations_write_waits_for_the_earlier_ones_so_the_later_one_stays
    inner = Cronwatch::Stores::Memory.new
    store = HeldUpsert.new(inner)
    cw = Cronwatch.new(store: store, alerts: [Capture.new], cron_secret: nil)
    earlier = cw.job("a")
    run = Thread.new { earlier.run { nil } }
    store.wait
    cw.job("a", schedule: "every 5m")
    later = Thread.new { cw.job_summary("a") }
    # Were the later write not to wait its turn, it would land here, under the earlier one.
    Thread.pass until later.status == "sleep" || !later.alive?
    store.release
    [run, later].each(&:join)
    assert_equal "every 5m", inner.get_job("a").definition.schedule
    assert_equal "every 5m", later.value.definition.schedule
  end

  def test_the_silence_endpoints_return_the_state_with_its_version
    cw, = make
    cw.run("v") { nil }
    silenced = cw.silence("v", "1h")
    assert_equal 1, silenced.version
    assert_equal 2, cw.unsilence("v").version
    assert_equal 2, cw.store.get_state("v").version
  end
end
