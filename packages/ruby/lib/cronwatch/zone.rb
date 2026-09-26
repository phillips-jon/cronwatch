# frozen_string_literal: true

require "fugit"

module Cronwatch
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
end
