# frozen_string_literal: true

require "active_record"

module Cronwatch
  module Stores
    # Keeps jobs, runs and state in the app's database through ActiveRecord.
    # The same three tables, columns, indexes and JSON as the SDK's SQLite and
    # Postgres stores (packages/sdk/src/stores/sql.ts), so a Node process and a
    # Ruby process can share one database. Postgres and SQLite are supported
    # and tested; MySQL is untested (the statements use ON CONFLICT and TEXT
    # primary keys, which it does not take as written).
    #
    #   Cronwatch.configure do |c|
    #     c.store = Cronwatch::Stores::ActiveRecord.new
    #   end
    #
    # It never creates tables on its own: in Rails the install generator's
    # migration does, and elsewhere call ActiveRecord.create_tables!. Every call
    # checks a connection out of the pool for just that call, so checks and
    # runs in other threads are fine. Inside an open transaction each call runs
    # in a savepoint, so a store error cannot abort the app's transaction; the
    # rows still commit or roll back with it. Pass a connection_class that
    # connects_to another database to keep them apart.
    class ActiveRecord
      DEFAULT_PREFIX = "cronwatch_"
      # Postgres truncates identifiers past 63 bytes; the longest name built is the prefix plus "runs_job_started".
      MAX_PREFIX = 63 - "runs_job_started".length
      NAME = "Cronwatch"
      JS_SAFE_INTEGER = (2**53) - 1

      # Raised by init when the tables are not there.
      class MissingTables < StandardError; end

      attr_reader :prefix

      # prefix:           table name prefix, a plain lowercase identifier. Default "cronwatch_".
      # connection_class: the ActiveRecord class whose connection pool to use (or its name, looked
      #                   up on first use). Default ActiveRecord::Base.
      def initialize(prefix: DEFAULT_PREFIX, connection_class: nil)
        @prefix = self.class.table_prefix(prefix)
        @connection_class = connection_class
        @statements = {}
      end

      # Table names are built from the prefix, so it must be a plain lowercase
      # identifier. Uppercase is refused rather than folded: Postgres lowercases
      # unquoted names, so "Monitoring_" would quietly become "monitoring_".
      def self.table_prefix(prefix = DEFAULT_PREFIX)
        unless prefix.is_a?(String) && /\A[a-z_][a-z0-9_]*\z/.match?(prefix) && prefix.length <= MAX_PREFIX
          raise ArgumentError,
                "cronwatch: invalid table prefix #{JS.json(prefix.to_s)}. Use lowercase letters, digits and underscores, " \
                "not starting with a digit, at most #{MAX_PREFIX} characters."
        end

        prefix
      end

      # :postgres or :sqlite, from a connection's adapter.
      def self.dialect(connection)
        /postg/i.match?(connection.adapter_name) ? :postgres : :sqlite
      end

      # The SDK's schema, character for character (sql.ts `schema`).
      def self.schema(dialect, prefix = DEFAULT_PREFIX)
        p = table_prefix(prefix)
        pg = dialect.to_sym == :postgres
        int = pg ? "BIGINT" : "INTEGER"
        json = pg ? "JSONB" : "TEXT"
        text = <<-SQL
    CREATE TABLE IF NOT EXISTS #{p}jobs (
      name TEXT PRIMARY KEY,
      definition #{json} NOT NULL,
      created_at #{int} NOT NULL,
      updated_at #{int} NOT NULL
    );
    CREATE TABLE IF NOT EXISTS #{p}runs (#{pg ? "\n      seq BIGSERIAL," : ""}
      id TEXT PRIMARY KEY,
      job TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at #{int} NOT NULL,
      finished_at #{int},
      duration_ms #{int},
      error TEXT,
      output TEXT,
      metrics #{json} NOT NULL DEFAULT '{}',
      trigger TEXT NOT NULL DEFAULT 'run'
    );
    CREATE INDEX IF NOT EXISTS #{p}runs_job_started ON #{p}runs (job, started_at DESC);
    CREATE INDEX IF NOT EXISTS #{p}runs_running ON #{p}runs (status) WHERE status = 'running';
    CREATE TABLE IF NOT EXISTS #{p}state (
      job TEXT PRIMARY KEY,
      state #{json} NOT NULL
    );
        SQL
        "\n#{text}  "
      end

      # Creates the three tables if they are missing, with the SDK's DDL. For
      # the install generator's migration and for apps outside Rails. On
      # Postgres it holds the SDK's advisory lock for the prefix, so it takes
      # turns with Node processes creating the same tables.
      def self.create_tables!(connection = ::ActiveRecord::Base.connection, prefix: DEFAULT_PREFIX)
        p = table_prefix(prefix)
        if dialect(connection) == :postgres
          connection.transaction(requires_new: true) do
            connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote("cronwatch:#{p}")}))")
            connection.execute(schema(:postgres, p))
          end
        else
          # One statement at a time, each the same text the SDK hands SQLite.
          schema(:sqlite, p).split(";").each do |statement|
            connection.execute(statement) unless statement.strip.empty?
          end
        end
        nil
      end

      def self.drop_tables!(connection = ::ActiveRecord::Base.connection, prefix: DEFAULT_PREFIX)
        p = table_prefix(prefix)
        %w[state runs jobs].each { |table| connection.execute("DROP TABLE IF EXISTS #{p}#{table}") }
        nil
      end

      # Checks that the tables are there, with a clear error when they are not.
      def init
        with_connection do |conn|
          missing = %w[jobs runs state].map { |t| "#{@prefix}#{t}" }.reject { |t| conn.table_exists?(t) }
          unless missing.empty?
            raise MissingTables,
                  "cronwatch: missing table#{missing.length == 1 ? "" : "s"} #{missing.join(", ")}. In Rails run " \
                  "`bin/rails generate cronwatch:install` and migrate; elsewhere call " \
                  "Cronwatch::Stores::ActiveRecord.create_tables!(connection#{@prefix == DEFAULT_PREFIX ? "" : ", prefix: #{@prefix.inspect}"})."
          end
        end
        nil
      end

      def upsert_job(definition, now)
        definition = JobDefinition.from_h(definition)
        write(:upsert_job, [definition.name, JS.json(definition.to_h), now, now])
        nil
      end

      def get_job(name)
        row = read(:get_job, [name]).first
        row && row_to_job(row)
      end

      # Byte order on both databases, as the SDK's SQL stores sort.
      def list_jobs
        read(:list_jobs, []).map { |row| row_to_job(row) }
      end

      def delete_job(name)
        with_connection do |conn|
          conn.transaction(requires_new: true) do
            %i[delete_runs delete_state delete_job].each { |key| conn.exec_update(sql(conn, key), NAME, [name]) }
          end
        end
        nil
      end

      def insert_run(run)
        write(:insert_run, [run.id, run.job, run.status.to_s, run.started_at, run.finished_at, run.duration_ms,
                            run.error, run.output, JS.json(run.metrics || {}), run.trigger])
        nil
      end

      # A run that is gone (its job was forgotten) stays gone.
      def update_run(run)
        write(:update_run, [run.status.to_s, run.finished_at, run.duration_ms, run.error, run.output,
                            JS.json(run.metrics || {}), run.id])
        nil
      end

      def get_run(id)
        row = read(:get_run, [id]).first
        row && row_to_run(row)
      end

      # Newest first; runs that started in the same millisecond, last written first.
      def list_runs(job, limit)
        read(:list_runs, [job, [limit.to_i, 0].max]).map { |row| row_to_run(row) }
      end

      def last_run(job)
        list_runs(job, 1).first
      end

      # Oldest first, then in the order they were written.
      def running_runs
        read(:running_runs, []).map { |row| row_to_run(row) }
      end

      def get_state(job)
        row = read(:get_state, [job]).first
        row && JobState.from_h(json(row["state"]))
      end

      def set_state(state)
        write(:set_state, [state.job, JS.json(state.to_h)])
        nil
      end

      # Deletes finished runs that started before this time, except each job's
      # newest run. Returns how many.
      def prune(before)
        write(:prune, [before])
      end

      # The pool belongs to the app; there is nothing to close.
      def close
        nil
      end

      private

      def connection_class
        klass = @connection_class || ::ActiveRecord::Base
        klass.is_a?(String) ? Object.const_get(klass) : klass
      end

      def with_connection(&block)
        connection_class.connection_pool.with_connection do |conn|
          # A failed statement aborts a Postgres transaction; a savepoint keeps that from reaching the app's.
          conn.transaction_open? ? conn.transaction(requires_new: true) { block.call(conn) } : block.call(conn)
        end
      end

      # Reads skip the query cache: a job's own run is read back right after it is written.
      def read(key, binds)
        with_connection { |conn| conn.uncached { conn.select_all(sql(conn, key), NAME, binds).to_a } }
      end

      def write(key, binds)
        with_connection { |conn| conn.exec_update(sql(conn, key), NAME, binds) }
      end

      def sql(conn, key)
        dialect = self.class.dialect(conn)
        (@statements[dialect] ||= statements(dialect)).fetch(key)
      end

      # sql.ts `statements`: the same text, with `?` numbered for Postgres.
      def statements(dialect)
        p = @prefix
        pg = dialect == :postgres
        # Insertion order, to break ties between runs that started in the same millisecond.
        seq = pg ? "seq" : "rowid"
        # Byte order on both, so names sort the same whatever the database's collation.
        by_name = pg ? 'name COLLATE "C"' : "name"
        sql = {
          upsert_job: "INSERT INTO #{p}jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)\n      " \
                      "ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at",
          get_job: "SELECT * FROM #{p}jobs WHERE name = ?",
          list_jobs: "SELECT * FROM #{p}jobs ORDER BY #{by_name}",
          delete_runs: "DELETE FROM #{p}runs WHERE job = ?",
          delete_state: "DELETE FROM #{p}state WHERE job = ?",
          delete_job: "DELETE FROM #{p}jobs WHERE name = ?",
          insert_run: "INSERT INTO #{p}runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)\n      " \
                      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          update_run: "UPDATE #{p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?",
          get_run: "SELECT * FROM #{p}runs WHERE id = ?",
          list_runs: "SELECT * FROM #{p}runs WHERE job = ? ORDER BY started_at DESC, #{seq} DESC LIMIT ?",
          running_runs: "SELECT * FROM #{p}runs WHERE status = 'running' ORDER BY started_at, #{seq}",
          get_state: "SELECT state FROM #{p}state WHERE job = ?",
          set_state: "INSERT INTO #{p}state (job, state) VALUES (?, ?) ON CONFLICT (job) DO UPDATE SET state = excluded.state",
          # Each job's newest run is kept whatever its age: without it, a job that
          # runs less often than the retention looks like it never ran.
          prune: "DELETE FROM #{p}runs WHERE status <> 'running' AND started_at < ?\n      " \
                 "AND started_at < (SELECT MAX(r.started_at) FROM #{p}runs r WHERE r.job = #{p}runs.job)",
        }
        if pg
          sql.transform_values! do |text|
            n = 0
            text.gsub("?") { "$#{n += 1}" }
          end
        end
        sql.freeze
      end

      # SQLite hands back JSON as TEXT; Postgres drivers may hand back JSONB
      # parsed or as text, and BIGINT as a string.
      def json(value)
        js_numbers(value.is_a?(String) ? JS.parse(value) : value)
      end

      # JSONB writes 1e21 back as 1000000000000000000000, which JavaScript
      # reads as a double and Ruby as an Integer. Past 2**53 an Integer is
      # turned into the Float JavaScript would hold, so Node and Ruby read the
      # same number and write it back the same.
      def js_numbers(value)
        case value
        when Integer then value.abs > JS_SAFE_INTEGER ? value.to_f : value
        when Hash then value.transform_values! { |v| js_numbers(v) }
        when Array then value.map! { |v| js_numbers(v) }
        else value
        end
      end

      def int(value)
        value.nil? ? nil : Integer(value)
      end

      def row_to_job(row)
        StoredJob.new(name: row["name"], definition: JobDefinition.from_h(json(row["definition"])),
                      created_at: int(row["created_at"]), updated_at: int(row["updated_at"]))
      end

      def row_to_run(row)
        metrics = row["metrics"].nil? ? {} : json(row["metrics"])
        Run.new(id: row["id"], job: row["job"], status: row["status"].to_sym, started_at: int(row["started_at"]),
                finished_at: int(row["finished_at"]), duration_ms: int(row["duration_ms"]), error: row["error"],
                output: row["output"], metrics: metrics, trigger: row["trigger"])
      end
    end
  end
end
