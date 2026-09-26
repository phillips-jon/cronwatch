# frozen_string_literal: true

require "rails/railtie"

module Cronwatch
  # Hooks the gem into a Rails app. There is nothing to start: runs are
  # recorded as monitored jobs perform, and checks come from
  # Cronwatch::CheckJob (or Cronwatch::Sidekiq::CheckWorker) on your
  # scheduler, so no interval thread runs inside web or worker processes.
  # Errors outside jobs (the store, a channel) go to Rails.logger unless the
  # initializer sets on_error.
  class Railtie < ::Rails::Railtie
    # With Sidekiq in the bundle, its server records the runs of
    # Cronwatch::Sidekiq jobs. Checked here rather than when the gem loads,
    # so the order of the Gemfile does not matter.
    initializer "cronwatch.sidekiq" do
      if defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)
        require "cronwatch/sidekiq"
        Cronwatch::Sidekiq.install
      end
    end

    # Once config/initializers/cronwatch.rb has run and, in production, app/jobs
    # is loaded: declare every monitored job, and what
    # Cronwatch.declare_from_scheduler! asked for, so a check knows each
    # schedule before the job first runs. A bad declaration (or a schedule
    # that cannot be read from the scheduler's config) stops the boot, as it
    # would in plain Ruby.
    config.after_initialize do
      Cronwatch::Monitored.boot!
    end

    rake_tasks do
      require_relative "tasks"
    end
  end
end
