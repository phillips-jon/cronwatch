# frozen_string_literal: true

require_relative "../support/rails_app"
require "active_job/queue_adapters/sidekiq_adapter"

if ::Sidekiq.respond_to?(:testing!)
  ::Sidekiq.testing!(:fake)
else
  require "sidekiq/testing"
  ::Sidekiq::Testing.fake!
end
::Sidekiq.default_configuration.logger.level = ::Logger::WARN

# The app's schedules: Solid Queue's recurring.yml and sidekiq-cron's
# schedule.yml. Set before the classes below, which read their schedule as
# they load, since the app has booted.
SCHEDULES = File.expand_path("../support/schedules", __dir__)
RECURRING = Cronwatch::Scheduler::SolidQueue.new(File.join(SCHEDULES, "recurring.yml"), time_zone: "UTC")
SIDEKIQ_CRON = Cronwatch::Scheduler::SidekiqCron.new(File.join(SCHEDULES, "schedule.yml"))
Cronwatch::Scheduler.sources = [RECURRING, SIDEKIQ_CRON]

# In recurring.yml; its schedule comes from there.
class SyncFeedsJob < ActiveJob::Base
  include Cronwatch::ActiveJob
  cronwatch schedule: :from_scheduler, grace: "5m"

  def perform
    cronwatch.log("Feeds synced")
  end
end

# In recurring.yml, not watched by a `cronwatch` of their own.
class DailyDigestJob < ActiveJob::Base
  def perform(options)
    "digest #{options[:kind]}"
  end
end

class RefreshScoresJob < ActiveJob::Base
  def perform = nil
end

class NightlyBackupJob < ActiveJob::Base
  class Failed < StandardError; end

  def perform(fail = false)
    raise Failed, "disk full" if fail
  end
end

# Stands in for the job Solid Queue runs a `command:` task with.
module SolidQueue
  class RecurringJob < ActiveJob::Base
    COMMANDS = []

    def perform(command)
      COMMANDS << command
    end
  end
end

# In schedule.yml (sidekiq-cron): Sidekiq jobs without ActiveJob.
class ReportWorker
  include Sidekiq::Job
  include Cronwatch::Sidekiq
  cronwatch schedule: :from_scheduler

  def perform
    cronwatch.log("Report sent")
  end
end

class HardWorker
  include Sidekiq::Job

  def perform = nil
end

class CleanupWorker
  include Sidekiq::Job

  def perform = nil
end

class SchedulersTest < Minitest::Test
  include TestHelpers

  S = Cronwatch::Stores::ActiveRecord
  Error = Cronwatch::Scheduler::Error
  M = Cronwatch::Sidekiq::ServerMiddleware

  def setup
    @clock = Clock.new
    @sent = []
    conn = ActiveRecord::Base.connection
    S.drop_tables!(conn)
    S.create_tables!(conn)
    sent = @sent
    Cronwatch.configure do |c|
      c.store = S.new
      c.alerts = [Cronwatch::Alerts::Custom.new("capture") { |alert| sent << alert }]
      c.now = @clock.to_proc
      c.cron_secret = nil
    end
    ::Sidekiq::Testing.server_middleware { |chain| chain.add(M) }
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  def teardown
    Cronwatch::Scheduler.reset!
    Cronwatch::Scheduler.sources = [RECURRING, SIDEKIQ_CRON]
    ::Sidekiq::Testing.server_middleware(&:clear)
    ::Sidekiq::Worker.clear_all
  end

  def runs(name)
    Cronwatch.client.runs(name)
  end

  def definition(klass)
    klass.cronwatch_handle.definition
  end

  def sent
    @sent.map { |alert| [alert.type, alert.job] }
  end

  def test_the_railtie_loads_sidekiq_support_and_adds_the_middleware_to_a_server
    assert_equal "constant", defined?(Cronwatch::Sidekiq::ServerMiddleware)
    chain = ::Sidekiq.default_configuration.server_middleware
    chain.remove(M)
    initializer = Cronwatch::Railtie.initializers.find { |i| i.name == "cronwatch.sidekiq" }
    initializer.run(Rails.application)
    refute chain.exists?(M), "not a Sidekiq server"

    server = ::Sidekiq.method(:server?).unbind
    ::Sidekiq.singleton_class.send(:remove_method, :server?)
    ::Sidekiq.singleton_class.send(:define_method, :server?) { true }
    begin
      initializer.run(Rails.application)
    ensure
      ::Sidekiq.singleton_class.send(:remove_method, :server?)
      ::Sidekiq.singleton_class.send(:define_method, :server?, server)
    end
    assert chain.exists?(M)
  ensure
    chain&.remove(M)
  end

  def test_a_class_takes_its_schedule_from_the_scheduler
    assert_equal "12 * * * *", definition(SyncFeedsJob).schedule, "every hour at minute 12"
    assert_equal "UTC", definition(SyncFeedsJob).timezone
    assert_equal "5m", definition(SyncFeedsJob).grace
    assert_equal({ schedule: :from_scheduler, grace: "5m", name: "sync-feeds" }, SyncFeedsJob.cronwatch_options)
    assert_equal "0 9 * * *", definition(ReportWorker).schedule, "every day at 9am Europe/London"
    assert_equal "Europe/London", definition(ReportWorker).timezone
  end

  def test_a_class_the_scheduler_has_not_got_or_has_twice_stops_the_boot
    error = assert_raises(Error) do
      Class.new(ActiveJob::Base) do
        include Cronwatch::ActiveJob
        def self.name = "UnscheduledJob"
        cronwatch schedule: :from_scheduler
      end
    end
    assert_match(/UnscheduledJob uses schedule: :from_scheduler, but no enabled entry in .*recurring\.yml or .*schedule\.yml has class UnscheduledJob/,
                 error.message)
    refute_includes Cronwatch::Monitored.monitored, "UnscheduledJob", "a class whose declaration failed is not monitored"

    Cronwatch::Scheduler.sources = [RECURRING, Cronwatch::Scheduler::SidekiqCron.new({ "twice" => { "class" => "HardWorker", "cron" => "0 * * * *" },
                                                                                         "again" => { "class" => "HardWorker", "cron" => "30 * * * *" } })]
    error = assert_raises(Error) do
      Class.new do
        include Sidekiq::Job
        include Cronwatch::Sidekiq
        def self.name = "HardWorker"
        cronwatch schedule: :from_scheduler
      end
    end
    assert_match(/scheduled 2 times \(the sidekiq-cron config twice, the sidekiq-cron config again\)/, error.message)

    assert_raises(ArgumentError) { Class.new(ActiveJob::Base) { include Cronwatch::ActiveJob; cronwatch name: "x", schedule: :from_scheduler, timezone: "UTC" } }
    assert_raises(ArgumentError) { Class.new(ActiveJob::Base) { include Cronwatch::ActiveJob; cronwatch name: "x", schedule: :scheduler } }
    error = assert_raises(ArgumentError) { Class.new(ActiveJob::Base) { include Cronwatch::Sidekiq } }
    assert_match(/is an ActiveJob class; include Cronwatch::ActiveJob instead/, error.message)
  end

  def test_a_job_from_the_config_is_missed_and_recovers
    Cronwatch::CheckJob.perform_now
    assert_empty @sent

    SyncFeedsJob.perform_now
    assert_equal "Feeds synced", runs("sync-feeds").first.output
    @clock.now = Time.utc(2026, 1, 5, 10, 18).to_i * 1000 # 10:12 and its 5 minutes have passed
    Cronwatch::CheckJob.perform_now
    assert_includes sent, [:missed, "sync-feeds"]
    alert = @sent.find { |a| a.job == "sync-feeds" }
    assert_includes alert.message, "Due 2026-01-05 10:12:00 UTC (6m ago)"
    @sent.clear
    SyncFeedsJob.perform_now
    assert_equal [[:recovered, "sync-feeds"]], sent
  end

  def test_sidekiq_jobs_run_through_the_middleware
    ReportWorker.perform_async
    ReportWorker.drain
    run = runs("report-worker").first
    assert_equal ["sidekiq", :ok, "Report sent"], [run.trigger, run.status, run.output]
  end

  def test_an_active_job_on_the_sidekiq_adapter_is_recorded_once
    adapter = ActiveJob::QueueAdapters::SidekiqAdapter.new
    adapter.enqueue(SyncFeedsJob.new)
    wrapper = ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper
    assert_equal 1, wrapper.jobs.length
    assert_equal "SyncFeedsJob", wrapper.jobs.first["wrapped"]
    wrapper.drain
    assert_equal [["active-job", :ok]], runs("sync-feeds").map { |r| [r.trigger, r.status] }

    # Also for a class declare_from_scheduler! watches.
    Cronwatch.declare_from_scheduler!
    adapter.enqueue(RefreshScoresJob.new)
    wrapper.drain
    assert_equal ["active-job"], runs("refresh-scores").map(&:trigger)
  end

  def test_declare_from_scheduler_watches_every_entry
    Cronwatch.declare_from_scheduler!(grace: "10m", tags: ["scheduled"])
    names = Cronwatch.client.defined_jobs.map(&:name)
    %w[daily-digest refresh-scores clear_solid_queue_finished_jobs nightly-backup hard-worker cleanup-worker].each do |name|
      assert_includes names, name
    end
    refute_includes names, "import-worker", "disabled in sidekiq-cron"
    refute_includes names, "cronwatch:check-job", "the check itself is left alone"

    digest = Cronwatch.client.defined_jobs.find { |d| d.name == "daily-digest" }
    assert_equal ["0 10 * * *", "UTC", "10m", ["scheduled"], "The morning digest"],
                 [digest.schedule, digest.timezone, digest.grace, digest.tags, digest.description]
    command = Cronwatch.client.defined_jobs.find { |d| d.name == "clear_solid_queue_finished_jobs" }
    assert_equal "0 3 * * *", command.schedule
    cleanup = Cronwatch.client.defined_jobs.find { |d| d.name == "cleanup-worker" }
    assert_equal ["30 4 * * 0", "America/New_York"], [cleanup.schedule, cleanup.timezone]
    # The check knows each one before it has run.
    result = Cronwatch::CheckJob.perform_now
    checked = result.jobs.map(&:name)
    assert_includes checked, "clear_solid_queue_finished_jobs"
    assert_empty @sent
    # Classes with a `cronwatch` of their own declare themselves, once.
    assert_equal 1, checked.count("sync-feeds")
    assert_equal 1, checked.count("report-worker")

    # Runs are recorded: ActiveJob classes, the command by its text, Sidekiq jobs.
    assert_equal "digest daily", DailyDigestJob.perform_now({ kind: "daily" })
    SolidQueue::RecurringJob.perform_now("SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)")
    SolidQueue::RecurringJob.perform_now("something else")
    HardWorker.perform_async
    HardWorker.drain
    assert_raises(NightlyBackupJob::Failed) { NightlyBackupJob.perform_now(true) }
    assert_equal [:ok], runs("daily-digest").map(&:status)
    assert_equal ["active-job"], runs("clear_solid_queue_finished_jobs").map(&:trigger)
    assert_equal ["sidekiq"], runs("hard-worker").map(&:trigger)
    assert_equal [:failed], runs("nightly-backup").map(&:status)
    assert_equal [[:failed, "nightly-backup"]], sent

    # The day after, what did not run is missed; what ran is not.
    @sent.clear
    @clock.now = Time.utc(2026, 1, 6, 3, 11).to_i * 1000
    Cronwatch::CheckJob.perform_now
    missed = sent.select { |type, _| type == :missed }.map(&:last)
    assert_includes missed, "clear_solid_queue_finished_jobs", "due 03:00, grace 10m"
    assert_includes missed, "refresh-scores"
    assert_includes missed, "daily-digest", "10:00 yesterday"
    refute_includes missed, "cleanup-worker", "not due until Sunday 04:30 in New York"
  end

  def test_declare_from_scheduler_refuses_what_it_cannot_watch
    Cronwatch::Scheduler.sources = [Cronwatch::Scheduler::SolidQueue.new({ "gone" => { "class" => "NoSuchJob", "schedule" => "every hour" } })]
    error = assert_raises(Error) { Cronwatch.declare_from_scheduler! }
    assert_match(/the Solid Queue config gone names the class NoSuchJob, which does not load/, error.message)
    Cronwatch.declare_from_scheduler!(except: ["gone"])

    Cronwatch::Scheduler.sources = [Cronwatch::Scheduler::SolidQueue.new({ "a" => { "class" => "HardWorker", "schedule" => "every hour" },
                                                                          "b" => { "class" => "HardWorker", "schedule" => "every day" } })]
    error = assert_raises(Error) { Cronwatch.declare_from_scheduler! }
    assert_match(/the Solid Queue config b and the Solid Queue config a would both be the job "hard-worker"; leave one out with declare_from_scheduler!\(except: \["b"\]\)/,
                 error.message)

    Cronwatch::Scheduler.sources = [Cronwatch::Scheduler::SolidQueue.new({ "late" => { "command" => "x", "schedule" => "every day at 2:30am America/New_York" } })]
    error = assert_raises(Error) { Cronwatch.declare_from_scheduler! }
    assert_match(/does not exist in America\/New_York/, error.message)
    assert_raises(ArgumentError) { Cronwatch.declare_from_scheduler!(schedule: "0 * * * *") }
  end

  def test_the_check_worker_checks
    Cronwatch::Sidekiq::CheckWorker.perform_async
    Cronwatch::Sidekiq::CheckWorker.drain
    assert_includes Cronwatch.client.jobs.map(&:name), "report-worker"
  end
end
