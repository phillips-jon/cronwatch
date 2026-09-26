# frozen_string_literal: true

require "active_support/concern"
require "active_support/inflector"
require "active_job"

module Cronwatch
  # Monitors an ActiveJob class. Each perform is a recorded run with the
  # trigger "active_job"; `cronwatch` in the job is the run's context, for
  # log and metric. A perform that raises is recorded as failed and then
  # raises as before, so retry_on, discard_on and error reporters see it
  # unchanged.
  #
  #   class NightlyReportJob < ApplicationJob
  #     include Cronwatch::ActiveJob
  #     cronwatch schedule: "0 2 * * *", grace: "15m", expect: "Report written" # name: "nightly-report"
  #
  #     def perform
  #       cronwatch.log("Report written")
  #       cronwatch.metric(:cost, 1.2)
  #     end
  #   end
  #
  # The job is declared on Cronwatch.client once the app has booted (after
  # config/initializers/cronwatch.rb ran), and again if the client is
  # replaced. Only classes that call `cronwatch` are monitored; subclasses
  # declare their own.
  module ActiveJob
    extend ActiveSupport::Concern

    TRIGGER = "active_job"

    # What `cronwatch` is outside a monitored perform: it takes log and metric
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

      # Called by the Railtie once the app has booted. From then on a class
      # declares its job as soon as it calls `cronwatch`.
      def ready!
        @ready = true
      end

      def ready?
        @ready
      end

      # Declares every monitored class's job on Cronwatch.client, so a check
      # knows about jobs that have not run in this process. A class that no
      # longer loads is skipped. With strict: false a bad declaration goes to
      # the client's on_error instead of raising.
      def register_all(strict: true)
        monitored.each do |name|
          klass = begin
            Object.const_get(name)
          rescue NameError
            next
          end
          klass.cronwatch_registration(strict: strict) if klass.respond_to?(:cronwatch_registration)
        end
        nil
      end

      # Loads app/jobs when the app does not eager load (development), so a
      # check sees every monitored class, not only those used since boot.
      def load_app_jobs
        return unless defined?(::Rails) && ::Rails.respond_to?(:application) && (app = ::Rails.application)
        return if app.config.eager_load

        loader = ::Rails.respond_to?(:autoloaders) && ::Rails.autoloaders.main
        return unless loader.respond_to?(:eager_load_dir)

        Array(app.paths["app/jobs"]&.existent).each { |dir| loader.eager_load_dir(dir) }
        nil
      rescue StandardError, ScriptError => e
        Cronwatch.client.report(e, "loading app/jobs")
        nil
      end

      # NightlyReportJob is "nightly-report"; Reports::NightlyJob is "reports:nightly".
      def default_name(klass)
        raise ArgumentError, "cronwatch: an anonymous job class needs a name: option" if klass.name.nil?

        ActiveSupport::Inflector.underscore(klass.name.delete_suffix("Job")).dasherize.tr("/", ":")
      end
    end

    included do
      around_perform :cronwatch_perform
    end

    class_methods do
      # Monitor this job. Takes the options of Cronwatch::Client#job (schedule,
      # timezone, grace, timeout, max_duration, budget, expect,
      # failures_before_alert, description, tags) and name:, which defaults to
      # the class name without "Job", dasherized.
      def cronwatch(name: nil, **options)
        @cronwatch_options = options.merge(name: name || Cronwatch::ActiveJob.default_name(self)).freeze
        @cronwatch_registration = nil
        Cronwatch::ActiveJob.track(self)
        cronwatch_registration if Cronwatch::ActiveJob.ready?
        nil
      end

      # The options given to `cronwatch`, with the name. Nil when this class is not monitored.
      def cronwatch_options
        @cronwatch_options
      end

      def cronwatch_name
        @cronwatch_options&.fetch(:name)
      end

      # This class's job handle on the current Cronwatch.client.
      def cronwatch_handle(strict: true)
        cronwatch_registration(strict: strict)&.last
      end

      # [client, handle]: the job declared on Cronwatch.client, the first time
      # and again whenever the client is replaced.
      def cronwatch_registration(strict: true)
        options = @cronwatch_options
        return nil unless options

        client = Cronwatch.client
        current = @cronwatch_registration
        return current if current && current[0].equal?(client)

        handle = client.job(options[:name], **options.except(:name))
        @cronwatch_registration = [client, handle].freeze
      rescue StandardError => e
        raise if strict

        (client || Cronwatch.client).report(e, "declaring #{name}")
        nil
      end
    end

    # The run's context during a monitored perform: log, metric, metrics,
    # aborted?, signal. Outside one, a stand-in that drops what it is given.
    def cronwatch
      @cronwatch || NULL_CONTEXT
    end

    private

    # Runs the perform as a recorded run. A job whose declaration is broken
    # still performs, unrecorded, with the error sent to on_error.
    def cronwatch_perform
      client, handle = self.class.cronwatch_registration(strict: false)
      return yield unless handle

      outcome = client.execute(handle.definition, TRIGGER) do |context|
        previous = @cronwatch
        @cronwatch = context
        begin
          yield
        ensure
          @cronwatch = previous
        end
      end
      raise outcome.error if outcome.threw

      outcome.result
    end
  end
end
