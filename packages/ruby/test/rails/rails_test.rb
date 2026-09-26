# frozen_string_literal: true

require_relative "../support/rails_app"
require "rake"

class NightlyReportJob < ActiveJob::Base
  include Cronwatch::ActiveJob
  cronwatch schedule: "0 2 * * *", grace: "15m", expect: "Report written", budget: { rows: 100 }

  def perform(rows)
    cronwatch.log("Report written:", rows)
    cronwatch.metric(:rows, rows)
    :finished
  end
end

class FlakyJob < ActiveJob::Base
  include Cronwatch::ActiveJob
  cronwatch name: "flaky", schedule: "every 1h"

  class Boom < StandardError; end
  retry_on Boom, attempts: 2, wait: 0

  def perform(mode)
    cronwatch.log("attempt #{executions}")
    raise Boom, "flaked" if mode == "retry"
    raise ArgumentError, "bad input" if mode == "raise"
  end
end

module Reports
  class WeeklyJob < ActiveJob::Base
    include Cronwatch::ActiveJob
    cronwatch schedule: "0 6 * * 1"

    def perform; end
  end
end

# Includes the concern without declaring anything: not monitored.
class PlainJob < ActiveJob::Base
  include Cronwatch::ActiveJob

  def perform
    cronwatch.log("dropped")
    cronwatch
  end
end

class RailsIntegrationTest < Minitest::Test
  include TestHelpers

  S = Cronwatch::Stores::ActiveRecord

  def setup
    @clock = Clock.new
    @sent = []
    conn = ActiveRecord::Base.connection
    S.drop_tables!(conn)
    S.create_tables!(conn)
    configure
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    RailsApp::LOG.truncate(0)
    RailsApp::LOG.rewind
  end

  def configure(store: S.new)
    sent = @sent
    Cronwatch.configure do |c|
      c.store = store
      c.alerts = [Cronwatch::Alerts::Custom.new("capture") { |alert| sent << alert }]
      c.now = @clock.to_proc
      c.cron_secret = nil
    end
  end

  def sent
    @sent.map { |alert| [alert.type, alert.job] }
  end

  def runs(name)
    Cronwatch.client.runs(name)
  end

  def test_an_active_support_duration_is_stored_as_milliseconds
    job = Cronwatch.client.job("durations", schedule: "every 1h", grace: 15.minutes, timeout: 2.hours)
    job.run { nil }
    stored = Cronwatch.client.store.get_job("durations").definition.to_h
    assert_equal 900_000, stored["grace"]
    assert_equal 7_200_000, stored["timeout"]
  end

  def test_the_dashboard_needs_no_require_of_its_own_in_rails
    assert_equal "constant", defined?(Cronwatch::Web)
  end

  def test_development_follows_rails_env
    before = [ENV.fetch("RAILS_ENV", nil), ENV.fetch("RACK_ENV", nil)]
    ENV.delete("RAILS_ENV")
    ENV.delete("RACK_ENV")
    assert Cronwatch::Client.development?, "Rails.env is #{Rails.env}"
  ensure
    ENV["RAILS_ENV"], ENV["RACK_ENV"] = before
  end

  def test_the_job_name_is_the_class_name_without_job_dasherized
    assert_equal "nightly-report", NightlyReportJob.cronwatch_name
    assert_equal "flaky", FlakyJob.cronwatch_name
    assert_equal "reports:weekly", Reports::WeeklyJob.cronwatch_name
    assert_nil PlainJob.cronwatch_name
    assert_equal %w[NightlyReportJob FlakyJob Reports::WeeklyJob], Cronwatch::Monitored.monitored.first(3)
  end

  def test_a_perform_is_recorded_as_an_ok_run_with_its_output_and_metrics
    assert_equal :finished, NightlyReportJob.perform_now(42)
    run = runs("nightly-report").first
    assert_equal :ok, run.status
    assert_equal "Report written: 42", run.output
    assert_equal({ "rows" => 42 }, run.metrics)
    assert_equal "active_job", run.trigger
    stored = Cronwatch.client.store.get_job("nightly-report").definition.to_h
    assert_equal({ "schedule" => "0 2 * * *", "grace" => "15m", "expect" => 'contains "Report written"',
                   "budget" => { "rows" => 100 }, "name" => "nightly-report" }.sort.to_h, stored.sort.to_h)
    assert_equal [], @sent
  end

  def test_a_perform_that_raises_is_recorded_as_failed_and_still_raises
    error = assert_raises(ArgumentError) { FlakyJob.perform_now("raise") }
    assert_equal "bad input", error.message
    run = runs("flaky").first
    assert_equal :failed, run.status
    assert_match(/\AArgumentError: bad input\n/, run.error)
    assert_equal "attempt 1", run.output
    assert_equal [[:failed, "flaky"]], sent
  end

  def test_retry_on_still_sees_the_exception_and_retries
    FlakyJob.perform_now("retry")
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.length, "retry_on enqueued the next attempt"
    assert_equal "FlakyJob", ActiveJob::Base.queue_adapter.enqueued_jobs.first[:job].name
    assert_match(/\AFlakyJob::Boom: flaked/, runs("flaky").first.error)

    # The retry performs as the second execution and is a run of its own.
    job = ActiveJob::Base.deserialize(ActiveJob::Base.queue_adapter.enqueued_jobs.first.merge("arguments" => ["ok"])
                                                                                     .transform_keys(&:to_s))
    job.perform_now
    assert_equal [:ok, :failed], runs("flaky").map(&:status)
    assert_equal "attempt 2", runs("flaky").first.output
  end

  def test_a_metric_over_budget_alerts
    NightlyReportJob.perform_now(500)
    assert_equal [[:over_budget, "nightly-report"]], sent
  end

  def test_check_job_finds_a_missed_run_and_alerts_through_the_channel
    result = Cronwatch::CheckJob.perform_now
    # (schedulers_test.rb's classes are monitored in this process too)
    assert_empty %w[flaky nightly-report reports:weekly] - result.jobs.map(&:name), "declared before they ever ran"
    assert_equal [], @sent

    @clock.now = Time.utc(2026, 1, 6, 2, 20).to_i * 1000 # the 02:00 run's 15 minute grace is over
    Cronwatch::CheckJob.perform_now
    assert_includes sent, [:missed, "nightly-report"]
    missed = @sent.find { |alert| alert.type == :missed && alert.job == "nightly-report" }
    assert_equal "nightly-report missed its scheduled run", missed.title
    assert_includes missed.message, "Due 2026-01-06 02:00:00 UTC (20m ago)"
    refute_includes sent.map(&:last), "reports:weekly"

    @sent.clear
    NightlyReportJob.perform_now(1)
    assert_equal [[:recovered, "nightly-report"]], sent
  end

  def test_check_job_can_be_enqueued
    Cronwatch::CheckJob.perform_later
    assert_equal "Cronwatch::CheckJob", ActiveJob::Base.queue_adapter.enqueued_jobs.first[:job].name
  end

  def test_cronwatch_outside_a_monitored_perform_drops_what_it_is_given
    assert_same Cronwatch::Monitored::NULL_CONTEXT, NightlyReportJob.new(1).cronwatch
    assert_nil NightlyReportJob.new(1).cronwatch.log("x")
    assert_same Cronwatch::Monitored::NULL_CONTEXT, PlainJob.perform_now
    assert_nil Cronwatch.client.store.get_job("plain")
  end

  def test_a_store_that_is_down_does_not_stop_the_job
    configure(store: S.new(prefix: "missing_"))
    assert_equal :finished, NightlyReportJob.perform_now(1)
    assert_match(/\[cronwatch\] .*missing tables missing_jobs, missing_runs, missing_state/, RailsApp::LOG.string,
                 "errors outside the job go to Rails.logger")
  end

  def test_a_bad_declaration_raises_where_it_is_made
    error = assert_raises(ArgumentError) do
      Class.new(ActiveJob::Base) do
        include Cronwatch::ActiveJob
        cronwatch name: "bad", schedule: "not a schedule"
      end
    end
    assert_match(/"not a schedule" is not a cron expression/, error.message)
    assert_raises(ArgumentError) do
      Class.new(ActiveJob::Base) do
        include Cronwatch::ActiveJob
        cronwatch schedule: "0 2 * * *"
      end
    end
  end

  def test_the_client_is_declared_again_when_it_is_replaced
    first = NightlyReportJob.cronwatch_handle
    configure
    refute_same first, NightlyReportJob.cronwatch_handle
    assert_equal first.definition, NightlyReportJob.cronwatch_handle.definition
  end

  def test_the_rake_task_runs_a_check
    Rails.application.load_tasks unless Rake::Task.task_defined?("cronwatch:check")
    out, = capture_io { Rake::Task["cronwatch:check"].execute }
    assert_equal "cronwatch: checked #{Cronwatch.client.jobs.length} jobs, sent 0 alerts\n", out
    assert_operator Cronwatch.client.jobs.length, :>=, 3
  end
end

class RailsGeneratorTest < Minitest::Test
  S = Cronwatch::Stores::ActiveRecord

  def setup
    @dir = Dir.mktmpdir("cronwatch-gen-")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def generate(*args)
    capture_io { Cronwatch::Generators::InstallGenerator.start(args, destination_root: @dir) }
  end

  def migrations
    Dir[File.join(@dir, "db/migrate/*_create_cronwatch_tables.rb")]
  end

  def test_rails_finds_the_generator
    assert_equal Cronwatch::Generators::InstallGenerator, Rails::Generators.find_by_namespace("cronwatch:install")
  end

  def test_install_writes_the_migration_and_initializer_and_says_what_next
    out, = generate
    assert_equal 1, migrations.length
    assert_match(%r{db/migrate/\d{14}_create_cronwatch_tables\.rb\z}, migrations.first)
    migration = File.read(migrations.first)
    assert_includes migration, "class CreateCronwatchTables < ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]"
    assert_includes migration, 'Cronwatch::Stores::ActiveRecord.create_tables!(connection, prefix: "cronwatch_")'

    initializer = File.read(File.join(@dir, "config/initializers/cronwatch.rb"))
    assert_includes initializer, "c.store = Cronwatch::Stores::ActiveRecord.new\n"
    assert_includes initializer, 'Cronwatch::Alerts::Slack.new(webhook_url: ENV["SLACK_WEBHOOK_URL"])'

    ["bin/rails db:migrate", "config/recurring.yml", "class: Cronwatch::CheckJob", "schedule: every 5 minutes",
     "config/schedule.yml", 'cron: "*/5 * * * *"', 'class: "Cronwatch::CheckJob"', "bin/rails cronwatch:check",
     'mount Cronwatch::Web.new(Cronwatch.client) => "/cronwatch"'].each { |text| assert_includes out, text }

    out, = generate
    assert_equal 1, migrations.length, "running it again adds no second migration"
    assert_match(/exist.*create_cronwatch_tables/, out)
  end

  def test_the_migration_creates_the_sdk_tables_and_drops_them
    generate
    conn = ActiveRecord::Base.connection
    S.drop_tables!(conn)
    load migrations.first
    CreateCronwatchTables.new.migrate(:up)
    sql = conn.select_rows("SELECT name, sql FROM sqlite_master WHERE name LIKE 'cronwatch_%' ORDER BY name").to_h
    assert_equal %w[cronwatch_jobs cronwatch_runs cronwatch_runs_job_started cronwatch_runs_running cronwatch_state], sql.keys
    expected = S.schema(:sqlite).split(";").map(&:strip).reject(&:empty?).map { |s| s.sub(" IF NOT EXISTS", "") }
    assert_equal expected.sort, sql.values.sort, "the SDK's statements, as SQLite keeps them"

    CreateCronwatchTables.new.migrate(:down)
    refute conn.table_exists?("cronwatch_runs")
  ensure
    S.create_tables!(ActiveRecord::Base.connection)
  end

  def test_the_initializer_configures_a_client_on_the_store
    generate
    previous = ENV.delete("SLACK_WEBHOOK_URL")
    load File.join(@dir, "config/initializers/cronwatch.rb")
    assert_instance_of S, Cronwatch.client.store
    assert_equal ["console"], Cronwatch.client.alerts.map(&:name), "no Slack URL: alerts go to the console"
    ENV["SLACK_WEBHOOK_URL"] = "https://hooks.slack.com/services/T/B/x"
    load File.join(@dir, "config/initializers/cronwatch.rb")
    assert_equal [Cronwatch::Alerts::Slack], Cronwatch.client.alerts.map(&:class)
  ensure
    previous ? ENV["SLACK_WEBHOOK_URL"] = previous : ENV.delete("SLACK_WEBHOOK_URL")
  end

  def test_a_prefix_reaches_the_migration_and_the_initializer
    generate
    generate("--prefix", "ops_", "--force") # the initializer changes too
    assert_equal 1, migrations.length
    prefixed = Dir[File.join(@dir, "db/migrate/*_create_cronwatch_ops_tables.rb")]
    assert_equal 1, prefixed.length, "a second prefix gets a migration of its own"
    assert_includes File.read(prefixed.first), "class CreateCronwatchOpsTables < ActiveRecord::Migration"
    assert_includes File.read(prefixed.first), 'create_tables!(connection, prefix: "ops_")'
    assert_includes File.read(File.join(@dir, "config/initializers/cronwatch.rb")),
                    'c.store = Cronwatch::Stores::ActiveRecord.new(prefix: "ops_")'
  end

  def test_a_bad_prefix_is_refused_before_anything_is_written
    _, err = generate("--prefix", "Ops-")
    assert_match(/invalid table prefix "Ops-"/, err)
    assert_empty Dir[File.join(@dir, "**/*.rb")]
  end
end
