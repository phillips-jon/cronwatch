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
  # reports problems (`host.on_error(error, where)`). A host with
  # `defined_jobs` lets a source declare again a job forgotten since. sync
  # returns the alerts recording sent, or anything else for none.
  module Sources
    # Watches pg_cron jobs, which run inside Postgres where nothing can wrap
    # them (the SDK's sources/pgcron.ts). As a source, on every check it
    # reads cron.job and declares each job with its schedule, then copies new
    # rows of cron.job_run_details in as runs (ids "pgcron:<runid>"), so the
    # usual evaluation raises missed, failed, stuck, and slow alerts.
    #
    # A job that is renamed, unscheduled, or no longer picked keeps its old
    # name's runs and history, and that name is declared again without a
    # schedule, so it is never reported missed. Its description says why.
    # Forgetting that old name from the dashboard while a run of it is still
    # open lets the run go: it is not recorded, and no error is reported.
    #
    #   require "cronwatch/pg_cron"
    #   Cronwatch.configure do |c|
    #     c.store   = Cronwatch::Stores::ActiveRecord.new
    #     c.sources = [Cronwatch::Sources::PgCron.new(ActiveRecord::Base)]
    #   end
    #
    # `db` is an ActiveRecord class, connection pool, or connection
    # (queried through exec_query), a PG::Connection (exec_params), or
    # anything with `query(sql, params)` returning rows as hashes with string
    # keys.
    #
    # jobs:     which jobs to watch: names or ids, or a callable that picks them (given a Job). Default every job the role can see.
    # prefix:   put before every job name, to keep them apart from your own ("db:"). Also keeps run ids apart.
    # job_name: a callable giving the CronWatch name for a Job. Default its jobname with anything other than
    #           letters, digits, ".", "_", ":", and "-" turned into "-", or "pg_cron:<jobid>" when it has none.
    #           The prefix goes in front either way. One that raises or returns no name, like a `jobs` or
    #           `options` callable that raises, is reported once and fails only that job, which keeps its last
    #           declaration until the callable works again.
    # options: grace, timeout, max_duration, expect, and the rest, for every job (a hash) or per job (a callable
    #           given a Job). The schedule and timezone always come from pg_cron.
    # timezone: the timezone pg_cron reads its cron expressions in. Default the server's cron.timezone, read from
    #           pg_settings, which shows it only to roles with pg_read_all_settings; UTC (pg_cron's default) is
    #           assumed when it cannot be read.
    class PgCron
      # A row of cron.job.
      Job = Struct.new(:jobid, :jobname, :schedule, :database, :username, :active, keyword_init: true)

      # How many of a job's newest runs are copied, without alerting, the first time it is seen.
      BACKFILL = 20
      # Run details read per query, and the most pages read in one sync.
      PAGE = 500
      MAX_PAGES = 10
      # How long a run pg_cron has queued but not started (no start_time yet)
      # is waited for. After that it is copied as running from when it was
      # first seen, so a run that never starts is marked stuck like any other.
      HOLD_MS = 10 * 60_000

      JOBS_SQL = "SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid"
      # pg_settings has no row for a setting the role may not read, where
      # current_setting() raises an error that would abort the caller's transaction.
      SETTING_SQL = "SELECT setting FROM pg_settings WHERE name = $1"
      COLUMNS = "d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time"
      # Every tracked job's runs after its cursor, and any run still open here, whatever its job.
      RUNS_SQL = <<~SQL.chomp
        SELECT #{COLUMNS}
          FROM cron.job_run_details d
          LEFT JOIN unnest($1::bigint[], $2::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid
          WHERE d.runid > c.after OR d.runid = ANY($3::bigint[])
          ORDER BY d.runid LIMIT #{PAGE}
      SQL
      NEWEST_SQL = "SELECT #{COLUMNS} FROM cron.job_run_details d WHERE d.jobid = $1 ORDER BY d.runid DESC LIMIT #{BACKFILL}"

      SECONDS = Regexp.new("\\A(\\d+)[#{JS::WHITESPACE}]*seconds?\\z", Regexp::IGNORECASE)
      REBOOT = /\A@reboot\z/i
      UTC = /\A(gmt|utc|z)\z/i
      SCHEDULE_ONLY = %i[schedule timezone].freeze
      # The options of a definition that are declared again, without its schedule, for a name no longer in use.
      UNSCHEDULED = %i[description tags grace timeout max_duration budget floor failures_before_alert].freeze
      DESCRIBED = /\Apg_cron job (\d+) in /
      private_constant :BACKFILL, :COLUMNS, :DESCRIBED, :JOBS_SQL, :MAX_PAGES, :NEWEST_SQL, :PAGE, :REBOOT, :RUNS_SQL,
                       :SCHEDULE_ONLY, :SECONDS, :SETTING_SQL, :UNSCHEDULED, :UTC

      attr_reader :name

      def initialize(db, jobs: nil, prefix: "", job_name: nil, options: nil, timezone: nil)
        @db = PgCron.adapter(db)
        @jobs = jobs
        @prefix = prefix.to_s
        @id_prefix = "pgcron:#{@prefix}"
        @job_name = job_name
        @options = options
        @timezone = timezone
        # The newest runid read for each jobid, once known.
        @cursors = {}
        # The start of the newest run copied for each jobid: where a restart row with no times is put.
        @last_at = {}
        # Runs copied while still going, by runid, with their job: read again until they finish, even once a check marks them timeout.
        @pending = {}
        # Runs read before they started, by runid, with when they were first seen.
        @held = {}
        # Each job's name and definition as last declared, by jobid.
        @known = {}
        # The last definition declared for each name, so an unchanged job is not declared again.
        @declared = {}
        # Names declared again without a schedule by retire, whose open runs are still read.
        @retired = Set.new
        # The names the host declares, read on each sync after the retires (nil for a host without defined_jobs).
        @declared_now = nil
        @scanned = false
        @warned = Set.new
        # Jobids whose callback failed, reported once until it works again.
        @failing = Set.new
        @name = "pg_cron"
      end

      # pg_cron takes a cron expression, with "$" for the last day of the
      # month, or "N seconds" for 1 to 59 seconds. Returns the CronWatch
      # schedule, or nil for one that has no cadence to watch. pg_cron reads
      # only the first five fields of an expression and ignores the rest, so
      # only those are kept (a sixth would otherwise be read as seconds).
      def self.schedule(schedule)
        text = JS.trim(schedule.to_s)
        seconds = SECONDS.match(text)
        return "every #{seconds[1].to_i}s" if seconds
        return nil if REBOOT.match?(text)

        fields = text.split(JS::SPACES)
        fields = fields.first(5) if fields.length > 5 && !fields[0].start_with?("@")
        fields[2] = fields[2].tr("$", "L") if fields.length == 5 && fields[2].include?("$")
        fields.join(" ")
      end

      # The default CronWatch name for a pg_cron job, before the prefix.
      def self.job_name(job)
        cleaned = job.jobname.to_s.gsub(/[^A-Za-z0-9._:-]+/, "-").sub(/\A[^A-Za-z0-9]+/, "")[0, 100]
        cleaned.empty? ? "pg_cron:#{job.jobid}" : cleaned
      end

      # Whether a row's status says the run is over.
      def self.finished_status?(status)
        %w[succeeded failed].include?(status.to_s)
      end

      # A row of cron.job_run_details as a CronWatch run, or nil for one that
      # has not started (no start_time, not finished). A finished row with no
      # start_time (pg_cron writes these for runs a server restart cut off,
      # "server restarted") starts at its end_time, else at `fallback_at`
      # (the reader passes the job's newest run's start, or now).
      def self.run(row, job, id_prefix, fallback_at = nil)
        finished_at = row["end_time"].nil? ? nil : epoch_ms(row["end_time"])
        done = finished_status?(row["status"])
        return nil if row["start_time"].nil? && !done

        started_at =
          if row["start_time"].nil? then finished_at || fallback_at || Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
          else epoch_ms(row["start_time"])
          end
        message = row["return_message"].nil? ? nil : JS.trim(Output.utf8(row["return_message"]))
        message = nil if message == ""
        status = { "succeeded" => :ok, "failed" => :failed }.fetch(row["status"].to_s, :running)
        finish = done ? [started_at, finished_at || started_at].max : nil
        Run.new(
          id: "#{id_prefix}#{row["runid"]}", job: job, status: status, started_at: started_at, finished_at: finish,
          duration_ms: finish.nil? ? nil : Evaluate.run_duration(started_at, finish),
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
      #
      # @api private
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
      #
      # @api private
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
        now = host.now
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
        all = rows.map { |r| job_from(r) }
        names, definitions = declare(host, all, timezone, recording)
        retire_unused(host, names, definitions, all)
        return [] if !recording || names.empty?

        # The names declared now, after the retires above. A run copied under
        # a retired name that was then forgotten (the dashboard's forget) has
        # no job to go to: it is let go, never recorded, and never read again.
        @declared_now = host.respond_to?(:defined_jobs) ? host.defined_jobs.to_set(&:name) : nil
        alerts = []
        start_cursors(host, names, alerts, now)
        read_new(host, names, alerts, now)
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
        value = rows.first && rows.first["setting"]
        value&.to_s
      rescue StandardError
        nil
      end

      def run_id_of(id)
        return nil unless id.start_with?(@id_prefix)

        rest = id[@id_prefix.length..]
        /\A\d{1,15}\z/.match?(rest) ? rest.to_i : nil
      end

      # Declares each job picked. A paused one (active = false) keeps its failures but loses its schedule, so it
      # is not missed. Returns [{ jobid => name }, { jobid => definition as declared }].
      def declare(host, all, timezone, recording)
        # One forgotten since it was declared (the dashboard's forget) is declared again, though unchanged:
        # record_run takes runs only of a declared job.
        live = host.respond_to?(:defined_jobs) ? host.defined_jobs.to_set(&:name) : nil
        names = {}
        definitions = {}
        used = Set.new
        # A callback of the app's (jobs, job_name, options) that raised, or a job_name that gave no name, fails
        # only its job, as a bad row does: reported once until it works again, and the job carries on as last
        # declared (skipped when it never was), so its runs are still copied.
        trouble = lambda do |job, what|
          unless @failing.include?(job.jobid)
            @failing << job.jobid
            host.on_error(RuntimeError.new("pg_cron job #{job.jobid}: #{what}; it keeps its last declaration until that works"),
                          "source pg_cron")
          end
          last = @known[job.jobid]
          next if last.nil? || used.include?(last[:name])

          names[job.jobid] = last[:name]
          definitions[job.jobid] = last[:definition]
          used << last[:name]
        end
        all.each do |job|
          begin
            picked = picks?(job)
          rescue StandardError => e
            trouble.call(job, "the jobs callback raised #{e.class}: #{e.message}")
            next
          end
          unless picked
            @failing.delete(job.jobid)
            next
          end
          begin
            base = @job_name ? @job_name.call(job) : PgCron.job_name(job)
          rescue StandardError => e
            trouble.call(job, "job_name raised #{e.class}: #{e.message}")
            next
          end
          unless base.is_a?(String) || base.is_a?(Symbol)
            trouble.call(job, "job_name returned #{base.nil? ? "nil" : base.class}, not a name")
            next
          end
          begin
            extra = (@options.respond_to?(:call) ? @options.call(job) : @options) || {}
            extra = extra.to_h.transform_keys(&:to_sym).except(*SCHEDULE_ONLY)
          rescue StandardError => e
            trouble.call(job, "the options callback raised #{e.class}: #{e.message}")
            next
          end
          @failing.delete(job.jobid)
          name = @prefix + base.to_s
          name = "#{name}:#{job.jobid}" if used.include?(name)
          used << name
          schedule = job.active && recording ? PgCron.schedule(job.schedule) : nil
          definition = {
            description: "pg_cron job #{job.jobid} in #{job.database} as #{job.username}#{job.active ? "" : " (paused)"}",
            tags: ["pg_cron"],
          }.merge(extra)
          definition.merge!(schedule: schedule, timezone: timezone) if schedule
          begin
            key = definition_key(definition)
            if @declared[name] != key || (live && !live.include?(name))
              begin
                host.job(name, **definition)
              rescue StandardError => e
                raise unless schedule

                # A schedule CronWatch cannot read: watch the runs, not the cadence.
                host.on_error(RuntimeError.new("pg_cron job #{job.jobid}: #{e.message}; watching it without a schedule"), "source pg_cron")
                definition = definition.except(*SCHEDULE_ONLY)
                host.job(name, **definition)
              end
              @declared[name] = key
            end
            names[job.jobid] = name
            definitions[job.jobid] = definition
          rescue StandardError => e
            host.on_error(e, "source pg_cron: job #{job.jobid}")
          end
        end
        [names, definitions]
      end

      # A definition as text, to tell a changed one from the last declared.
      def definition_key(definition)
        JS.json(definition.transform_values { |v| v.is_a?(Regexp) ? v.inspect : v.respond_to?(:call) ? "function" : v })
      end

      # The options of a stored or declared definition that can be declared again, without its schedule.
      def unscheduled(definition)
        UNSCHEDULED.each_with_object({}) do |field, out|
          value = definition[field]
          out[field] = value unless value.nil?
        end
      end

      # Declares a name this source no longer uses for any job again, without its schedule.
      def retire(host, name, definition, why)
        base = unscheduled(definition)
        following = base.merge(description: "#{base[:description] || "pg_cron job"} (#{why})")
        host.job(name, **following)
        @declared[name] = definition_key(following)
        @retired << name
      rescue StandardError => e
        host.on_error(e, "source pg_cron: job #{name}")
      end

      # A name this source used for a job that has since been renamed, unscheduled, or dropped from `jobs`
      # is declared again without its schedule. Once per process, the same for names left scheduled in the
      # store while no process was watching.
      def retire_unused(host, names, definitions, all)
        in_use = names.values.to_set
        in_use.each { |name| @retired.delete(name) }
        @known.each do |jobid, previous|
          next if in_use.include?(previous[:name])

          renamed = names[jobid]
          retire(host, previous[:name], previous[:definition], renamed ? "renamed to #{renamed}" : "no longer watched")
        end
        @known = names.to_h { |jobid, name| [jobid, { name: name, definition: definitions[jobid] }] }
        return if @scanned || all.empty?

        @scanned = true
        begin
          visible = all.map(&:jobid).to_set
          host.store.list_jobs.each do |stored|
            definition = stored.definition
            # A foreign or damaged definition (not an object, tags not a list) is not one of ours.
            next if !definition.is_a?(JobDefinition) || definition.unreadable? || !definition.tags.is_a?(Array)
            next if !stored.name.start_with?(@prefix) || in_use.include?(stored.name)
            next if definition.schedule.nil? || definition.schedule.to_s.empty? || !definition.tags.include?("pg_cron")

            description = definition.description
            match = DESCRIBED.match(description.is_a?(String) ? description : "")
            next unless match

            jobid = match[1].to_i
            current = names[jobid]
            if !visible.include?(jobid)
              retire(host, stored.name, definition, "no longer in cron.job")
            elsif current && !stored.name.end_with?(current[@prefix.length..])
              # Another pg_cron source's name for the same job ends the same way: that one is left alone.
              retire(host, stored.name, definition, "renamed to #{current}")
            end
          end
        rescue StandardError => e
          host.on_error(e, "source pg_cron")
        end
      end

      # Copies one detail row in as a run. A row that cannot be recorded is
      # reported and skipped; it never stops the others.
      def record(host, names, row, evaluate, alerts, now)
        runid = Integer(row["runid"])
        jobid = Integer(row["jobid"])
        name = @pending[runid] || names[jobid]
        if name.nil? || (@declared_now && !names.value?(name) && !@declared_now.include?(name))
          @pending.delete(runid)
          @held.delete(runid)
          @retired.delete(name) if name
          return
        end
        if row["start_time"].nil? && !PgCron.finished_status?(row["status"])
          since = @held.fetch(runid, now)
          if now - since < HOLD_MS
            @held[runid] = since
            return
          end
          run = PgCron.run(row.merge("start_time" => since), name, @id_prefix)
        else
          run = PgCron.run(row, name, @id_prefix, @last_at.fetch(jobid, now))
        end
        @held.delete(runid)
        return unless run

        begin
          alerts.concat(host.record_run(run, evaluate: evaluate))
        rescue StandardError => e
          host.on_error(e, "source pg_cron: run #{runid}")
          return
        end
        if run.status == :running
          @pending[runid] = name
        else
          @pending.delete(runid)
        end
        @last_at[jobid] = run.started_at if !@last_at.key?(jobid) || run.started_at > @last_at[jobid]
      end

      # Where each job left off. Found from the store the first time, so a restart carries on.
      def start_cursors(host, names, alerts, now)
        names.each do |jobid, name|
          next if @cursors.key?(jobid)

          ours = host.store.list_runs(name, BACKFILL).select { |r| run_id_of(r.id) }
          if ours.any?
            @cursors[jobid] = ours.map { |r| run_id_of(r.id) }.max
            @last_at[jobid] = ours.map(&:started_at).max
            ours.each { |r| @pending[run_id_of(r.id)] = r.job if %i[running timeout].include?(r.status) }
            next
          end
          # First sight: copy recent history quietly, and judge only from the newest finished run on.
          # The cursor goes to the newest row read, whatever is held, so history is never judged later.
          ordered = @db.query(NEWEST_SQL, [jobid]).reverse
          last_finished = -1
          ordered.each_with_index { |r, i| last_finished = i if PgCron.finished_status?(r["status"]) }
          ordered.each_with_index do |row, i|
            # Already copied under another name (the job was renamed while no process watched): left there.
            next if host.store.get_run("#{@id_prefix}#{row["runid"]}")

            record(host, names, row, i >= last_finished, alerts, now)
          end
          @cursors[jobid] = ordered.empty? ? 0 : Integer(ordered.last["runid"])
        end
      end

      # New runs, runs copied while still going (or since marked timeout), and runs not yet started.
      def read_new(host, names, alerts, now)
        watched = names.values.to_set | @retired
        host.store.running_runs.each do |run|
          id = run_id_of(run.id)
          @pending[id] = run.job if id && watched.include?(run.job)
        end
        open = (@pending.keys + @held.keys).to_set
        complete = false
        MAX_PAGES.times do
          jobids = names.keys
          details = @db.query(RUNS_SQL, [jobids, jobids.map { |j| @cursors.fetch(j, 0) }, open.to_a])
          details.each do |row|
            jobid = Integer(row["jobid"])
            runid = Integer(row["runid"])
            open.delete(runid)
            record(host, names, row, true, alerts, now)
            # Held or not, the cursor moves on: a held run is read again by its runid.
            @cursors[jobid] = runid if names.key?(jobid) && runid > @cursors.fetch(jobid, 0)
          end
          if details.length < PAGE
            complete = true
            break
          end
        end
        # Every row was read and these were not among them: pg_cron no longer has them.
        return unless complete

        open.each do |runid|
          @pending.delete(runid)
          @held.delete(runid)
        end
      end
    end
  end
end
