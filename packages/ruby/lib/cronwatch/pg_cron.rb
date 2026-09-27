# frozen_string_literal: true

# The pg_cron reader. Needs no gem of its own: it queries through the
# connection it is given (ActiveRecord, the pg gem, or your own).
#
#   require "cronwatch/pg_cron"
require "set"
require "time"
require "cronwatch" unless defined?(Cronwatch::Client)

module Cronwatch
  # Where runs this process does not wrap come from. A source is anything
  # with `name` and `sync(host)`: on every check the client calls sync with
  # itself as the host, and the source declares jobs (`host.job`), reads the
  # store (`host.store`), records the runs it found (`host.record_run`) and
  # reports problems (`host.on_error(error, where)`). sync returns the alerts
  # recording sent, or anything else for none.
  module Sources
    # Watches pg_cron jobs, which run inside Postgres where nothing can wrap
    # them (the SDK's sources/pgcron.ts). As a source, on every check it
    # reads cron.job and declares each job with its schedule, then copies new
    # rows of cron.job_run_details in as runs (ids "pgcron:<runid>"), so the
    # usual evaluation raises missed, failed, stuck and slow alerts.
    #
    #   require "cronwatch/pg_cron"
    #   Cronwatch.configure do |c|
    #     c.store   = Cronwatch::Stores::ActiveRecord.new
    #     c.sources = [Cronwatch::Sources::PgCron.new(ActiveRecord::Base)]
    #   end
    #
    # `db` is an ActiveRecord class, connection pool or connection
    # (queried through exec_query), a PG::Connection (exec_params), or
    # anything with `query(sql, params)` returning rows as hashes with string
    # keys.
    #
    # jobs:     which jobs to watch: names or ids, or a callable that picks them (given a Job). Default every job the role can see.
    # prefix:   put before every job name, to keep them apart from your own ("db:"). Also keeps run ids apart.
    # job_name: a callable giving the CronWatch name for a Job. Default its jobname with anything other than
    #           letters, digits, ".", "_", ":" and "-" turned into "-", or "pg_cron:<jobid>" when it has none.
    #           The prefix goes in front either way.
    # options:  grace, timeout, max_duration, expect and the rest, for every job (a hash) or per job (a callable
    #           given a Job). The schedule and timezone always come from pg_cron.
    # timezone: the timezone pg_cron reads its cron expressions in. Default the server's cron.timezone, which only
    #           roles with pg_read_all_settings may read; UTC (pg_cron's default) is assumed when it cannot be read.
    class PgCron
      # A row of cron.job.
      Job = Struct.new(:jobid, :jobname, :schedule, :database, :username, :active, keyword_init: true)

      # How many of a job's newest runs are copied, without alerting, the first time it is seen.
      BACKFILL = 20
      # Run details read per query, and the most pages read in one sync.
      PAGE = 500
      MAX_PAGES = 10

      JOBS_SQL = "SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid"
      COLUMNS = "d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time"
      # Every tracked job's runs after its cursor, and any run still open here.
      RUNS_SQL = <<~SQL.chomp
        SELECT #{COLUMNS}
          FROM cron.job_run_details d
          JOIN unnest($1::bigint[], $2::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid
          WHERE d.runid > c.after OR d.runid = ANY($3::bigint[])
          ORDER BY d.runid LIMIT #{PAGE}
      SQL
      NEWEST_SQL = "SELECT #{COLUMNS} FROM cron.job_run_details d WHERE d.jobid = $1 ORDER BY d.runid DESC LIMIT #{BACKFILL}"
      SETTING_SQL = "SELECT current_setting($1, true) AS value"

      SECONDS = Regexp.new("\\A(\\d+)[#{JS::WHITESPACE}]*seconds?\\z", Regexp::IGNORECASE)
      REBOOT = /\A@reboot\z/i
      UTC = /\A(gmt|utc|z)\z/i
      SCHEDULE_ONLY = %i[schedule timezone].freeze

      attr_reader :name

      def initialize(db, jobs: nil, prefix: "", job_name: nil, options: nil, timezone: nil)
        @db = PgCron.adapter(db)
        @jobs = jobs
        @prefix = prefix.to_s
        @id_prefix = "pgcron:#{@prefix}"
        @job_name = job_name
        @options = options
        @timezone = timezone
        # The newest runid copied for each jobid, once known.
        @cursors = {}
        # The last definition declared for each name, so an unchanged job is not declared again.
        @declared = {}
        @warned = Set.new
        @name = "pg_cron"
      end

      # pg_cron takes a cron expression, with "$" for the last day of the
      # month, or "N seconds" for 1 to 59 seconds. Returns the CronWatch
      # schedule, or nil for one that has no cadence to watch.
      def self.schedule(schedule)
        text = JS.trim(schedule.to_s)
        seconds = SECONDS.match(text)
        return "every #{seconds[1].to_i}s" if seconds
        return nil if REBOOT.match?(text)

        fields = text.split(JS::SPACES)
        fields[2] = fields[2].tr("$", "L") if fields.length == 5 && fields[2].include?("$")
        fields.join(" ")
      end

      # The default CronWatch name for a pg_cron job, before the prefix.
      def self.job_name(job)
        cleaned = job.jobname.to_s.gsub(/[^A-Za-z0-9._:-]+/, "-").sub(/\A[^A-Za-z0-9]+/, "")[0, 100]
        cleaned.empty? ? "pg_cron:#{job.jobid}" : cleaned
      end

      # A row of cron.job_run_details as a CronWatch run, or nil while it has not started.
      def self.run(row, job, id_prefix)
        return nil if row["start_time"].nil?

        started_at = epoch_ms(row["start_time"])
        finished_at = row["end_time"].nil? ? nil : epoch_ms(row["end_time"])
        message = row["return_message"].nil? ? nil : JS.trim(Output.utf8(row["return_message"]))
        message = nil if message == ""
        status = { "succeeded" => :ok, "failed" => :failed }.fetch(row["status"].to_s, :running)
        finish = status == :running ? nil : (finished_at || started_at)
        Run.new(
          id: "#{id_prefix}#{row["runid"]}", job: job, status: status, started_at: started_at, finished_at: finish,
          duration_ms: finish.nil? ? nil : [0, finish - started_at].max,
          error: status == :failed ? (message || "pg_cron reported the run as failed") : nil,
          output: status == :ok ? message : nil, metrics: {}, trigger: "pg_cron",
        )
      end

      # A timestamp as epoch milliseconds: a Time (ActiveRecord decodes them), a string as Postgres writes one, or a number.
      def self.epoch_ms(value)
        case value
        when Integer then value
        when Time then (value.to_r * 1000).floor
        when String then (Time.parse(value).to_r * 1000).floor
        else value.respond_to?(:to_time) ? (value.to_time.to_r * 1000).floor : Integer(value)
        end
      end

      # A value as a query parameter: arrays as Postgres array literals, the rest as given.
      def self.encode(value)
        value.is_a?(Array) ? "{#{value.map { |v| Integer(v) }.join(",")}}" : value
      end

      def self.boolean(value)
        [true, "t", "true", 1, "1"].include?(value)
      end

      # The query adapter for `db`.
      def self.adapter(db)
        if db.respond_to?(:exec_params) then PGConnection.new(db)
        elsif db.respond_to?(:connection_pool) || db.respond_to?(:with_connection) || db.respond_to?(:exec_query)
          ActiveRecordConnection.new(db)
        elsif db.respond_to?(:query) then db
        else
          raise ArgumentError, "Cronwatch::Sources::PgCron needs an ActiveRecord class or connection, a PG::Connection, " \
                               "or an object with query(sql, params)"
        end
      end

      # Queries through the pg gem's PG::Connection#exec_params.
      class PGConnection
        def initialize(connection)
          @connection = connection
          @lock = Mutex.new
        end

        def query(sql, params = [])
          @lock.synchronize { @connection.exec_params(sql, params.map { |v| PgCron.encode(v) }).to_a }
        end
      end

      # Queries through an ActiveRecord connection's exec_query, checking one
      # out of the pool for each query when given a class or a pool.
      class ActiveRecordConnection
        def initialize(source)
          @source = source
        end

        def query(sql, params = [])
          with_connection do |connection|
            connection.exec_query(sql, "Cronwatch pg_cron", params.map { |v| PgCron.encode(v) }).to_a
          end
        end

        private

        # A class's pool is the writing role's, as the store's is, even
        # inside the app's connected_to(role: :reading): cron.job_run_details
        # is read where pg_cron writes it, not on a replica that may lag or
        # not be configured at all.
        def with_connection(&block)
          if record_class?
            ::ActiveRecord::Base.connected_to(role: ::ActiveRecord.writing_role, prevent_writes: false) do
              @source.connection_pool.with_connection(&block)
            end
          elsif @source.respond_to?(:connection_pool) then @source.connection_pool.with_connection(&block)
          elsif @source.respond_to?(:with_connection) then @source.with_connection(&block)
          else yield @source
          end
        end

        def record_class?
          defined?(::ActiveRecord::Base) && @source.is_a?(Class) && @source <= ::ActiveRecord::Base
        end
      end

      # Declares the jobs and records their new runs. Returns the alerts recording them sent.
      def sync(host)
        timezone = @timezone
        if timezone.nil? || timezone.to_s.empty?
          tz = setting("cron.timezone")
          if tz.nil?
            warn_once(host, "tz", "could not read cron.timezone; assuming UTC. Grant pg_read_all_settings or pass " \
                                  "Cronwatch::Sources::PgCron.new(db, timezone: ...).")
          end
          timezone = tz.nil? || UTC.match?(tz) ? "UTC" : tz
        end
        recording = setting("cron.log_run") != "off"
        unless recording
          warn_once(host, "log_run", "cron.log_run is off, so pg_cron records no runs: jobs are watched without their " \
                                     "schedules and no run can fail. Turn it on to watch them.")
        end

        rows = @db.query(JOBS_SQL, [])
        if rows.empty?
          warn_once(host, "empty", "cron.job shows no jobs. pg_cron's row level security shows a role only the jobs it " \
                                   "scheduled: connect as that role, or give this one BYPASSRLS.")
        end
        jobs = rows.map { |r| job_from(r) }.select { |job| picks?(job) }
        names = declare(host, jobs, timezone, recording)
        return [] if !recording || names.empty?

        alerts = []
        start_cursors(host, names, alerts)
        read_new(host, names, alerts)
        alerts
      end

      private

      def job_from(row)
        Job.new(jobid: Integer(row["jobid"]), jobname: row["jobname"], schedule: row["schedule"].to_s,
                database: row["database"], username: row["username"], active: PgCron.boolean(row["active"]))
      end

      def warn_once(host, key, message)
        return if @warned.include?(key)

        @warned << key
        host.on_error(RuntimeError.new(message), "source pg_cron")
      end

      def picks?(job)
        return true if @jobs.nil?
        return @jobs.call(job) ? true : false if @jobs.respond_to?(:call)

        Array(@jobs).any? { |j| j.is_a?(Integer) ? j == job.jobid : j.to_s == job.jobname }
      end

      def setting(name)
        rows = @db.query(SETTING_SQL, [name])
        value = rows.first && rows.first["value"]
        value&.to_s
      rescue StandardError
        # Unprivileged roles may not read cron.* settings at all.
        nil
      end

      def run_id_of(id)
        return nil unless id.start_with?(@id_prefix)

        rest = id[@id_prefix.length..]
        /\A\d{1,15}\z/.match?(rest) ? rest.to_i : nil
      end

      # Declares each job. A paused one (active = false) keeps its failures but loses its schedule, so it is not missed.
      # Returns { jobid => name }.
      def declare(host, jobs, timezone, recording)
        names = {}
        used = Set.new
        jobs.each do |job|
          name = @prefix + (@job_name ? @job_name.call(job).to_s : PgCron.job_name(job))
          name = "#{name}:#{job.jobid}" if used.include?(name)
          used << name
          extra = (@options.respond_to?(:call) ? @options.call(job) : @options) || {}
          extra = extra.to_h.transform_keys(&:to_sym).except(*SCHEDULE_ONLY)
          schedule = job.active && recording ? PgCron.schedule(job.schedule) : nil
          definition = {
            description: "pg_cron job #{job.jobid} in #{job.database} as #{job.username}#{job.active ? "" : " (paused)"}",
            tags: ["pg_cron"],
          }.merge(extra)
          definition.merge!(schedule: schedule, timezone: timezone) if schedule
          key = definition_key(definition)
          begin
            if @declared[name] != key
              begin
                host.job(name, **definition)
              rescue StandardError => e
                raise unless schedule

                # A schedule CronWatch cannot read: watch the runs, not the cadence.
                host.on_error(RuntimeError.new("pg_cron job #{job.jobid}: #{e.message}; watching it without a schedule"), "source pg_cron")
                host.job(name, **definition.except(*SCHEDULE_ONLY))
              end
              @declared[name] = key
            end
            names[job.jobid] = name
          rescue StandardError => e
            host.on_error(e, "source pg_cron: job #{job.jobid}")
          end
        end
        names
      end

      # A definition as text, to tell a changed one from the last declared.
      def definition_key(definition)
        JS.json(definition.transform_values { |v| v.is_a?(Regexp) ? v.inspect : v.respond_to?(:call) ? "function" : v })
      end

      # Copies a detail row in as a run. False when it has not started, so it must be read again.
      def record(host, names, row, evaluate, alerts)
        name = names[Integer(row["jobid"])]
        return true unless name

        run = PgCron.run(row, name, @id_prefix)
        return false unless run

        alerts.concat(host.record_run(run, evaluate: evaluate))
        true
      end

      # Where each job left off. Found from the store the first time, so a restart carries on.
      def start_cursors(host, names, alerts)
        names.each do |jobid, name|
          next if @cursors.key?(jobid)

          ids = host.store.list_runs(name, BACKFILL).filter_map { |r| run_id_of(r.id) }
          if ids.any?
            @cursors[jobid] = ids.max
            next
          end
          # First sight: copy recent history quietly, and judge only from the newest finished run on.
          ordered = @db.query(NEWEST_SQL, [jobid]).reverse
          last_finished = -1
          ordered.each_with_index { |r, i| last_finished = i if %w[succeeded failed].include?(r["status"]) }
          cursor = 0
          held = false
          ordered.each_with_index do |row, i|
            copied = record(host, names, row, i >= last_finished, alerts)
            held = true unless copied
            cursor = Integer(row["runid"]) unless held
          end
          @cursors[jobid] = cursor
        end
      end

      # New runs, and runs copied while still going.
      def read_new(host, names, alerts)
        open = Set.new
        watched = names.values.to_set
        host.store.running_runs.each do |run|
          id = run_id_of(run.id)
          open << id if id && watched.include?(run.job)
        end
        MAX_PAGES.times do
          jobids = names.keys
          details = @db.query(RUNS_SQL, [jobids, jobids.map { |j| @cursors.fetch(j, 0) }, open.to_a])
          held_from = {}
          details.each do |row|
            jobid = Integer(row["jobid"])
            runid = Integer(row["runid"])
            open.delete(runid)
            copied = record(host, names, row, true, alerts)
            # A run not yet started holds its job's cursor, so it is read again next time.
            held_from[jobid] = runid if !copied && !held_from.key?(jobid)
            @cursors[jobid] = runid if !held_from.key?(jobid) && runid > @cursors.fetch(jobid, 0)
          end
          break if details.length < PAGE || held_from.any?
        end
      end
    end
  end
end
