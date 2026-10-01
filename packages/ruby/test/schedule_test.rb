# frozen_string_literal: true

require_relative "test_helper"

# Schedule cases beyond the conformance fixture: Fugit reads a date no month
# has, or a month the days cannot fall in, differently from croner.
class ScheduleTest < Minitest::Test
  def fires(schedule, from, count)
    parsed = Cronwatch::Schedule.parse(schedule, "UTC")
    Array.new(count) { from = Cronwatch::Schedule.next_fire(parsed, from, nil) }.map { |t| t && Cronwatch::JS.iso(t) }
  end

  def test_a_month_the_days_cannot_fall_in_is_kept_for_the_weekdays
    # croner fires "31 2,3 1" on every Monday of February and March (and the
    # 31st of March); Fugit alone reads the months as March only.
    assert_equal %w[2026-02-02T00:00:00.000Z 2026-02-09T00:00:00.000Z 2026-02-16T00:00:00.000Z 2026-02-23T00:00:00.000Z 2026-03-02T00:00:00.000Z],
                 fires("0 0 31 2,3 1", 1_767_571_200_000, 5)
  end

  def test_a_date_no_month_has_never_fires_and_is_never_due
    parsed = Cronwatch::Schedule.parse("0 0 31 11 *", "UTC")
    assert_nil Cronwatch::Schedule.next_fire(parsed, 0, nil)
    assert_equal [], Cronwatch::Schedule.fires_between(parsed, 0, 4_102_444_800_000, 10)
    assert_nil Cronwatch::Schedule.expectation(parsed, nil, 0, 0)
  end

  def test_one_time_dates_are_refused
    error = assert_raises(ArgumentError) { Cronwatch::Schedule.parse("2027-01-01 09:00") }
    assert_equal 'schedule "2027-01-01 09:00" is not a cron expression or "every <duration>": CronPattern: a one-time date is not supported', error.message
  end
end
