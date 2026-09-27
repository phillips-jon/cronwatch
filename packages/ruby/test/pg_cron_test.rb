# frozen_string_literal: true

require_relative "test_helper"
require "cronwatch/pg_cron"

# The pg_cron reader against cron.job and cron.job_run_details held in
# memory (as packages/sdk/test/pgcron.test.ts), and, when
# CRONWATCH_TEST_PGCRON is the URL of a Postgres with pg_cron, against the
# real thing through the pg gem.
class PgCronTest < Minitest::Test
  include TestHelpers

  PgCron = Cronwatch::Sources::PgCron
  Detail = Struct.new(:runid, :jobid, :status, :return_message, :start_time, :end_time, keyword_init: true)

  # cron.job and cron.job_run_details in memory, answering the reader's queries.
  class FakeCron
    attr_reader :jobs, :details, :queries

    def initialize
      @jobs = []
      @details = []
      @runid = 0
      @queries = []
    end

    def job(jobid, jobname, schedule, active = true)
      @jobs << { "jobid" => jobid, "jobname" => jobname, "schedule" => schedule, "database" => "postgres", "username" => "postgres", "active" => active }
    end

    def add(jobid, status, start, finish, message = nil)
      d = Detail.new(runid: @runid += 1, jobid: jobid, status: status, return_message: message,
                     start_time: start && Time.at(Rational(start, 1000)).utc, end_time: finish && Time.at(Rational(finish, 1000)).utc)
      @details << d
      d
    end

    def query(text, values = [])
      @queries << text
      return [{ "value" => values[0] == "cron.timezone" ? "GMT" : "on" }] if text.include?("current_setting")
      return @jobs.map { |j| j.merge("jobid" => j["jobid"].to_s) } if text.include?("FROM cron.job ORDER BY")
      if text.include?("ORDER BY d.runid DESC")
        return out(@details.select { |d| d.jobid == values[0] }.sort_by { |d| -d.runid }.first(20))
      end
      if text.include?("unnest")
        ids, afters, open = values
        after = ids.zip(afters).to_h
        return out(@details.select { |d| after.key?(d.jobid) && (d.runid > after[d.jobid] || open.include?(d.runid)) }.sort_by(&:runid).first(500))
      end
      raise "unexpected query #{text}"
    end

    private

    def out(rows)
      rows.map do |d|
        { "runid" => d.runid.to_s, "jobid" => d.jobid.to_s, "status" => d.status, "return_message" => d.return_message,
          "start_time" => d.start_time, "end_time" => d.end_time }
      end
    end
  end

  DAY = 24 * HOUR

  def job_named(result, name)
    result.jobs.find { |j| j.name == name }
  end

  def test_schedules_and_names
    assert_equal "every 30s", PgCron.schedule("30 seconds")
    assert_equal "every 1s", PgCron.schedule("1 second")
    assert_equal "0 0 L * *", PgCron.schedule("0 0 $ * *")
    assert_equal "*/5 * * * *", PgCron.schedule(" */5  * * * * ")
    assert_nil PgCron.schedule("@reboot")
    job = ->(jobid, jobname) { PgCron::Job.new(jobid: jobid, jobname: jobname) }
    assert_equal "nightly-vacuum", PgCron.job_name(job.(7, "nightly vacuum"))
    assert_equal "pg_cron:7", PgCron.job_name(job.(7, nil))
    assert_equal "pg_cron:7", PgCron.job_name(job.(7, "  "))
  end

  def test_rows_become_runs
    at = Time.utc(2026, 1, 5, 9, 30)
    row = { "runid" => "9", "jobid" => "1", "status" => "failed", "return_message" => "  ERROR:  boom\n", "start_time" => at, "end_time" => "2026-01-05 09:30:02.5+00" }
    run = PgCron.run(row, "vacuum", "pgcron:")
    assert_equal ["pgcron:9", :failed, T0, T0 + 2500, 2500, "ERROR:  boom", nil, "pg_cron"],
                 [run.id, run.status, run.started_at, run.finished_at, run.duration_ms, run.error, run.output, run.trigger]
    assert_equal "pg_cron reported the run as failed", PgCron.run(row.merge("return_message" => " "), "vacuum", "pgcron:").error
    going = PgCron.run(row.merge("status" => "running", "end_time" => nil), "vacuum", "pgcron:")
    assert_equal [:running, nil, nil, nil], [going.status, going.finished_at, going.duration_ms, going.error]
    assert_nil PgCron.run(row.merge("start_time" => nil), "vacuum", "pgcron:")
  end

  def test_jobs_are_declared_history_is_copied_quietly_and_imports_are_idempotent
    clock = Clock.new
    cron = FakeCron.new
    cron.job(1, "nightly vacuum", "0 3 * * *")
    cron.job(2, nil, "10 seconds")
    cron.job(3, "paused", "0 * * * *", false)
    cron.job(4, "other", "0 * * * *")
    three = Time.utc(2026, 1, 5, 3).to_i * 1000
    24.downto(1) { |i| cron.add(1, "succeeded", three - (i * DAY), three - (i * DAY) + 5000, "VACUUM") }
    cron.add(1, "failed", three, three + 2000, "ERROR:  deadlock detected\n")
    store = Cronwatch::Stores::Memory.new
    capture = Capture.new
    source = -> { PgCron.new(cron, jobs: ->(j) { j.jobid != 4 }, prefix: "db:") }
    cw = Cronwatch.new(store: store, alerts: [capture], now: clock.to_proc, cron_secret: nil, sources: [source.call])

    first = cw.check
    assert_equal ["db:nightly-vacuum", "db:paused", "db:pg_cron:2"], first.jobs.map(&:name)
    vacuum = job_named(first, "db:nightly-vacuum")
    assert_equal "0 3 * * *", vacuum.definition.schedule
    assert_equal "UTC", vacuum.definition.timezone
    assert_equal ["pg_cron"], vacuum.definition.tags
    assert_equal "every 10s", job_named(first, "db:pg_cron:2").definition.schedule
    assert_nil job_named(first, "db:paused").definition.schedule, "a paused job is not expected to run"
    runs = cw.runs("db:nightly-vacuum", 100)
    assert_equal 20, runs.length, "twenty newest runs copied on first sight"
    assert_equal ["pgcron:db:25", :failed, "ERROR:  deadlock detected", 2000, "pg_cron"],
                 [runs[0].id, runs[0].status, runs[0].error, runs[0].duration_ms, runs[0].trigger]
    assert_equal "VACUUM", runs[1].output
    assert_equal [:failed], capture.types, "only the newest finished run is judged; history does not alert"

    cw.check
    cw = Cronwatch.new(store: store, alerts: [capture], now: clock.to_proc, cron_secret: nil, sources: [source.call])
    cw.check
    assert_equal 20, cw.runs("db:nightly-vacuum", 100).length, "a re-import, even after a restart, adds nothing"
    assert_equal [:failed], capture.types

    # A run not yet started holds the cursor; the run after it is copied now and it is copied once it starts.
    starting = cron.add(2, "starting", nil, nil)
    cron.add(2, "succeeded", T0 - 5000, T0 - 4000, "1 row")
    clock.advance(1000)
    cw.check
    assert_equal ["pgcron:db:27"], cw.runs("db:pg_cron:2").map(&:id)
    starting.status = "running"
    starting.start_time = Time.at(Rational(T0 - 3000, 1000)).utc
    cw.check
    assert_equal :running, cw.run("pgcron:db:26").status
    starting.status = "failed"
    starting.end_time = Time.at(Rational(T0 - 1000, 1000)).utc
    starting.return_message = "ERROR:  boom"
    clock.advance(1000)
    cw.check
    finished = cw.run("pgcron:db:26")
    assert_equal [:failed, 2000], [finished.status, finished.duration_ms]
    assert_equal %i[failed failed], capture.types, "a run that was running and then failed is judged when it finishes"

    # The nightly job stops running: missed, from its schedule, with no run details at all.
    clock.now = Time.utc(2026, 1, 6, 3, 11).to_i * 1000
    cron.jobs.shift
    cron.add(2, "succeeded", clock.now - 2000, clock.now - 1000, "1 row")
    later = cw.check
    assert_equal ["missed db:nightly-vacuum", "recovered db:pg_cron:2"], later.alerts.map { |a| "#{a.type} #{a.job}" }.sort
    assert_empty cw.check.alerts, "each condition alerts once"
  end

  def test_job_options_apply_and_an_unreadable_schedule_is_reported
    cron = FakeCron.new
    cron.job(1, "odd", "not a schedule")
    errors = []
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [], cron_secret: nil,
                       on_error: ->(e, _where) { errors << e.message },
                       sources: [PgCron.new(cron, options: { grace: "1m", expect: /rows?/ })])
    now = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    cron.add(1, "succeeded", now - 1000, now, "nothing")
    result = cw.check
    assert_nil result.jobs[0].definition.schedule
    assert_equal "1m", result.jobs[0].definition.grace
    assert_match(/watching it without a schedule/, errors.join("\n"))
    run = cw.runs("odd").first
    assert_equal :failed, run.status, "expect applies to imported output"
    assert_match(/did not match/, run.error)
  end

  def test_warnings_come_once
    cron = FakeCron.new
    def cron.query(text, values = [])
      raise "permission denied" if text.include?("current_setting")

      super
    end
    errors = []
    cw = Cronwatch.new(alerts: [], cron_secret: nil, on_error: ->(e, where) { errors << "#{where}: #{e.message}" },
                       sources: [PgCron.new(cron)])
    cw.check
    cw.check
    assert_equal 2, errors.length, errors.inspect
    assert_match(/could not read cron.timezone; assuming UTC/, errors[0])
    assert_match(/cron.job shows no jobs/, errors[1])
  end

  def test_adapters
    assert_raises(ArgumentError) { PgCron.new(Object.new) }
    pg = Class.new do
      attr_reader :calls

      def exec_params(sql, params)
        (@calls ||= []) << [sql, params]
        [{ "value" => "UTC" }]
      end
    end.new
    assert_equal [{ "value" => "UTC" }], PgCron.adapter(pg).query("SELECT $1", [[1, 2], 3, "x"])
    assert_equal [["SELECT $1", ["{1,2}", 3, "x"]]], pg.calls
  end

  # ---------------------------------------------------------------- a real pg_cron

  PGCRON = ENV.fetch("CRONWATCH_TEST_PGCRON", nil)

  def pg_connect
    require "pg"
    conn = PG.connect(PGCRON)
    conn.set_notice_receiver { |_result| nil }
    conn
  end

  def detail_count(conn, name)
    conn.exec_params("SELECT count(*) AS n FROM cron.job_run_details d JOIN cron.job j USING (jobid) " \
                     "WHERE j.jobname = $1 AND d.start_time IS NOT NULL", [name]).first["n"].to_i
  end

  def test_against_a_real_pg_cron
    skip "set CRONWATCH_TEST_PGCRON to the URL of a Postgres with pg_cron (in cron.database_name) to run" unless PGCRON

    conn = pg_connect
    admin = pg_connect
    tag = "cwrb#{Process.pid}"
    names = { ok: "#{tag}-ok", fail: "#{tag}-fail", sleep: "#{tag}-sleep" }
    offset = 0
    now = -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) + offset }
    store = Cronwatch::Stores::Memory.new
    capture = Capture.new
    make = lambda do
      Cronwatch.new(store: store, alerts: [capture], now: now, cron_secret: nil,
                    sources: [PgCron.new(conn, jobs: ->(j) { j.jobname.to_s.start_with?(tag) }, options: { grace: "30s" })])
    end
    begin
      admin.exec("CREATE EXTENSION IF NOT EXISTS pg_cron")
      admin.exec_params("SELECT cron.schedule($1, '1 seconds', 'SELECT 1')", [names[:ok]])
      admin.exec_params("SELECT cron.schedule($1, '1 seconds', 'SELECT 1/0')", [names[:fail]])
      admin.exec_params("SELECT cron.schedule($1, '1 seconds', 'SELECT pg_sleep(3)')", [names[:sleep]])
      sleep 3.5

      cw = make.call
      first = cw.check
      by_name = first.jobs.to_h { |j| [j.name, j] }
      assert_equal "every 1s", by_name[names[:ok]].definition.schedule
      assert_equal "UTC", by_name[names[:ok]].definition.timezone
      ok_runs = cw.runs(names[:ok])
      assert_operator ok_runs.length, :>=, 2, "ok runs imported"
      assert(ok_runs.all? { |r| r.id.start_with?("pgcron:") && r.trigger == "pg_cron" })
      assert(ok_runs.any? { |r| r.status == :ok && r.output == "1 row" })
      assert(cw.runs(names[:fail]).any? { |r| r.status == :failed && r.error.to_s.include?("division by zero") }, "failure and its message imported")
      assert_equal ["failed #{names[:fail]}"], first.alerts.map { |a| "#{a.type} #{a.job}" }
      assert_equal :healthy, by_name[names[:ok]].health

      # A run imported while it was going is updated when it finishes.
      running = nil
      40.times do
        row = admin.exec_params("SELECT d.runid FROM cron.job_run_details d JOIN cron.job j USING (jobid) " \
                                "WHERE j.jobname = $1 AND d.status = 'running' AND d.start_time IS NOT NULL", [names[:sleep]]).first
        running = row && row["runid"]
        break if running

        sleep 0.25
      end
      assert running, "saw the sleeping job running"
      cw.check
      assert_equal :running, cw.run("pgcron:#{running}")&.status
      sleep 3.5
      cw.check
      slept = cw.run("pgcron:#{running}")
      assert_equal :ok, slept.status
      assert_operator slept.duration_ms, :>=, 2900

      # New runs keep arriving; nothing is copied twice, even by a fresh client after a restart.
      before = cw.runs(names[:ok], 500).length
      sleep 2
      cw.check
      after = cw.runs(names[:ok], 500)
      assert_operator after.length, :>, before, "later runs imported"
      assert_equal after.length, after.map(&:id).uniq.length

      # The ok job is unscheduled: it is missed once its grace passes.
      admin.exec_params("SELECT cron.unschedule($1)", [names[:ok]])
      admin.exec_params("SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = $1", [names[:fail]])
      sleep 1.5
      cw = make.call
      cw.check
      settled = cw.runs(names[:fail], 500).length
      cw.check
      assert_equal settled, cw.runs(names[:fail], 500).length, "re-import adds nothing"
      assert_equal [detail_count(admin, names[:fail]), settled].min, cw.runs(names[:fail], 500).length
      offset = 2 * MIN
      late = cw.check
      assert(late.alerts.any? { |a| a.type == :missed && a.job == names[:ok] }, "unscheduled job reported missed")
      refute(late.alerts.any? { |a| a.job == names[:fail] && a.type == :missed }, "paused job not missed")
    ensure
      begin
        admin.exec_params("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1", ["#{tag}%"])
      rescue StandardError
        nil
      end
      conn&.close
      admin&.close
    end
  end
end
