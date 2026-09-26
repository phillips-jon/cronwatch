# frozen_string_literal: true

require "active_job"

module Cronwatch
  # Looks for missed and stuck runs across every job, sends alerts, retries
  # undelivered ones and prunes old runs: Cronwatch.client.check, as a job.
  # Schedule it every few minutes; nothing else notices a job that never ran.
  #
  #   # config/recurring.yml (Solid Queue)
  #   production:
  #     cronwatch_check:
  #       class: Cronwatch::CheckJob
  #       schedule: every 5 minutes
  #
  #   # config/schedule.yml (sidekiq-cron)
  #   cronwatch_check:
  #     cron: "*/5 * * * *"
  #     class: "Cronwatch::CheckJob"
  #
  # Returns the CheckResult.
  class CheckJob < ::ActiveJob::Base
    queue_as :default

    def perform
      Cronwatch::ActiveJob.load_app_jobs
      Cronwatch::ActiveJob.register_all(strict: false)
      Cronwatch.client.check
    end
  end
end
