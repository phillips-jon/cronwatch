# frozen_string_literal: true

# The Rails integration: a Railtie, the Cronwatch::ActiveJob concern,
# Cronwatch::CheckJob and the `cronwatch:install` generator. Needs railties
# and activejob; the ActiveRecord store loads on first use.
#
# `gem "cronwatch"` loads this file on its own when Rails is already loaded,
# as it is under Bundler.require; require it by hand only otherwise.
require "cronwatch" unless defined?(Cronwatch::Client) # loaded from cronwatch.rb when Rails is already up
require "rails"
require "active_job"

module Cronwatch
  # So the mount line in config/routes.rb needs no require of its own.
  autoload :Web, File.expand_path("web", __dir__) unless const_defined?(:Web, false)

  module Stores
    autoload :ActiveRecord, File.expand_path("stores/active_record", __dir__) unless const_defined?(:ActiveRecord, false)
  end
end

require_relative "rails/active_job"
require_relative "rails/check_job"
require_relative "rails/railtie"
