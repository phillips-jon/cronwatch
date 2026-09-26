# frozen_string_literal: true

require_relative "test_helper"
require "cronwatch/scheduler"

# Reading schedules from Solid Queue's and sidekiq-cron's config, and turning
# what Fugit reads into the cron expression CronWatch reads.
class SchedulerTest < Minitest::Test
  include TestHelpers

  SQ = Cronwatch::Scheduler::SolidQueue
  SC = Cronwatch::Scheduler::SidekiqCron
  Error = Cronwatch::Scheduler::Error
  DIR = File.expand_path("support/schedules", __dir__)
  DAY = 86_400_000

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

  # Every accepted conversion, in zones with and without daylight saving:
  # after each run Fugit makes, CronWatch wants the next run Fugit makes.
  # Where clocks go back Fugit runs a repeated time twice, which CronWatch
  # takes as an early run; nowhere does CronWatch want a run Fugit skips.
  def test_conversions_match_fugits_own_next_time_across_the_year
    schedules = ["every hour at minute 12", "every day at 10am", "every day at 3am", "0 2 * * *", "every 5 minutes",
                 "every monday at 9am", "every weekday at 8:30", "0 0 L * *", "0 12 * * 5#-1", "every 30 seconds"]
    zones = %w[UTC America/New_York Europe/London Australia/Sydney Asia/Kolkata]
    checked = 0
    zones.each do |zone|
      schedules.each do |schedule|
        converted = begin
          sq("#{schedule} #{zone}").convert
        rescue Error
          next if zone != "UTC" # a clock change the scheduler skips: refused, as above

          raise
        end
        cron = Fugit.parse("#{schedule} #{zone}")
        parsed = Cronwatch::Schedule.parse(converted[:schedule], converted[:timezone])
        changes = Cronwatch::Zone.get(zone).transitions_up_to(Time.utc(2028, 1, 1), Time.utc(2026, 1, 1)).map { |c| c.at.to_i * 1000 }
        windows(schedule, changes).each do |from, to|
          at = cron.next_time(Time.at(from / 1000).utc).to_i * 1000
          while at < to
            following = cron.next_time(Time.at(at / 1000).utc).to_i * 1000
            due = Cronwatch::Schedule.due_after_run(parsed, at)
            near = changes.any? { |t| t > at - DAY && t < following + DAY }
            label = "#{schedule} in #{zone}, after #{Time.at(at / 1000).utc}"
            if near
              assert_operator due, :>=, following, label
            else
              assert_equal following, due, label
            end
            checked += 1
            at = following
          end
        end
      end
    end
    assert_operator checked, :>, 5000
  end

  # Stretches to walk: around every clock change of 2026 and 2027, and the
  # start of each month of 2026, shorter the more often the schedule fires (all of
  # 2026 for one that fires weekly or less).
  def windows(schedule, changes)
    return [[Time.utc(2026, 1, 1).to_i * 1000, Time.utc(2027, 1, 1).to_i * 1000]] if schedule.match?(/ L | 5#-1|monday/)

    around, month =
      case schedule
      when /seconds/ then [20 * 60_000, 5 * 60_000]
      when /minutes/ then [2 * 3_600_000, 3_600_000]
      when /hour/ then [DAY / 2, DAY / 2]
      else [3 * DAY, 7 * DAY]
      end
    months = (1..12).map { |i| Time.utc(2026, i, 1).to_i * 1000 }
    changes.map { |t| [t - around, t + around] } + months.map { |t| [t, t + month] }
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
