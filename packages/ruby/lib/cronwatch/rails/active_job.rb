# frozen_string_literal: true

require "active_support/concern"
require "active_support/inflector"
require "active_job"
require_relative "../scheduler"

module Cronwatch
  # Monitors an ActiveJob class. Each perform is a recorded run with the
  # trigger "active-job"; `cronwatch` in the job is the run's context, for
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
  # `cronwatch schedule: :from_scheduler` takes the schedule from the class's
  # entry in config/recurring.yml (Solid Queue) or sidekiq-cron's schedule,
  # so the cron expression is written once.
  #
  # The job is declared on Cronwatch.client once the app has booted (after
  # config/initializers/cronwatch.rb ran), and again if the client is
  # replaced. Only classes that call `cronwatch` are monitored; subclasses
  # declare their own.
  module ActiveJob
    extend ActiveSupport::Concern
    include Cronwatch::Monitored

    TRIGGER = Scheduler::ACTIVE_JOB_TRIGGER

    included do
      around_perform :cronwatch_perform
    end

    class_methods do
      include Cronwatch::Monitored::ClassMethods
    end

    private

    # Runs the perform as a recorded run. A job whose declaration is broken
    # still performs, unrecorded, with the error sent to on_error.
    def cronwatch_perform(&block)
      Cronwatch::Monitored.record(self.class.cronwatch_declaration, TRIGGER, self, &block)
    end
  end
end
