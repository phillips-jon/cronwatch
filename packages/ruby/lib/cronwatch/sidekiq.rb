# frozen_string_literal: true

# Sidekiq jobs that include Sidekiq::Job (or Sidekiq::Worker) directly,
# without ActiveJob: the Cronwatch::Sidekiq module, the server middleware
# that records their runs, and Cronwatch::Sidekiq::CheckWorker. Needs the
# sidekiq gem (7 or newer), which stays optional.
#
# In a Rails app with Sidekiq in the Gemfile this loads with the Rails
# integration, and the Railtie adds the middleware to Sidekiq's server.
# Elsewhere, require it and add the middleware yourself:
#
#   require "cronwatch/sidekiq"
#
#   Sidekiq.configure_server do |config|
#     config.server_middleware { |chain| chain.add Cronwatch::Sidekiq::ServerMiddleware }
#     config.on(:startup) { Cronwatch::Sidekiq.ready! } # after Cronwatch.configure, with the jobs loaded
#   end
begin
  require "sidekiq"
rescue LoadError => e
  raise LoadError, "cronwatch/sidekiq needs the sidekiq gem (7 or newer): add `gem \"sidekiq\"` to your Gemfile (#{e.message})"
end

require "cronwatch" unless defined?(Cronwatch::Client)
require_relative "scheduler"

module Cronwatch
  # Monitors a Sidekiq job class. Each perform run by a Sidekiq server with
  # Cronwatch::Sidekiq::ServerMiddleware is a recorded run with the trigger
  # "sidekiq"; `cronwatch` in the job is the run's context, for log and
  # metric. A perform that raises is recorded as failed and then raises as
  # before, so Sidekiq's retries, death handlers, and error handlers see it
  # unchanged.
  #
  #   class NightlyReportJob
  #     include Sidekiq::Job
  #     include Cronwatch::Sidekiq
  #     cronwatch schedule: "0 2 * * *", grace: "15m" # name: "nightly-report"
  #
  #     def perform
  #       cronwatch.log("Report written")
  #     end
  #   end
  #
  # The name, the options, and when the job is declared are as for
  # Cronwatch::ActiveJob, including schedule: :from_scheduler.
  module Sidekiq
    include Cronwatch::Monitored

    TRIGGER = "sidekiq"

    def self.included(base)
      if defined?(::ActiveJob::Base) && base.is_a?(Class) && base < ::ActiveJob::Base
        raise ArgumentError, "cronwatch: #{base.name || "this class"} is an ActiveJob class; include Cronwatch::ActiveJob instead"
      end

      super
      base.extend(Cronwatch::Monitored::ClassMethods)
    end

    class << self
      # Marks the app as booted and declares every monitored class's job on
      # Cronwatch.client, so a check knows about jobs that have not run yet.
      # The Railtie does this in Rails; call it outside Rails once
      # Cronwatch.configure has run and the job classes are loaded.
      def ready!
        Cronwatch::Monitored.boot!
      end

      # Adds ServerMiddleware to the server's chain, when this process is a
      # Sidekiq server. The Railtie calls it; adding it twice is harmless.
      def install
        ::Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add ServerMiddleware unless chain.exists?(ServerMiddleware)
          end
        end
        nil
      end

      # The declaration whose job a Sidekiq job instance runs as: its class's
      # own `cronwatch`, or its entry in the scheduler's config when
      # Cronwatch.declare_from_scheduler! declared it. Nil for anything else,
      # including ActiveJob's wrapper, which Cronwatch::ActiveJob records.
      def declaration_for(job, payload)
        return nil if payload.is_a?(Hash) && payload["wrapped"]

        klass = job.class
        return klass.cronwatch_declaration if klass.respond_to?(:cronwatch_declaration) && klass.cronwatch_declaration

        Cronwatch::Scheduler.declaration_for_class(klass.name)
      end
    end

    # Records the runs of monitored Sidekiq jobs. Anything else passes
    # through untouched.
    class ServerMiddleware
      include ::Sidekiq::ServerMiddleware if defined?(::Sidekiq::ServerMiddleware)

      def call(job, payload, _queue, &block)
        declaration = Cronwatch::Sidekiq.declaration_for(job, payload)
        return yield unless declaration

        Cronwatch::Monitored.record(declaration, TRIGGER, job, &block)
      end
    end

    # Cronwatch::CheckJob for apps whose Sidekiq jobs do not go through
    # ActiveJob: declares every monitored job and runs a check. Schedule it
    # every five minutes with sidekiq-cron:
    #
    #   cronwatch_check:
    #     cron: "*/5 * * * *"
    #     class: "Cronwatch::Sidekiq::CheckWorker"
    class CheckWorker
      include ::Sidekiq::Job

      # A check that fails is repeated by the next one five minutes later.
      sidekiq_options retry: false

      def perform
        Cronwatch::Monitored.load_app_jobs
        Cronwatch::Monitored.register_all(strict: false)
        Cronwatch.client.check
        nil
      end
    end
  end
end
