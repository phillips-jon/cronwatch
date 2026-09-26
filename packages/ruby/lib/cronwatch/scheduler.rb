# frozen_string_literal: true

require "erb"
require "yaml"
require "fugit"
require "cronwatch" unless defined?(Cronwatch::Client)

module Cronwatch
  # Reads schedules from the scheduler's own config, so a job's cron
  # expression is written once: Solid Queue's config/recurring.yml and
  # sidekiq-cron's schedule. Both parse schedules with Fugit, which also
  # takes phrases such as "every day at 3am"; each is turned into the cron
  # expression and timezone CronWatch reads, or refused with an error when
  # CronWatch would not expect runs at exactly the times the scheduler makes
  # them.
  #
  #   cronwatch schedule: :from_scheduler      # in a Cronwatch::ActiveJob or Cronwatch::Sidekiq class
  #   Cronwatch.declare_from_scheduler!        # every entry, once the app has booted
  #
  # The sources are found on their own (Solid Queue's file when Solid Queue
  # is loaded, sidekiq-cron's when it is) or set by hand:
  #
  #   Cronwatch::Scheduler.sources = [Cronwatch::Scheduler::SidekiqCron.new("config/cron.yml")]
  module Scheduler
    # A schedule that cannot be read, found or converted exactly.
    class Error < ArgumentError; end

    # One recurring entry as the scheduler's config gives it. `schedule` is
    # the text as written; `class_name` or `command` says what runs.
    Entry = Struct.new(:source, :key, :class_name, :command, :schedule, :description, :disabled, keyword_init: true) do
      def label
        "#{source.label} #{key}"
      end

      # { schedule:, timezone: } for Cronwatch::Client#job. Raises Error.
      def convert
        source.convert(self)
      end
    end

    # How far ahead the daylight saving check looks.
    HORIZON_YEARS = 5
    # Where, and for how many runs (or until when), a conversion is compared with Fugit.
    SAMPLE_FROM = Time.utc(2026, 1, 1)
    SAMPLE_RUNS = 32
    SAMPLE_UNTIL = Time.utc(2027, 2, 1).to_i * 1000

    # Where a schedule's file is read from, and how its entries are parsed.
    class Source
      attr_reader :config

      def initialize(config, label)
        @config = config
        @label = label
      end

      # config/recurring.yml, relative to the app's root when it is inside it.
      def label
        return @label if @label
        return "the #{name} config" unless path

        root = Scheduler.root.to_s
        path.start_with?("#{root}/") ? path.delete_prefix("#{root}/") : path
      end

      def path
        @config.is_a?(Hash) || @config.is_a?(Array) ? nil : File.expand_path(@config.to_s, Scheduler.root.to_s)
      end

      def entries
        raise NotImplementedError
      end

      private

      # The config: the Hash or Array given, or the file after ERB, as both schedulers read it.
      def read
        return @config if @config.is_a?(Hash) || @config.is_a?(Array)
        return nil unless File.exist?(path)

        text = ERB.new(File.read(path)).result
        YAML.safe_load(text, aliases: true, permitted_classes: [Symbol])
      rescue Psych::Exception, SystemCallError => e
        raise Error, "cronwatch: could not read #{label}: #{e.message}"
      end

      # Fugit::Cron, and the IANA name of the zone the scheduler reads it in.
      def finish(entry, cron, zone)
        zone ||= Scheduler.local_zone_name(entry, name)
        Scheduler.to_cronwatch(entry, cron, zone, name)
      end
    end

    # Solid Queue's recurring tasks: config/recurring.yml (or the file
    # SOLID_QUEUE_RECURRING_SCHEDULE names), the section for the current
    # environment when the file has one, each task a `class:` or a
    # `command:` with a `schedule:`. Read as Solid Queue 1.x reads it.
    class SolidQueue < Source
      # config: a path (default: SOLID_QUEUE_RECURRING_SCHEDULE or
      # config/recurring.yml under the app's root) or the parsed Hash.
      # env: the section to read (default: Rails.env). time_zone: the zone a
      # schedule without one is read in; by default Solid Queue's own
      # (config.solid_queue.time_zone, which is config.time_zone unless set),
      # and Fugit's local zone when that is nil or Solid Queue is older than 1.5.
      def initialize(config = nil, env: nil, time_zone: :auto, label: nil)
        super(config || ENV["SOLID_QUEUE_RECURRING_SCHEDULE"] || "config/recurring.yml", label)
        @env = env
        @time_zone = time_zone
      end

      def name = "Solid Queue"

      def env
        (@env || Scheduler.env).to_s
      end

      def entries
        config = read
        return [] if config.nil?
        raise Error, "cronwatch: #{label} is not a map of recurring tasks" unless config.is_a?(Hash)

        config = symbolize(config)
        config = config[env.to_sym] if config[env.to_sym]
        return [] unless config.is_a?(Hash)

        config.filter_map do |key, options|
          next unless options.is_a?(Hash) && options.key?(:schedule)

          Entry.new(source: self, key: key.to_s, class_name: present(options[:class]), command: present(options[:command]),
                    schedule: options[:schedule], description: present(options[:description]), disabled: false)
        end
      end

      def convert(entry)
        cron = begin
          Fugit.parse(entry.schedule.to_s, multi: :fail)
        rescue ArgumentError => e
          raise Error, "cronwatch: #{entry.label}: Solid Queue does not accept the schedule #{entry.schedule.to_s.inspect}: #{e.message}"
        end
        unless cron.instance_of?(Fugit::Cron)
          raise Error, "cronwatch: #{entry.label}: #{entry.schedule.to_s.inspect} is not a recurring schedule Solid Queue accepts"
        end

        cron = with_default_zone(cron)
        finish(entry, cron, cron.timezone&.name)
      end

      private

      def default_zone
        return @time_zone unless @time_zone == :auto
        return nil unless defined?(::SolidQueue) && ::SolidQueue.respond_to?(:time_zone)

        ::SolidQueue.time_zone
      end

      # As SolidQueue::RecurringTask#apply_default_time_zone_to.
      def with_default_zone(cron)
        zone = default_zone
        return cron unless cron.zone.nil? && zone && zone.to_s != ""

        with = Fugit.parse("#{cron.to_cron_s} #{zone}", multi: :fail)
        with.is_a?(Fugit::Cron) ? with : cron
      rescue ArgumentError
        cron
      end

      def symbolize(value)
        case value
        when Hash then value.each_with_object({}) { |(k, v), out| out[k.respond_to?(:to_sym) ? k.to_sym : k] = symbolize(v) }
        when Array then value.map { |v| symbolize(v) }
        else value
        end
      end

      def present(value)
        value.nil? || value.to_s.strip.empty? ? nil : value.to_s
      end
    end

    # sidekiq-cron's schedule: config/schedule.yml (or the file its
    # configuration names), a map of name to job or a list of jobs with
    # `name:`, each with `cron:` and `class:`. A `cron:` may end in a
    # timezone. Read as sidekiq-cron 1.x and 2.x read it; an entry with
    # `status: disabled` is not scheduled.
    class SidekiqCron < Source
      # config: a path (default: sidekiq-cron's cron_schedule_file, or
      # config/schedule.yml), or the Hash or Array given to
      # Sidekiq::Cron::Job.load_from_hash / load_from_array. mode: how a
      # natural-language schedule with several times is read, as
      # sidekiq-cron's natural_cron_parsing_mode (:single keeps the first,
      # :strict refuses it); by default sidekiq-cron's own setting.
      def initialize(config = nil, mode: :auto, label: nil)
        super(config || default_file, label)
        @mode = mode
      end

      def name = "sidekiq-cron"

      # As sidekiq-cron, a missing .yml is looked for as .yaml.
      def path
        found = super
        return found if found.nil? || File.exist?(found) || !found.end_with?(".yml")

        yaml = found.sub(/\.yml\z/, ".yaml")
        File.exist?(yaml) ? yaml : found
      end

      def entries
        config = read
        return [] if config.nil?

        jobs =
          case config
          when Hash then config.map { |key, job| job.is_a?(Hash) ? stringify(job).merge("name" => key.to_s) : { "name" => key.to_s } }
          when Array then config.map { |job| job.is_a?(Hash) ? stringify(job) : {} }
          else raise Error, "cronwatch: #{label} is not a map or list of cron jobs"
          end
        jobs.map do |job|
          klass = job["class"] || job["klass"]
          Entry.new(source: self, key: job["name"].to_s, class_name: klass&.to_s, command: nil, schedule: job["cron"],
                    description: job["description"]&.to_s, disabled: job["status"].to_s == "disabled")
        end
      end

      def convert(entry)
        text = entry.schedule
        raise Error, "cronwatch: #{entry.label}: sidekiq-cron needs a cron: string" unless text.is_a?(String) && !text.strip.empty?

        cron = begin
          if mode == :strict
            Fugit.parse_cron(text) || Fugit.parse_nat(text, multi: :fail) || raise(ArgumentError, "invalid cron string #{text.inspect}")
          else
            Fugit.do_parse_cronish(text)
          end
        rescue ArgumentError => e
          raise Error, "cronwatch: #{entry.label}: sidekiq-cron does not accept the cron #{text.inspect}: #{e.message}"
        end
        finish(entry, cron, cron.timezone&.name)
      end

      private

      def mode
        return @mode unless @mode == :auto

        config = defined?(::Sidekiq::Cron) && ::Sidekiq::Cron.respond_to?(:configuration) && ::Sidekiq::Cron.configuration
        config.respond_to?(:natural_cron_parsing_mode) ? config.natural_cron_parsing_mode : :single
      end

      def default_file
        config = defined?(::Sidekiq::Cron) && ::Sidekiq::Cron.respond_to?(:configuration) && ::Sidekiq::Cron.configuration
        (config.respond_to?(:cron_schedule_file) && config.cron_schedule_file) || "config/schedule.yml"
      end

      def stringify(hash)
        hash.to_h { |k, v| [k.to_s, v] }
      end
    end

    @sources = nil
    @env = nil
    @root = nil
    @pending = nil
    @lock = Mutex.new
    @by_class = {}.freeze
    @by_command = {}.freeze
    @hooked = false

    class << self
      attr_writer :sources, :env, :root

      # The sources read, in order. By default Solid Queue's recurring file
      # when Solid Queue is loaded, and sidekiq-cron's schedule when
      # sidekiq-cron is loaded and enabled.
      def sources
        return @sources if @sources

        found = []
        found << SolidQueue.new if defined?(::SolidQueue)
        if defined?(::Sidekiq::Cron::Job)
          config = ::Sidekiq::Cron.respond_to?(:configuration) && ::Sidekiq::Cron.configuration
          found << SidekiqCron.new unless config.respond_to?(:enabled) && config.enabled == false
        end
        found
      end

      # The environment whose section of a Solid Queue file is read: Rails.env, or RAILS_ENV.
      def env
        return @env if @env
        return ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env)

        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      end

      # Relative paths are read from here: Rails.root, or the working directory.
      def root
        return @root.to_s if @root
        return ::Rails.root.to_s if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root

        Dir.pwd
      end

      # Every entry of every source.
      def entries
        sources.flat_map(&:entries)
      end

      # { schedule:, timezone: } for the class's one entry in the scheduler's
      # config. Raises Error when it has none, or more than one.
      def schedule_for(klass)
        name = klass.is_a?(Module) ? klass.name : klass.to_s
        found = sources
        if found.empty?
          raise Error, "cronwatch: #{name} uses schedule: :from_scheduler, but neither Solid Queue nor sidekiq-cron is loaded; " \
                       "set Cronwatch::Scheduler.sources to say where the schedule is"
        end

        matches = found.flat_map(&:entries).select { |entry| !entry.disabled && same_class?(entry.class_name, name) }
        if matches.empty?
          raise Error, "cronwatch: #{name} uses schedule: :from_scheduler, but no enabled entry in " \
                       "#{found.map(&:label).join(" or ")} has class #{name}"
        end
        if matches.length > 1
          raise Error, "cronwatch: #{name} uses schedule: :from_scheduler, but it is scheduled #{matches.length} times " \
                       "(#{matches.map(&:label).join(", ")}); a job has one schedule, so give cronwatch a schedule: of its own"
        end

        matches.first.convert
      end

      # Declares a job for every enabled entry once the app has booted, so a
      # check reports one that never runs: a class that calls `cronwatch`
      # declares itself, any other class is named as `cronwatch` would name
      # it and its runs are recorded, and a Solid Queue `command:` is named
      # after its key. Takes the options of Cronwatch::Client#job other than
      # schedule and timezone (grace, timeout, failures_before_alert, tags,
      # ...), for every job it declares, and except: keys to leave out.
      def declare_from_scheduler!(except: [], **options)
        bad = options.keys & %i[schedule timezone name]
        raise ArgumentError, "cronwatch: declare_from_scheduler! takes #{bad.join(" and ")} from the scheduler" if bad.any?

        @lock.synchronize { @pending = { except: Array(except).map(&:to_s), options: options.freeze }.freeze }
        declare_pending! if Monitored.ready?
        nil
      end

      # Declares what declare_from_scheduler! asked for. Called once the app
      # has booted; raises Error for an entry that cannot be declared.
      def declare_pending!
        pending = @lock.synchronize { @pending }
        return nil unless pending

        by_class = {}
        by_command = {}
        by_name = {}
        entries.each do |entry|
          next if entry.disabled || pending[:except].include?(entry.key)

          name, target = declared_name(entry)
          next unless name

          if (other = by_name[name])
            raise Error, "cronwatch: #{entry.label} and #{other.where} would both be the job #{name.inspect}; " \
                         "leave one out with declare_from_scheduler!(except: [#{entry.key.inspect}])"
          end

          options = pending[:options].merge(entry.convert)
          options[:description] ||= entry.description if entry.description
          declaration = Monitored::Declaration.new(name, options, where: entry.label)
          by_name[name] = declaration
          target == :command ? by_command[entry.command] = declaration : by_class[entry.class_name.strip.delete_prefix("::")] = declaration
        end
        by_name.each_value { |declaration| declaration.registration(strict: true) }
        @lock.synchronize do
          @by_class = by_class.freeze
          @by_command = by_command.freeze
        end
        install_active_job_hook if (by_class.any? || by_command.any?) && defined?(::ActiveJob::Base)
        nil
      end

      # Declares the jobs declare_from_scheduler! declared on the current
      # Cronwatch.client, as Monitored.register_all does for classes.
      def register_declared(strict: true)
        declarations = @lock.synchronize { (@by_class.values + @by_command.values).uniq }
        declarations.each { |declaration| declaration.registration(strict: strict) }
        nil
      end

      # The declaration for a class declare_from_scheduler! declared, if any.
      def declaration_for_class(name)
        @by_class[name.to_s]
      end

      # The declaration an ActiveJob perform runs as, if declare_from_scheduler!
      # declared it: its class, or a Solid Queue command by its text. Nil for
      # a class that calls `cronwatch`, which records itself.
      def declaration_for_active_job(job)
        klass = job.class
        return nil if klass.respond_to?(:cronwatch_declaration) && klass.cronwatch_declaration
        return @by_command[job.arguments.first.to_s] if command_job?(klass) && @by_command.any?

        @by_class[klass.name.to_s]
      end

      # Forgets declare_from_scheduler! and what it declared. For tests.
      def reset!
        @lock.synchronize do
          @pending = nil
          @by_class = {}.freeze
          @by_command = {}.freeze
        end
        nil
      end

      # The IANA name of the zone Fugit reads a schedule without one in (TZ,
      # then Rails' Time.zone, then the system's), for the entry's error.
      def local_zone_name(entry, scheduler)
        zone = ::EtOrbi.determine_local_tzone
        name = zone.respond_to?(:identifier) ? zone.identifier : zone&.name
        return name if name.is_a?(String) && Zone.valid?(name)

        raise Error, "cronwatch: #{entry.label}: #{entry.schedule.to_s.inspect} has no timezone, and #{scheduler} reads it in " \
                     "the process's zone, which is not an IANA timezone (#{name.inspect}); add one to the schedule, " \
                     "as in #{"#{entry.schedule} UTC".inspect}"
      end

      # The cron expression CronWatch reads for a Fugit::Cron in `zone`, as
      # { schedule:, timezone: }. Raises Error for anything CronWatch would
      # not read the same way: a form croner has no equivalent for, a zone
      # that is not an IANA name, or a time that daylight saving skips.
      def to_cronwatch(entry, cron, zone, scheduler)
        where = "cronwatch: #{entry.label}: #{entry.schedule.to_s.inspect}"
        unless Zone.valid?(zone)
          raise Error, "#{where} is read in #{zone.inspect}, which is not an IANA timezone; name one, such as UTC or Europe/London"
        end
        raise Error, "#{where} picks a random time (~), which #{scheduler} and CronWatch would not pick alike" if cron.original.to_s.include?("~")

        text = cron_text(cron, where)
        parsed = begin
          Schedule.parse(text, zone)
        rescue ArgumentError => e
          raise Error, "#{where} is #{text.inspect}, which CronWatch cannot read: #{e.message}"
        end
        check_fires(cron, parsed, where, scheduler)
        { schedule: text, timezone: zone }
      end

      private

      def same_class?(written, name)
        !written.nil? && written.to_s.strip.delete_prefix("::") == name.to_s
      end

      # Solid Queue runs a `command:` task as RecurringTask.default_job_class
      # (SolidQueue::RecurringJob), with the command as its one argument.
      def command_job?(klass)
        task = defined?(::SolidQueue::RecurringTask) && ::SolidQueue::RecurringTask
        default = task.respond_to?(:default_job_class) && task.default_job_class
        default ? klass <= default : klass.name == "SolidQueue::RecurringJob"
      end

      # [name, :class or :command] for an entry, or nil for one left alone.
      def declared_name(entry)
        if entry.class_name
          class_name = entry.class_name.strip.delete_prefix("::")
          return nil if %w[Cronwatch::CheckJob Cronwatch::Sidekiq::CheckWorker].include?(class_name)

          klass = begin
            Object.const_get(class_name)
          rescue NameError
            raise Error, "cronwatch: #{entry.label} names the class #{class_name}, which does not load"
          end
          return nil if klass.respond_to?(:cronwatch_declaration) && klass.cronwatch_declaration

          [Monitored.default_name(klass), :class]
        elsif entry.command
          unless Client::NAME_RE.match?(entry.key)
            raise Error, "cronwatch: #{entry.label}: the key #{entry.key.inspect} cannot be a job name; " \
                         "use letters, digits, \".\", \"_\", \":\" or \"-\", or leave it out with except:"
          end

          [entry.key, :command]
        else
          raise Error, "cronwatch: #{entry.label} has neither a class nor a command to watch; leave it out with except:"
        end
      end

      def install_active_job_hook
        @lock.synchronize do
          return if @hooked

          @hooked = true
        end
        ::ActiveJob::Base.around_perform do |job, block|
          declaration = Cronwatch::Scheduler.declaration_for_active_job(job)
          if declaration
            Cronwatch::Monitored.record(declaration, "active_job", job) { block.call }
          else
            block.call
          end
        end
      end

      # The five or six fields croner reads for a Fugit::Cron.
      def cron_text(cron, where)
        fields = [list(cron.minutes), list(cron.hours), monthdays(cron.monthdays, where), list(cron.months),
                  weekdays(cron.weekdays, where)]
        day_and = cron.instance_variable_get(:@day_and)
        fields[4] = "+#{fields[4]}" if day_and && cron.monthdays && cron.weekdays
        fields.unshift(list(cron.seconds)) unless cron.seconds == [0]
        fields.join(" ")
      end

      def list(values)
        values.nil? ? "*" : values.join(",")
      end

      def monthdays(values, where)
        return "*" if values.nil?

        values.map do |day|
          next day.to_s if day.positive?
          next "L" if day == -1

          raise Error, "#{where} counts days back from the end of the month (#{day}), which CronWatch cannot read; only the last day (L) is"
        end.join(",")
      end

      def weekdays(values, where)
        return "*" if values.nil?

        values.map do |day, nth|
          if nth.nil? then day.to_s
          elsif nth == -1 then "#{day}L"
          elsif nth.is_a?(Integer) && nth.between?(1, 5) then "#{day}##{nth}"
          elsif nth.is_a?(Array)
            raise Error, "#{where} fires every #{nth[0]} weeks (%), which CronWatch cannot read"
          else
            raise Error, "#{where} counts weekdays back from the end of the month (##{nth}), which CronWatch cannot read"
          end
        end.join(",")
      end

      # Checks that CronWatch expects each run exactly when the scheduler
      # makes it: for a run of the scheduler, the next one CronWatch wants
      # is the scheduler's next. Where daylight saving changes the clock the
      # two may differ in one way only: the scheduler (Fugit) runs a time
      # that repeats when clocks go back twice, which CronWatch takes as an
      # early run. A time that clocks skip when they go forward is refused:
      # Fugit skips the run, and CronWatch would expect it and report it
      # missed.
      def check_fires(cron, parsed, where, scheduler)
        zone = parsed.timezone
        tz = Zone.get(zone)
        cron = in_zone(cron, zone)

        # Away from clock changes, every due time is the scheduler's next run.
        # Sampled from a fixed day, so the answer does not depend on when the app boots.
        runs = [fugit_ms(cron.next_time(SAMPLE_FROM))]
        until runs.length > SAMPLE_RUNS || (runs.length > 1 && runs.last > SAMPLE_UNTIL)
          runs << fugit_ms(cron.next_time(Time.at(runs.last / 1000).utc))
        end
        changes = tz.transitions_up_to(Time.at(runs.last / 1000 + 86_400).utc, Time.at(runs.first / 1000 - 86_400).utc)
                    .map { |change| change.at.to_i * 1000 }
        runs.each_cons(2) do |at, following|
          due = Schedule.due_after_run(parsed, at)
          next if due == following || changes.any? { |t| t > at - 86_400_000 && t < following + 86_400_000 }

          raise Error, "#{where} is #{parsed.source.inspect} in #{zone}, but after a run at #{stamp(at, zone)} #{scheduler} " \
                       "runs it next at #{stamp(following, zone)} and CronWatch would expect #{due ? stamp(due, zone) : "nothing"}, so it " \
                       "cannot be converted exactly; give cronwatch a schedule: of its own"
        end

        # Where clocks go forward. A cron that names no day or month meets
        # each change alike, so one change per clock time is enough.
        daily = cron.monthdays.nil? && cron.months.nil? && cron.weekdays.nil?
        seen = {}
        now = Time.now.utc
        tz.transitions_up_to(Time.utc(now.year + HORIZON_YEARS + 1, 1, 1), Time.utc(now.year, 1, 1)).each do |change|
          before = change.previous_offset.utc_total_offset
          gap = (change.offset.utc_total_offset - before) * 1000
          next unless gap.positive?
          next if daily && seen[[(change.at.to_i + before) % 86_400, gap]]

          seen[[(change.at.to_i + before) % 86_400, gap]] = true
          check_gap(cron, parsed, change.at.to_i * 1000, gap, before, where, scheduler)
        end
      rescue RuntimeError => e
        raise Error, "#{where} never fires: #{e.message}"
      end

      # Checks one spring-forward change. CronWatch moves a fire whose wall
      # time the change skips to the same distance past the change, as cron
      # does; Fugit runs only at wall times that exist. So each fire
      # CronWatch has between the change and one gap after it must be one
      # Fugit makes, or be covered by the run Fugit makes before it.
      def check_gap(cron, parsed, jump, gap, before, where, scheduler)
        zone = parsed.timezone
        fire = jump - 1
        loop do
          fire = Schedule.next_runs(parsed, 1, fire).first
          break if fire.nil? || fire >= jump + gap
          next if cron.match?(Time.at(fire / 1000).utc)

          at = fugit_ms(cron.previous_time(Time.at(fire / 1000).utc))
          following = fugit_ms(cron.next_time(Time.at(at / 1000).utc))
          due = Schedule.due_after_run(parsed, at)
          next unless due && due < following

          old = Time.at(jump / 1000 + before).utc
          raise Error, "#{where} is due at a time that does not exist in #{zone} on #{old.strftime("%Y-%m-%d")}, when clocks " \
                       "go forward from #{old.strftime("%H:%M")} to #{Time.at((jump + gap) / 1000 + before).utc.strftime("%H:%M")}. " \
                       "#{scheduler} skips that run and CronWatch would expect it at #{stamp(due, zone)}, so it would be " \
                       "reported missed. Move the time outside the change, give the schedule a zone without daylight " \
                       "saving (such as UTC), or give cronwatch a schedule: of its own"
        end
      end

      # The cron with its zone named, so it is read in `zone` whatever this
      # process's local zone is later.
      def in_zone(cron, zone)
        return cron if cron.timezone

        Fugit::Cron.parse("#{cron.to_cron_s} #{zone}") || cron
      end

      def fugit_ms(time)
        time.to_i * 1000
      end

      def stamp(ms, zone)
        wall = Zone.wall(ms / 1000, zone)
        format("%04d-%02d-%02d %02d:%02d:%02d", *wall)
      end
    end
  end

  class << self
    # Declares a job for every entry in the scheduler's config (Solid Queue's
    # config/recurring.yml, sidekiq-cron's schedule), once the app has
    # booted. See Cronwatch::Scheduler.declare_from_scheduler!.
    def declare_from_scheduler!(**options)
      Scheduler.declare_from_scheduler!(**options)
    end
  end
end

require_relative "monitored" unless defined?(Cronwatch::Monitored)
