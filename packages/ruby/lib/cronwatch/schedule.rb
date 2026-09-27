# frozen_string_literal: true

require "fugit"
require_relative "zone"
require_relative "cron_pattern"

module Cronwatch
  # Schedules: "0 2 * * *" (cron, five or six fields), "@hourly", or
  # "every 5m". The SDK computes fire times with croner; this module gives
  # the same times. Fugit parses the cron fields. Croner's rules decide what
  # is accepted and how a fire lands on a clock that jumps (daylight saving),
  # so both are ported here and a Node and a Ruby process sharing one store
  # agree on every due time.
  module Schedule
    # How early a run may start and still count for the fire it was meant for.
    EARLY_SLACK_MS = 60_000

    Parsed = Struct.new(:kind, :source, :timezone, :every_ms, keyword_init: true) do
      include Serializable

      # The compiled cron fields, kept out of the public shape.
      attr_accessor :pattern

      def cron? = kind == :cron
      def interval? = kind == :interval

      def to_h
        out = { "kind" => kind.to_s, "source" => source }
        out["timezone"] = timezone if timezone
        out["everyMs"] = every_ms if every_ms
        out
      end
    end

    Expectation = Struct.new(:due_at, :deadline, keyword_init: true) do
      include Serializable

      def to_h = { "dueAt" => due_at, "deadline" => deadline }
    end

    @cache = {}
    @lock = Mutex.new

    module_function

    # Parsed once per (schedule, timezone) pair and cached. Without a timezone
    # the expression is read in the process timezone, like crontab. Vercel and
    # GitHub Actions run their crons in UTC, so pass timezone: "UTC" for those.
    def parse(schedule, timezone = nil)
      key = "#{timezone}|#{schedule}"
      hit = @lock.synchronize { @cache[key] }
      return hit if hit

      text = JS.trim(schedule.to_s)
      every = Regexp.new("\\Aevery[#{JS::WHITESPACE}]+(.+)\\z", Regexp::IGNORECASE).match(text)
      if every
        every_ms = Duration.parse(every[1], "schedule interval")
        raise ArgumentError, "schedule \"#{schedule}\" is shorter than one second" if every_ms < 1000

        parsed = Parsed.new(kind: :interval, source: text, every_ms: every_ms)
      else
        begin
          pattern = CronPattern.compile(text)
        rescue ArgumentError => e
          raise ArgumentError, "schedule \"#{schedule}\" is not a cron expression or \"every <duration>\": #{e.message}"
        end
        parsed = Parsed.new(kind: :cron, source: text, timezone: timezone.nil? || timezone == "" ? nil : timezone)
        parsed.pattern = pattern
      end
      parsed.freeze
      @lock.synchronize { @cache[key] = parsed }
    end

    # The first fire strictly after `from`, or nil when the cron never fires
    # again. The walker works on the wall clock and Zone.to_utc takes the
    # earlier of a repeated time, so, like croner, asked from inside the hour
    # that repeats when clocks go back it can answer with times in the past.
    # Its answers are filtered, and a stretch of nothing but past times is
    # stepped over an hour at a time. Ported from fireAfter in schedule.ts.
    def fire_after(parsed, from)
      raise ArgumentError, "schedule \"#{parsed.source}\" was not made by Schedule.parse" unless parsed.pattern

      probe = from
      4.times do
        runs = next_runs(parsed, 8, probe)
        return nil if runs.empty?

        found = runs.find { |t| t > from }
        return found if found

        probe += 3_600_000
      end
      nil
    end

    # Every fire of a cron strictly after `from` and at or before `to`,
    # ascending, or nil when there are more than `limit`. Walks the fires in
    # batches, as firesBetween in schedule.ts asks croner for them, and drops
    # any that do not move forward (see fire_after).
    def fires_between(parsed, from, to, limit)
      raise ArgumentError, "schedule \"#{parsed.source}\" was not made by Schedule.parse" unless parsed.pattern

      out = []
      probe = from
      last = from
      1000.times do
        batch = next_runs(parsed, [limit + 1 - out.length, 24].min, probe)
        return out if batch.empty?

        batch.each do |t|
          next if t <= last
          return out if t > to

          out << t
          last = t
          return nil if out.length > limit
        end
        finish = batch.last
        probe = finish > probe ? finish : probe + 3_600_000
      end
      out
    end

    # Up to `count` fires, each found from the one before, as croner's nextRuns.
    def next_runs(parsed, count, from)
      runs = []
      at = from
      count.times do
        at = parsed.pattern.next_after(at, parsed.timezone)
        break if at.nil?

        runs << at
      end
      runs
    end

    # The next time the schedule fires strictly after `from`. For an interval, counted from the last run when there is one.
    def next_fire(parsed, from, last_run_at)
      return (last_run_at || from) + parsed.every_ms if parsed.interval?

      fire_after(parsed, from)
    end

    # When the schedule next wants a run, given the last one. For a cron that is
    # the first fire the last run does not already cover; with no run yet, the
    # first fire at or after registration. For an interval it is the last run's
    # start (or registration) plus the interval. Nil for a cron that never
    # fires again.
    #
    # Counting forward from the last run, rather than back from now, is what
    # lets a job whose period is shorter than its grace be missed at all, and it
    # works for a cron that fires once a year or less.
    def expectation(parsed, last_run_at, registered_at, grace_ms)
      due_at =
        if parsed.interval? then (last_run_at || registered_at) + parsed.every_ms
        elsif last_run_at.nil? then fire_after(parsed, registered_at - 1)
        else due_after_run(parsed, last_run_at)
        end
      due_at.nil? ? nil : Expectation.new(due_at: due_at, deadline: due_at + grace_ms)
    end

    # The first fire that a run starting at `started_at` does not cover.
    def due_after_run(parsed, started_at)
      # A fire at or before the start is covered by the run itself.
      following_fire = fire_after(parsed, started_at)
      return nil if following_fire.nil?

      following = fire_after(parsed, following_fire)
      covers = run_covers?(started_at, following_fire, following) || in_spring_forward_gap?(parsed, started_at, following_fire)
      covers ? following : following_fire
    end

    # Whether a run starting at `started_at` covers the fire at `due_at`. A minute
    # of slack before the tick absorbs schedulers that fire a touch early. When
    # the fire after `due_at` is known, the slack is at most half the gap between
    # the two, so one run of an every-minute cron never covers two fires.
    def run_covers?(started_at, due_at, following_at = nil)
      slack = following_at.nil? ? EARLY_SLACK_MS : [EARLY_SLACK_MS, (following_at - due_at).div(2)].min
      started_at >= due_at - slack
    end

    # On the night clocks spring forward, a fire whose local time does not exist
    # (02:30 when 02:00 jumps to 03:00) is moved by croner to the same distance
    # past the jump (03:30), while vixie cron runs it at the jump itself (03:00).
    # A run that starts at or after the jump, and before the first fire after
    # it when that fire lies within one gap of it, is taken to cover that fire,
    # so neither scheduler's run is reported as missed. A cron that really fires
    # at 03:30 that night is treated the same way, which only matters if it also
    # ran early by up to an hour.
    def in_spring_forward_gap?(parsed, started_at, fire_at)
      lookback = 3 * 3_600_000
      after = utc_offset(fire_at, parsed.timezone)
      before = utc_offset(fire_at - lookback, parsed.timezone)
      gap = after - before
      return false if gap <= 0

      # Find the jump: the first minute in the window with the later offset.
      lo = fire_at - lookback
      hi = fire_at
      while hi - lo > 60_000
        mid = lo + (hi - lo).div(2)
        if utc_offset(mid, parsed.timezone) == after then hi = mid
        else lo = mid
        end
      end
      jump_at = hi.div(60_000) * 60_000
      return false if fire_at - jump_at >= gap || started_at < jump_at - EARLY_SLACK_MS || started_at >= fire_at

      # Only the first fire after the jump can be a moved one; a cron that also
      # fires at the jump (every 10 minutes, say) was not moved at all.
      fire_after(parsed, jump_at - 1) == fire_at
    end

    # Milliseconds the zone's wall clock is ahead of UTC at `at`.
    def utc_offset(at, timezone)
      Zone.offset(at.div(1000), timezone) * 1000
    end
  end
end
