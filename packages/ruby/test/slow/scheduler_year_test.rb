# frozen_string_literal: true

require_relative "../test_helper"
require "cronwatch/scheduler"

# The slow check behind Cronwatch::Scheduler: every conversion walked against
# Fugit across the year, independently of the check the converter makes.
# Run by `rake test:slow`, part of `rake test` (and so of CI), not of
# `rake test:core`.
class SchedulerYearTest < Minitest::Test
  Error = Cronwatch::Scheduler::Error
  DAY = 86_400_000

  def sq(schedule)
    Cronwatch::Scheduler::SolidQueue.new({ "task" => { "class" => "SomeJob", "schedule" => schedule } }, time_zone: nil).entries.first
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
end
