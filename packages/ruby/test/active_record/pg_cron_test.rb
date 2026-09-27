# frozen_string_literal: true

require_relative "../support/active_record_helper"
require "cronwatch/pg_cron"

# The pg_cron reader on the app's ActiveRecord connection, with the
# ActiveRecord store in the same database: what a Rails app on Supabase or
# any Postgres with pg_cron runs. Needs CRONWATCH_TEST_PGCRON.
class ActiveRecordPgCronTest < Minitest::Test
  PGCRON = ENV.fetch("CRONWATCH_TEST_PGCRON", nil).then { |url| url.nil? || url.empty? ? nil : url }

  def self.connection_class
    @connection_class ||= begin
      klass = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      Object.const_set("CronwatchTestPgCronRecord", klass)
      klass.establish_connection(PGCRON)
      klass
    end
  end

  def setup
    skip "set CRONWATCH_TEST_PGCRON to the URL of a Postgres with pg_cron (in cron.database_name) to run" unless PGCRON
    @klass = self.class.connection_class
    @prefix = ARSupport.prefix
    @tag = "cwar#{Process.pid}#{SecureRandom.hex(2)}"
    @klass.connection_pool.with_connection do |conn|
      Cronwatch::Stores::ActiveRecord.create_tables!(conn, prefix: @prefix)
      conn.execute("CREATE EXTENSION IF NOT EXISTS pg_cron")
    end
  end

  def teardown
    return unless PGCRON

    @klass.connection_pool.with_connection do |conn|
      conn.exec_query("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1", "cleanup", ["#{@tag}%"])
      Cronwatch::Stores::ActiveRecord.drop_tables!(conn, prefix: @prefix)
    end
  end

  def test_runs_are_read_through_the_apps_connection
    @klass.connection_pool.with_connection do |conn|
      conn.exec_query("SELECT cron.schedule($1, '1 seconds', 'SELECT 1')", "schedule", ["#{@tag}-ok"])
      conn.exec_query("SELECT cron.schedule($1, '1 seconds', 'SELECT 1/0')", "schedule", ["#{@tag}-fail"])
    end
    sleep 2.5

    store = Cronwatch::Stores::ActiveRecord.new(prefix: @prefix, connection_class: @klass)
    errors = []
    picks = ->(job) { job.jobname.to_s.start_with?(@tag) }
    # A class, its pool and a checked out connection all work.
    [@klass, @klass.connection_pool].each_with_index do |db, i|
      client = Cronwatch.new(store: store, alerts: [], cron_secret: nil, on_error: ->(e, where) { errors << "#{where}: #{e.message}" },
                             sources: [Cronwatch::Sources::PgCron.new(db, jobs: picks, prefix: "p#{i}:")])
      client.check
      ok = client.runs("p#{i}:#{@tag}-ok")
      refute_empty ok
      assert(ok.all? { |r| r.status == :ok && r.output == "1 row" && r.trigger == "pg_cron" })
      assert(client.runs("p#{i}:#{@tag}-fail").any? { |r| r.status == :failed && r.error.include?("division by zero") })

      # Times are read to the millisecond Postgres holds, whichever way the driver decodes them.
      runid = ok.first.id.delete_prefix("pgcron:p#{i}:")
      expected = @klass.connection_pool.with_connection do |conn|
        conn.exec_query("SELECT floor(extract(epoch FROM start_time) * 1000)::bigint AS s, floor(extract(epoch FROM end_time) * 1000)::bigint AS e " \
                        "FROM cron.job_run_details WHERE runid = $1", "times", [runid.to_i]).first
      end
      assert_equal [expected["s"].to_i, expected["e"].to_i], [ok.first.started_at, ok.first.finished_at]
    end
    @klass.connection_pool.with_connection do |conn|
      client = Cronwatch.new(store: store, alerts: [], cron_secret: nil, sources: [Cronwatch::Sources::PgCron.new(conn, jobs: picks, prefix: "p2:")])
      client.check
      refute_empty client.runs("p2:#{@tag}-ok")
    end
    assert_empty errors
  end
end
