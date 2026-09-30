# frozen_string_literal: true

require_relative "test_helper"

# The alert outbox: an alert is written with the state that opens its
# condition, so a process that dies before sending it does not lose it.
# packages/sdk/test/outbox.test.ts.
class OutboxTest < Minitest::Test
  include TestHelpers

  LEASE = Cronwatch::Evaluate::SEND_LEASE_MS

  # A store for a process that is about to die: once `kill` is called,
  # nothing it asks of the store ever completes, as when the process is gone.
  class Mortal
    def initialize(store)
      @store = store
      @dead = false
    end

    def kill
      @dead = true
    end

    def respond_to_missing?(name, include_private = false)
      @store.respond_to?(name, include_private)
    end

    def method_missing(name, *args, &block)
      return super unless @store.respond_to?(name)

      Queue.new.pop if @dead
      @store.public_send(name, *args, &block)
    end
  end

  # A channel whose sends wait for `release`, and which says when one has started.
  class Held
    attr_reader :name, :sent

    def initialize
      @name = "held"
      @sent = []
      @gate = Queue.new
      @sending = Queue.new
    end

    # Returns once a send has started.
    def wait_for_send = @sending.pop

    def release = @gate.push(true)

    def call(alert)
      @sending.push(true)
      @gate.pop
      @sent << alert
    end
  end

  # Counts the store's conditional state writes.
  class Counting < Cronwatch::Stores::Memory
    attr_reader :writes

    def initialize
      super
      @writes = 0
    end

    def compare_and_set_state(state, expected_version)
      @writes += 1
      super
    end
  end

  def test_the_write_that_opens_a_condition_holds_its_alert_so_a_process_that_dies_before_sending_it_does_not_lose_it
    clock = Clock.new
    shared = Cronwatch::Stores::Memory.new
    mortal = Mortal.new(shared)
    triaged = Queue.new
    # The process dies while its triage call is out: no channel was ever called.
    dying_triage = lambda do |_context|
      mortal.kill
      triaged.push(true)
      Queue.new.pop
    end
    dying = Cronwatch.new(store: mortal, now: clock.to_proc, alerts: [Capture.new], cron_secret: nil, triage: dying_triage)
    Thread.new do
      dying.run("nightly") { raise "disk full" }
    rescue RuntimeError
      nil
    end
    triaged.pop
    state = shared.get_state("nightly")
    assert_equal T0, state.open[:failed]
    assert_equal [[:failed, T0, T0 + LEASE]], state.sending.map { |entry| [entry["alert"].type, entry["alert"].at, entry["until"]] }
    refute state.sending[0]["alert"].triage_tried?, "triage is made at send time, never stored here"
    refute_includes shared.get_state("nightly").to_json, "triage"
    assert_equal [], state.undelivered

    # Another process's checks leave it alone while its sender's lease runs.
    sent = Capture.new
    server = Cronwatch.new(store: shared, now: clock.to_proc, alerts: [sent], cron_secret: nil, triage: ->(_) { "The disk is full." })
    clock.advance(MIN)
    server.check
    assert_equal [], sent.types

    # Once it has run out, the next check sends it, triaged, once.
    clock.now = T0 + LEASE + 1
    result = server.check
    assert_equal [:failed], result.alerts.map(&:type)
    assert_equal [[:failed, T0, "The disk is full."]], sent.alerts.map { |a| [a.type, a.at, a.triage] }
    after = shared.get_state("nightly")
    assert_nil after.sending, "the key goes once nothing is being sent"
    refute_includes after.to_json, "sending"
    assert_equal [], after.undelivered
    server.check
    assert_raises(RuntimeError) { server.run("nightly") { raise "again" } }
    assert_equal [:failed], sent.types, "the condition still alerts once"
  end

  def test_an_alert_a_channel_took_just_before_its_process_died_is_sent_again_after_the_lease_at_least_once
    clock = Clock.new
    shared = Cronwatch::Stores::Memory.new
    mortal = Mortal.new(shared)
    first = Capture.new
    took = Queue.new
    # Accepted, then the process is gone before it records that.
    accepting = Cronwatch::Alerts::Custom.new("first") do |alert|
      first.call(alert)
      mortal.kill
      took.push(true)
    end
    dying = Cronwatch.new(store: mortal, now: clock.to_proc, alerts: [accepting], cron_secret: nil)
    Thread.new do
      dying.run("nightly") { raise "x" }
    rescue RuntimeError
      nil
    end
    took.pop
    assert_equal [:failed], first.types
    sent = Capture.new
    server = Cronwatch.new(store: shared, now: clock.to_proc, alerts: [sent], cron_secret: nil)
    clock.now = T0 + LEASE + 1
    server.check
    assert_equal [:failed], sent.types, "sent a second time: the one duplicate a crash can cause"
  end

  def test_while_an_alert_is_being_sent_no_check_anywhere_sends_it_too
    clock = Clock.new
    shared = Cronwatch::Stores::Memory.new
    held = Held.new
    worker = Cronwatch.new(store: shared, now: clock.to_proc, alerts: [held], cron_secret: nil)
    other = Capture.new
    server = Cronwatch.new(store: shared, now: clock.to_proc, alerts: [other], cron_secret: nil)
    run = Thread.new do
      worker.run("nightly") { raise "x" }
    rescue RuntimeError
      nil
    end
    held.wait_for_send
    clock.advance(MIN)
    server.check
    # The sending process's own check, too.
    worker.check
    held.release
    run.join
    assert_equal [:failed], held.sent.map(&:type)
    assert_equal [], other.types
    state = shared.get_state("nightly")
    assert_nil state.sending
    assert_equal [], state.undelivered
    assert_equal T0, state.last_alert_at, "the time the run was judged, as before"
    clock.now = T0 + LEASE + MIN
    server.check
    worker.check
    assert_equal [], other.types
    assert_equal [:failed], held.sent.map(&:type)
  end

  def test_an_alert_no_channel_took_moves_from_the_outbox_to_the_retry_queue_with_its_triage
    clock = Clock.new
    shared = Cronwatch::Stores::Memory.new
    down = Cronwatch::Alerts::Custom.new("down") { |_alert| raise "down" }
    cw = Cronwatch.new(store: shared, now: clock.to_proc, alerts: [down], cron_secret: nil, on_error: ->(*) {},
                       triage: ->(_) { "Look at the disk." })
    assert_raises(RuntimeError) { cw.run("nightly") { raise "x" } }
    state = shared.get_state("nightly")
    assert_nil state.sending
    assert_equal [[:failed, "Look at the disk."]], state.undelivered.map { |a| [a.type, a.triage] }
  end

  def test_a_process_that_queues_its_alerts_for_a_check_elsewhere_writes_them_with_the_state_that_opens_the_condition
    clock = Clock.new
    counting = Counting.new
    recorder = Cronwatch.new(store: counting, now: clock.to_proc, deliver: :check, cron_secret: nil)
    assert_raises(RuntimeError) { recorder.run("backup") { raise "disk full" } }
    state = counting.get_state("backup")
    assert_equal [:failed], state.undelivered.map(&:type)
    assert_nil state.sending
    assert_equal 1, counting.writes, "one write: the failure and its alert together"
  end

  def test_a_state_written_by_an_older_version_without_sending_still_reads_and_a_malformed_entry_does_not_stop_it
    store = Cronwatch::Stores::Memory.new
    raw = { "job" => "j", "open" => {}, "consecutiveFailures" => 0, "silencedUntil" => nil, "lastAlertAt" => nil,
            "sending" => [nil, { "until" => "x" }, { "until" => 1, "alert" => "not an alert" }] }
    store.set_state(Cronwatch::JobState.from_h(raw))
    cw = Cronwatch.new(store: store, alerts: [Capture.new], cron_secret: nil, now: -> { T0 })
    cw.job("j")
    cw.check
    assert_nil store.get_state("j").sending, "every malformed entry counts as run out, and none carries an alert to send"
  end
end
