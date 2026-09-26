# frozen_string_literal: true

module Cronwatch
  # What Cronwatch::ActiveJob and Cronwatch::Sidekiq share: the `cronwatch`
  # class macro, the list of classes that called it, and when their jobs are
  # declared on Cronwatch.client. Needs nothing beyond the core, so Sidekiq
  # without Rails can use it.
  module Monitored
    # What `cronwatch` is outside a monitored run: it takes log and metric
    # calls and drops them, so the job's code runs the same either way.
    class NullContext
      def name = nil
      def run_id = nil
      def started_at = nil
      def signal = nil
      def log(*) = nil
      def metric(_name, _value) = nil
      def metrics(_values = nil, **) = nil
      def aborted? = false
    end
    NULL_CONTEXT = NullContext.new.freeze

    # Where the context goes for a job that has no `cronwatch` to hold it (one
    # declared from the scheduler's config): nowhere.
    module Discard
      def self.cronwatch_with(_context) = yield
    end

    # One job's options and its handle on the current Cronwatch.client. The
    # job is declared the first time it is needed and again whenever the
    # client is replaced. `resolve`, when given, turns the options into the
    # ones to declare (schedule: :from_scheduler reads the scheduler's config)
    # the first time they are needed; its answer is kept.
    class Declaration
      attr_reader :name, :options, :where

      def initialize(name, options, where:, resolve: nil)
        @name = name
        @options = options.freeze
        @where = where
        @resolve = resolve
        @resolved = nil
        @registration = nil
        @lock = Mutex.new
      end

      # The options the job is declared with, once resolved.
      def resolved_options
        @lock.synchronize { resolve_locked }
      end

      # [client, handle] on Cronwatch.client. With strict: false a bad
      # declaration goes to the client's on_error and the answer is nil.
      def registration(strict: true)
        client = Cronwatch.client
        @lock.synchronize do
          current = @registration
          return current if current && current[0].equal?(client)

          handle = client.job(@name, **resolve_locked)
          @registration = [client, handle].freeze
        end
      rescue StandardError => e
        raise if strict

        client.report(e, "declaring #{@where}")
        nil
      end

      private

      def resolve_locked
        @resolved ||= (@resolve ? @resolve.call(@options) : @options).freeze
      end
    end

    @monitored = {}
    @lock = Mutex.new
    @ready = false

    class << self
      # The names of the classes that declared `cronwatch`, in the order they did.
      def monitored
        @lock.synchronize { @monitored.keys }
      end

      def track(klass)
        @lock.synchronize { @monitored[klass.name] = true } if klass.name
        nil
      end

      # Called once the app has booted (by the Railtie in Rails). From then on
      # a class declares its job as soon as it calls `cronwatch`.
      def ready!
        @ready = true
      end

      def ready?
        @ready
      end

      # Once the app has booted: from now on classes declare as they load,
      # every class loaded so far declares now, and so does what
      # Cronwatch.declare_from_scheduler! asked for. A bad declaration raises.
      def boot!
        ready!
        register_all(strict: true)
        Cronwatch::Scheduler.declare_pending!
        nil
      end

      # Declares every monitored class's job on Cronwatch.client, and every
      # job Cronwatch.declare_from_scheduler! took from the scheduler's
      # config, so a check knows about jobs that have not run in this
      # process. A class that no longer loads is skipped. With strict: false a
      # bad declaration goes to the client's on_error instead of raising.
      def register_all(strict: true)
        monitored.each do |name|
          klass = begin
            Object.const_get(name)
          rescue NameError
            next
          end
          klass.cronwatch_registration(strict: strict) if klass.respond_to?(:cronwatch_registration)
        end
        Cronwatch::Scheduler.register_declared(strict: strict) if defined?(Cronwatch::Scheduler)
        nil
      end

      # Loads app/jobs (and app/workers and app/sidekiq, where Sidekiq jobs
      # often live) when the app does not eager load (development), so a check
      # sees every monitored class, not only those used since boot.
      def load_app_jobs
        return unless defined?(::Rails) && ::Rails.respond_to?(:application) && (app = ::Rails.application)
        return if app.config.eager_load

        loader = ::Rails.respond_to?(:autoloaders) && ::Rails.autoloaders.main
        return unless loader.respond_to?(:eager_load_dir)

        dirs = Array(app.paths["app/jobs"]&.existent)
        %w[app/workers app/sidekiq].each do |dir|
          path = app.root.join(dir).to_s
          dirs << path if File.directory?(path) && loader.dirs.include?(path)
        end
        dirs.uniq.each { |dir| loader.eager_load_dir(dir) }
        nil
      rescue StandardError, ScriptError => e
        Cronwatch.client.report(e, "loading app/jobs")
        nil
      end

      # NightlyReportJob is "nightly-report"; Reports::NightlyJob is "reports:nightly".
      def default_name(klass)
        raise ArgumentError, "cronwatch: an anonymous job class needs a name: option" if klass.name.nil?

        dasherize(underscore(klass.name.delete_suffix("Job"))).tr("/", ":")
      end

      # Runs the block as a recorded run of the declaration's job, with the
      # run's context as `cronwatch` on `job` (when it has one). A declaration that is broken
      # runs the block unrecorded, with the error sent to on_error. The
      # block's error is raised again after the run is recorded.
      def record(declaration, trigger, job)
        client, handle = declaration&.registration(strict: false)
        return yield unless handle

        holder = job.respond_to?(:cronwatch_with, true) ? job : Discard
        outcome = client.execute(handle.definition, trigger) do |context|
          holder.__send__(:cronwatch_with, context) { yield }
        end
        raise outcome.error if outcome.threw

        outcome.result
      end

      private

      # ActiveSupport's, when it is loaded, so the app's acronyms apply; the
      # same rules without them otherwise.
      def underscore(text)
        return ::ActiveSupport::Inflector.underscore(text) if defined?(::ActiveSupport::Inflector)

        text.gsub("::", "/").gsub(/(?<=[A-Z])(?=[A-Z][a-z])|(?<=[a-z\d])(?=[A-Z])/, "_").tr("-", "_").downcase
      end

      def dasherize(text)
        text.tr("_", "-")
      end
    end

    # The class side: `cronwatch` and what it declares.
    module ClassMethods
      # Monitor this job. Takes the options of Cronwatch::Client#job (schedule,
      # timezone, grace, timeout, max_duration, budget, expect,
      # failures_before_alert, description, tags) and name:, which defaults to
      # the class name without "Job", dasherized. schedule: :from_scheduler
      # takes the schedule (and its timezone) from the class's entry in Solid
      # Queue's config/recurring.yml or sidekiq-cron's schedule.
      def cronwatch(name: nil, **options)
        name ||= Cronwatch::Monitored.default_name(self)
        resolve = nil
        if options[:schedule] == :from_scheduler
          if options.key?(:timezone)
            raise ArgumentError, "cronwatch: #{self.name || name} takes its timezone from the scheduler with schedule: :from_scheduler; " \
                                 "drop timezone:"
          end
          klass = self
          resolve = ->(given) { given.merge(Cronwatch::Scheduler.schedule_for(klass)) }
        elsif options[:schedule].is_a?(Symbol)
          raise ArgumentError, "cronwatch: schedule #{options[:schedule].inspect} is not a schedule; did you mean :from_scheduler?"
        end
        declaration = Declaration.new(name, options, where: self.name || name, resolve: resolve)
        declaration.registration if Cronwatch::Monitored.ready? # a bad one raises here, leaving the class unmonitored
        @cronwatch_declaration = declaration
        Cronwatch::Monitored.track(self)
        nil
      end

      # The options given to `cronwatch`, with the name. Nil when this class is not monitored.
      def cronwatch_options
        declaration = @cronwatch_declaration
        declaration && declaration.options.merge(name: declaration.name).freeze
      end

      def cronwatch_name
        @cronwatch_declaration&.name
      end

      def cronwatch_declaration
        @cronwatch_declaration
      end

      # This class's job handle on the current Cronwatch.client.
      def cronwatch_handle(strict: true)
        cronwatch_registration(strict: strict)&.last
      end

      # [client, handle]: the job declared on Cronwatch.client, the first time
      # and again whenever the client is replaced.
      def cronwatch_registration(strict: true)
        @cronwatch_declaration&.registration(strict: strict)
      end
    end

    # The run's context during a monitored run: log, metric, metrics,
    # aborted?, signal. Outside one, a stand-in that drops what it is given.
    def cronwatch
      @cronwatch || NULL_CONTEXT
    end

    private

    def cronwatch_with(context)
      previous = @cronwatch
      @cronwatch = context
      begin
        yield
      ensure
        @cronwatch = previous
      end
    end
  end
end

require_relative "scheduler" unless defined?(Cronwatch::Scheduler)
