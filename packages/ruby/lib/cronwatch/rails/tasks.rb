# frozen_string_literal: true

# `bin/rails cronwatch:check`: one check, for a plain crontab instead of a job scheduler.
namespace :cronwatch do
  desc "Check for missed and stuck runs and send alerts (what Cronwatch::CheckJob does)"
  task check: :environment do
    result = Cronwatch::CheckJob.perform_now
    jobs = result.jobs.length
    alerts = result.alerts.length
    puts "cronwatch: checked #{jobs} job#{jobs == 1 ? "" : "s"}, sent #{alerts} alert#{alerts == 1 ? "" : "s"}"
  end
end
