# frozen_string_literal: true

require_relative "test_helper"
require "cronwatch/scheduler"
require "tmpdir"

# Reading schedules from Solid Queue's and sidekiq-cron's config, and turning
# what Fugit reads into the cron expression CronWatch reads.
class SchedulerTest < Minitest::Test
  include TestHelpers

  SQ = Cronwatch::Scheduler::SolidQueue
  SC = Cronwatch::Scheduler::SidekiqCron
  Error = Cronwatch::Scheduler::Error
  DIR = File.expand_path("support/schedules", __dir__)

  def teardown
    Cronwatch::Scheduler.sources = nil
    Cronwatch::Scheduler.env = nil
    Cronwatch::Scheduler.root = nil
  end

  def recurring(env: "production", time_zone: nil)
    SQ.new(File.join(DIR, "recurring.yml"), env: env, time_zone: time_zone)
  end

  def cron_file
    SC.new(File.join(DIR, "schedule.yml"), mode: :single)
  end

  # One Solid Queue entry, from a schedule string.
  def sq(schedule, time_zone: nil)
    SQ.new({ "task" => { "class" => "SomeJob", "schedule" => schedule } }, time_zone: time_zone).entries.first
  end

  def sc(cron, mode: :single)
    SC.new({ "task" => { "class" => "SomeWorker", "cron" => cron } }, mode: mode).entries.first
  end

  def by_key(entries)
    entries.to_h { |entry| [entry.key, entry] }
  end

  def test_solid_queue_reads_the_section_for_the_environment
    entries = by_key(recurring.entries)
    assert_equal %w[sync_feeds daily_digest refresh_scores clear_solid_queue_finished_jobs nightly_backup cronwatch_check],
                 entries.keys
    assert_equal "SyncFeedsJob", entries["sync_feeds"].class_name
    assert_equal "every hour at minute 12", entries["sync_feeds"].schedule
    assert_nil entries["clear_solid_queue_finished_jobs"].class_name
    assert_equal "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)",
                 entries["clear_solid_queue_finished_jobs"].command
    assert_equal "The morning digest", entries["daily_digest"].description
    assert_equal "test/support/schedules/recurring.yml sync_feeds",
                 entries["sync_feeds"].label.sub("#{File.expand_path("..", __dir__)}/", ""),
                 "an entry says where it came from"

    development = by_key(recurring(env: "development").entries)
    assert_equal %w[sync_feeds], development.keys, "a task without a schedule is not a task, as in Solid Queue"
    assert_equal "every 30 minutes", development["sync_feeds"].schedule

    # A file without a section for the environment is read whole, as Solid Queue does.
    flat = SQ.new({ "nightly" => { "class" => "NightlyJob", "schedule" => "0 2 * * *" } }, env: "production")
    assert_equal %w[nightly], flat.entries.map(&:key)
    assert_empty SQ.new(File.join(DIR, "missing.yml")).entries, "no file, no tasks"
  end

  def test_the_real_world_phrases_convert_to_the_cron_solid_queue_runs
    converted = recurring(time_zone: "UTC").entries.to_h { |entry| [entry.key, entry.convert] }
    assert_equal({ schedule: "12 * * * *", timezone: "UTC" }, converted["sync_feeds"])
    assert_equal({ schedule: "0 10 * * *", timezone: "UTC" }, converted["daily_digest"])
    assert_equal({ schedule: "0,5,10,15,20,25,30,35,40,45,50,55 * * * *", timezone: "UTC" }, converted["refresh_scores"])
    assert_equal({ schedule: "0 3 * * *", timezone: "UTC" }, converted["clear_solid_queue_finished_jobs"])
    assert_equal({ schedule: "0 2 * * *", timezone: "UTC" }, converted["nightly_backup"])
  end

  def test_the_zone_is_the_one_the_scheduler_reads_the_schedule_in
    # Solid Queue 1.5 and later read a schedule without a zone in config.time_zone.
    assert_equal({ schedule: "0 3 * * *", timezone: "America/Chicago" }, sq("every day at 3am", time_zone: "America/Chicago").convert)
    # A zone in the schedule wins, in either scheduler.
    assert_equal({ schedule: "0 3 * * *", timezone: "Europe/London" },
                 sq("every day at 3am Europe/London", time_zone: "America/Chicago").convert)
    assert_equal({ schedule: "0 9 * * *", timezone: "Europe/London" }, sc("every day at 9am Europe/London").convert)
    assert_equal({ schedule: "30 4 * * 0", timezone: "America/New_York" }, sc("30 4 * * sun America/New_York").convert)

    # Otherwise Fugit's local zone: TZ, then Rails' Time.zone, then the system's.
    assert_equal({ schedule: "0 3 * * *", timezone: "UTC" }, sq("every day at 3am").convert)
    before = ENV.fetch("TZ", nil)
    ENV["TZ"] = "Asia/Tokyo"
    assert_equal({ schedule: "0 3 * * *", timezone: "Asia/Tokyo" }, sq("every day at 3am").convert)
    assert_equal({ schedule: "*/5 * * * *".sub("*/5", "0,5,10,15,20,25,30,35,40,45,50,55"), timezone: "Asia/Tokyo" },
                 sc("*/5 * * * *").convert)
  ensure
    ENV["TZ"] = before
  end

  def test_sidekiq_cron_reads_a_map_or_a_list
    entries = by_key(cron_file.entries)
    assert_equal %w[hard_worker morning_report weekly_cleanup old_import cronwatch_check], entries.keys
    assert_equal "CleanupWorker", entries["weekly_cleanup"].class_name, "klass: is read as class:"
    assert entries["old_import"].disabled
    refute entries["hard_worker"].disabled
    assert_equal "Report for the London office", entries["morning_report"].description
    assert_equal({ schedule: "0,15,30,45 * * * *", timezone: "UTC" }, entries["hard_worker"].convert)

    # A missing .yml is looked for as .yaml, as sidekiq-cron does.
    list = SC.new(File.join(DIR, "schedule_list.yml"))
    assert_equal File.join(DIR, "schedule_list.yaml"), list.path
    assert_equal({ "hard_worker" => { schedule: "0 0,6,12,18 * * *", timezone: "UTC" },
                   "report" => { schedule: "30 8 * * 1", timezone: "UTC" } },
                 list.entries.to_h { |entry| [entry.key, entry.convert] })
  end

  def test_each_scheduler_reads_several_times_in_one_phrase_its_own_way
    phrase = "every day at 9:15 and 17:30"
    error = assert_raises(Error) { sq(phrase).convert }
    assert_match(/Solid Queue does not accept the schedule "every day at 9:15 and 17:30": multiple crons/, error.message)
    assert_equal({ schedule: "15 9 * * *", timezone: "UTC" }, sc(phrase, mode: :single).convert,
                 "sidekiq-cron's default keeps the first, and so does CronWatch")
    assert_raises(Error) { sc(phrase, mode: :strict).convert }
    assert_equal({ schedule: "0 9,17 * * *", timezone: "UTC" }, sq("every day at 9am and 5pm").convert)
  end

  def test_forms_croner_reads_are_written_the_way_it_reads_them
    assert_equal "0 0 L * *", sq("0 0 L * *").convert[:schedule]
    assert_equal "0 0 * * 5L", sq("0 0 * * 5#-1").convert[:schedule], "the last Friday"
    assert_equal "0 0 * * 5#2", sq("0 0 * * fri#2").convert[:schedule]
    assert_equal "0 0 1 * +1", sq("0 0 1 * 1&").convert[:schedule], "Fugit's & (both days) is croner's +"
    assert_equal "0,30 * * * * *", sq("every 30 seconds").convert[:schedule]
    assert_equal "0 12 * * 1,2,3,4,5", sq("0 12 * * mon-fri").convert[:schedule]
    assert_equal "0 * * * *", sq("every 90 minutes").convert[:schedule], "what Fugit makes of it, which is what runs"
  end

  def test_what_cannot_be_converted_exactly_is_refused
    {
      "0 0 * * 1%2" => /fires every 2 weeks \(%\), which CronWatch cannot read/,
      "0 0 -2 * *" => /counts days back from the end of the month \(-2\)/,
      "0 0 * * 5#-2" => /counts weekdays back from the end of the month \(#-2\)/,
      "0~10 3 * * *" => /picks a random time/,
      "every day at 3am +05:00" => /is read in "\+05:00", which is not an IANA timezone/,
      "5m" => /is not a recurring schedule Solid Queue accepts/,
      "not a schedule" => /is not a recurring schedule Solid Queue accepts/,
      # Croner, and so CronWatch, skips the 1st of March 2026 (a Sunday) for this one; Fugit does not.
      "0 0 1,15 * 1" => /after a run at 2026-02-23 00:00:00 Solid Queue runs it next at 2026-03-01 00:00:00 and CronWatch would expect 2026-03-02 00:00:00/,
    }.each do |schedule, message|
      error = assert_raises(Error, schedule) { sq(schedule).convert }
      assert_match message, error.message, schedule
      assert_match(/\Acronwatch: the Solid Queue config task: /, error.message)
    end
    assert_raises(Error) { sc(nil).convert }
    assert_raises(Error) { sc("every blue moon").convert }
  end

  def test_a_time_that_clocks_skip_is_refused
    error = assert_raises(Error) { sq("every day at 2:30am America/New_York").convert }
    assert_match(/is due at a time that does not exist in America\/New_York on \d{4}-03-\d\d, when clocks go forward from 02:00 to 03:00\. Solid Queue skips that run and CronWatch would expect it at \d{4}-03-\d\d 03:30:00/,
                 error.message)
    assert_raises(Error) { sq("every 2 hours America/New_York").convert }
    assert_raises(Error) { sq("0 1 * * * Europe/London").convert }
    assert_raises(Error, "a half hour change moves every hour") { sq("every hour Australia/Lord_Howe").convert }
    error = assert_raises(Error) { sq("every day at 2am", time_zone: "Europe/Berlin").convert }
    assert_match(/Europe\/Berlin/, error.message)

    # Next to the change, or where the change moves a time onto a run that exists, is fine.
    assert_equal "America/New_York", sq("every day at 3am America/New_York").convert[:timezone]
    assert_equal "0 * * * *", sq("every hour America/New_York").convert[:schedule]
    assert_equal "12 * * * *", sq("every hour at minute 12 Europe/London").convert[:schedule]
    assert_equal "0 2 * * 0#1", sq("0 2 * * 0#1 America/New_York").convert[:schedule], "never the second Sunday of March"
    assert_equal "Asia/Kolkata", sq("every day at 2:30am Asia/Kolkata").convert[:timezone]
  end

  # Fugit's own next_time drops runs on the day clocks change in these (its
  # hour steps, a midnight that repeats, a half hour change), where CronWatch
  # would expect them and report them missed.
  def test_a_run_fugit_drops_on_a_clock_change_is_refused
    {
      "every 5 hours America/New_York" => /after a run at 2026-03-08 00:00:00 Solid Queue runs it next at 2026-03-08 10:00:00 and CronWatch would expect 2026-03-08 05:00:00/,
      "0 */5 * * * America/New_York" => /Solid Queue runs it next at 2026-03-08 10:00:00/,
      "0 0,4 * * * America/New_York" => /after a run at 2026-11-01 00:00:00/,
      "0 0 */2 * * Australia/Lord_Howe" => /in Australia\/Lord_Howe, but after a run at/,
      "45 2 * * * Pacific/Chatham" => /does not exist in Pacific\/Chatham on \d{4}-09-\d\d, when clocks go forward from 02:45 to 03:45/,
    }.each do |schedule, message|
      error = assert_raises(Error, schedule) { sq(schedule).convert }
      assert_match message, error.message, schedule
    end
    # A midnight clock change: Havana springs from 00:00 to 01:00 and falls back from 01:00 to 00:00.
    assert_raises(Error) { sq("0 0 * * * America/Havana").convert }
    assert_equal "America/Havana", sq("every minute America/Havana").convert[:timezone]
  end

  # A burst of minutes: after the last but one, CronWatch counts the last as
  # covered by it (a minute of early slack), so it wants the next burst.
  def test_a_difference_the_early_slack_explains_is_accepted
    assert_equal({ schedule: "* 5 * * *", timezone: "Asia/Kolkata" }, sq("* 5 * * * Asia/Kolkata").convert)
    assert_equal "22,23,24,25,26,27,28,29,30,31,32,33 1 * * *", sq("22-33 1 * * * UTC").convert[:schedule]
    assert_equal "19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48 11 * * 3",
                 sq("19-48 11 * * 3 UTC").convert[:schedule]
  end

  def test_a_rails_time_zone_name_is_read_as_solid_queue_reads_it
    require "active_support"
    require "active_support/values/time_zone"
    assert_equal({ schedule: "0 3 * * *", timezone: "America/New_York" },
                 sq("every day at 3am", time_zone: "Eastern Time (US & Canada)").convert)
    assert_equal "Europe/London", sq("every day at 3am", time_zone: ActiveSupport::TimeZone["London"]).convert[:timezone]
    error = assert_raises(Error) { sq("every day at 3am", time_zone: "Middle Earth").convert }
    assert_match(/the time zone "Middle Earth" is neither an IANA timezone .* nor a Rails time zone name/, error.message)
  end

  def test_dates_and_times_in_a_tasks_args_are_read_as_solid_queue_reads_them
    Dir.mktmpdir do |dir|
      path = File.join(dir, "recurring.yml")
      File.write(path, <<~YAML)
        production:
          backfill:
            class: BackfillJob
            args: [2026-01-01, 2026-01-01 12:00:00]
            schedule: every day at 4am
      YAML
      entries = SQ.new(path, env: "production", time_zone: "UTC").entries
      assert_equal %w[backfill], entries.map(&:key)
      assert_equal({ schedule: "0 4 * * *", timezone: "UTC" }, entries.first.convert)
    end
  end

  def test_solid_queue_skip_recurring_reads_no_tasks
    with = ->(value, &block) do
      before = ENV.fetch("SOLID_QUEUE_SKIP_RECURRING", nil)
      value.nil? ? ENV.delete("SOLID_QUEUE_SKIP_RECURRING") : ENV["SOLID_QUEUE_SKIP_RECURRING"] = value
      block.call
    ensure
      before.nil? ? ENV.delete("SOLID_QUEUE_SKIP_RECURRING") : ENV["SOLID_QUEUE_SKIP_RECURRING"] = before
    end
    with.call("true") do
      assert_empty recurring.entries
      assert_match(/not read: SOLID_QUEUE_SKIP_RECURRING is set/, recurring.label)
      refute_empty SQ.new(File.join(DIR, "recurring.yml"), env: "production", skip_recurring: false).entries
    end
    with.call("false") { refute_empty recurring.entries }
    with.call("") { refute_empty recurring.entries }
  end

  # sidekiq-cron's own parse, where the gem is here: the same Fugit::Cron.
  def test_sidekiq_cron_parses_as_the_conversion_assumes
    begin
      require "sidekiq-cron"
    rescue LoadError
      skip "sidekiq-cron is not installed"
    end
    ["*/15 * * * *", "every day at 9am Europe/London", "30 4 * * sun America/New_York", "every monday at 8:30",
     "every day at 9:15 and 17:30"].each do |text|
      job = Sidekiq::Cron::Job.allocate
      job.instance_variable_set(:@cron, text)
      theirs = job.send(:parsed_cron)
      converted = sc(text).convert
      parsed = Cronwatch::Schedule.parse(converted[:schedule], converted[:timezone])
      at = Time.utc(2026, 3, 1)
      40.times do
        at = theirs.next_time(at).utc
        assert_equal at.to_i * 1000, Cronwatch::Schedule.fire_after(parsed, at.to_i * 1000 - 1), text
      end
    end
  end

  def test_schedule_for_finds_the_class_once
    Cronwatch::Scheduler.sources = [recurring(time_zone: "UTC"), cron_file]
    assert_equal({ schedule: "12 * * * *", timezone: "UTC" }, Cronwatch::Scheduler.schedule_for("SyncFeedsJob"))
    assert_equal({ schedule: "0,15,30,45 * * * *", timezone: "UTC" }, Cronwatch::Scheduler.schedule_for("HardWorker"))

    error = assert_raises(Error) { Cronwatch::Scheduler.schedule_for("MissingJob") }
    assert_match(/MissingJob uses schedule: :from_scheduler, but no enabled entry in .*recurring\.yml or .*schedule\.yml has class MissingJob/,
                 error.message)
    error = assert_raises(Error) { Cronwatch::Scheduler.schedule_for("ImportWorker") }
    assert_match(/no enabled entry/, error.message, "a disabled sidekiq-cron job is not scheduled")

    Cronwatch::Scheduler.sources = [recurring(time_zone: "UTC"), SC.new({ "again" => { "class" => "SyncFeedsJob", "cron" => "0 * * * *" } })]
    error = assert_raises(Error) { Cronwatch::Scheduler.schedule_for("SyncFeedsJob") }
    assert_match(/SyncFeedsJob uses schedule: :from_scheduler, but it is scheduled 2 times \(.*recurring\.yml sync_feeds, the sidekiq-cron config again\); a job has one schedule/,
                 error.message)

    Cronwatch::Scheduler.sources = []
    error = assert_raises(Error) { Cronwatch::Scheduler.schedule_for("SyncFeedsJob") }
    assert_match(/neither Solid Queue nor sidekiq-cron is loaded; set Cronwatch::Scheduler.sources/, error.message)
  end

  def test_schedule_for_reads_the_file_in_a_process_that_schedules_nothing
    # One of several bin/jobs, started with SOLID_QUEUE_SKIP_RECURRING: it still performs what the scheduling one enqueues.
    skipping = SQ.new(File.join(DIR, "recurring.yml"), env: "production", time_zone: "UTC", skip_recurring: true)
    Cronwatch::Scheduler.sources = [skipping]
    assert_empty skipping.entries, "declare_from_scheduler! still declares nothing here"
    assert_equal({ schedule: "12 * * * *", timezone: "UTC" }, Cronwatch::Scheduler.schedule_for("SyncFeedsJob"))
  end

  def test_schedule_for_a_class_scheduled_only_in_another_environment_is_no_schedule_here
    # Rails 8's generated recurring.yml has only production:.
    production_only = { "production" => { "nightly" => { "class" => "NightlyJob", "schedule" => "every day at 3am" } } }
    %w[development test].each do |env|
      Cronwatch::Scheduler.sources = [SQ.new(production_only, env: env, time_zone: "UTC")]
      assert_equal({ schedule: nil }, Cronwatch::Scheduler.schedule_for("NightlyJob"), env)
      error = assert_raises(Error) { Cronwatch::Scheduler.schedule_for("MissingJob") }
      assert_match(/no enabled entry/, error.message, "a class no environment schedules is still refused")
    end
    # A section for this environment without the class, too.
    Cronwatch::Scheduler.sources = [recurring(env: "development", time_zone: "UTC")]
    assert_equal({ schedule: nil }, Cronwatch::Scheduler.schedule_for("NightlyBackupJob"))
    assert_equal({ schedule: "0,30 * * * *", timezone: "UTC" }, Cronwatch::Scheduler.schedule_for("SyncFeedsJob"))
    Cronwatch::Scheduler.sources = [SQ.new(production_only, env: "production", time_zone: "UTC")]
    assert_equal({ schedule: "0 3 * * *", timezone: "UTC" }, Cronwatch::Scheduler.schedule_for("NightlyJob"))
  end

  def test_a_monitored_class_scheduled_only_in_another_environment_loads_and_is_declared_without_a_schedule
    Cronwatch::Scheduler.sources = [SQ.new({ "production" => { "nightly" => { "class" => "NightlyJob", "schedule" => "every day at 3am" } } },
                                           env: "development", time_zone: "UTC")]
    klass = Class.new do
      extend Cronwatch::Monitored::ClassMethods

      def self.name = "NightlyJob"
    end
    klass.cronwatch(schedule: :from_scheduler)
    client, handle = klass.cronwatch_registration
    assert_same Cronwatch.client, client
    assert_nil handle.definition.schedule
    assert_equal "nightly", handle.name
  end

  def test_default_sources_follow_what_is_loaded
    expected = defined?(::Sidekiq::Cron::Job) ? [SC] : []
    assert_equal expected, Cronwatch::Scheduler.sources.map(&:class), "Solid Queue is not loaded in this process"
    Cronwatch::Scheduler.root = DIR
    assert_equal File.join(DIR, "config/recurring.yml"), SQ.new.path
    assert_equal File.join(DIR, "config/schedule.yml"), SC.new.path
    assert_equal "config/recurring.yml", SQ.new.label
  end

  # A job whose schedule came from the config is reported missed at the
  # time the scheduler should have run it, and not before.
  def test_a_job_from_the_config_is_missed_when_the_scheduler_skips_a_run
    converted = sq("every day at 3am America/New_York").convert
    client, clock, capture = make
    clock.now = Time.utc(2026, 3, 6, 12).to_i * 1000
    job = client.job("backup", **converted, grace: "10m")
    cron = Fugit.parse("every day at 3am America/New_York")

    # The scheduler runs it every day across the change to summer time.
    at = cron.next_time(Time.at(clock.now / 1000).utc)
    5.times do
      clock.now = at.to_i * 1000 + 5000
      job.run { "ok" }
      clock.now = cron.next_time(at).to_i * 1000 + 9 * 60_000
      client.check
      at = cron.next_time(at)
    end
    assert_empty capture.types, "no run was missed"

    # Then it skips one: missed once the grace after 03:00 New York time is over.
    skipped = at.to_i * 1000
    clock.now = skipped + 9 * 60_000
    client.check
    assert_empty capture.types
    clock.now = skipped + 11 * 60_000
    client.check
    assert_equal [:missed], capture.types
    assert_includes capture.alerts.first.message, "Due 2026-03-12 07:00:00 UTC (11m ago)" # 03:00 in New York
    assert_includes capture.alerts.first.message, "Schedule: 0 3 * * * (America/New_York)."
  end
end
