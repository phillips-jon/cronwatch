# frozen_string_literal: true

# The Rails integration: a Railtie, the Cronwatch::ActiveJob concern,
# Cronwatch::CheckJob, Cronwatch::Web and the `cronwatch:install` generator.
# Needs railties and activejob; the ActiveRecord store loads on first use,
# and so does Cronwatch::Sidekiq when the app has Sidekiq (the Railtie loads
# it at boot).
#
# `gem "cronwatch"` loads this file on its own when Rails is already loaded,
# as it is under Bundler.require; require it by hand only otherwise.
require "cronwatch" unless defined?(Cronwatch::Client) # loaded from cronwatch.rb when Rails is already up
begin
  require "rails"
  require "active_job"
rescue LoadError => e
  raise LoadError, "cronwatch/rails needs the railties and activejob gems, which a Rails app has (#{e.message})"
end

# Rails always brings Rack, so the dashboard loads here and the mount line in
# config/routes.rb needs no require of its own.
require_relative "web"

module Cronwatch
  autoload :Sidekiq, File.expand_path("sidekiq", __dir__) unless const_defined?(:Sidekiq, false)

  module Stores
    autoload :ActiveRecord, File.expand_path("stores/active_record", __dir__) unless const_defined?(:ActiveRecord, false)
  end
end

require_relative "sidekiq" if defined?(::Sidekiq::Job) || defined?(::Sidekiq::Worker)

require_relative "rails/active_job"
require_relative "rails/check_job"
require_relative "rails/railtie"
