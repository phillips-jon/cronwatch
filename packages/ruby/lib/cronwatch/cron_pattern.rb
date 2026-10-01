# frozen_string_literal: true

require "fugit"
require_relative "zone"
require_relative "walker"

module Cronwatch
  # A cron expression's fields, and the next time they match. What is
  # accepted, and which times match, follow croner; Fugit parses the values.
  #
  # @api private
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
      # Fugit refuses a date no month has ("30 2"), and drops a month the
      # days cannot fall in ("31 2,3" reads as March alone). Croner keeps
      # both, so the days are read with every month and the months with
      # every day, and a date no month has is a cron that never fires.
      cron = fugit(fields.each_with_index.map { |f, i| i == 3 ? dom : (i == 4 ? "*" : (i == 5 ? dow : f)) })
      months = fugit(["0", "0", "0", "*", fields[4], "*"])
      # Croner accepts a few forms Fugit does not read (a range with #, a day of
      # the month with L after it). Those are refused.
      raise ArgumentError, "CronPattern: '#{text}' uses a form the Ruby port does not read" unless cron && months

      @seconds = flags(cron.seconds, 60, 0)
      @minutes = flags(cron.minutes, 60, 0)
      @hours = flags(cron.hours, 24, 0)
      @days = Array.new(31, false)
      if cron.monthdays.nil?
        @days.fill(true)
      else
        cron.monthdays.each { |d| @days[d - 1] = true if d.positive? }
      end
      @months = flags(months.months, 12, 1)
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

    def fugit(fields)
      Fugit::Cron.parse(fields.join(" "))
    rescue StandardError
      nil
    end

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
  end
end
