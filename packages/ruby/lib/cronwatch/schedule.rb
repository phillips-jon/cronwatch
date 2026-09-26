# frozen_string_literal: true

require "fugit"

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

    # The first fire strictly after `from`, or nil when the cron never fires again.
    # The first fire strictly after `from`, or nil when the cron never fires
    # again. Like croner, the walker can answer with times in the past when
    # asked from inside the hour that repeats when clocks go back, so its
    # answers are filtered, and a stretch of nothing but past times is stepped
    # over an hour at a time. Ported from fireAfter in schedule.ts.
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

  # IANA zones through TZInfo (which Fugit brings, by way of et-orbi), or the
  # process's own zone when none is named, as JavaScript's Date does.
  module Zone
    @zones = {}
    @names = nil
    @lock = Mutex.new

    module_function

    # A TZInfo zone. Names are matched without regard to case, as Intl does.
    def get(name)
      @lock.synchronize do
        @zones[name] ||= begin
          TZInfo::Timezone.get(name)
        rescue TZInfo::InvalidTimezoneIdentifier
          @names ||= TZInfo::Timezone.all_identifiers.to_h { |id| [id.downcase, id] }
          canonical = @names[name.to_s.downcase]
          raise ArgumentError, "timezone \"#{name}\" is not an IANA timezone" unless canonical

          TZInfo::Timezone.get(canonical)
        end
      end
    end

    def valid?(name)
      get(name)
      true
    rescue ArgumentError, TZInfo::InvalidTimezoneIdentifier, TZInfo::InvalidDataSource
      false
    end

    # Seconds the wall clock is ahead of UTC at epoch second `sec`.
    def offset(sec, timezone)
      return Time.at(sec).utc_offset if timezone.nil?

      get(timezone).period_for_utc(Time.at(sec).utc).utc_total_offset
    end

    # The wall clock at epoch second `sec`: [year, month, day, hour, minute, second].
    def wall(sec, timezone)
      t = Time.at(sec + offset(sec, timezone)).utc
      [t.year, t.month, t.day, t.hour, t.min, t.sec]
    end

    def civil_seconds(wall)
      Time.utc(*wall).to_i
    end

    # Croner's fromTZ: the instant a wall-clock time names. A time that falls in
    # a spring-forward gap is moved forward by the gap; a time that occurs
    # twice (fall back) is the earlier of the two. Returns epoch seconds.
    def to_utc(wall, timezone)
      target = civil_seconds(wall)
      guess = target + (target - civil_seconds(wall(target, timezone)))
      seen = wall(guess, timezone)
      if seen == wall
        earlier = guess - 3600
        return wall(earlier, timezone) == wall ? earlier : guess
      end

      shifted = guess + target - civil_seconds(seen)
      return shifted if wall(shifted, timezone) == wall

      [guess, shifted].max
    end
  end

  # A cron expression's fields, and the next time they match. What is
  # accepted, and which times match, follow croner; Fugit parses the values.
  class CronPattern
    NICKNAMES = {
      "@yearly" => "0 0 1 1 *", "@annually" => "0 0 1 1 *", "@monthly" => "0 0 1 * *", "@weekly" => "0 0 * * 0",
      "@daily" => "0 0 * * *", "@midnight" => "0 0 * * *", "@hourly" => "0 * * * *",
    }.freeze
    SIZES = { second: 60, minute: 60, hour: 24, day: 31, month: 12, dayOfWeek: 7 }.freeze
    # Croner's bits for "the nth weekday of the month"; 32 is the last one, 63 any.
    NTH = [1, 2, 4, 8, 16].freeze
    LAST_NTH = 32
    ANY_NTH = 63

    attr_reader :seconds, :minutes, :hours, :days, :months, :weekdays, :last_day_of_month, :star_dom, :star_dow,
                :and_logic

    def self.compile(text)
      new(text)
    end

    def initialize(text)
      fields, dom, dow = croner_fields(text)
      cron = begin
        Fugit::Cron.parse(fields.each_with_index.map { |f, i| i == 3 ? dom : (i == 5 ? dow : f) }.join(" "))
      rescue StandardError
        nil
      end
      # Croner accepts a few forms Fugit does not read (a range with #, a day of
      # the month with L after it, a date no month has). Those are refused.
      raise ArgumentError, "CronPattern: '#{text}' uses a form the Ruby port does not read" unless cron

      @seconds = flags(cron.seconds, 60, 0)
      @minutes = flags(cron.minutes, 60, 0)
      @hours = flags(cron.hours, 24, 0)
      @days = Array.new(31, false)
      if cron.monthdays.nil?
        @days.fill(true)
      else
        cron.monthdays.each { |d| @days[d - 1] = true if d.positive? }
      end
      @months = flags(cron.months, 12, 1)
      @weekdays = Array.new(7, 0)
      if cron.weekdays.nil?
        @weekdays.fill(ANY_NTH)
      else
        cron.weekdays.each do |day, nth|
          day = 0 if day == 7
          @weekdays[day] =
            if nth.nil? then ANY_NTH
            elsif nth == -1 then @weekdays[day] | LAST_NTH
            else @weekdays[day] | NTH[nth - 1]
            end
        end
      end
      freeze
    end

    # The first fire strictly after epoch milliseconds `from`, as epoch
    # milliseconds, or nil when there is none before the year 3000.
    def next_after(from, timezone)
      wall = Zone.wall(from.div(1000), timezone)
      date = Walker.new(self, wall)
      date.second += 1
      date.apply
      found = date.search
      found && Zone.to_utc(found, timezone) * 1000
    end

    private

    def flags(values, size, base)
      return Array.new(size, true) if values.nil?

      out = Array.new(size, false)
      values.each { |v| out[v - base] = true }
      out
    end

    # Applies croner's reading of the text: nicknames, five fields padded with
    # seconds, month and weekday names, L, ?, the + for AND, and the checks
    # croner makes on every field, with its messages. Returns the six fields,
    # and the day-of-month and day-of-week fields to hand Fugit.
    def croner_fields(text)
      pattern = text
      pattern = JS.trim(NICKNAMES.fetch(JS.trim(pattern).downcase) { nickname_or_text(pattern) }) if pattern.include?("@")
      parts = pattern.scan(JS::NOT_SPACE)
      parts = [""] if parts.empty?
      if parts.length < 5 || parts.length > 7
        raise ArgumentError, "CronPattern: invalid configuration format ('#{pattern}'), exactly five, six, or seven space separated parts are required."
      end
      raise ArgumentError, "CronPattern: a seventh (year) field is not supported by the Ruby port" if parts.length == 7

      parts.unshift("0") if parts.length == 5
      @last_day_of_month = false
      fugit_dom = parts[3]
      if parts[3].upcase == "LW"
        raise ArgumentError, "CronPattern: LW is not supported by the Ruby port"
      elsif parts[3].upcase.include?("L")
        parts[3] = parts[3].gsub(/L/i, "")
        @last_day_of_month = true
      end
      @star_dom = parts[3] == "*"
      parts[4] = month_names(parts[4]) if parts[4].length >= 3
      parts[5] = day_names(parts[5]) if parts[5].length >= 3
      @and_logic = false
      if parts[5].start_with?("+")
        @and_logic = true
        parts[5] = parts[5][1..]
        raise ArgumentError, "CronPattern: Day-of-week field cannot be empty after '+' modifier." if parts[5].empty?
      end
      @star_dow = parts[5] == "*"
      if pattern.include?("?")
        parts.map! { |p| p.tr("?", "*") }
        fugit_dom = fugit_dom.tr("?", "*")
      end
      parts.each_with_index do |part, i|
        illegal = i == 3 ? %r{[^/*0-9,\-WwLl]+} : (i == 5 ? %r{[^/*0-9,\-#Ll]+} : %r{[^/*0-9,\-]+})
        raise ArgumentError, "CronPattern: configuration entry #{i} (#{part}) contains illegal characters." if illegal.match?(part)
      end
      raise ArgumentError, "CronPattern: W is not supported by the Ruby port" if parts[3].match?(/w/i)

      check(:second, parts[0], 0)
      check(:minute, parts[1], 0)
      check(:hour, parts[2], 0)
      check(:day, parts[3], -1)
      check(:month, parts[4], -1)
      check(:dayOfWeek, parts[5], 0)
      # Croner writes the last Friday as 5L, Fugit as 5#-1.
      fugit_dow = parts[5].gsub(/(\d+)L/i) { "#{Regexp.last_match(1)}#-1" }
      fugit_dom = fugit_dom.gsub(/L/i, "L")
      [parts, fugit_dom, fugit_dow]
    end

    def nickname_or_text(pattern)
      raise ArgumentError, "CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection." if JS.trim(pattern).downcase == "@reboot"

      pattern
    end

    def month_names(text)
      %w[jan feb mar apr may jun jul aug sep oct nov dec].each_with_index.reduce(text) do |out, (name, i)|
        out.gsub(/#{name}/i, (i + 1).to_s)
      end
    end

    def day_names(text)
      text = text.gsub(/-sun/i, "-7")
      %w[sun mon tue wed thu fri sat].each_with_index.reduce(text) { |out, (name, i)| out.gsub(/#{name}/i, i.to_s) }
    end

    # Croner's partToArray, keeping only its checks.
    def check(type, text, offset)
      if text == "" && !(type == :day && @last_day_of_month)
        raise ArgumentError, "CronPattern: configuration entry #{type} (#{text}) is empty, check for trailing spaces."
      end
      return if text == "*"

      items = text.split(",", -1)
      if items.length > 1
        items.each { |item| check(type, item, offset) }
      elsif text.include?("-") && text.include?("/")
        check_range_with_step(type, text, offset)
      elsif text.include?("-")
        check_range(type, text, offset)
      elsif text.include?("/")
        check_step(type, text, offset)
      elsif text != ""
        value, nth = extract_nth(text, type)
        number = parse_int(value)
        raise ArgumentError, "CronPattern: #{type} is not a number: '#{text}'" if number.nil?

        check_value(type, number + offset, nth)
      end
    end

    def check_range_with_step(type, text, offset)
      value, nth = extract_nth(text, type)
      match = %r{\A(\d+)-(\d+)/(\d+)\z}.match(value)
      raise ArgumentError, "CronPattern: Syntax error, illegal range with stepping: '#{text}'" unless match

      from = match[1].to_i + offset
      to = match[2].to_i + offset
      step = match[3].to_i
      check_range_bounds(from, to, step, type, text)
      from.step(to, step) { |v| check_value(type, v, nth) }
    end

    def check_range(type, text, offset)
      value, nth = extract_nth(text, type)
      bounds = value.split("-", -1)
      raise ArgumentError, "CronPattern: Syntax error, illegal range: '#{text}'" unless bounds.length == 2

      from = parse_int(bounds[0])
      to = parse_int(bounds[1])
      raise ArgumentError, "CronPattern: Syntax error, illegal lower range (NaN)" if from.nil?
      raise ArgumentError, "CronPattern: Syntax error, illegal upper range (NaN)" if to.nil?

      check_range_bounds(from + offset, to + offset, nil, type, text)
      (from + offset).upto(to + offset) { |v| check_value(type, v, nth) }
    end

    def check_step(type, text, _offset)
      value, nth = extract_nth(text, type)
      parts = value.split("/", -1)
      raise ArgumentError, "CronPattern: Syntax error, illegal stepping: '#{text}'" unless parts.length == 2
      if parts[0] == ""
        raise ArgumentError, "CronPattern: Syntax error, stepping with missing prefix ('#{text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead."
      end
      if parts[0] != "*"
        raise ArgumentError, "CronPattern: Syntax error, stepping with numeric prefix ('#{text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead."
      end

      step = parse_int(parts[1])
      raise ArgumentError, "CronPattern: Syntax error, illegal stepping: (NaN)" if step.nil?

      check_range_bounds(0, SIZES[type] - 1, step, type, text)
      0.step(SIZES[type] - 1, step) { |v| check_value(type, v, nth) }
    end

    def check_range_bounds(from, to, step, type, text)
      raise ArgumentError, "CronPattern: From value is larger than to value: '#{text}'" if from > to
      return if step.nil?
      raise ArgumentError, "CronPattern: Syntax error, illegal stepping: 0" if step.zero?
      if step > SIZES[type]
        raise ArgumentError, "CronPattern: Syntax error, steps cannot be greater than maximum value of part (#{SIZES[type]})"
      end
    end

    def extract_nth(text, type)
      if text.include?("#")
        raise ArgumentError, "CronPattern: nth (#) only allowed in day-of-week field" unless type == :dayOfWeek

        pieces = text.split("#", -1)
        [pieces[0], pieces[1]]
      elsif text.upcase.end_with?("L")
        unless type == :dayOfWeek
          raise ArgumentError, "CronPattern: L modifier only allowed in day-of-week field (use L alone for day-of-month)"
        end

        [text[0...-1], "L"]
      else
        [text, nil]
      end
    end

    def check_value(type, value, nth)
      if type == :dayOfWeek
        value = 0 if value == 7
        raise ArgumentError, "CronPattern: Invalid value for dayOfWeek: #{value}" if value.negative? || value > 6
        # An empty nth ("1#") falls back to any, as `"" || 63` does in croner.
        return if nth.nil? || nth == "" || nth.upcase == "L"

        n = nth.match?(/\A\d+\z/) ? nth.to_i : nil
        return if n && n < 6 && n.positive?

        raise ArgumentError, "CronPattern: nth weekday out of range, should be 1-5 or L. Value: #{nth}, Type: string"
      end
      limit = SIZES[type]
      return if value >= 0 && value < limit

      raise ArgumentError, "CronPattern: Invalid value for #{type}: #{value}"
    end

    # JavaScript's parseInt, for the characters a field may hold: nil for NaN.
    def parse_int(text)
      match = /\A[+-]?\d+/.match(text)
      match && match[0].to_i
    end

    # Croner's CronDate: a wall-clock time whose fields are moved forward to
    # the next match, a field at a time, spilling into the next month or year
    # as croner does (including its habit of stepping into a day the month
    # does not have and letting the date roll over). Month is 0 based.
    class Walker
      DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze
      # [field, the field above it, offset from a field value to its pattern index]
      ORDER = [%i[month year], %i[day month], %i[hour day], %i[minute hour], %i[second minute]].freeze
      OFFSETS = { month: 0, day: -1, hour: 0, minute: 0, second: 0 }.freeze

      attr_accessor :year, :month, :day, :hour, :minute, :second

      def initialize(pattern, wall)
        @pattern = pattern
        @year, month, @day, @hour, @minute, @second = wall
        @month = month - 1
      end

      def apply
        unless month > 11 || month.negative? || day > DAYS_IN_MONTH[month] || day < 1 || hour > 59 || minute > 59 ||
               second > 59 || hour.negative? || minute.negative? || second.negative?
          return false
        end

        first = Time.utc(year + month.div(12), (month % 12) + 1, 1).to_i
        t = Time.at(first + ((day - 1) * 86_400) + (hour * 3600) + (minute * 60) + second).utc
        @year = t.year
        @month = t.month - 1
        @day = t.day
        @hour = t.hour
        @minute = t.min
        @second = t.sec
        true
      end

      # Croner's recurse, as a loop. Returns the wall-clock match or nil.
      def search
        level = 0
        loop do
          field, above = ORDER[level]
          found = find_next(field, OFFSETS[field])
          if found > 1
            ((level + 1)...ORDER.length).each { |i| set(ORDER[i][0], -OFFSETS[ORDER[i][0]]) }
            if found == 3
              set(above, get(above) + 1)
              set(field, -OFFSETS[field])
              apply
              level = 0
              next
            elsif apply
              level -= 1
              next
            end
          end
          level += 1
          return [year, month + 1, day, hour, minute, second] if level >= ORDER.length
          return nil if year >= 3000
        end
      end

      private

      def get(field) = instance_variable_get(:"@#{field}")
      def set(field, value) = instance_variable_set(:"@#{field}", value)

      def table(field)
        case field
        when :month then @pattern.months
        when :day then @pattern.days
        when :hour then @pattern.hours
        when :minute then @pattern.minutes
        else @pattern.seconds
        end
      end

      # 1: the field already matches, 2: moved forward to a match, 3: none left.
      def find_next(field, offset)
        before = get(field)
        values = table(field)
        last_day = last_day_of_month(year, month) if @pattern.last_day_of_month
        first_weekday = weekday(year, month, 1) if field == :day && !@pattern.star_dow
        index = get(field) + offset
        while index < values.length
          matched = values[index]
          if field == :day
            day_of_month = index - offset
            matched = true if @pattern.last_day_of_month && day_of_month == last_day
            unless @pattern.star_dow
              bits = @pattern.weekdays[(first_weekday + (day_of_month - 1)) % 7]
              weekday_ok = bits.positive? && nth_weekday?(year, month, day_of_month, bits)
              matched =
                if @pattern.and_logic || @pattern.star_dom then matched && weekday_ok
                else matched || weekday_ok
                end
            end
          end
          if matched
            set(field, index - offset)
            return before == get(field) ? 1 : 2
          end
          index += 1
        end
        3
      end

      def last_day_of_month(year, month)
        return DAYS_IN_MONTH[month] unless month == 1

        (year % 4).zero? && (!(year % 100).zero? || (year % 400).zero?) ? 29 : 28
      end

      # 0 is Sunday. A day past the month's end rolls into the next, as Date.UTC does.
      def weekday(year, month, day)
        days = Time.utc(year + month.div(12), (month % 12) + 1, 1).to_i.div(86_400) + day - 1
        (days + 4) % 7
      end

      def nth_weekday?(year, month, day, bits)
        return true if bits == ANY_NTH

        target = weekday(year, month, day)
        count = (1..day).count { |d| weekday(year, month, d) == target }
        return true if (bits & ANY_NTH).positive? && count <= 5 && (NTH[count - 1] & bits).positive?

        if (bits & LAST_NTH).positive?
          ((day + 1)..last_day_of_month(year, month)).none? { |d| weekday(year, month, d) == target }
        else
          false
        end
      end
    end
  end
end
