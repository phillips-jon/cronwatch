# frozen_string_literal: true

require "monitor"
require "securerandom"
require "set"

module Cronwatch
  # Raised (and handed to on_error) when a channel or triage takes too long.
  class TimeoutError < StandardError; end

  class Client
    NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,119}\z/
    TRIAGE_TIMEOUT_MS = 25_000
    # How long one channel may take to send one alert.
    CHANNEL_TIMEOUT_MS = 15_000
    PRUNE_INTERVAL_MS = 60 * 60_000
    # Undelivered alerts kept per job for retry; the oldest go first.
    MAX_UNDELIVERED = 20
    # Runs read for a baseline, and the most read when failures crowd out the successes.
    HISTORY_PAGE = Evaluate::BASELINE_WINDOW + 5
    HISTORY_MAX = 200
    DEFAULT_OPTIONS = %i[grace timeout timezone failures_before_alert].freeze
    # Tells "cron_secret not given" (read CRON_SECRET) from "cron_secret: nil" (no secret on purpose).
    UNSET = Object.new.freeze

    # What execute returns: the recorded run, and the block's own outcome.
    ExecuteResult = Struct.new(:run, :result, :error, :threw, keyword_init: true)
    # What a triage callable receives. Pass the signal to anything that can stop early.
    TriageContext = Struct.new(:alert, :recent_runs, :signal, keyword_init: true)
    # A job's summary and its newest runs, as the dashboard shows them.
    JobWithRuns = Struct.new(:job, :runs, keyword_init: true) do
      include Serializable

      def to_h = { "job" => job.to_h, "runs" => runs.map(&:to_h) }
    end

    attr_reader :store, :alerts, :triage, :cron_secret, :retention_ms, :defaults

    # store:       where jobs, runs and state live. Defaults to an in-memory store that forgets on restart.
    # alerts:      where alerts go: objects with #call(alert) and #name. Defaults to the console.
    # triage:      a callable taking a TriageContext and returning a short diagnosis, added to every alert but recoveries.
    # cron_secret: a second bearer Cronwatch::Web accepts for /api/check, for an outside cron. Defaults to
    #              ENV["CRON_SECRET"]; an empty string counts as unset. Pass nil for none.
    # retention:   how long finished runs are kept. Default "30d".
    # defaults:    grace, timeout, timezone and failures_before_alert applied to every job unless it sets its own.
    # redact:      applied to every run's output and error before it is stored, shown or sent to an alert
    #              channel or triage. The default (Output.redact_secrets) blanks values that look like secrets
    #              (password=..., URL credentials, bearer tokens, AWS, GitHub, Slack, Stripe and API key
    #              formats). Pass your own callable, or false to keep output exactly as logged.
    # now:         the clock, a callable returning epoch milliseconds. Tests use this.
    # on_error:    called with (error, where) for anything that goes wrong outside a job: the store failing,
    #              an alert channel failing, a triage timeout.
    def initialize(store: nil, alerts: nil, triage: nil, cron_secret: UNSET, retention: "30d", defaults: {}, redact: nil,
                   deliver: :now, now: nil, on_error: nil)
      @using_default_store = store.nil?
      @store = store || Stores::Memory.new
      @alerts = alerts.nil? ? [Alerts::Console.new] : Array(alerts)
      @triage = triage
      secret = cron_secret.equal?(UNSET) ? ENV.fetch("CRON_SECRET", nil) : cron_secret
      @cron_secret = secret.nil? || secret.to_s.empty? ? nil : secret.to_s
      @retention_ms = Duration.parse(retention || "30d", "retention")
      @defaults = (defaults || {}).transform_keys(&:to_sym)
      unknown = @defaults.keys - DEFAULT_OPTIONS
      raise ArgumentError, "defaults may set #{DEFAULT_OPTIONS.join(", ")}, not #{unknown.join(", ")}" if unknown.any?

      if !(redact.nil? || redact == false || redact.respond_to?(:call))
        raise ArgumentError, "redact must be a callable, or false to keep output as logged"
      end

      @redact = redact == false ? ->(text) { text } : (redact || Output.method(:redact_secrets))
      unless [:now, :check, "now", "check", nil].include?(deliver)
        raise ArgumentError, "deliver must be \"now\" or \"check\", not #{deliver.inspect}"
      end

      # :check queues alerts in the store for another process's check to send. See DESIGN.md and deliver in the SDK.
      @defer_delivery = deliver.to_s == "check"
      @clock = now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
      @on_error = on_error || method(:default_on_error)
      @definitions = {}
      @synced = Set.new
      @registry = Mutex.new
      @locks = {}
      @ready = false
      @ready_lock = Mutex.new
      @check_lock = Mutex.new
      @checking = nil
      @last_prune_at = 0
      @ticker = nil
      # Seconds before start()'s first check, and how long a channel or triage may take. Tests shorten them.
      @first_tick_s = 1.0
      @channel_timeout_ms = CHANNEL_TIMEOUT_MS
      @triage_timeout_ms = TRIAGE_TIMEOUT_MS
      @warned_no_secret = false
    end

    # Epoch milliseconds, from the clock the client was given.
    def now
      @clock.call
    end

    # Declare a job. Call it once, when the app loads, and keep the handle.
    def job(name, **options)
      name = name.to_s if name.is_a?(Symbol)
      unless name.is_a?(String) && NAME_RE.match?(name)
        raise ArgumentError, "job name \"#{name}\" must be 1 to 120 characters of letters, digits, \".\", \"_\", \":\" or \"-\""
      end

      definition = build_definition(name, options)
      validate_definition(definition)
      @registry.synchronize do
        @definitions[name] = definition
        @synced.delete(name)
      end
      JobHandle.new(self, definition)
    end

    # With a block: run a job by name without keeping a handle, declaring it
    # on first use (or again, when options are given). Without a block: the
    # run with this id, as get_run.
    def run(name_or_id, **options, &block)
      return get_run(name_or_id) unless block

      declared = @registry.synchronize { @definitions[name_or_id.to_s] }
      handle = options.any? || declared.nil? ? job(name_or_id, **options) : JobHandle.new(self, declared)
      handle.run(&block)
    end

    # The definitions declared in this process.
    def defined_jobs
      @registry.synchronize { @definitions.values }
    end

    # Runs a block as a recorded run. The block always runs, whatever the store
    # is doing: store errors go to on_error, and the result is the block's own
    # outcome. Never raises for the block's own error; see `threw`.
    #
    # Meant for integrations (the Rack handler, ActiveJob) rather than apps.
    # `failure` is an optional callable that turns the block's result into an
    # error message, or nil when the result is fine: an HTTP handler uses it to
    # count a 500 response as a failed run.
    def execute(definition, trigger, failure: nil)
      name = definition.name
      started_at = now
      run = Run.new(id: SecureRandom.uuid, job: name, status: :running, started_at: started_at, finished_at: nil,
                    duration_ms: nil, error: nil, output: nil, metrics: {}, trigger: trigger)
      recorded = false
      begin
        sync(definition)
        @store.insert_run(run.dup)
        recorded = true
      rescue StandardError => e
        report(e, "recording #{name}")
      end
      # The SDK closes missed and stuck beside the running job; here it is done
      # just before the block runs. The result is the same.
      if recorded
        begin
          serial(name) do
            before = read_state(name)
            after = Evaluate.on_run_start(before)
            @store.set_state(after) unless same_state?(before, after)
          end
        rescue StandardError => e
          report(e, "starting #{name}")
        end
      end

      recorder = RunRecorder.new(run, Evaluate.timeout_ms(definition))
      result = nil
      error = nil
      threw = false
      begin
        result = yield(recorder.context)
      rescue StandardError => e
        error = e
        threw = true
      ensure
        recorder.signal.settle!
      end

      finished_at = now
      run.finished_at = finished_at
      run.duration_ms = [0, finished_at - started_at].max
      run.metrics = recorder.metrics
      run.output = recorder.output || (result.is_a?(String) ? Output.cap(result) : nil)

      if threw
        run.status = :failed
        run.error = Output.error_message(error)
      elsif (problem = failure&.call(result))
        run.status = :failed
        run.error = problem
      else
        expect_text = recorder.expect_text || (result.is_a?(String) ? result : nil)
        unmet = Serialize.check_expectation(definition.expect, expect_text)
        if unmet
          run.status = :failed
          run.error = unmet
        else
          run.status = :ok
        end
      end
      # Redacted after the expect check, so a rule can still match what was logged.
      run.output = @redact.call(run.output) unless run.output.nil?
      run.error = @redact.call(run.error) unless run.error.nil?

      stored = Serialize.to_stored(definition)
      if recorded && marked_timed_out?(run)
        # A check gave up on this run while it was going and already counted
        # it as a stuck failure. A late failure must not count twice; a late
        # success still closes stuck and recovers.
        begin
          @store.update_run(run)
        rescue StandardError => e
          report(e, "recording #{name}")
        end
      elsif recorded
        finish_run(stored, run, finished_at, true)
      else
        # The start was never written; the store may be back by now.
        begin
          sync(definition)
          @store.insert_run(run)
          recorded = true
        rescue StandardError => e
          report(e, "recording #{name}")
        end
        finish_run(stored, run, finished_at, false) if recorded
      end

      ExecuteResult.new(run: run, result: result, error: error, threw: threw)
    end

    # Look for missed and stuck runs across every job, send alerts, retry
    # alerts no channel accepted, and prune old runs. Call it from start(), a
    # scheduled job (Cronwatch::CheckJob), or by hand. Concurrent calls share
    # one check.
    def check
      flight = nil
      mine = false
      @check_lock.synchronize do
        flight = @checking ||= begin
          mine = true
          Flight.new
        end
      end
      if mine
        begin
          flight.resolve(run_check)
        rescue StandardError => e
          flight.reject(e)
        ensure
          @check_lock.synchronize { @checking = nil }
        end
      end
      flight.value
    end

    # Every job the store knows about, with its health. Does not send alerts.
    def jobs
      jobs_with_runs(0).map(&:job)
    end

    # Every job's summary with its newest `limit` runs, read together. What the dashboard shows.
    def jobs_with_runs(limit = 20)
      ensure_ready
      defined_jobs.each { |definition| sync(definition) }
      at = now
      count = clamp_limit(limit, 20, 0)
      @store.list_jobs.map { |stored| snapshot(stored, at, count) }
    end

    def job_summary(name)
      ensure_ready
      definition = @registry.synchronize { @definitions[name] }
      sync(definition) if definition
      stored = @store.get_job(name)
      return nil unless stored

      snapshot(stored, now, 0).job
    end

    # A job's runs, newest first. `limit` is a whole number from 1 to 500.
    def runs(name, limit = 50)
      ensure_ready
      @store.list_runs(name, clamp_limit(limit, 50, 1))
    end

    def get_run(id)
      ensure_ready
      @store.get_run(id)
    end

    # Stop alerts for a job for a while. State keeps updating underneath.
    #   silence("nightly-report", for: "2h")
    def silence(name, duration = nil, **options)
      duration = options.fetch(:for) if duration.nil? && options.key?(:for)
      ms = Duration.parse(duration, "silence duration")
      patch_state(name) { |state| state.silenced_until = now + ms }
    end

    def unsilence(name)
      patch_state(name) { |state| state.silenced_until = nil }
    end

    # Remove a job and its runs from the store. A job still declared in code comes back on its next run.
    def forget(name)
      ensure_ready
      @registry.synchronize do
        @definitions.delete(name)
        @synced.delete(name)
      end
      @store.delete_job(name)
      nil
    end

    # Check on an interval, in a background thread, for long-running
    # processes. Default every minute; the first check comes after a second.
    def start(every = "1m")
      return if @ticker

      seconds = [5_000, Duration.parse(every, "check interval")].max / 1000.0
      @ticker = Ticker.new(seconds, @first_tick_s) do
        check
      rescue StandardError => e
        report(e, "check")
      end
      nil
    end

    def stop
      @ticker&.stop
      @ticker = nil
      nil
    end

    def close
      stop
      @store.close if @store.respond_to?(:close)
      nil
    end

    # True in development or test: Rails.env when Rails is loaded, otherwise
    # RAILS_ENV or RACK_ENV. Cronwatch::Web without a token only serves then.
    def self.development?
      env = defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env.to_s : (ENV["RAILS_ENV"] || ENV.fetch("RACK_ENV", nil))
      %w[development test].include?(env)
    end

    # Hands an error to on_error. An on_error that raises is not allowed to
    # take the job down with it.
    def report(error, where)
      @on_error.call(error, where)
    rescue StandardError => e
      warn "[cronwatch] on_error raised #{e.class}: #{e.message} (reporting #{where}: #{error.message})"
    end

    private

    def build_definition(name, options)
      unknown = options.keys.map(&:to_sym) - JobDefinition::OPTIONS
      raise ArgumentError, "job \"#{name}\": unknown option #{unknown.map(&:inspect).join(", ")}" if unknown.any?

      fields = {}
      @defaults.each { |k, v| fields[k] = v }
      options.each do |k, v|
        fields[k.to_sym] = v.is_a?(Hash) && k.to_sym == :budget ? v.transform_keys(&:to_s) : v
      end
      fields[:name] = name
      JobDefinition.new(fields)
    end

    # Raises a clear error for options that would otherwise quietly turn a check off.
    def validate_definition(definition)
      name = definition.name
      unless definition.schedule.nil?
        unless definition.schedule.is_a?(String) && JS.trim(definition.schedule) != ""
          raise ArgumentError, "job \"#{name}\": schedule must be a non-empty string"
        end

        Schedule.parse(definition.schedule, definition.timezone)
      end
      if !definition.timezone.nil? && !(definition.timezone.is_a?(String) && Zone.valid?(definition.timezone))
        raise ArgumentError, "job \"#{name}\": timezone \"#{definition.timezone}\" is not an IANA timezone"
      end

      Duration.parse(definition.grace, "grace") unless definition.grace.nil?
      if !definition.timeout.nil? && Duration.parse(definition.timeout, "timeout") <= 0
        raise ArgumentError, "job \"#{name}\": timeout must be longer than zero"
      end
      if !definition.max_duration.nil? && Duration.parse(definition.max_duration, "maxDuration") <= 0
        raise ArgumentError, "job \"#{name}\": maxDuration must be longer than zero"
      end

      failures = definition.failures_before_alert
      if !failures.nil? && !(failures.is_a?(Numeric) && JS.integer?(failures) && failures >= 1)
        raise ArgumentError, "job \"#{name}\": failuresBeforeAlert must be a whole number, 1 or more (got #{js_string(failures)})"
      end
      unless definition.budget.nil?
        raise ArgumentError, "job \"#{name}\": budget must be an object of { metric: ceiling }" unless definition.budget.is_a?(Hash)

        definition.budget.each do |metric, ceiling|
          next if ceiling.is_a?(Numeric) && ceiling.real? && JS.finite?(ceiling) && ceiling >= 0

          raise ArgumentError, "job \"#{name}\": budget.#{metric} must be a finite number, 0 or more (got #{js_string(ceiling)})"
        end
      end
      expect = definition.expect
      return if expect.nil? || expect.is_a?(String) || expect.is_a?(Regexp) || expect.respond_to?(:call)

      raise ArgumentError, "job \"#{name}\": expect must be a string, a RegExp or a function"
    end

    # String(value) as JavaScript writes it, for the messages above.
    def js_string(value)
      case value
      when nil then "null"
      when Numeric then JS.number(value)
      else value.to_s
      end
    end

    def ensure_ready
      return if @ready

      @ready_lock.synchronize do
        next if @ready

        @store.init if @store.respond_to?(:init)
        if @using_default_store && (ENV["RAILS_ENV"] || ENV.fetch("RACK_ENV", nil)) == "production"
          warn "[cronwatch] using the in-memory store: runs and state are lost on restart. " \
               "Pass a store such as Cronwatch::Stores::ActiveRecord."
        end
        # Only once init has gone through: a failure is tried again on the next call.
        @ready = true
      end
    end

    def sync(definition)
      ensure_ready
      return if @registry.synchronize { @synced.include?(definition.name) }

      @store.upsert_job(Serialize.to_stored(definition), now)
      @registry.synchronize { @synced << definition.name }
    end

    # Runs the block while holding the job's lock, so two runs (or a run and a
    # check) in this process never read and write the job's state over each
    # other. Other processes are not coordinated. Only store reads and writes
    # happen inside; alerts are sent outside it.
    def serial(job, &block)
      lock = @registry.synchronize { @locks[job] ||= Monitor.new }
      lock.synchronize(&block)
    end

    def read_state(job)
      Evaluate.normalize_state(@store.get_state(job), job)
    end

    def same_state?(a, b)
      JS.json(a.to_h) == JS.json(b.to_h)
    end

    # Identifies an alert across retries.
    def alert_key(alert)
      "#{alert.type}|#{alert.at}|#{alert.run&.id}"
    end

    # Whether a check already marked this run as timed out, for a failure that finished late.
    def marked_timed_out?(run)
      return false if run.status == :ok

      @store.get_run(run.id)&.status == :timeout
    rescue StandardError
      false
    end

    # Record a finished run (ok, failed, or timed out by a check), evaluate it
    # against the job's state and send what that produces. Never raises.
    def finish_run(definition, run, at, write)
      drafts = nil
      begin
        @store.update_run(run) if write
        drafts = serial(run.job) do
          history = history(run)
          previous = read_state(run.job)
          settle(previous, Evaluate.on_run_finish(definition, run, previous, history, at), at).alerts
        end
      rescue StandardError => e
        report(e, "evaluating #{run.job}")
        return []
      end
      dispatch(drafts, definition, at)
    end

    # The runs before `run`, newest first, with up to BASELINE_WINDOW
    # successful ones when the store has them. One small read normally; a
    # larger one only when failures crowd the successes out of it.
    def history(run)
      runs = @store.list_runs(run.job, HISTORY_PAGE)
      if runs.length == HISTORY_PAGE && !Evaluate.full_baseline?(runs.reject { |r| r.id == run.id })
        runs = @store.list_runs(run.job, HISTORY_MAX)
      end
      runs.reject { |r| r.id == run.id }
    end

    def run_check
      ensure_ready
      defined_jobs.each { |definition| sync(definition) }
      at = now
      alerts = []

      # Runs that never reported back.
      @store.running_runs.each do |run|
        declared = @registry.synchronize { @definitions[run.job] }
        definition = declared ? Serialize.to_stored(declared) : @store.get_job(run.job)&.definition
        next if definition.nil? || !Evaluate.stuck?(definition, run, at)

        run.status = :timeout
        run.finished_at = at
        run.duration_ms = at - run.started_at
        run.error = "Still running after #{Duration.format(Evaluate.timeout_ms(definition))}; marked as timed out"
        alerts.concat(finish_run(definition, run, at, true))
      end

      jobs = []
      @store.list_jobs.each do |stored|
        recent = @store.list_runs(stored.name, Evaluate::BASELINE_WINDOW)
        previous, evaluation, settled = serial(stored.name) do
          before = read_state(stored.name)
          result = Evaluate.on_check(stored.definition, stored, recent.first, before, at)
          [before, result, settle(before, result, at)]
        end
        alerts.concat(retry_undelivered(stored.name, previous, at))
        alerts.concat(dispatch(settled.alerts, stored.definition, at))
        jobs << Evaluate.summarize(stored, recent, settled.state, evaluation.next_expected_at, at)
      end

      pruned = 0
      if at - @last_prune_at > PRUNE_INTERVAL_MS
        @last_prune_at = at
        begin
          pruned = @store.prune(at - @retention_ms)
        rescue StandardError => e
          report(e, "pruning")
        end
      end

      CheckResult.new(checked_at: at, jobs: jobs, alerts: alerts, pruned: pruned)
    end

    # A job's summary and its newest runs, without alerting.
    def snapshot(stored, at, count)
      recent = @store.list_runs(stored.name, [count, Evaluate::BASELINE_WINDOW].max)
      state = read_state(stored.name)
      next_expected_at = Evaluate.on_check(stored.definition, stored, recent.first, state, at).next_expected_at
      JobWithRuns.new(job: Evaluate.summarize(stored, recent, state, next_expected_at, at), runs: recent.first(count))
    end

    # Read, change and write one job's state, in turn with every other update to it.
    def patch_state(name)
      ensure_ready
      serial(name) do
        state = read_state(name)
        yield state
        @store.set_state(state)
        state
      end
    end

    # Save an evaluation's state, honouring silence, and return what should be sent. Call inside serial.
    def settle(previous, evaluation, at)
      state = evaluation.state
      alerts = evaluation.alerts
      if Evaluate.silenced?(previous, at)
        state = Evaluate.mute_opens(previous, state)
        alerts = []
      end
      @store.set_state(state) unless same_state?(state, previous)
      Evaluate::Evaluation.new(state: state, alerts: alerts)
    end

    # Compose, triage and send each draft. The state was saved before this
    # (settle), so a slow channel holds up nothing else; afterwards only the
    # delivery fields are written back, onto a fresh read of the state.
    def dispatch(drafts, definition, at)
      return [] if drafts.empty?

      composed = []
      delivered = []
      failed = []
      drafts.each do |draft|
        alert = Format.compose_alert(draft, definition, at)
        if @defer_delivery
          failed << alert
        else
          add_triage(alert) if @triage && alert.type != :recovered
          (deliver(alert) ? delivered : failed) << alert
        end
        composed << alert
      end
      record_delivery(definition.name, delivered, failed, at)
      composed
    end

    # Send the alerts that no channel accepted last time, once each.
    def retry_undelivered(name, state, at)
      pending = state.undelivered || []
      return [] if pending.empty? || Evaluate.silenced?(state, at) || @defer_delivery

      delivered = []
      failed = []
      pending.each do |alert|
        # An alert queued by a process that delivers at check time was never triaged.
        add_triage(alert) if @triage && alert.type != :recovered && alert.triage.nil?
        (deliver(alert) ? delivered : failed) << alert
      end
      record_delivery(name, delivered, failed, at)
      delivered
    end

    # Mark delivered alerts done and keep failed ones for the next check. last_alert_at moves only on a delivery.
    def record_delivery(name, delivered, failed, at)
      serial(name) do
        previous = read_state(name)
        state = Evaluate.normalize_state(previous, name)
        done = delivered.map { |a| alert_key(a) }.to_set
        kept = state.undelivered.reject { |a| done.include?(alert_key(a)) }
        known = kept.map { |a| alert_key(a) }.to_set
        kept.concat(failed.reject { |a| known.include?(alert_key(a)) })
        state.undelivered = kept.last(MAX_UNDELIVERED)
        state.last_alert_at = at if delivered.any?
        @store.set_state(state) unless same_state?(state, previous)
      end
    rescue StandardError => e
      report(e, "recording alert delivery for #{name}")
    end

    # Send to every channel at once, each in its own thread with its own
    # timeout. True when at least one accepted it, or there are none. A
    # channel that times out is left to finish on its own.
    def deliver(alert)
      return true if @alerts.empty?

      outcomes = Array.new(@alerts.length)
      threads = @alerts.each_with_index.map do |channel, i|
        Thread.new do
          Thread.current.report_on_exception = false
          channel.call(alert)
          outcomes[i] = true
        rescue StandardError, ScriptError => e
          outcomes[i] = e
        end
      end
      deadline = Signal.monotonic + (@channel_timeout_ms / 1000.0)
      results = threads.each_with_index.map do |thread, i|
        finished = thread.join([deadline - Signal.monotonic, 0].max)
        finished ? outcomes[i] : TimeoutError.new("timed out after #{@channel_timeout_ms}ms")
      end
      results.each_with_index do |result, i|
        report(result, "alert channel #{channel_name(@alerts[i])}") unless result == true
      end
      results.include?(true)
    end

    def channel_name(channel)
      channel.respond_to?(:name) && channel.name ? channel.name : channel.class.name
    end

    def add_triage(alert)
      signal = Signal.new
      recent = @store.list_runs(alert.job, 5)
      context = TriageContext.new(alert: alert, recent_runs: recent, signal: signal)
      outcome = nil
      thread = Thread.new do
        Thread.current.report_on_exception = false
        outcome = [:ok, @triage.call(context)]
      rescue StandardError, ScriptError => e
        outcome = [:error, e]
      end
      raise TimeoutError, "timed out after #{@triage_timeout_ms}ms" unless thread.join(@triage_timeout_ms / 1000.0)
      raise outcome[1] if outcome[0] == :error

      diagnosis = outcome[1]
      alert.triage = diagnosis if diagnosis.is_a?(String) && !diagnosis.empty?
    rescue StandardError => e
      signal&.abort!
      report(e, "triage for #{alert.job}")
    end

    # A whole number in range, or the fallback for anything that is not a number.
    def clamp_limit(limit, fallback, min)
      n = limit.is_a?(Numeric) && limit.real? && JS.finite?(limit) ? limit.truncate : fallback
      [500, [min, n].max].min
    end

    def default_on_error(error, where)
      message = "[cronwatch] #{where}: #{error.class}: #{error.message}"
      if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
        ::Rails.logger.error(message)
      else
        warn message
      end
    end

    # One shared check: the first caller runs it, the others wait for its result.
    class Flight
      def initialize
        @lock = Mutex.new
        @done = ConditionVariable.new
        @finished = false
      end

      def resolve(value)
        settle(value, nil)
      end

      def reject(error)
        settle(nil, error)
      end

      def value
        @lock.synchronize do
          @done.wait(@lock) until @finished
          raise @error if @error

          @value
        end
      end

      private

      def settle(value, error)
        @lock.synchronize do
          @value = value
          @error = error
          @finished = true
          @done.broadcast
        end
      end
    end

    # Calls the block after `first` seconds, then every `interval` seconds
    # counted from the start, in a background thread, until stopped.
    class Ticker
      def initialize(interval, first, &tick)
        @lock = Mutex.new
        @wake = ConditionVariable.new
        @stopped = false
        started = Signal.monotonic
        @thread = Thread.new do
          Thread.current.name = "cronwatch-check" if Thread.current.respond_to?(:name=)
          Thread.current.report_on_exception = false
          first_at = started + first
          next_at = started + interval
          loop do
            due = first_at ? [first_at, next_at].min : next_at
            break unless wait_until(due)

            clock = Signal.monotonic
            if first_at && clock >= first_at
              first_at = nil
            else
              next_at += interval while next_at <= clock
            end
            tick.call
          end
        end
      end

      def stop
        @lock.synchronize do
          @stopped = true
          @wake.broadcast
        end
      end

      private

      # False once stopped.
      def wait_until(due)
        @lock.synchronize do
          loop do
            return false if @stopped

            left = due - Signal.monotonic
            return true if left <= 0

            @wake.wait(@lock, left)
          end
        end
      end
    end
  end
end
