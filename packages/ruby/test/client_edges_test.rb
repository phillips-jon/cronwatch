# frozen_string_literal: true

require_relative "test_helper"
require "timeout"
require "cronwatch/scheduler"

# Where Ruby differs from JavaScript under the client: exceptions outside
# StandardError, bytes that are not UTF-8, threads left behind, forks, and a
# store another process wrote.
class ClientEdgesTest < Minitest::Test
  include TestHelpers

  def wait_for(timeout = 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  # Sidekiq::Shutdown is an Interrupt, raised into a busy job when a deploy outlasts its timeout.
  class Shutdown < Interrupt; end

  def test_an_exception_outside_standard_error_is_recorded_as_failed_and_raised_again
    cw, clock, capture = make
    job = cw.job("abstract", schedule: "0 * * * *", failures_before_alert: 10)
    [NotImplementedError.new("subclass must implement"), SystemExit.new(1, "shutting down"), Interrupt.new, Shutdown.new].each do |error|
      raised = assert_raises(error.class) { job.run { raise error } }
      assert_same error, raised, "the original exception"
    end
    assert_raises(Timeout::Error) { Timeout.timeout(0.05) { job.run { sleep 1 } } }

    runs = cw.runs("abstract")
    assert_equal [:failed] * 5, runs.map(&:status), "none is left running"
    firsts = runs.map { |run| run.error.split("\n").first }.reverse
    assert_equal "NotImplementedError: subclass must implement", firsts[0]
    assert_equal "Interrupted: SystemExit: shutting down", firsts[1]
    assert_equal "Interrupted: Interrupt", firsts[2]
    assert_equal "Interrupted: ClientEdgesTest::Shutdown", firsts[3]
    assert_match(/\AInterrupted: Timeout::/, firsts[4])

    clock.advance(2 * HOUR)
    cw.check
    refute_includes capture.types, :stuck, "no run looks stuck later"
    assert_equal [], cw.store.running_runs
  end

  def test_a_check_stopped_by_a_timeout_does_not_leave_its_waiters_hanging
    store = Cronwatch::Stores::Memory.new
    entered = Queue.new
    gate = Queue.new
    slow = true
    store.define_singleton_method(:list_jobs) do
      if slow
        entered.push(true)
        gate.pop
      end
      super()
    end
    cw, = make(store: store)
    owner = Thread.new do
      Timeout.timeout(0.2) { cw.check }
    rescue Timeout::Error => e
      e
    end
    entered.pop
    waiter = Thread.new do
      cw.check
    rescue Cronwatch::InterruptedError => e
      e
    end
    assert_kind_of Timeout::Error, owner.value, "the caller that ran the check sees its own timeout"
    assert waiter.join(2), "the waiter is not left hanging"
    assert_match(/the check was interrupted by Timeout::/, waiter.value.message)
    slow = false
    assert_kind_of Cronwatch::CheckResult, cw.check, "the next check runs"
  ensure
    gate&.push(nil)
  end

  def test_a_flight_hands_its_value_or_its_error_to_every_waiter
    flight = Cronwatch::Client::Flight.new
    waiters = Array.new(3) do
      Thread.new do
        flight.value
      rescue ArgumentError => e
        e
      end
    end
    wait_for { waiters.all? { |t| t.status == "sleep" } }
    error = ArgumentError.new("no")
    flight.reject(error)
    assert(waiters.all? { |t| t.value.equal?(error) })

    resolved = Cronwatch::Client::Flight.new
    resolved.resolve(42)
    assert_equal 42, resolved.value
  end

  def test_undelivered_alerts_are_capped_the_oldest_dropped_first
    cw, = make(alerts: [Cronwatch::Alerts::Custom.new("down") { raise "down" }], on_error: ->(*) {})
    job = cw.job("flappy", failures_before_alert: 1)
    11.times do
      assert_raises(RuntimeError) { job.run { raise "boom" } }
      job.run { "fine" }
    end
    undelivered = cw.store.get_state("flappy").undelivered
    assert_equal Cronwatch::Client::MAX_UNDELIVERED, undelivered.length
    assert_equal 22, cw.runs("flappy").length
    assert_equal cw.runs("flappy").reverse[2].id, undelivered.first.run.id, "the first two alerts were dropped"
  end

  # A channel that never returns (a socket with no timeout) holds one
  # thread, however many alerts and checks come after it.
  def test_a_hung_channel_or_triage_holds_one_thread_not_one_per_alert
    gate = Queue.new
    hung = Cronwatch::Alerts::Custom.new("hung") { gate.pop }
    triage = ->(_context) { gate.pop }
    errors = []
    cw, clock, = make(alerts: [hung], triage: triage, on_error: ->(e, where) { errors << [where, e.message] })
    cw.instance_variable_set(:@channel_timeout_ms, 30)
    cw.instance_variable_set(:@triage_timeout_ms, 30)
    before = Thread.list.length
    5.times do |i|
      job = cw.job("job-#{i}", failures_before_alert: 1)
      assert_raises(RuntimeError) { job.run { raise "boom" } }
      job.run { "ok" }
    end
    10.times do
      clock.advance(MIN)
      cw.check
    end
    assert_operator Thread.list.length - before, :<=, 2, "one channel thread and one triage thread"
    assert(errors.any? { |_, message| message.include?("skipped: an earlier alert timed out") })
    assert(errors.any? { |_, message| message.include?("skipped: an earlier triage timed out") })
    queued = cw.store.get_state("job-0").undelivered
    assert_equal [:recovered], queued.map(&:type), "the recovery kept for a later check; the failure, closed since, dropped as stale"
  ensure
    20.times { gate&.push(nil) }
  end

  # A schedule written by a Node process sharing the store that this port
  # does not read: that job is reported and shown as failing, the others are checked.
  def test_a_stored_schedule_this_port_cannot_read_does_not_stop_the_check
    errors = []
    cw, clock, capture = make(on_error: ->(e, where) { errors << [where, e.message] })
    cw.store.upsert_job(Cronwatch::JobDefinition.from_h("name" => "from-node", "schedule" => "0 0 15W * *"), T0)
    cw.job("hourly", schedule: "0 * * * *", grace: "5m")
    cw.check
    clock.advance(2 * HOUR)
    result = cw.check
    assert_equal [:missed], capture.types, "the other job is checked"
    assert_equal({ "from-node" => :failing, "hourly" => :late }, result.jobs.to_h { |job| [job.name, job.health] })
    assert_nil result.jobs.first.next_expected_at
    assert_equal "checking from-node", errors.first[0]
    assert_match(/W is not supported by the Ruby port/, errors.first[1])

    listed = cw.jobs.to_h { |job| [job.name, job] }
    assert_equal %w[from-node hourly], listed.keys.sort, "still listed"
    assert_nil listed["from-node"].next_expected_at
    assert_equal :failing, listed["from-node"].health
    assert_nil cw.job_summary("from-node").next_expected_at
    assert_equal "reading from-node", errors.last[0]
  end

  def test_bytes_that_are_not_utf8_are_kept_as_replacement_characters
    errors = []
    cw, = make(on_error: ->(e, where) { errors << [where, e] })
    cw.run("bytes") do |job|
      job.log("binary:", "\xFF\xFEok".b)
      job.log("latin1:".encode("ISO-8859-1"), "caf\xE9".dup.force_encoding("ISO-8859-1"))
      job.log("bad utf8: \xC3\x28")
      job.metric("rows\xFF".b, 1)
    end
    run = cw.runs("bytes").first
    assert_equal :ok, run.status
    assert_equal "binary: \u{FFFD}\u{FFFD}ok\nlatin1: café\nbad utf8: \u{FFFD}(", run.output
    assert_equal({ "rows\u{FFFD}" => 1 }, run.metrics)

    assert_raises(RuntimeError) { cw.run("bytes") { raise "failed on \xFF".b } }
    assert_equal "RuntimeError: failed on \u{FFFD}", cw.runs("bytes").first.error.split("\n").first
    assert_equal :ok, cw.run("returned") { "\xFF".b } && cw.runs("returned").first.status
    assert_equal "\u{FFFD}", cw.runs("returned").first.output
    assert_equal [], errors
  end

  def test_run_without_a_block_takes_no_options
    cw, = make
    error = assert_raises(ArgumentError) { cw.run("nightly", schedule: "0 2 * * *") }
    assert_match(/needs a block/, error.message)
    assert_nil cw.run("no-such-run-id")
  end

  def test_silence_takes_for_and_nothing_else
    cw, clock, = make
    cw.run("quiet") { nil }
    assert_equal clock.now + (2 * HOUR), cw.silence("quiet", for: "2h").silenced_until
    assert_equal clock.now + HOUR, cw.silence("quiet", "1h").silenced_until
    assert_raises(ArgumentError) { cw.silence("quiet", fro: "2h") }
    assert_raises(ArgumentError) { cw.silence("quiet", "1h", for: "2h") }
  end

  def test_a_second_start_with_another_interval_is_reported_and_ignored
    errors = []
    cw, = make(on_error: ->(e, where) { errors << [where, e.message] })
    cw.start("1m")
    cw.start("1m")
    assert_equal [], errors
    cw.start("5m")
    assert_equal [["start", 'start("5m") ignored: already checking every 1m; call stop first to change it']], errors
  ensure
    cw&.stop
  end

  def with_env(vars)
    before = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    before.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # One reading of the environment for the dashboard, the scheduler and the
  # in-memory store's warning (Rails.env first when Rails is loaded).
  def test_the_environment_is_read_one_way_everywhere
    skip "Rails is loaded" if defined?(::Rails)

    with_env("RAILS_ENV" => "", "RACK_ENV" => "production") do
      assert_equal "production", Cronwatch::Environment.name, "an empty RAILS_ENV counts as unset"
      assert_equal "production", Cronwatch::Scheduler.env
      refute Cronwatch::Client.development?
      _, err = capture_io { Cronwatch.new.jobs }
      assert_match(/using the in-memory store/, err)
    end
    with_env("RAILS_ENV" => "test", "RACK_ENV" => "production") do
      assert Cronwatch::Client.development?, "RAILS_ENV before RACK_ENV"
    end
    with_env("RAILS_ENV" => nil, "RACK_ENV" => nil) do
      assert_nil Cronwatch::Environment.name
      assert_equal "development", Cronwatch::Scheduler.env
    end
  end

  # Puma (preload_app), Unicorn and Sidekiq fork after the app has loaded.
  def test_start_and_check_work_in_a_forked_child
    skip "no fork on this platform" unless Process.respond_to?(:fork)

    store = Cronwatch::Stores::Memory.new
    entered = Queue.new
    gate = Queue.new
    slow = false
    store.define_singleton_method(:list_jobs) do
      if slow
        entered.push(true)
        gate.pop
      end
      super()
    end
    cw, = make(store: store)
    cw.job("a", schedule: "* * * * *")
    cw.instance_variable_set(:@first_tick_s, 0.05)
    checks = 0
    cw.define_singleton_method(:check) do
      checks += 1
      super()
    end
    cw.start("5s")
    wait_for { checks >= 1 }
    slow = true
    in_flight = Thread.new { cw.check }
    entered.pop # the parent is inside a check as it forks

    reader, writer = IO.pipe
    pid = fork do
      reader.close
      slow = false
      before = checks
      cw.start("5s")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.01 until checks > before || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      ticked = checks > before
      checked = Thread.new { cw.check }.join(2) ? "checked" : "hung"
      writer.write("#{ticked ? "ticked" : "no tick"} #{checked}")
      writer.close
      exit!(0)
    end
    writer.close
    Process.wait(pid)
    assert_equal "ticked checked", reader.read
  ensure
    gate&.push(nil)
    in_flight&.join(2)
    cw&.stop
  end
end
