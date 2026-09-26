# frozen_string_literal: true

module Cronwatch
  class CronPattern
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
