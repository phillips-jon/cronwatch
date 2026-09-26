# frozen_string_literal: true

require "rails/railtie"

module Cronwatch
  # Hooks the gem into a Rails app. There is nothing to start: runs are
  # recorded as monitored jobs perform, and checks come from
  # Cronwatch::CheckJob on your scheduler, so no interval thread runs inside
  # web or worker processes. Errors outside jobs (the store, a channel) go to
  # Rails.logger unless the initializer sets on_error.
  class Railtie < ::Rails::Railtie
    # Once config/initializers/cronwatch.rb has run and, in production, app/jobs
    # is loaded: declare every monitored job, so a check knows each schedule
    # before the job first runs. A bad declaration stops the boot, as it would
    # in plain Ruby.
    config.after_initialize do
      Cronwatch::ActiveJob.ready!
      Cronwatch::ActiveJob.register_all(strict: true)
    end

    rake_tasks do
      require_relative "tasks"
    end
  end
end
