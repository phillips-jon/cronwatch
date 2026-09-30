# frozen_string_literal: true

require_relative "test_helper"

# The SDK's client tests (client.test.ts, client-hardening.test.ts), in Ruby.
class ClientTest < Minitest::Test
  include TestHelpers

  def shorten_timeouts(client, channel: 200, triage: 200)
    client.instance_variable_set(:@channel_timeout_ms, channel)
    client.instance_variable_set(:@triage_timeout_ms, triage)
  end

  # Waits for a condition another thread makes true.
  def wait_for(timeout = 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def test_run_records_output_metrics_and_duration_and_returns_the_result
    cw, clock, = make
    job = cw.job("report", schedule: "0 2 * * *")
    result = job.run do |j|
      j.log("hello", { n: 1 })
      j.metric(:rows, 42)
      clock.advance(1500)
      "done"
    end
    assert_equal "done", result
    run = cw.runs("report").first
    assert_equal :ok, run.status
    assert_equal 1500, run.duration_ms
    assert_equal 'hello {"n":1}', run.output
    assert_equal({ "rows" => 42 }, run.metrics)
    summary = cw.job_summary("report")
    assert_equal :healthy, summary.health
    assert_equal Time.utc(2026, 1, 6, 2).to_i * 1000, summary.next_expected_at
  end

  def test_a_raising_job_is_recorded_as_failed_alerts_and_reraises
    cw, _, alerts = make
    job = cw.job("nightly")
    error = assert_raises(RuntimeError) { job.run { raise "db down" } }
    assert_equal "db down", error.message
    run = cw.runs("nightly").first
    assert_equal :failed, run.status
    assert_match(/\ARuntimeError: db down\n    at /, run.error)
    assert_equal [:failed], alerts.types
    assert_match(/db down/, alerts.alerts[0].message)
    assert_equal :failing, cw.job_summary("nightly").health
  end

  def test_expect_turns_a_quiet_success_into_a_failure
    cw, clock, alerts = make
    job = cw.job("export", expect: "wrote")
    job.run { |j| j.log("wrote 12 files") }
    assert_equal [], alerts.types
    clock.advance(HOUR)
    job.run { |j| j.log("nothing to do") }
    run = cw.runs("export").first
    assert_equal :failed, run.status
    assert_match(/did not contain "wrote"/, run.error)
    assert_equal [:failed], alerts.types
    # A returned string counts as output too.
    job.run { "wrote 3 files" }
    assert_equal %i[failed recovered], alerts.types
  end

  def test_expect_takes_a_regexp_or_a_callable
    cw, = make
    assert_equal :ok, (cw.job("a", expect: /wrote \d+/).run { "wrote 3" } && cw.runs("a").first.status)
    cw.job("b", expect: ->(out) { out.lines.length > 1 }).run { "one line" }
    assert_equal "Output did not pass the expect() check", cw.runs("b").first.error
    cw.job("c", expect: ->(_) { raise "bad check" }).run { "x" }
    assert_equal "Output check threw: bad check", cw.runs("c").first.error
    assert_equal "matches /wrote \\d+/", cw.store.get_job("a").definition.expect
    assert_equal "custom function", cw.store.get_job("b").definition.expect
  end

  def test_an_expect_pattern_that_backtracks_without_end_times_out_and_fails
    # A backreference turns off Onigmo's memoization, so this backtracks
    # polynomially over newlines it does not match; the timeout stops it.
    cw, = make
    output = "#{"\n" * 32_000}zx"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    cw.job("slow", expect: /(\n*)\n*\n*\1x/).run { output }
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    run = cw.runs("slow").first
    assert_equal :failed, run.status
    assert_equal "Output did not match /(\\n*)\\n*\\n*\\1x/", run.error
    assert_operator took, :<, 3, "took #{took}s"
    # A shorter timeout of the pattern's own is kept; the pattern is not changed.
    short = Regexp.new('(\n*)\n*\n*\1x', timeout: 0.1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal "Output did not match /(\\n*)\\n*\\n*\\1x/", Cronwatch::Serialize.check_expectation(short, output)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.9
    assert_in_delta 0.1, short.timeout
    # Patterns that finish answer as before, flags and all.
    assert_nil Cronwatch::Serialize.check_expectation(/DONE$/i, "all done")
    assert_nil Cronwatch::Serialize.check_expectation(/(\n*)\n*\n*\1x/, "\n\nx")
  end

  def test_run_defines_on_first_use_and_validates_names_and_schedules
    cw, = make
    assert_equal 1, cw.run("adhoc", schedule: "every 5m") { 1 }
    assert_equal 1, cw.jobs.length
    assert_match(/job name/, assert_raises(ArgumentError) { cw.job("bad name!") }.message)
    assert_match(/not a cron expression/, assert_raises(ArgumentError) { cw.job("x", schedule: "nope") }.message)
    assert_match(/grace/, assert_raises(ArgumentError) { cw.job("x", grace: "soon") }.message)
    assert_match(/unknown option :sechdule/, assert_raises(ArgumentError) { cw.job("x", sechdule: "@daily") }.message)
    # Without a block, run looks a run up by id.
    run = cw.runs("adhoc").first
    assert_equal run.id, cw.run(run.id).id
    assert_equal run.id, cw.get_run(run.id).id
  end

  def test_check_finds_a_missed_run_once_and_a_later_run_recovers
    cw, clock, alerts = make
    job = cw.job("sync", schedule: "every 1h", grace: "10m")
    cw.check # registers at T0
    clock.advance(30 * MIN)
    assert_equal [], cw.check.alerts
    clock.now = T0 + (70 * MIN) + 1
    result = cw.check
    assert_equal [:missed], result.alerts.map(&:type)
    assert_equal :late, result.jobs[0].health
    assert_equal [], cw.check.alerts, "no repeat"
    job.run { nil }
    assert_equal %i[missed recovered], alerts.types
    assert_equal :healthy, cw.job_summary("sync").health
  end

  def test_a_job_declared_again_without_its_schedule_closes_missed_with_a_recovery_once
    cw, clock, alerts = make
    cw.job("sync", schedule: "every 1h", grace: "10m")
    cw.check
    clock.now = T0 + (70 * MIN) + 1
    assert_equal [:missed], cw.check.alerts.map(&:type)
    job = cw.job("sync")
    clock.advance(MIN)
    result = cw.check
    assert_equal [:recovered], result.alerts.map(&:type)
    alert = result.alerts[0]
    assert_equal "sync is no longer scheduled", alert.title
    assert_equal "Missed since 2026-01-05 10:40:00 UTC (1m ago). It has no schedule now, so nothing is due; the missed alert is closed.",
                 alert.message
    assert_equal({ after: [:missed], reason: :unscheduled, since: T0 + (70 * MIN) + 1 }, alert.details)
    assert_equal alert.to_h, Cronwatch::Alert.from_h(JSON.parse(alert.to_json)).to_h, "the reason survives the undelivered queue"
    assert_equal :never_ran, result.jobs[0].health
    assert_equal [], cw.check.alerts, "no repeat"
    job.run { nil }
    assert_equal %i[missed recovered], alerts.types, "the next run owes nothing"
  end

  def test_an_unscheduled_recovery_names_missed_alone_and_failed_keeps_its_own
    definition = Cronwatch::JobDefinition.from_h("name" => "j", "schedule" => "every 30m", "grace" => "1m")
    stored = Cronwatch::StoredJob.new(name: "j", definition: definition, created_at: T0, updated_at: T0)
    failed = Cronwatch::Run.new(id: "r1", job: "j", status: :failed, started_at: T0 + MIN, finished_at: T0 + MIN + 1000,
                                duration_ms: 1000, error: "boom", output: nil, metrics: {}, trigger: "run")
    state = Cronwatch::Evaluate.on_run_finish(definition, failed, Cronwatch::Evaluate.empty_state("j"), [], T0 + MIN + 1000).state
    state = Cronwatch::Evaluate.on_check(definition, stored, failed, state, T0 + (40 * MIN)).state
    state.pending_recovery = [:missed]
    bare = Cronwatch::JobDefinition.from_h("name" => "j")
    gone = Cronwatch::Evaluate.on_check(bare, stored.dup.tap { |s| s.definition = bare }, failed, state, T0 + (41 * MIN))
    assert_equal [:recovered], gone.alerts.map(&:type)
    assert_equal({ after: [:missed], reason: :unscheduled, since: T0 + (40 * MIN) }, gone.alerts[0].details)
    assert_equal [:failed], gone.state.open.keys, "failed stays open"
    assert_equal [], gone.state.pending_recovery, "missed is not owed a second recovery"
    ok = Cronwatch::Run.new(id: "r2", job: "j", status: :ok, started_at: T0 + HOUR, finished_at: T0 + HOUR + 1000,
                            duration_ms: 1000, error: nil, output: nil, metrics: {}, trigger: "run")
    done = Cronwatch::Evaluate.on_run_finish(bare, ok, Cronwatch::Evaluate.on_run_start(gone.state), [failed], T0 + HOUR + 1000)
    assert_equal [{ after: [:failed] }], done.alerts.map(&:details)
  end

  def test_a_schedule_removed_while_silenced_closes_missed_quietly
    cw, clock, alerts = make
    cw.job("sync", schedule: "every 1h", grace: "10m")
    cw.check
    clock.now = T0 + (70 * MIN) + 1
    cw.check
    cw.silence("sync", "1h")
    cw.job("sync")
    clock.advance(MIN)
    assert_equal [], cw.check.alerts
    assert_equal [], cw.job_summary("sync").open
    clock.advance(2 * HOUR)
    assert_equal [], cw.check.alerts
    assert_equal [:missed], alerts.types
  end

  def test_check_marks_a_run_that_never_finished_as_stuck
    cw, clock, alerts = make
    job = cw.job("long", timeout: "5m")
    gate = Queue.new
    thread = Thread.new { job.run { gate.pop } }
    wait_for { cw.runs("long").first&.status == :running }
    clock.advance(4 * MIN)
    assert_equal [], cw.check.alerts
    clock.advance(2 * MIN)
    result = cw.check
    assert_equal [:stuck], result.alerts.map(&:type)
    assert_equal :timeout, cw.runs("long").first.status
    assert_equal "Still running after 5m; marked as timed out", cw.runs("long").first.error
    assert_equal :stuck, result.jobs[0].health
    assert_match(/never reported finishing/, alerts.alerts[0].message)
  ensure
    thread&.kill
  end

  def test_slow_and_over_budget_alerts_come_from_the_jobs_own_baseline
    cw, clock, alerts = make
    job = cw.job("agent", budget: { cost: 1 })
    5.times do
      job.run do |j|
        clock.advance(1000)
        j.metrics(tokens: 1000, cost: 0.5)
      end
      clock.advance(HOUR)
    end
    assert_equal [], alerts.types
    job.run do |j|
      clock.advance(15_000)
      j.metrics(tokens: 1000, cost: 0.5)
    end
    assert_equal [:slow], alerts.types
    clock.advance(HOUR)
    job.run do |j|
      clock.advance(1000)
      j.metrics("tokens" => 5000, "cost" => 1.2)
    end
    assert_equal %i[slow over_budget], alerts.types
    last = alerts.alerts[1]
    assert_match(/cost: 1\.2, limit 1 \(budget\)/, last.message)
    assert_match(/tokens: 5,000, limit 3,000 \(three times the usual 1,000\)/, last.message)
    clock.advance(HOUR)
    job.run do |j|
      clock.advance(1000)
      j.metrics(tokens: 1000, cost: 0.5)
    end
    assert_equal %i[slow over_budget recovered], alerts.types
  end

  def test_silence_swallows_alerts_and_nothing_opens_underneath_unsilence_alerts_again
    cw, _, alerts = make
    job = cw.job("flaky")
    state = cw.silence("flaky", for: "1h")
    assert_equal T0 + HOUR, state.silenced_until
    assert_raises(RuntimeError) { job.run { raise "x" } }
    assert_equal [], alerts.types
    assert_equal :silenced, cw.job_summary("flaky").health
    assert_equal({}, cw.store.get_state("flaky").open)
    cw.unsilence("flaky")
    assert_raises(RuntimeError) { job.run { raise "y" } }
    assert_equal [:failed], alerts.types
    cw.silence("flaky", 60_000)
    assert_equal T0 + MIN, cw.store.get_state("flaky").silenced_until
  end

  def test_triage_output_is_attached_to_failure_alerts_and_never_blocks_them
    cw, _, alerts = make(triage: ->(ctx) { "Probably #{ctx.alert.job}'s database." })
    assert_raises(RuntimeError) { cw.run("t") { raise "x" } }
    assert_equal "Probably t's database.", alerts.alerts[0].triage

    errors = []
    cw2, _, alerts2 = make(triage: ->(_) { raise "api down" }, on_error: ->(_e, where) { errors << where })
    assert_raises(RuntimeError) { cw2.run("t") { raise "x" } }
    assert_equal [:failed], alerts2.types
    assert_nil alerts2.alerts[0].triage
    assert alerts2.alerts[0].triage_tried?, "tried, and gave nothing: JSON null"
    assert_equal ["triage for t"], errors
  end

  def test_triage_is_aborted_when_the_client_stops_waiting_for_it
    signal = nil
    errors = []
    gate = Queue.new
    cw, _, alerts = make(
      triage: lambda do |ctx|
        signal = ctx.signal
        gate.pop
      end,
      on_error: ->(_e, where) { errors << where },
    )
    shorten_timeouts(cw)
    assert_raises(RuntimeError) { cw.run("t") { raise "x" } }
    assert signal.aborted?
    assert_equal ["triage for t"], errors
    assert_equal [:failed], alerts.types
  ensure
    gate&.push(nil)
  end

  def test_forget_removes_the_job_and_its_runs
    cw, = make
    cw.run("gone") { nil }
    assert_equal 1, cw.jobs.length
    cw.forget("gone")
    assert_equal 0, cw.jobs.length
    assert_nil cw.job_summary("gone")
  end

  def test_a_failing_alert_channel_does_not_break_the_run
    errors = []
    broken = Cronwatch::Alerts::Custom.new("broken") { raise "no network" }
    cw, = make(alerts: [broken], on_error: ->(_e, where) { errors << where })
    assert_raises(RuntimeError) { cw.run("x") { raise "job" } }
    assert_equal ["alert channel broken"], errors
  end

  def test_a_cron_firing_more_often_than_its_grace_is_still_missed
    cw, clock, alerts = make
    job = cw.job("often", schedule: "*/5 * * * *") # default grace 10m
    job.run { nil } # 09:30
    clock.advance(14 * MIN)
    assert_equal [], cw.check.alerts, "09:35 is due, grace runs to 09:45"
    clock.advance(2 * MIN)
    assert_equal [:missed], cw.check.alerts.map(&:type)
    job.run { nil }
    assert_equal %i[missed recovered], alerts.types
  end

  def test_a_missed_run_whose_next_run_fails_below_the_threshold_still_recovers_later
    cw, clock, alerts = make
    job = cw.job("quiet", schedule: "every 1h", failures_before_alert: 3)
    cw.check
    clock.advance(2 * HOUR)
    cw.check
    assert_raises(RuntimeError) { job.run { raise "x" } }
    assert_equal [:missed], alerts.types
    job.run { nil }
    assert_equal %i[missed recovered], alerts.types
    assert_match(/after: missed/, alerts.alerts[1].message)
  end

  def test_a_store_outage_never_stops_the_job_and_store_errors_go_to_on_error
    broken = Set[:upsert_job, :insert_run, :get_state, :set_state, :update_run, :list_runs]
    errors = []
    cw, = make(store: Flaky.new(Cronwatch::Stores::Memory.new, broken), on_error: ->(_e, where) { errors << where })
    ran = 0
    assert_equal(7, cw.run("s") do
      ran += 1
      7
    end)
    assert_raises(RuntimeError) do
      cw.run("s") do
        ran += 1
        raise "the job's own"
      end
    end
    assert_equal 2, ran
    assert errors.any? && errors.all?("recording s"), errors.join(", ")
    broken.clear
    cw.run("s") { "back" }
    assert_equal 1, cw.runs("s").length
  end

  def test_a_store_that_fails_to_initialise_is_tried_again_on_the_next_call
    store = Cronwatch::Stores::Memory.new
    inits = 0
    store.define_singleton_method(:init) do
      inits += 1
      raise "not yet" if inits == 1
    end
    errors = []
    cw, = make(store: store, on_error: ->(_e, where) { errors << where })
    assert_equal 1, cw.run("i") { 1 }
    assert_equal ["recording i"], errors
    # The finished run was written on the retry, once init went through.
    assert_equal 2, inits
    cw.run("i") { 2 }
    assert_equal 2, inits
    assert_equal 2, cw.runs("i").length
  end

  def test_dispatch_does_not_overwrite_a_silence_made_while_an_alert_was_being_sent
    cw_ref = nil
    silencer = Cronwatch::Alerts::Custom.new("silencer") { cw_ref.silence("loud", for: "1h") }
    cw, = make(alerts: [silencer])
    cw_ref = cw
    assert_raises(RuntimeError) { cw.run("loud") { raise "x" } }
    state = cw.store.get_state("loud")
    refute_nil state.silenced_until, "the silence survived"
    assert_equal({ failed: T0 }, state.open)
    assert_equal T0, state.last_alert_at
  end

  def test_a_hung_channel_times_out_without_holding_up_the_others
    errors = []
    good = Capture.new
    gate = Queue.new
    hung = Cronwatch::Alerts::Custom.new("hung") { gate.pop }
    cw, = make(alerts: [hung, good], on_error: ->(_e, where) { errors << where })
    shorten_timeouts(cw)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(RuntimeError) { cw.run("h") { raise "x" } }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_equal [:failed], good.types, "the other channel has it"
    assert_equal ["alert channel hung"], errors
    assert_equal [], cw.store.get_state("h").undelivered, "one channel took it: delivered"
  ensure
    gate&.push(nil)
  end

  def test_deliver_check_queues_alerts_for_another_processes_check_which_sends_them_with_triage
    clock = Clock.new
    store = Cronwatch::Stores::Memory.new
    unused = Capture.new
    triaged = 0
    # The recording process: no network, so it sends nothing itself.
    recorder = Cronwatch.new(store: store, now: clock.to_proc, alerts: [unused], deliver: :check,
                             triage: ->(_) { "never asked" }, cron_secret: nil)
    job = recorder.job("backup", schedule: "40 3 * * *", timezone: "UTC")
    assert_raises(RuntimeError) { job.run { raise "disk full" } }
    assert_equal [], unused.types, "nothing sent from the recording process"
    state = store.get_state("backup")
    assert_equal [:failed], state.undelivered.map(&:type)
    assert_nil state.last_alert_at
    assert_equal [], recorder.check.alerts, "its own check does not send either"

    # The web server: can send, and has not declared the job.
    sent = Capture.new
    server = Cronwatch.new(store: store, now: clock.to_proc, alerts: [sent], cron_secret: nil,
                           triage: lambda { |_|
                             triaged += 1
                             "The disk is full."
                           })
    clock.advance(MIN)
    assert_equal [:failed], server.check.alerts.map(&:type)
    assert_equal [:failed], sent.types
    assert_equal "The disk is full.", sent.alerts[0].triage
    assert_equal T0, sent.alerts[0].at, "the alert from the run, not a new one"
    assert_equal 1, triaged
    state = store.get_state("backup")
    assert_equal [], state.undelivered
    assert_equal T0 + MIN, state.last_alert_at
    server.check
    assert_equal [:failed], sent.types, "sent once"

    # The recovery takes the same route.
    job.run { nil }
    server.check
    assert_equal %i[failed recovered], sent.types
    assert_equal 1, triaged, "recoveries are not triaged"
  end

  def test_deliver_takes_only_now_or_check
    error = assert_raises(ArgumentError) { Cronwatch.new(deliver: :later) }
    assert_match(/deliver must be "now" or "check"/, error.message)
    assert Cronwatch.new(deliver: "check", cron_secret: nil)
  end

  def test_an_alert_no_channel_took_is_retried_once_per_check_until_one_does
    down = true
    attempts = 0
    got = []
    channel = Cronwatch::Alerts::Custom.new("flaky") do |alert|
      attempts += 1
      raise "down" if down

      got << alert
    end
    cw, clock, = make(alerts: [channel], on_error: ->(*) {})
    assert_raises(RuntimeError) { cw.run("r") { raise "x" } }
    state = cw.store.get_state("r")
    assert_equal 1, state.undelivered.length
    assert_nil state.last_alert_at, "nothing was delivered"
    clock.advance(MIN)
    cw.check
    assert_equal 2, attempts, "one retry per check"
    down = false
    clock.advance(MIN)
    result = cw.check
    assert_equal [:failed], result.alerts.map(&:type)
    assert_equal [:failed], got.map(&:type)
    assert_equal T0, got[0].at, "the same alert, not a new one"
    state = cw.store.get_state("r")
    assert_equal [], state.undelivered
    assert_equal T0 + (2 * MIN), state.last_alert_at
    cw.check
    assert_equal 3, attempts, "not sent again"
  end

  def test_overlapping_runs_of_one_job_share_its_state_without_losing_updates
    cw, _, alerts = make
    job = cw.job("par", failures_before_alert: 2)
    gate = Queue.new
    threads = Array.new(3) do
      Thread.new do
        job.run do
          gate.pop
          raise "x"
        end
      rescue RuntimeError
        nil
      end
    end
    wait_for { cw.runs("par").length == 3 }
    3.times { gate.push(nil) }
    threads.each(&:join)
    assert_equal 3, cw.store.get_state("par").consecutive_failures
    assert_equal [:failed], alerts.types, "one alert, not one per run"
  end

  def test_job_rejects_numbers_that_would_quietly_turn_a_check_off
    cw, = make
    {
      { failures_before_alert: Float::NAN } => /failuresBeforeAlert must be a whole number, 1 or more \(got NaN\)/,
      { failures_before_alert: 0 } => /failuresBeforeAlert/,
      { failures_before_alert: 1.5 } => /\(got 1\.5\)/,
      { failures_before_alert: "2" } => /failuresBeforeAlert/,
      { budget: { cost: Float::NAN } } => /budget\.cost must be a finite number, 0 or more \(got NaN\)/,
      { budget: { cost: Float::INFINITY } } => /budget\.cost/,
      { budget: { cost: -1 } } => /budget\.cost/,
      { budget: 5 } => /budget must be an object/,
      { grace: Float::NAN } => /grace must be a non-negative number of milliseconds/,
      { timeout: 0 } => /job "a": timeout must be longer than zero/,
      { max_duration: "0s" } => /maxDuration must be longer than zero/,
      { schedule: "0 2 * * *", timezone: "Mars/Olympus" } => /timezone "Mars\/Olympus" is not an IANA timezone/,
      { schedule: " " } => /schedule must be a non-empty string/,
      { expect: 42 } => /expect must be a string, a RegExp or a function/,
    }.each do |options, pattern|
      assert_match pattern, assert_raises(ArgumentError, options.inspect) { cw.job("a", **options) }.message
    end
    assert_match(/failuresBeforeAlert/, assert_raises(ArgumentError) { Cronwatch.new(defaults: { failures_before_alert: Float::NAN }).job("a") }.message)
    cw.job("a", budget: { errors: 0 }, failures_before_alert: 2, timeout: "5m", timezone: "america/new_york")
  end

  def test_a_returned_string_is_capped_like_logged_output
    cw, = make
    cw.run("big") { "x" * 40_000 }
    run = cw.runs("big").first
    assert_operator run.output.length, :<, 17 * 1024
    assert_match(/\A\[earlier output trimmed\]/, run.output)
  end

  def test_runs_takes_a_whole_number_of_runs_in_range
    cw, = make
    3.times { cw.run("n") { nil } }
    assert_equal 2, cw.runs("n", 2.7).length
    assert_equal 1, cw.runs("n", -4).length
    assert_equal 3, cw.runs("n", Float::NAN).length
    assert_equal 3, cw.runs("n", "2").length
    entry = cw.jobs_with_runs(2).first
    assert_equal 2, entry.runs.length
    assert_equal entry.runs[0].id, entry.job.last_run.id
  end

  def test_an_error_is_named_once_and_keeps_five_backtrace_lines
    cw, _, alerts = make
    error = RuntimeError.new("connect ECONNREFUSED 10.0.0.12:5432")
    error.set_backtrace(%w[a.rb:1 b.rb:2 c.rb:3 d.rb:4 e.rb:5 f.rb:6])
    assert_raises(RuntimeError) { cw.run("db") { raise error } }
    assert_equal "RuntimeError: connect ECONNREFUSED 10.0.0.12:5432\n    at a.rb:1\n    at b.rb:2\n    at c.rb:3\n    at d.rb:4\n    at e.rb:5",
                 cw.runs("db").first.error
    refute_match(/Error: RuntimeError:/, alerts.alerts[0].message)
    assert_match(/^RuntimeError: connect ECONNREFUSED/, alerts.alerts[0].message)
    assert_raises(RuntimeError) { cw.run("db") { raise "two\nlines" } }
    assert_match(/\ARuntimeError: two\nlines\n    at /, cw.runs("db").first.error)
  end

  def test_the_baseline_reads_past_recent_failures_to_twenty_successful_runs
    cw, clock, alerts = make
    job = cw.job("base")
    at = lambda do |ms, fail = false|
      begin
        job.run do
          clock.advance(ms)
          raise "x" if fail
        end
      rescue RuntimeError
        nil
      end
      clock.advance(MIN)
    end
    5.times { at.call(100_000) }
    15.times { at.call(1_000) }
    10.times { at.call(1_000, true) }
    # Fifteen 1s runs alone would make 10s the limit; with the five 100s runs, p95 is 100s.
    at.call(30_000)
    assert_equal %i[failed recovered], alerts.types
  end

  def test_the_signal_aborts_once_the_timeout_passes_and_nothing_is_killed
    cw, = make
    seen = nil
    result = cw.job("slowpoke", timeout: 30).run do |j|
      refute j.aborted?
      sleep 0.08
      seen = j.signal.aborted?
      assert_raises(Cronwatch::AbortError) { j.signal.check! }
      "finished anyway"
    end
    assert seen
    assert_equal "finished anyway", result
    assert_equal :ok, cw.runs("slowpoke").first.status
  end

  def test_metric_must_be_a_finite_number
    cw, = make
    error = assert_raises(ArgumentError) { cw.run("m") { |j| j.metric(:cost, Float::NAN) } }
    assert_equal 'metric "cost" must be a finite number', error.message
    assert_raises(ArgumentError) { cw.run("m") { |j| j.metric(:cost, "1") } }
    assert_equal :failed, cw.runs("m").first.status
  end

  def test_log_writes_values_as_the_sdk_does
    cw, = make
    cw.run("log") do |j|
      j.log("a", 1, 2.0, 1.5, nil, true, [1, "x"], { k: :v }, :sym, RuntimeError.new("boom"))
    end
    assert_equal 'a 1 2 1.5 null true [1,"x"] {"k":"v"} sym RuntimeError: boom', cw.runs("log").first.output
  end

  def test_the_stored_definition_keeps_the_sdks_key_order
    cw, = make(defaults: { timezone: "UTC", grace: "5m" })
    cw.job("ordered", expect: "ok", schedule: "0 2 * * *", grace: "1m", budget: { cost: 2 }).run { "ok" }
    stored = cw.store.get_job("ordered").definition
    # Defaults first, then options as given, then name; expect moves to the end.
    assert_equal %w[timezone grace schedule budget name expect], stored.to_h.keys
    assert_equal '{"timezone":"UTC","grace":"1m","schedule":"0 2 * * *","budget":{"cost":2},"name":"ordered","expect":"contains \"ok\""}',
                 stored.to_json
  end

  def test_check_is_shared_by_concurrent_callers
    store = Cronwatch::Stores::Memory.new
    calls = 0
    entered = Queue.new
    gate = Queue.new
    store.define_singleton_method(:list_jobs) do
      calls += 1
      entered.push(true)
      gate.pop
      super()
    end
    cw, = make(store: store)
    first = Thread.new { cw.check }
    entered.pop # the first check is inside the store now
    others = Array.new(2) { Thread.new { cw.check } }
    wait_for { others.all? { |t| t.status == "sleep" } } # both waiting on the shared check
    gate.push(nil)
    results = [first, *others].map(&:value)
    assert_equal 1, calls
    assert(results.all? { |r| r.equal?(results[0]) })
    gate.push(nil)
    cw.check
    assert_equal 2, calls
  end

  def test_stop_also_cancels_the_first_check_start_schedules
    cw, = make
    checks = 0
    cw.define_singleton_method(:check) { checks += 1 }
    cw.instance_variable_set(:@first_tick_s, 0.05)
    cw.start
    cw.stop
    sleep 0.15
    assert_equal 0, checks
    cw.start
    cw.start # a second start does nothing
    wait_for { checks >= 1 }
    cw.stop
    sleep 0.1
    assert_equal 1, checks
  end

  def test_a_check_error_in_the_background_goes_to_on_error
    errors = []
    cw, = make(on_error: ->(e, where) { errors << [where, e.message] })
    cw.define_singleton_method(:check) { raise "boom" }
    cw.instance_variable_set(:@first_tick_s, 0.01)
    cw.start
    wait_for { errors.any? }
    cw.close
    assert_equal [%w[check boom]], errors
  end

  # A source whose sync raises what it is told to, and says each time it is called.
  class RaisingSource
    attr_reader :name

    def initialize(error)
      @name = "raising"
      @error = error
      @calls = Queue.new
    end

    def wait_for_call = @calls.pop

    def sync(_host)
      @calls.push(true)
      raise @error
    end
  end

  def test_a_check_error_outside_standard_error_in_the_background_is_reported_and_the_thread_keeps_going
    errors = Queue.new
    source = RaisingSource.new(LoadError.new("cannot load such file -- pg"))
    cw, = make(sources: [source], on_error: ->(e, where) { errors.push([where, e.class]) })
    cw.instance_variable_set(:@first_tick_s, 0.01)
    cw.start("5s")
    source.wait_for_call
    assert_equal ["check", LoadError], errors.pop
    thread = cw.instance_variable_get(:@ticker).instance_variable_get(:@thread)
    Thread.pass until thread.status == "sleep" || !thread.alive?
    assert thread.alive?, "still ticking"
  ensure
    cw&.close
  end

  def test_start_replaces_an_interval_thread_that_ended
    source = RaisingSource.new(RuntimeError.new("tick"))
    cw, = make(sources: [source], on_error: ->(*) {})
    cw.instance_variable_set(:@first_tick_s, 0.01)
    cw.start("5s")
    source.wait_for_call
    ticker = cw.instance_variable_get(:@ticker)
    thread = ticker.instance_variable_get(:@thread)
    thread.kill
    thread.join
    cw.start("5s")
    refute_same ticker, cw.instance_variable_get(:@ticker)
    source.wait_for_call # the new thread's first check
  ensure
    cw&.close
  end

  def test_on_error_defaults_to_standard_error_and_a_raising_on_error_is_contained
    _, err = capture_io do
      cw = Cronwatch.new(alerts: [Cronwatch::Alerts::Custom.new("x") { raise "nope" }], cron_secret: nil)
      assert_raises(RuntimeError) { cw.run("e") { raise "job" } }
    end
    assert_match(/\[cronwatch\] alert channel x: RuntimeError: nope/, err)
    _, err = capture_io do
      cw = Cronwatch.new(alerts: [Cronwatch::Alerts::Custom.new("x") { raise "nope" }], on_error: ->(*) { raise "worse" })
      assert_raises(RuntimeError) { cw.run("e") { raise "job" } }
    end
    assert_match(/on_error raised RuntimeError: worse/, err)
  end

  def test_the_console_channel_is_the_default
    out, err = capture_io do
      cw = Cronwatch.new(now: Clock.new.to_proc)
      assert_raises(RuntimeError) { cw.run("c") { raise "x" } }
      cw.run("c") { nil }
    end
    assert_match(/\A\[cronwatch\] c failed\n/, err)
    assert_match(/\A\[cronwatch\] c recovered\n/, out)
  end

  def test_cron_secret_reads_the_environment_unless_given
    ENV["CRON_SECRET"] = "from-env"
    assert_equal "from-env", Cronwatch.new.cron_secret
    assert_nil Cronwatch.new(cron_secret: "").cron_secret
    assert_nil Cronwatch.new(cron_secret: nil).cron_secret
  ensure
    ENV.delete("CRON_SECRET")
  end

  def test_configure_builds_the_app_client
    clock = Clock.new
    store = Cronwatch::Stores::Memory.new
    client = Cronwatch.configure do |c|
      c.store = store
      c.alerts = []
      c.now = clock.to_proc
      c.retention = "7d"
    end
    assert_same client, Cronwatch.client
    assert_same store, Cronwatch.client.store
    assert_equal 7 * 86_400_000, client.retention_ms
    Cronwatch.client.run("configured") { nil }
    assert_equal 1, store.list_runs("configured", 5).length
  ensure
    Cronwatch.client = nil
  end

  def test_prune_removes_old_finished_runs_once_an_hour
    cw, clock, = make(retention: "1d")
    cw.run("p") { nil }
    clock.advance(2 * 86_400_000)
    cw.run("p") { nil }
    assert_equal 1, cw.check.pruned
    assert_equal 1, cw.runs("p").length
    assert_equal 0, cw.check.pruned
  end

  def test_check_results_and_summaries_are_the_sdks_json
    cw, = make
    cw.job("j", schedule: "every 1h").run { |j| j.metric(:rows, 3) }
    json = JSON.parse(cw.check.to_json)
    assert_equal %w[checkedAt jobs alerts pruned], json.keys
    assert_equal %w[name definition health open lastRun nextExpectedAt consecutiveFailures silencedUntil stats], json["jobs"][0].keys
    assert_equal({ "runs" => 1, "okRate" => 1, "p50Ms" => 0, "p95Ms" => 0 }, json["jobs"][0]["stats"])
  end

  # The SDK's redaction.test.ts and correctness.test.ts.

  def test_secrets_are_redacted_from_output_and_errors_before_they_are_stored_or_alerted
    cw, _, alerts = make
    assert_raises(RuntimeError) do
      cw.run("leaky") do |job|
        job.log("DB_PASSWORD=hunter2 tokens: 1200")
        raise "connect ECONNREFUSED postgres://app:s3cr3t@10.0.0.12:5432/db"
      end
    end
    run = cw.runs("leaky").first
    assert_equal "DB_PASSWORD=[redacted] tokens: 1200", run.output
    assert_match(%r{postgres://app:\[redacted\]@10\.0\.0\.12}, run.error)
    assert_equal 1, alerts.alerts.length
    refute_match(/hunter2|s3cr3t/, alerts.alerts.map(&:to_json).join)

    raw, = make(redact: false)
    raw.run("raw") { |job| job.log("password=kept") }
    assert_equal "password=kept", raw.runs("raw").first.output

    own, = make(redact: ->(text) { text.upcase })
    own.run("own") { |job| job.log("quiet") }
    assert_equal "QUIET", own.runs("own").first.output
    assert_raises(ArgumentError) { Cronwatch.new(redact: true) }
  end

  def test_expect_still_sees_the_unredacted_output
    cw, = make
    cw.run("e", expect: "token=abc") { |job| job.log("token=abc") }
    run = cw.runs("e").first
    assert_equal :ok, run.status
    assert_equal "token=[redacted]", run.output
  end

  def test_errors_are_capped_like_logged_output
    cw, = make
    assert_raises(RuntimeError) { cw.run("big") { raise "x" * 100_000 } }
    error = cw.runs("big").first.error
    assert_operator error.length, :<=, Cronwatch::Output::CAP + 30
    assert error.start_with?("[earlier output trimmed]\n")
  end

  def test_a_secret_split_by_the_16_kb_cut_is_redacted_whole_redaction_comes_before_the_cap
    cap = Cronwatch::Output::CAP
    pem = "-----BEGIN PRIVATE KEY-----\n#{Array.new(25) { |i| "#{"QUJD" * 15}#{i.to_s.rjust(4, "0")}" }.join("\n")}\n-----END PRIVATE KEY-----"
    bearer = "Authorization: Bearer opaqueTOKENvalue1234567890"
    cw, = make
    # The cut lands inside the key's body, and in a second run just after "Bea".
    cw.run("pem") do |job|
      job.log("x" * cap)
      job.log(pem[0, 900])
      job.log(pem[900..])
      job.log("done")
    end
    pem_output = cw.runs("pem").first.output
    refute_match(/QUJD/, pem_output)
    assert_match(/\[redacted\]\ndone\z/, pem_output)
    tail = "y" * (cap - 30)
    cw.run("bearer") { "#{bearer}\n#{tail}" }
    bearer_output = cw.runs("bearer").first.output
    refute_match(/opaqueTOKEN/, bearer_output)
    assert_operator bearer_output.length, :<=, cap + "[earlier output trimmed]\n".length

    # Errors, recorded runs and flushed lines the same way.
    assert_raises(RuntimeError) { cw.run("thrown") { raise "#{"e" * cap} #{bearer} #{"z" * (cap - 40)}" } }
    refute_match(/opaqueTOKEN/, cw.runs("thrown").first.error)
    cw.job("imported")
    cw.record_run({ id: "i1", job: "imported", status: "ok", started_at: 1, finished_at: 2, duration_ms: 1, error: nil,
                    output: "#{bearer}\n#{tail}", metrics: {}, trigger: "source" })
    refute_match(/opaqueTOKEN/, cw.get_run("i1").output)
    handle = cw.job("flushed").start
    handle.log(bearer)
    handle.log(tail)
    handle.flush
    refute_match(/opaqueTOKEN/, cw.get_run(handle.id).output)
    handle.finish
    refute_match(/opaqueTOKEN/, cw.get_run(handle.id).output)
  end

  def test_record_run_refuses_a_metric_that_is_no_finite_number_and_stores_nothing
    cw, = make
    cw.job("imported")
    base = { id: "m1", job: "imported", status: "ok", started_at: 1, finished_at: 2, duration_ms: 1, error: nil, output: nil,
             trigger: "source" }
    [Float::NAN, Float::INFINITY, nil, "3"].each do |value|
      error = assert_raises(ArgumentError) { cw.record_run(base.merge(metrics: { rows: value })) }
      assert_equal 'record_run: metric "rows" must be a finite number (job "imported", run "m1")', error.message
    end
    assert_nil cw.get_run("m1")
    cw.record_run(base.merge(metrics: { rows: 3 }))
    assert_equal({ "rows" => 3 }, cw.get_run("m1").metrics)
  end

  def test_text_past_the_redaction_window_never_keeps_what_came_right_after_its_cut
    cap = Cronwatch::Output::CAP
    edge = Cronwatch::Output::REDACT_EDGE
    trimmed = "[earlier output trimmed]\n"
    redact = Cronwatch::Output.method(:redact_secrets)
    text = "-----BEGIN PRIVATE KEY-----\n#{"QUJD" * 4000}\n#{"k" * (cap + edge - 8000)}"
    kept = Cronwatch::Output.redact_and_cap(text, redact)
    assert kept.start_with?(trimmed)
    assert_equal trimmed.length + cap, kept.length
    refute_match(/QUJD/, kept)

    # A redaction that shrinks the window cannot pull its first units into view.
    shrinking = ->(t) { t.gsub("s" * 100, "") }
    assert_equal trimmed, Cronwatch::Output.redact_and_cap(("QUJD" * 100) + ("s" * (cap + edge)), shrinking)

    # Short text is redacted whole, then capped as before; NULs go either side of redact.
    assert_equal "password=[redacted]", Cronwatch::Output.redact_and_cap("password=x", redact)
    assert_equal "ab", Cronwatch::Output.redact_and_cap("a\0b", ->(t) { "#{t}\0" })
    assert_equal "#{trimmed}#{"x" * cap}", Cronwatch::Output.redact_and_cap("x" * (cap + 5), redact)
  end

  def test_pruning_keeps_each_jobs_newest_run_so_a_monthly_job_is_not_reported_missed
    cw, clock, alerts = make(retention: "30d")
    clock.now = Time.utc(2026, 1, 1).to_i * 1000
    cw.job("monthly", schedule: "0 0 1 * *", timezone: "UTC").run { nil }
    clock.now = Time.utc(2026, 1, 31, 12).to_i * 1000
    assert_equal 0, cw.check.pruned
    clock.advance(2 * HOUR)
    cw.check
    assert_equal [], alerts.types
    assert_equal :healthy, cw.job_summary("monthly").health
  end

  def test_an_expect_regexp_gives_the_same_answer_every_run
    cw, = make
    [/done/, /DONE/i, /d o n e/x, /done.?/m].each_with_index do |pattern, i|
      job = cw.job("g#{i}", expect: pattern)
      4.times { job.run { |j| j.log("done") } }
      assert_equal %i[ok ok ok ok], cw.runs("g#{i}").map(&:status), pattern.inspect
    end
  end

  def test_expect_sees_a_line_logged_early_even_after_the_stored_output_has_dropped_it
    cw, = make
    cw.run("report", expect: "Report written") do |j|
      j.log("Report written: /tmp/r.pdf")
      3000.times { |i| j.log("row #{i} #{"x" * 40}") }
    end
    run = cw.runs("report").first
    assert_equal :ok, run.status
    refute_match(/Report written/, run.output, "the stored output is still only the tail")
  end

  def test_expect_checks_a_returned_string_in_full_not_its_capped_tail
    cw, = make
    cw.run("returned", expect: "header") { "header\n#{"y" * 40_000}" }
    run = cw.runs("returned").first
    assert_equal :ok, run.status
    assert run.output.start_with?("[earlier output trimmed]\n")
  end

  def test_an_interval_job_whose_run_is_still_going_is_busy_not_missed
    cw, clock, alerts = make
    job = cw.job("long", schedule: "every 5m", grace: "2m")
    gate = Queue.new
    thread = Thread.new { job.run { gate.pop } }
    wait_for { cw.runs("long").first&.status == :running }
    clock.advance(8 * MIN)
    cw.check
    assert_equal [], alerts.types
    gate.push(nil)
    thread.join
    assert_equal [], alerts.types, "and no recovered for a miss that never was"
  end

  def test_a_run_a_check_marked_stuck_that_then_fails_counts_once
    cw, clock, alerts = make
    job = cw.job("slowpoke", timeout: "1m", failures_before_alert: 2)
    gate = Queue.new
    thread = Thread.new do
      job.run do
        gate.pop
        raise "gave up"
      end
    rescue RuntimeError
      nil
    end
    wait_for { cw.runs("slowpoke").first&.status == :running }
    clock.advance(2 * MIN)
    cw.check
    assert_equal 1, cw.store.get_state("slowpoke").consecutive_failures
    gate.push(nil)
    thread.join
    assert_equal 1, cw.store.get_state("slowpoke").consecutive_failures
    assert_equal [], alerts.types, "one run is one failure, under the threshold of two"
    assert_equal "RuntimeError: gave up", cw.runs("slowpoke").first.error.split("\n").first, "the run keeps its real error"
  end

  def test_a_late_success_after_a_stuck_mark_closes_stuck_and_recovers
    cw, clock, alerts = make
    job = cw.job("late", timeout: "30s")
    gate = Queue.new
    thread = Thread.new { job.run { gate.pop } }
    wait_for { cw.runs("late").first&.status == :running }
    clock.advance(MIN)
    from_check = cw.check.alerts
    assert_match(/\AStill running after 30s;/, from_check[0].run.error)
    gate.push(nil)
    thread.join
    assert_equal %i[stuck recovered], alerts.types
  end
end
