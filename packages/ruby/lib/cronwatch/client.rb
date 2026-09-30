# frozen_string_literal: true

require "monitor"
require "securerandom"
require "set"
require_relative "abort_signal"
require_relative "environment"
require_relative "flight"
require_relative "ticker"

module Cronwatch
  # Raised (and handed to on_error) when a channel or triage takes too long,
  # or is skipped because its previous call has not finished.
  class TimeoutError < StandardError; end

  # What callers waiting on a shared check see when the check was stopped by
  # an exception outside StandardError (Interrupt, Timeout, SystemExit). The
  # caller that ran the check sees the original exception.
  class InterruptedError < StandardError; end

  class Client
    NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,119}\z/
    TRIAGE_TIMEOUT_MS = 25_000
    # How long one channel may take to send one alert.
    CHANNEL_TIMEOUT_MS = 15_000
    PRUNE_INTERVAL_MS = 60 * 60_000
    # Undelivered alerts kept per job for retry; the oldest go first.
    MAX_UNDELIVERED = 20
    # Wall-clock time one check spends retrying undelivered alerts, across
    # every job. Once it is spent the rest wait for the next check.
    RETRY_BUDGET_MS = 20_000
    # Reads and writes of one job's state before an update gives up on a store that keeps changing under it.
    STATE_ATTEMPTS = 10
    # Runs read for a baseline, and the most read when failures crowd out the successes.
    HISTORY_PAGE = Evaluate::BASELINE_WINDOW + 5
    HISTORY_MAX = 200
    DEFAULT_OPTIONS = %i[grace timeout timezone failures_before_alert].freeze
    # Tells "cron_secret not given" (read CRON_SECRET) from "cron_secret: nil" (no secret on purpose).
    UNSET = Object.new.freeze
    # Guards the reset a forked child makes of the parent's locks and threads.
    FORK_LOCK = Mutex.new
    SILENCE_OPTIONS = %i[for].freeze
    # Run ids that start with this belong to the pg_cron source (Sources::PgCron).
    RESERVED_RUN_ID_PREFIX = "pgcron:"

    # What execute returns: the recorded run, and the block's own outcome.
    ExecuteResult = Struct.new(:run, :result, :error, :threw, keyword_init: true)
    # What a channel's call receives with each alert (the SDK's ChannelContext).
    # on_error(error) reports a problem that did not stop the alert going
    # out, such as one of several recipients refusing it, to the client's on_error.
    class ChannelContext
      def initialize(on_error)
        @on_error = on_error
      end

      def on_error(error)
        @on_error.call(error)
        nil
      end
    end
    # What a triage callable receives. Pass the signal to anything that can stop early.
    TriageContext = Struct.new(:alert, :recent_runs, :signal, keyword_init: true)
    # A job's summary and its newest runs, as the dashboard shows them.
    JobWithRuns = Struct.new(:job, :runs, keyword_init: true) do
      include Serializable

      def to_h = { "job" => job.to_h, "runs" => runs.map(&:to_h) }
    end

    attr_reader :store, :alerts, :triage, :cron_secret, :retention_ms, :defaults, :sources

    # store:       where jobs, runs and state live. Defaults to an in-memory store that forgets on restart.
    # alerts:      where alerts go: objects with #call(alert) and #name. Defaults to the console.
    # triage:      a callable taking a TriageContext and returning a short diagnosis, added to every alert but recoveries.
    # cron_secret: a second bearer Cronwatch::Web accepts for /api/check, for an outside cron. Defaults to
    #              ENV["CRON_SECRET"]; an empty string counts as unset. Pass nil for none.
    # retention:   how long finished runs are kept. Default "30d".
    # defaults:    grace, timeout, timezone and failures_before_alert applied to every job unless it sets its own.
    # redact:      applied to every run's output and error before it is stored, shown or sent to an alert
    #              channel or triage. The default (Output.redact_secrets) blanks values that look like secrets
    #              (password=..., Authorization headers, URL credentials, bearer tokens, JWTs, PEM private
    #              keys, webhook URLs, AWS, GitHub, Slack, Stripe, Google and API key formats). Pass your own
    #              callable, or false to keep output exactly as logged. A callable that raises or returns
    #              something other than a String is reported to on_error ("redact") and the default is used.
    # now:         the clock, a callable returning epoch milliseconds. Tests use this.
    # on_error:    called with (error, where) for anything that goes wrong outside a job: the store failing,
    #              an alert channel failing, a triage timeout.
    # sources:     where runs this process does not wrap come from, such as pg_cron jobs
    #              (Cronwatch::Sources::PgCron). Each is synced at the start of every check; one that
    #              raises is reported to on_error and the check carries on. See "Sources" in DESIGN.md.
    def initialize(store: nil, alerts: nil, triage: nil, cron_secret: UNSET, retention: "30d", defaults: {}, redact: nil,
                   deliver: :now, now: nil, on_error: nil, sources: nil)
      @using_default_store = store.nil?
      @store = store || Stores::Memory.new
      @alerts = alerts.nil? ? [Alerts::Console.new] : Array(alerts)
      @sources = sources.nil? ? [] : Array(sources)
      @sources.each do |source|
        raise ArgumentError, "a source must respond to sync(host)" unless source.respond_to?(:sync)
      end
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

      @redact =
        if redact == false then ->(text) { text }
        elsif redact.nil? then Output.method(:redact_secrets)
        else guarded_redact(redact)
        end
      unless [:now, :check, "now", "check", nil].include?(deliver)
        raise ArgumentError, "deliver must be \"now\" or \"check\", not #{deliver.inspect}"
      end

      # :check queues alerts in the store for another process's check to send
      # (see "Delivery" in DESIGN.md, and deliver in the SDK).
      @defer_delivery = deliver.to_s == "check"
      @clock = now || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
      @on_error = on_error || method(:default_on_error)
      @definitions = {}
      @synced = Set.new
      @registry = Mutex.new
      @ready = false
      @last_prune_at = 0
      # Seconds before start()'s first check, and how long a channel or triage may take. Tests shorten them.
      @first_tick_s = 1.0
      @channel_timeout_ms = CHANNEL_TIMEOUT_MS
      @triage_timeout_ms = TRIAGE_TIMEOUT_MS
      @retry_budget_ms = RETRY_BUDGET_MS
      @warned_deferred_start = false
      reset_process_state
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
      unless block
        raise ArgumentError, "run(#{name_or_id.inspect}, ...) needs a block; without one, run(id) reads a run" if options.any?

        return get_run(name_or_id)
      end

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
    # outcome. A StandardError from the block is not raised; see `threw`. An
    # exception outside StandardError (Interrupt, SystemExit, Sidekiq::Shutdown,
    # a Timeout, NotImplementedError) is recorded as a failed run and then
    # raised again, so the run is never left running.
    #
    # `failure` is an optional callable that turns the block's result into an
    # error message, or nil when the result is fine: an HTTP handler uses it to
    # count a 500 response as a failed run.
    #
    # @api private For integrations (JobHandle#run, ActiveJob, Sidekiq), not apps.
    def execute(definition, trigger, failure: nil)
      after_fork_check
      name = definition.name
      started_at = now
      run = Run.new(id: SecureRandom.uuid, job: name, status: :running, started_at: started_at, finished_at: nil,
                    duration_ms: nil, error: nil, output: nil, metrics: {}, trigger: trigger)
      recorded = false
      begin
        sync(definition, confirm: true)
        @store.insert_run(run.dup)
        recorded = true
      rescue StandardError => e
        report(e, "recording #{name}")
      end
      # The SDK closes missed and stuck beside the running job; here it is done
      # just before the block runs. The result is the same.
      if recorded
        begin
          update_state(name) { |before| [Evaluate.on_run_start(before), nil] }
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
      rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then raised again below
        error = e
        threw = true
      ensure
        recorder.signal.settle!
      end

      finished_at = now
      run.finished_at = finished_at
      run.duration_ms = Evaluate.run_duration(started_at, finished_at)
      run.metrics = recorder.metrics
      returned = result.is_a?(String) ? Output.utf8(result) : nil
      run.output = recorder.output || returned

      conclude(definition, run, result, error, threw, recorder.expect_text || returned, failure: failure)
      begin
        ignored = record_finish(definition, run, recorded, finished_at)
        report(RuntimeError.new("run #{run.id} of #{name} #{ignored}; ignored"), "finishing #{name}") if ignored
      rescue StandardError => e
        report(e, "recording #{name}")
      end

      raise error if threw && interrupted?(error)

      ExecuteResult.new(run: run, result: result, error: error, threw: threw)
    end

    # A handle on a run started elsewhere, as job(name).resume(run_id). The
    # job must be declared in this process, or it raises ArgumentError.
    def resume_run(name, run_id)
      name = name.to_s if name.is_a?(Symbol)
      definition = @registry.synchronize { @definitions[name] }
      raise ArgumentError, "resume_run: job \"#{name}\" is not declared; call job first" unless definition

      resume_handle(definition, run_id)
    end

    # JobHandle#start: records a running run and returns a RunHandle to
    # finish it. Two starts with one id at once in this process record one
    # run: the second waits for the first, then finds its run.
    #
    # @api private For JobHandle#start, not apps.
    def start_run(definition, trigger: nil, id: nil)
      after_fork_check
      trigger = "start" if trigger.nil?
      return record_start(definition, trigger, nil) if id.nil?

      check_run_id(definition.name, id, "start")
      # Keyed by job as well, so another job's start with the same id is not
      # handed this job's run: it fails as it would one call later.
      key = "#{definition.name}\n#{id}"
      entry = @registry.synchronize do
        slot = (@starting[key] ||= [Mutex.new, 0])
        slot[1] += 1
        slot
      end
      begin
        entry[0].synchronize { record_start(definition, trigger, id) }
      ensure
        @registry.synchronize do
          entry[1] -= 1
          @starting.delete(key) if entry[1].zero? && @starting[key].equal?(entry)
        end
      end
    end

    # JobHandle#resume and resume_run. A store that cannot be read is
    # reported, and the handle's finish reads it again.
    #
    # @api private For JobHandle#resume, not apps.
    def resume_handle(definition, run_id)
      after_fork_check
      check_run_id(definition.name, run_id, "resume")
      begin
        ensure_ready
        stored = @store.get_run(run_id)
      rescue StandardError => e
        report(e, "resuming #{definition.name}")
        return run_handle(definition, run_id, nil, true, nil)
      end
      return run_handle(definition, run_id, nil, true, "was not found") unless stored

      existing_handle(definition, stored)
    end

    # Record a run that happened outside this process, for a source. Its job
    # must be declared with job first. Runs are keyed by id: a new one is
    # inserted, a stored one still running (or marked timeout by a check) is
    # finished when this one is not running, and anything else is left alone,
    # so recording the same run twice changes nothing. Finishing is
    # conditional (the store's update_run_if): when two processes record the
    # same finish, only the one whose write lands evaluates it, and the other
    # reports it as already finished. A stored run of another job is left
    # alone and reported. A finished run is judged as if it had been wrapped
    # here (expect, failures, duration, budgets) and its output and error are
    # redacted the same way; one finishing after a check marked it timeout is
    # judged only when it succeeded, as RunHandle#finish does. A metric that
    # is not a finite number raises ArgumentError before anything is written,
    # as JobContext#metric does. `evaluate: false` stores it without judging
    # it, for history imported on first sight. Returns the alerts it sent.
    #
    # `run` is a Cronwatch::Run, or a hash of its fields (camelCase or snake_case keys).
    def record_run(run, evaluate: true)
      after_fork_check
      input = run.is_a?(Run) ? run : Run.from_h(run.is_a?(Hash) ? run.to_h { |k, v| [Naming.camel(k), v] } : run)
      declared = @registry.synchronize { @definitions[input.job] }
      raise ArgumentError, "record_run: job \"#{input.job}\" is not declared; call job first" unless declared
      if input.id.to_s.include?("\0")
        raise ArgumentError, "record_run: run ids cannot contain a NUL character (job \"#{input.job}\")"
      end
      # Refused as JobContext#metric refuses them: a store keeps NaN and Infinity as null.
      unless input.metrics.nil? || input.metrics.is_a?(Hash)
        raise ArgumentError, "record_run: metrics must be a Hash of numbers (job \"#{input.job}\", run \"#{input.id}\")"
      end

      (input.metrics || {}).each do |metric, value|
        next if value.is_a?(Numeric) && value.real? && JS.finite?(value)

        raise ArgumentError, "record_run: metric \"#{metric}\" must be a finite number (job \"#{input.job}\", run \"#{input.id}\")"
      end

      sync(declared)
      run = input.dup
      run.status = run.status&.to_sym
      run.metrics = (run.metrics || {}).transform_keys(&:to_s)
      run.output = Output.utf8(run.output.to_s) unless run.output.nil?
      run.error = Output.utf8(run.error.to_s) unless run.error.nil?
      if run.status == :ok
        unmet = Serialize.check_expectation(declared.expect, run.output)
        if unmet
          run.status = :failed
          run.error = unmet
        end
      end
      run.output = Output.redact_and_cap(run.output, @redact) unless run.output.nil?
      run.error = Output.redact_and_cap(run.error, @redact) unless run.error.nil?
      definition = Serialize.to_stored(declared)

      stored = @store.get_run(run.id)
      return record_over(definition, stored, run, evaluate) if stored

      begin
        @store.insert_run(run)
      rescue StandardError
        # Another process recorded it first.
        again = begin
          @store.get_run(run.id)
        rescue StandardError
          nil
        end
        return record_over(definition, again, run, evaluate) if again

        raise
      end
      return [] unless evaluate

      update_state(run.job) { |before| [Evaluate.on_run_start(before), nil] }
      return [] if run.status == :running

      finish_run(definition, run, now)
    end

    # Hands an error to on_error, as a source reports what went wrong. See #report.
    def on_error(error, where)
      report(error, where)
    end

    # Look for missed and stuck runs across every job, send alerts, retry
    # alerts no channel accepted, and prune old runs. Call it from start(), a
    # scheduled job (Cronwatch::CheckJob), or by hand. Concurrent calls share
    # one check.
    def check
      after_fork_check
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
        rescue Exception => e # rubocop:disable Lint/RescueException -- the waiters must not hang
          # An Interrupt or a Timeout is meant for this thread only, so the
          # waiters get an error of their own and this thread the original.
          flight.reject(interrupted?(e) ? InterruptedError.new("the check was interrupted by #{e.class}") : e)
          raise if interrupted?(e)
        ensure
          @check_lock.synchronize { @checking = nil if @checking.equal?(flight) }
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
      after_fork_check
      ensure_ready
      jobs = stored_jobs
      at = now
      count = clamp_limit(limit, 20, 0)
      jobs.map { |stored| snapshot(stored, at, count) }
    end

    # A job's summary, or nil for one the store does not have. One declared
    # here and forgotten elsewhere is written again, as stored_jobs does.
    def job_summary(name)
      ensure_ready
      definition = @registry.synchronize { @definitions[name] }
      sync(definition, confirm: true) if definition
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

    # Stop alerts for a job for a while. State keeps updating underneath. The
    # end is a whole millisecond, held at 2**53 - 1 (see Evaluate.silence_end).
    #   silence("nightly-report", for: "2h")   # or silence("nightly-report", "2h")
    def silence(name, duration = nil, **options)
      unknown = options.keys - SILENCE_OPTIONS
      raise ArgumentError, "silence takes for:, not #{unknown.map(&:inspect).join(", ")}" if unknown.any?
      raise ArgumentError, "silence takes a duration or for:, not both" if !duration.nil? && options.key?(:for)

      duration = options[:for] if duration.nil?
      ms = Duration.parse(duration, "silence duration")
      patch_state(name) { |state| state.silenced_until = Evaluate.silence_end(now, ms) }
    end

    def unsilence(name)
      patch_state(name) { |state| state.silenced_until = nil }
    end

    # Remove a job and its runs from the store. A job still declared in code
    # comes back: here on its next run, and in any other process that
    # declares it on its next run there, or at that process's next check or
    # dashboard read.
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
    # Calling it again while it runs does nothing, and a different interval
    # is reported to on_error and ignored: stop first to change it. A forked
    # child (Puma, Unicorn, Sidekiq) has no thread, so call start there.
    def start(every = "1m")
      after_fork_check
      ms = [5_000, Duration.parse(every, "check interval")].max
      @ticker_lock.synchronize do
        if @ticker
          unless @ticker_ms == ms
            report(ArgumentError.new("start(#{every.inspect}) ignored: already checking every #{Duration.format(@ticker_ms)}; " \
                                     "call stop first to change it"), "start")
          end
          return nil
        end

        @ticker_ms = ms
        if @defer_delivery && !@warned_deferred_start
          @warned_deferred_start = true
          warn '[cronwatch] start() was called with deliver: "check", so these checks send no alerts. ' \
               'Another process must run checks with deliver: "now" (the default) to send them.'
        end
        @ticker = Ticker.new(ms / 1000.0, @first_tick_s) do
          check
        rescue StandardError => e
          report(e, "check")
        end
      end
      nil
    end

    def stop
      stop_ticker
      nil
    end

    # Stop the interval, wait for a check already under way (a failed one is
    # reported by whoever started it), then close the store. Runs being
    # recorded are not waited for.
    def close
      stop_ticker&.join
      flight = @check_lock.synchronize { @checking }
      if flight && !flight.owner.equal?(Thread.current)
        begin
          flight.value
        rescue StandardError
          nil
        end
      end
      @store.close if @store.respond_to?(:close)
      nil
    end

    # True in development or test. See Cronwatch::Environment.
    def self.development?
      Environment.development?
    end

    # Hands an error to on_error. An on_error that raises is not allowed to
    # take the job down with it.
    #
    # @api private For integrations (Cronwatch::Web, ActiveJob, Sidekiq), not apps.
    def report(error, where)
      @on_error.call(error, where)
    rescue StandardError => e
      warn "[cronwatch] on_error raised #{e.class}: #{e.message} (reporting #{where}: #{error.message})"
    end

    private

    # Stops the interval thread and returns it, or nil when there was none.
    def stop_ticker
      after_fork_check
      ticker = @ticker_lock.synchronize do
        current = @ticker
        @ticker = nil
        current
      end
      ticker&.stop
      ticker
    end

    # Locks, the check in flight, the interval thread and the channel and
    # triage threads belong to one process. A forked child (Puma, Unicorn,
    # Sidekiq) starts with fresh ones, so start and check work there.
    def reset_process_state
      @pid = Process.pid
      @locks = {}
      # Each job's turn to write its declaration. See sync.
      @syncing = {}
      @check_lock = Mutex.new
      @checking = nil
      @ticker_lock = Mutex.new
      @ticker = nil
      @ticker_ms = nil
      @ready_lock = Mutex.new
      @sending_lock = Mutex.new
      # start_run calls with an id still in flight: id => [Mutex, callers].
      @starting = {}
      # Channel (by index) and triage threads that timed out and are still going.
      @abandoned = {}
    end

    def after_fork_check
      return if @pid == Process.pid

      FORK_LOCK.synchronize { reset_process_state unless @pid == Process.pid }
    end

    # An exception outside StandardError: the thread is being stopped
    # (Interrupt, SystemExit, Sidekiq::Shutdown, a Timeout) or the code is
    # broken (NotImplementedError, LoadError).
    def interrupted?(error)
      !error.is_a?(StandardError)
    end

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
        if @using_default_store && Environment.production?
          warn "[cronwatch] using the in-memory store: runs and state are lost on restart. " \
               "Pass a store such as Cronwatch::Stores::ActiveRecord."
        end
        # Only once init has gone through: a failure is tried again on the next call.
        @ready = true
      end
    end

    # Writes the declaration of `definition`'s name as it stands, unless the
    # store has it. A handle kept from an earlier declaration writes the one
    # that replaced it, never its own over it, and one forgotten since writes
    # its own. The writes of one name take turns (the name's lock in
    # @syncing, held across the write), so one still under way cannot land
    # after a later one; and a name declared again while its write was under
    # way is still to be written. A name is marked as written only while
    # that same declaration stands, so a forget that lands during the write
    # (deleting the row after it) leaves the name to be written again, as
    # does one forgotten before it.
    #
    # With `confirm`, as a run starts, a name already written is read back:
    # another process may have forgotten the job since, and a job still
    # declared here comes back on its next run.
    def sync(definition, confirm: false)
      ensure_ready
      name = definition.name
      if @registry.synchronize { @synced.include?(name) }
        return if !confirm || @store.get_job(name)

        @registry.synchronize { @synced.delete(name) }
      end

      after_fork_check
      turn = @registry.synchronize { @syncing[name] ||= Mutex.new }
      turn.synchronize do
        standing = @registry.synchronize { @synced.include?(name) ? nil : @definitions.fetch(name, definition) }
        next if standing.nil?

        @store.upsert_job(Serialize.to_stored(standing), now)
        @registry.synchronize { @synced << name if @definitions[name].equal?(standing) }
      end
    end

    # Every stored job, once each declaration has been written. A job
    # declared here that the store no longer has was forgotten by another
    # process after this one wrote it: it is written again, as its next run
    # would, so it is checked and shown while any process still declares it.
    def stored_jobs
      defined_jobs.each { |definition| sync(definition) }
      jobs = @store.list_jobs
      listed = jobs.to_set(&:name)
      missing = defined_jobs.reject { |definition| listed.include?(definition.name) }
      return jobs if missing.empty?

      missing.each do |definition|
        name = definition.name
        # Not one forgotten here meanwhile.
        standing = @registry.synchronize { @definitions[name].equal?(definition) && @synced.delete(name) }
        sync(definition) if standing
      end
      @store.list_jobs
    end

    # Runs the block while holding the job's lock, so two runs (or a run and a
    # check) in this process never read and write the job's state over each
    # other. Other processes are coordinated by update_state instead. Only
    # store reads and writes happen inside; alerts are sent outside it. sync
    # gives a job's declaration writes turns the same way, on a lock of their own.
    def serial(job, &block)
      after_fork_check
      lock = @registry.synchronize { @locks[job] ||= Monitor.new }
      lock.synchronize(&block)
    end

    def read_state(job)
      Evaluate.normalize_state(@store.get_state(job), job)
    end

    def same_state?(a, b)
      JS.json(a.to_h) == JS.json(b.to_h)
    end

    # Every read-modify-write of a job's state goes through here. In turn with
    # this process's other updates to the job (serial), it reads the state,
    # yields it for the next one and a result (`[state, result]`), and writes
    # that with the version one higher, only if the stored version is still
    # the one read. When another process wrote in between, the write is
    # refused and it starts again from a fresh read, up to STATE_ATTEMPTS
    # times. So the block may run more than once and must only compute:
    # whatever it returns from the attempt that was written is the result.
    # Nothing is written when the state is unchanged. Returns
    # `[state as stored, result]`.
    def update_state(job)
      serial(job) do
        attempt = 0
        loop do
          attempt += 1
          current = read_state(job)
          state, result = yield(current)
          break [current, result] if same_state?(state, current)

          version = Evaluate.state_version(current)
          following = state.dup
          following.version = version + 1
          break [following, result] if write_state(following, version)
          if attempt >= STATE_ATTEMPTS
            raise "the state of #{job} changed under #{STATE_ATTEMPTS} attempts in a row to update it; gave up"
          end
        end
      end
    end

    # A conditional write, or for a store without compare_and_set_state, a
    # plain one that always succeeds.
    def write_state(state, expected_version)
      return @store.compare_and_set_state(state, expected_version) if @store.respond_to?(:compare_and_set_state)

      @store.set_state(state)
      true
    end

    # A custom redact, made safe: one that raises or returns something other
    # than a String is reported and the default is used instead, so a broken
    # redact neither stops the run finishing nor leaks what it was given.
    def guarded_redact(redact)
      lambda do |text|
        out = redact.call(text)
        raise TypeError, "redact must return a string, not #{out.nil? ? "null" : out.class}" unless out.is_a?(String)

        Output.utf8(out)
      rescue StandardError => e
        report(e, "redact")
        Output.redact_secrets(text)
      end
    end

    # Identifies an alert across retries.
    def alert_key(alert)
      "#{alert.type}|#{alert.at}|#{alert.run&.id}"
    end

    # record_run for a run already stored.
    def record_over(definition, stored, run, evaluate)
      if stored.job != run.job
        report(RuntimeError.new("run #{run.id} of #{run.job} belongs to job \"#{stored.job}\"; ignored"), "recording #{run.job}")
        return []
      end
      return [] if !%i[running timeout].include?(stored.status) || run.status == :running

      late, ignored = claim_finish(run)
      if ignored
        report(RuntimeError.new("run #{run.id} of #{run.job} #{ignored}; ignored"), "recording #{run.job}")
        return []
      end
      return [] if !evaluate || (late && run.status != :ok)

      finish_run(definition, run, now)
    end

    # A conditional write (the store's update_run_if), or for a store
    # without one, a read then a plain write, which is safe only while one
    # process at a time finishes a given run.
    def write_run_if(run, from_statuses)
      return @store.update_run_if(run, from_statuses) if @store.respond_to?(:update_run_if)

      stored = @store.get_run(run.id)
      return false if stored.nil? || !from_statuses.include?(stored.status)

      @store.update_run(run)
      true
    end

    # Writes a finished run over its stored row, only while that row is
    # still running, or else still marked timeout by a check. Only the
    # process whose write lands goes on to evaluate the run. Returns
    # `[late_after_timeout, nil]` once written, or `[nil, why]` when nothing
    # was: late_after_timeout means a check already counted the run as a
    # stuck failure, so a late failure must not count twice while a late
    # success still closes stuck and recovers. Raises when the store does.
    def claim_finish(run)
      return [false, nil] if write_run_if(run, [:running])
      return [true, nil] if write_run_if(run, [:timeout])

      stored = @store.get_run(run.id)
      [nil, stored ? "was already finished as #{stored.status}" : "was not found"]
    end

    # Sets a finished run's status and error from how it ended, then redacts
    # its output and error and caps them, in that order. Shared by execute
    # and RunHandle#finish.
    def conclude(definition, run, result, error, threw, expect_text, failure: nil)
      if threw
        run.status = :failed
        run.error = Output.describe_error(error)
      elsif (problem = failure&.call(result))
        run.status = :failed
        run.error = Output.utf8(problem.to_s)
      else
        unmet = Serialize.check_expectation(definition.expect, expect_text)
        if unmet
          run.status = :failed
          run.error = unmet
        else
          run.status = :ok
        end
      end
      # Redacted after the expect check, so a rule can still match what was
      # logged, and before the cap, so the cut cannot keep half a secret. NULs
      # go last, so not even a custom redact can store one.
      run.output = Output.redact_and_cap(run.output, @redact) unless run.output.nil?
      run.error = Output.redact_and_cap(run.error, @redact) unless run.error.nil?
    end

    # Writes a finished run and evaluates it. `recorded` says whether its
    # start was written; if not, it is inserted now. Returns why nothing was
    # recorded (another process finished the run first, say), or nil. Raises
    # when the store does, so a handle can be finished again. Shared by
    # execute and RunHandle#finish.
    def record_finish(definition, run, recorded, finished_at)
      unless recorded
        # The start was never written; the store may be back by now.
        sync(definition)
        begin
          @store.insert_run(run)
          finish_run(Serialize.to_stored(definition), run, finished_at)
          return nil
        rescue StandardError => e
          # Another process may have recorded a run with this id meanwhile.
          stored = begin
            @store.get_run(run.id)
          rescue StandardError
            nil
          end
          raise e unless stored
          return "belongs to job \"#{stored.job}\"" if stored.job != run.job
        end
      end
      late, ignored = claim_finish(run)
      return ignored if ignored

      finish_run(Serialize.to_stored(definition), run, finished_at) if !late || run.status == :ok
      nil
    end

    # The start of execute without the block: the run is inserted and missed
    # and stuck close (on_run_start). A store that fails is reported and the
    # handle inserts the finished run instead, as execute does.
    def record_start(definition, trigger, id)
      name = definition.name
      unless id.nil?
        stored = nil
        begin
          ensure_ready
          stored = @store.get_run(id)
        rescue StandardError => e
          report(e, "recording #{name}")
        end
        return existing_handle(definition, stored) if stored
      end
      run = Run.new(id: id || SecureRandom.uuid, job: name, status: :running, started_at: now, finished_at: nil,
                    duration_ms: nil, error: nil, output: nil, metrics: {}, trigger: trigger)
      recorded = false
      begin
        sync(definition, confirm: true)
        @store.insert_run(run.dup)
        recorded = true
      rescue StandardError => e
        # Another process may have started a run with this id first.
        stored = begin
          id.nil? ? nil : @store.get_run(id)
        rescue StandardError
          nil
        end
        return existing_handle(definition, stored) if stored

        report(e, "recording #{name}")
      end
      if recorded
        begin
          update_state(name) { |before| [Evaluate.on_run_start(before), nil] }
        rescue StandardError => e
          report(e, "starting #{name}")
        end
      end
      run_handle(definition, run.id, run, recorded, nil, started: true)
    end

    # A handle on a stored run. One still running, or marked timeout by a check, can be finished.
    def existing_handle(definition, stored)
      if stored.job != definition.name
        raise ArgumentError, "run \"#{stored.id}\" belongs to job \"#{stored.job}\", not \"#{definition.name}\""
      end

      finished = %i[ok failed].include?(stored.status)
      run_handle(definition, stored.id, stored, true, finished ? "already finished as #{stored.status}" : nil)
    end

    # The handle itself. `base` is the run as last known here, `recorded`
    # whether its start is in the store, and `inactive` why finish has
    # nothing to do, or nil. The handle keeps its lines and metrics until
    # flush or finish merges them onto a fresh read of the stored run.
    # `started` is true for a handle whose run this process inserted.
    def run_handle(definition, id, base, recorded, inactive, started: false)
      name = definition.name
      RunHandle.new(
        id: id, job: name, started_at: base&.started_at, inactive: inactive,
        finish: ->(recorder, outcome, head) { finish_handle(definition, id, base, recorded, recorder, outcome, head, started) },
        flush: recorded ? ->(lines, metrics) { flush_handle(name, id, lines, metrics) } : nil,
        ignored: ->(why) { ignore_finish(id, name, why) },
      )
    end

    # A finish that records nothing, reported rather than raised.
    def ignore_finish(id, name, why)
      report(RuntimeError.new("run #{id} of #{name} #{why}; ignored"), "finishing #{name}")
      nil
    end

    # RunHandle#finish, in turn with the handle's flushes: the stored run,
    # read again, with the handle's lines and metrics added, judged like any
    # run. `head` is the start of what the handle flushed, for expect.
    # Returns the run as recorded, or nil when nothing was. A store that
    # fails is reported and raises RunHandle::Retry, which leaves the handle
    # active to be finished again.
    def finish_handle(definition, id, base, recorded, recorder, outcome, head = nil, started = false)
      name = definition.name
      from = base
      if recorded
        begin
          stored = @store.get_run(id)
          if stored
            from = stored
          elsif started
            # Inserted by this process, yet gone: the start was written
            # inside a transaction that rolled back (on SQLite the store
            # joins the app's). Insert it now, as execute does for a start
            # it could not record.
            recorded = false
          end
        rescue StandardError => e
          retry_finish(e, name)
        end
      end
      return ignore_finish(id, name, "was not found") if from.nil?
      return ignore_finish(id, name, "belongs to job \"#{from.job}\"") if from.job != name
      return ignore_finish(id, name, "was already finished as #{from.status}") if %i[ok failed].include?(from.status)

      failed, result, error = RunHandle.read_outcome(outcome)
      finished_at = now
      returned = result.is_a?(String) ? Output.utf8(result) : nil
      added = recorder.output || returned
      run = from.dup
      run.status = :running
      run.finished_at = finished_at
      run.duration_ms = Evaluate.run_duration(from.started_at, finished_at)
      run.error = nil
      # Capped by conclude, after it is redacted.
      run.output = join_lines(from.output, added)
      run.metrics = (from.metrics || {}).merge(recorder.metrics)
      expect_text = join_lines(head, join_lines(from.output, recorder.expect_text || returned))
      conclude(definition, run, result, error, failed, expect_text)
      why = begin
        record_finish(definition, run, recorded, finished_at)
      rescue StandardError => e
        retry_finish(e, name)
      end
      return ignore_finish(id, name, why) if why

      run
    end

    # The store failed part way through a finish and nothing was recorded:
    # reported, and the handle left active so finish can be called again.
    def retry_finish(error, name)
      report(error, "finishing #{name}")
      raise RunHandle::Retry
    end

    # RunHandle#flush: appends lines and metrics to the stored run while it
    # is still running and belongs to this job, written only over a row still
    # running, so a flush never undoes a finish. True once written; false
    # when the handle should keep them for finish (the run is not running or
    # is another job's, or the store failed).
    def flush_handle(name, id, lines, metrics)
      stored = @store.get_run(id)
      # Not running: the lines stay in the handle for finish, which reports why it cannot record them.
      return false if stored.nil? || stored.status != :running

      if stored.job != name
        report(RuntimeError.new("run #{id} of #{name} belongs to job \"#{stored.job}\"; ignored"), "flushing #{name}")
        return false
      end

      updated = stored.dup
      updated.output = join_output(stored.output, Output.redact_and_cap(lines, @redact)) unless lines.nil?
      updated.metrics = (stored.metrics || {}).merge(metrics)
      write_run_if(updated, [:running])
    rescue StandardError => e
      report(e, "flushing #{name}")
      false
    end

    # Raises for a run id no store could hold, or one reserved for the pg_cron source.
    def check_run_id(job, id, method)
      unless id.is_a?(String) && !id.empty? && JS.length16(id) <= 200
        got = id.is_a?(String) ? "#{JS.length16(id)} characters" : id.class.to_s
        raise ArgumentError, "job \"#{job}\": #{method}() needs a run id of 1 to 200 characters (got #{got})"
      end
      # Postgres refuses NUL in text, so no store could hold such an id.
      raise ArgumentError, "job \"#{job}\": #{method}() cannot take a run id containing a NUL character" if id.include?("\0")
      return unless id.start_with?(RESERVED_RUN_ID_PREFIX)

      raise ArgumentError, "job \"#{job}\": #{method}() cannot take a run id starting with \"#{RESERVED_RUN_ID_PREFIX}\", " \
                           "which the pg_cron source uses for its runs"
    end

    # Two stretches of text as one, a line apart; either may be nil.
    def join_lines(before, after)
      return after if before.nil? || before.empty?
      return before if after.nil?

      "#{before}\n#{after}"
    end

    # Output appended to stored output, capped like any run's.
    def join_output(before, after)
      joined = join_lines(before, after)
      joined && Output.cap(joined)
    end

    # Evaluate a finished run (ok, failed, or timed out by a check), already
    # written, against the job's state and send what that produces. Never raises.
    def finish_run(definition, run, at)
      drafts = nil
      begin
        past = nil
        _, drafts = update_state(run.job) do |previous|
          past ||= history(run)
          settled = Evaluate.apply_silence(previous, Evaluate.on_run_finish(definition, run, previous, past, at), at)
          [settled.state, settled.alerts]
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
      alerts = []
      # Sources first, so what they record is evaluated in this check.
      @sources.each do |source|
        found = source.sync(self)
        alerts.concat(Array(found)) if found.is_a?(Array)
      rescue StandardError => e
        report(e, "source #{channel_name(source)}")
      end
      defined_jobs.each { |definition| sync(definition) }
      at = now

      # Runs that never reported back. One that cannot be judged (its job's
      # stored timeout no longer parses, say) is reported and skipped.
      @store.running_runs.each do |listed|
        declared = @registry.synchronize { @definitions[listed.job] }
        definition = declared ? Serialize.to_stored(declared) : @store.get_job(listed.job)&.definition
        next if definition.nil?

        evaluable(listed.job, definition)
        next unless Evaluate.stuck?(definition, listed, at)

        # Read again just before the write: lines and metrics flushed since the
        # list was read (while earlier stuck runs were sent, say) are kept.
        run = @store.get_run(listed.id)
        next if run.nil? || run.status != :running || run.job != listed.job

        timeout = Evaluate.timeout_ms(definition)
        run.status = :timeout
        run.finished_at = at
        run.duration_ms = Evaluate.run_duration(run.started_at, at)
        run.error = "Still running after #{Duration.format(timeout)}; marked as timed out"
        # Only over a row still running: a finish that landed meanwhile wins.
        next unless write_run_if(run, [:running])

        alerts.concat(finish_run(definition, run, at))
      rescue StandardError => e
        report(e, "checking #{listed.job}")
      end

      # Each job on its own: one that cannot be evaluated (a stored schedule
      # this process cannot read, one a Node process wrote, say) is reported,
      # shown as failing (see Evaluate.unevaluable_summary) and does not stop
      # the others.
      jobs = []
      retries = RetryBudget.new(0)
      stored_jobs.each do |stored|
        evaluable(stored.name, stored.definition)
        recent = @store.list_runs(stored.name, Evaluate::BASELINE_WINDOW)
        next_expected_at = nil
        state, drafts = update_state(stored.name) do |previous|
          evaluation = Evaluate.on_check(stored.definition, stored, recent.first, previous, at)
          next_expected_at = evaluation.next_expected_at
          settled = Evaluate.apply_silence(previous, evaluation, at)
          [settled.state, settled.alerts]
        end
        alerts.concat(retry_undelivered(stored.name, state, at, retries))
        alerts.concat(dispatch(drafts, stored.definition, at))
        jobs << Evaluate.summarize(stored, recent, state, next_expected_at, at)
      rescue StandardError => e
        report(e, "checking #{stored.name}")
        jobs << unevaluable(stored, at)
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

    # A job's summary and its newest runs, without alerting. A job that cannot
    # be evaluated (a stored schedule this process cannot read, say) is
    # reported and shown as failing.
    def snapshot(stored, at, count)
      recent = []
      begin
        recent = @store.list_runs(stored.name, [count, Evaluate::BASELINE_WINDOW].max)
        evaluable(stored.name, stored.definition)
        state = read_state(stored.name)
        next_expected_at = Evaluate.on_check(stored.definition, stored, recent.first, state, at).next_expected_at
        JobWithRuns.new(job: Evaluate.summarize(stored, recent, state, next_expected_at, at), runs: recent.first(count))
      rescue StandardError => e
        report(e, "reading #{stored.name}")
        JobWithRuns.new(job: unevaluable(stored, at), runs: recent.first(count))
      end
    end

    # Raises for a stored definition that was not a JSON object (see
    # JobDefinition.from_h), so that one job is reported and shown as
    # failing, and the others are checked as usual.
    def evaluable(name, definition)
      raise ArgumentError, "job \"#{name}\": its stored definition is not a JSON object" if definition.unreadable?
    end

    # The summary of a job whose evaluation failed, from whatever can still be read.
    def unevaluable(stored, at)
      recent = begin
        @store.list_runs(stored.name, Evaluate::BASELINE_WINDOW)
      rescue StandardError
        []
      end
      state = begin
        read_state(stored.name)
      rescue StandardError
        Evaluate.empty_state(stored.name)
      end
      Evaluate.unevaluable_summary(stored, recent, state, at)
    end

    # Read, change and write one job's state, in turn with every other update to it.
    def patch_state(name)
      ensure_ready
      state, = update_state(name) do |current|
        following = Evaluate.normalize_state(current, name)
        yield following
        [following, nil]
      end
      state
    end

    # Compose, triage and send each draft. The state was saved before this
    # (update_state), so a slow channel holds up nothing else; afterwards only
    # the delivery fields are written back, onto a fresh read of the state.
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
          add_triage(alert, @triage_timeout_ms) if @triage && alert.type != :recovered
          (deliver(alert) ? delivered : failed) << alert
        end
        composed << alert
      end
      record_delivery(definition.name, delivered, failed, [], at)
      composed
    end

    # The wall-clock milliseconds one check has spent retrying, across its jobs.
    RetryBudget = Struct.new(:spent_ms)

    # Send the alerts that no channel accepted last time, once each, oldest
    # first. `state` is the job's state as this check left it: an alert that
    # no longer describes it (Evaluate.stale_alert?) is dropped instead.
    # Retries across a check share RETRY_BUDGET_MS of wall-clock time; once it
    # is spent the rest stay queued for the next check.
    def retry_undelivered(name, state, at, budget)
      pending = state.undelivered || []
      return [] if pending.empty? || Evaluate.silenced?(state, at) || @defer_delivery

      delivered = []
      failed = []
      dropped = pending.select { |alert| Evaluate.stale_alert?(alert, state) }
      pending.each do |alert|
        next if dropped.any? { |d| d.equal?(alert) }

        left = @retry_budget_ms - budget.spent_ms
        break if left <= 0

        started = AbortSignal.monotonic
        # An alert queued by a process that delivers at check time was never
        # triaged. One that was tried (triage: null) is not tried again.
        add_triage(alert, [@triage_timeout_ms, left].min) if @triage && alert.type != :recovered && !alert.triage_tried?
        (deliver(alert) ? delivered : failed) << alert
        budget.spent_ms += [0, ((AbortSignal.monotonic - started) * 1000).round].max
      end
      record_delivery(name, delivered, failed, dropped, at)
      delivered
    end

    # Mark delivered alerts done, drop stale ones, and keep failed ones for the
    # next check. A failed alert replaces its stored copy, so a triage made on
    # this attempt is kept. last_alert_at moves only on a delivery.
    def record_delivery(name, delivered, failed, dropped, at)
      _, trimmed = update_state(name) do |previous|
        state = Evaluate.normalize_state(previous, name)
        done = (delivered + dropped).map { |a| alert_key(a) }.to_set
        retried = failed.to_h { |a| [alert_key(a), a] }
        kept = state.undelivered.reject { |a| done.include?(alert_key(a)) }.map { |a| retried.fetch(alert_key(a), a) }
        known = kept.map { |a| alert_key(a) }.to_set
        kept.concat(failed.reject { |a| known.include?(alert_key(a)) })
        state.undelivered = kept.last(MAX_UNDELIVERED)
        state.last_alert_at = at if delivered.any?
        [state, [0, kept.length - MAX_UNDELIVERED].max]
      end
      if trimmed.positive?
        report(RuntimeError.new("#{trimmed} undelivered alert#{trimmed == 1 ? "" : "s"} for #{name} dropped: " \
                                "only the newest #{MAX_UNDELIVERED} are kept for retry"), "alert queue for #{name}")
      end
    rescue StandardError => e
      report(e, "recording alert delivery for #{name}")
    end

    # Send to every channel at once, each in its own thread with its own
    # timeout. True when at least one accepted it, or there are none. A
    # channel that times out is left to finish on its own, and nothing more
    # is sent to it until it has: meanwhile its alerts count as not
    # delivered there, to be retried by a later check. So a hung channel
    # holds one thread, not one per alert.
    def deliver(alert)
      return true if @alerts.empty?

      outcomes = Array.new(@alerts.length)
      threads = @alerts.each_with_index.map do |channel, i|
        if @sending_lock.synchronize { @abandoned[i]&.alive? }
          outcomes[i] = TimeoutError.new("skipped: an earlier alert timed out and is still being sent")
          next nil
        end

        Thread.new do
          Thread.current.report_on_exception = false
          send_to(channel, alert)
          outcomes[i] = true
        rescue StandardError, ScriptError => e
          outcomes[i] = e
        end
      end
      deadline = AbortSignal.monotonic + (@channel_timeout_ms / 1000.0)
      results = threads.each_with_index.map do |thread, i|
        next outcomes[i] if thread.nil?
        next outcomes[i] if thread.join([deadline - AbortSignal.monotonic, 0].max)

        @sending_lock.synchronize { @abandoned[i] = thread }
        TimeoutError.new("timed out after #{@channel_timeout_ms}ms")
      end
      results.each_with_index do |result, i|
        report(result, "alert channel #{channel_name(@alerts[i])}") unless result == true
      end
      results.include?(true)
    end

    # channel.call(alert, context), the context's on_error reporting a problem
    # that did not stop the alert going out (one of several recipients
    # refusing it, say). A channel whose call takes only the alert, as custom
    # channels written before the context did, is called with the alert alone.
    def send_to(channel, alert)
      name = channel_name(channel)
      context = ChannelContext.new(->(error) { report(error, "alert channel #{name}") })
      if Client.takes_context?(channel)
        channel.call(alert, context)
      else
        channel.call(alert)
      end
    end

    # Whether a channel's call (or a Proc or Method itself) accepts a second argument.
    #
    # @api private
    def self.takes_context?(channel)
      params = channel.is_a?(Proc) || channel.is_a?(Method) ? channel.parameters : channel.method(:call).parameters
      params.any? { |kind, _| kind == :rest } || params.count { |kind, _| %i[req opt].include?(kind) } >= 2
    rescue NameError
      false
    end

    def channel_name(channel)
      channel.respond_to?(:name) && channel.name ? channel.name : channel.class.name
    end

    # Sets the alert's triage to the diagnosis, or to nil (JSON null) when
    # there is none (it raised, timed out or answered nil or ""), so it is
    # tried once per alert. While a triage that timed out is still going,
    # alerts go out without one rather than start another beside it.
    def add_triage(alert, timeout_ms)
      signal = AbortSignal.new
      if @sending_lock.synchronize { @abandoned[:triage]&.alive? }
        raise TimeoutError, "skipped: an earlier triage timed out and is still running"
      end

      recent = @store.list_runs(alert.job, 5)
      context = TriageContext.new(alert: alert, recent_runs: recent, signal: signal)
      outcome = nil
      thread = Thread.new do
        Thread.current.report_on_exception = false
        outcome = [:ok, @triage.call(context)]
      rescue StandardError, ScriptError => e
        outcome = [:error, e]
      end
      unless thread.join(timeout_ms / 1000.0)
        @sending_lock.synchronize { @abandoned[:triage] = thread }
        raise TimeoutError, "timed out after #{timeout_ms}ms"
      end
      raise outcome[1] if outcome[0] == :error

      diagnosis = outcome[1]
      alert.triage_result = diagnosis.is_a?(String) && !diagnosis.empty? ? Output.utf8(diagnosis) : nil
    rescue StandardError => e
      signal&.abort!
      alert.triage_result = nil
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
  end
end
