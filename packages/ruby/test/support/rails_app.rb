# frozen_string_literal: true

# The smallest Rails app that exercises the integration: ActiveRecord on
# SQLite in memory, ActiveJob on the test adapter, cronwatch/rails required as
# a Gemfile would. Booted once per process.
ENV["RAILS_ENV"] = "test"
require_relative "../test_helper"
require "logger"
require "stringio"
require "tmpdir"
require "fileutils"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "cronwatch/rails"
require "rails/generators"
require "generators/cronwatch/install/install_generator"

module RailsApp
  ROOT = Dir.mktmpdir("cronwatch-rails-")
  LOG = StringIO.new
  Minitest.after_run { FileUtils.rm_rf(ROOT) }

  FileUtils.mkdir_p(File.join(ROOT, "config"))
  File.write(File.join(ROOT, "config/database.yml"), <<~YAML)
    test:
      adapter: sqlite3
      database: ":memory:"
      pool: 1
  YAML

  class Application < ::Rails::Application
    config.root = ROOT
    config.eager_load = false
    config.logger = Logger.new(LOG)
    config.active_job.queue_adapter = :test
    config.secret_key_base = "cronwatch-test-#{"x" * 48}"
    config.active_support.deprecation = :silence
  end

  Application.initialize!
  ActiveRecord::Migration.verbose = false
end
