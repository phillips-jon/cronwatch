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
    attr_reader :jobs, :details, :queries, :settings

    def initialize
      @jobs = []
      @details = []
      @runid = 0
      @queries = []
      @settings = { "cron.timezone" => "GMT", "cron.log_run" => "on" }
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
      if text.include?("pg_settings")
        value = @settings[values[0]]
        return value.nil? ? [] : [{ "setting" => value }]
      end
      return @jobs.map { |j| j.merge("jobid" => j["jobid"].to_s) } if text.include?("FROM cron.job ORDER BY")
      if text.include?("ORDER BY d.runid DESC")
        return out(@details.select { |d| d.jobid == values[0] }.sort_by { |d| -d.runid }.first(20))
      end
      if text.include?("unnest")
        ids, afters, open = values
        after = ids.zip(afters).to_h
        return out(@details.select { |d| (after.key?(d.jobid) && d.runid > after[d.jobid]) || open.map(&:to_i).include?(d.runid) }
                           .sort_by(&:runid).first(500))
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
    assert_nil PgCron.run(row.merge("status" => "starting", "start_time" => nil, "end_time" => nil), "vacuum", "pgcron:"),
               "not started yet"
    # A run a server restart cut off: failed, no start_time; it starts at its end_time, else at the fallback.
    cut = PgCron.run(row.merge("start_time" => nil, "return_message" => "server restarted"), "vacuum", "pgcron:", T0 - HOUR)
    assert_equal [:failed, T0 + 2500, T0 + 2500, 0, "server restarted"], [cut.status, cut.started_at, cut.finished_at, cut.duration_ms, cut.error]
    timeless = PgCron.run(row.merge("start_time" => nil, "end_time" => nil), "vacuum", "pgcron:", T0 - HOUR)
    assert_equal [T0 - HOUR, T0 - HOUR, 0], [timeless.started_at, timeless.finished_at, timeless.duration_ms]
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
    assert_equal :running, cw.get_run("pgcron:db:26").status
    starting.status = "failed"
    starting.end_time = Time.at(Rational(T0 - 1000, 1000)).utc
    starting.return_message = "ERROR:  boom"
    clock.advance(1000)
    cw.check
    finished = cw.get_run("pgcron:db:26")
    assert_equal [:failed, 2000], [finished.status, finished.duration_ms]
    assert_equal %i[failed failed], capture.types, "a run that was running and then failed is judged when it finishes"

    # The nightly job stops running: missed, from its schedule, with no run details at all.
    clock.now = Time.utc(2026, 1, 6, 3, 11).to_i * 1000
    cron.add(2, "succeeded", clock.now - 2000, clock.now - 1000, "1 row")
    later = cw.check
    assert_equal ["missed db:nightly-vacuum", "recovered db:pg_cron:2"], later.alerts.map { |a| "#{a.type} #{a.job}" }.sort
    assert_empty cw.check.alerts, "each condition alerts once"

    # Unscheduled: its name keeps its history but loses its schedule, so it is never missed again,
    # and the missed alert it had open closes with a recovery that says so.
    cron.jobs.shift
    clock.now = Time.utc(2026, 1, 8, 3, 11).to_i * 1000
    gone = cw.check
    vacuum_now = job_named(gone, "db:nightly-vacuum")
    assert_nil vacuum_now.definition.schedule
    assert_match(/no longer watched/, vacuum_now.definition.description)
    assert_equal [:failed], vacuum_now.open, "its failure stays open until a successful run"
    closed = gone.alerts.select { |a| a.job == "db:nightly-vacuum" }
    assert_equal [:recovered], closed.map(&:type)
    assert_equal "db:nightly-vacuum is no longer scheduled", closed[0].title
    assert_equal({ after: [:missed], reason: :unscheduled, since: Time.utc(2026, 1, 6, 3, 11).to_i * 1000 }, closed[0].details)
    refute(cw.check.alerts.any? { |a| a.job == "db:nightly-vacuum" }, "once")
    assert_equal 20, cw.runs("db:nightly-vacuum", 100).length, "its history is kept"
  end

  def test_a_job_forgotten_from_the_dashboard_is_declared_again_and_its_later_runs_recorded
    clock = Clock.new
    cron = FakeCron.new
    cron.job(1, "vacuum", "0 3 * * *")
    cron.add(1, "succeeded", T0 - 5000, T0 - 4000, "VACUUM")
    errors = []
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [Capture.new], now: clock.to_proc, cron_secret: nil,
                       on_error: ->(e, where) { errors << "#{where}: #{e.message}" }, sources: [PgCron.new(cron)])
    cw.check
    cw.forget("vacuum")
    cron.add(1, "succeeded", T0 - 3000, T0 - 2000, "VACUUM")
    cron.add(1, "failed", T0 - 1000, T0, "ERROR:  boom")
    clock.advance(1000)
    result = cw.check
    assert_empty errors
    assert_equal ["vacuum"], result.jobs.map(&:name)
    assert_equal "0 3 * * *", result.jobs[0].definition.schedule
    assert_equal ["pgcron:3", "pgcron:2"], cw.runs("vacuum").map(&:id), "the runs after the forget"
    assert_equal ["vacuum"], cw.defined_jobs.map(&:name)
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
      raise "permission denied" if text.include?("pg_settings")

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

  def at(ms) = Time.at(Rational(ms, 1000)).utc

  def test_a_jobs_job_name_or_options_callback_that_fails_fails_only_its_job_reported_once
    clock = Clock.new
    cron = FakeCron.new
    %w[one two three four].each_with_index { |name, i| cron.job(i + 1, name, "0 * * * *") }
    broken = Set.new
    fault = ->(what, jobid) { broken.include?("#{what}:#{jobid}") }
    errors = []
    source = PgCron.new(
      cron,
      jobs: lambda { |j|
        raise "pick broke" if fault.call("pick", j.jobid)

        true
      },
      job_name: lambda { |j|
        raise "name broke" if fault.call("throw", j.jobid)
        return nil if fault.call("nil", j.jobid)
        return 7 if fault.call("number", j.jobid)

        "j-#{j.jobname}"
      },
      options: lambda { |j|
        raise "options broke" if fault.call("options", j.jobid)

        {}
      },
    )
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [], now: clock.to_proc, cron_secret: nil,
                       on_error: ->(e, _where) { errors << e.message }, sources: [source])
    notices = -> { errors.grep_v(/cron\.timezone|row level/) }
    tail = "; it keeps its last declaration until that works"
    # First sight, with job 1's name callable raising and job 2's giving nil: only those two are skipped.
    broken << "throw:1" << "nil:2"
    first = cron.add(3, "succeeded", T0 - 60_000, T0 - 59_000, "ok")
    cw.check
    assert_equal %w[j-four j-three], cw.store.list_jobs.map(&:name)
    assert_equal "j-three", cw.get_run("pgcron:#{first.runid}")&.job
    assert_equal ["pg_cron job 1: job_name raised RuntimeError: name broke#{tail}",
                  "pg_cron job 2: job_name returned nil, not a name#{tail}"], notices.call

    # Once they work, both are declared; then every callable fails in turn for jobs already declared.
    broken.clear
    cw.check
    assert_equal %w[j-four j-one j-three j-two], cw.store.list_jobs.map(&:name)
    broken << "pick:1" << "number:2" << "options:3" << "throw:4"
    errors.clear
    later = [cron.add(1, "failed", T0 + 1000, T0 + 2000, "ERROR:  one"), cron.add(3, "succeeded", T0 + 1000, T0 + 2000, "ok")]
    clock.advance(5000)
    cw.check
    cw.check
    assert_equal ["pg_cron job 1: the jobs callback raised RuntimeError: pick broke#{tail}",
                  "pg_cron job 2: job_name returned Integer, not a name#{tail}",
                  "pg_cron job 3: the options callback raised RuntimeError: options broke#{tail}",
                  "pg_cron job 4: job_name raised RuntimeError: name broke#{tail}"], notices.call, "each reported once, over two syncs"
    # Each keeps its name and schedule, is not retired, and its runs are still copied.
    cw.store.list_jobs.each do |stored|
      assert_equal "0 * * * *", stored.definition.schedule, stored.name
      refute_match(/no longer|renamed/, stored.definition.description.to_s, stored.name)
    end
    assert_equal "j-one", cw.get_run("pgcron:#{later[0].runid}")&.job
    assert_equal "j-three", cw.get_run("pgcron:#{later[1].runid}")&.job

    # Working again and then failing again is reported again.
    broken.clear
    cw.check
    broken << "pick:1"
    cw.check
    assert_equal 5, notices.call.length
    assert_match(/\Apg_cron job 1: the jobs callback raised/, notices.call[4])
  end

  def test_a_run_cut_off_by_a_restart_is_recorded_and_one_held_run_never_stops_the_others
    clock = Clock.new
    cron = FakeCron.new
    cron.job(1, "fast", "30 seconds")
    cron.job(2, "other", "0 * * * *")
    errors = []
    capture = Capture.new
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [capture], now: clock.to_proc, cron_secret: nil,
                       on_error: ->(e, _where) { errors << e.message }, sources: [PgCron.new(cron)])
    cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row")
    cw.check
    # pg_cron restarts while a run is queued: it marks it failed, "server restarted", with no times at all.
    restarted = cron.add(1, "failed", nil, nil, "server restarted")
    # The fast job then runs far more than a page's worth, and the other job fails after all of them.
    520.times { |i| cron.add(1, "succeeded", T0 - 50_000 + i, T0 - 50_000 + i + 1, "1 row") }
    failure = cron.add(2, "failed", T0 - 1000, T0 - 500, "ERROR:  disk full")
    queued = cron.add(1, "starting", nil, nil)
    clock.advance(1000)
    cw.check
    cw.check
    cut = cw.get_run("pgcron:#{restarted.runid}")
    assert_equal [:failed, "server restarted"], [cut.status, cut.error]
    assert_equal T0 - 60_000, cut.started_at, "placed at the job's newest run before it"
    assert_equal :failed, cw.get_run("pgcron:#{failure.runid}")&.status, "the other job's failure is not starved"
    assert(capture.alerts.any? { |a| a.type == :failed && a.job == "other" })
    assert_nil cw.get_run("pgcron:#{queued.runid}"), "a queued run is held"

    # Held only so long: then it is copied as running from when it was first seen, and a late start updates nothing but its end.
    clock.advance(11 * MIN)
    cw.check
    waiting = cw.get_run("pgcron:#{queued.runid}")
    assert_equal [:running, T0 + 1000], [waiting.status, waiting.started_at]
    queued.status = "succeeded"
    queued.start_time = at(clock.now - 2000)
    queued.end_time = at(clock.now - 1000)
    clock.advance(1000)
    cw.check
    assert_equal :ok, cw.get_run("pgcron:#{queued.runid}").status
    assert_equal [], errors.grep_v(/cron\.|row level/)
  end

  def test_first_sight_never_judges_history_even_with_a_held_or_cut_off_run_among_the_newest
    clock = Clock.new
    cron = FakeCron.new
    cron.job(1, "nightly", "0 3 * * *")
    30.times { |i| cron.add(1, "failed", T0 - ((40 - i) * HOUR), T0 - ((40 - i) * HOUR) + 1000, "ERROR:  old") }
    cron.add(1, "failed", nil, nil, "server restarted")
    19.times { |i| cron.add(1, "succeeded", T0 - ((10 - (i / 2.0)) * HOUR).to_i, T0 - ((10 - (i / 2.0)) * HOUR).to_i + 1000, "ok") }
    capture = Capture.new
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [capture], now: clock.to_proc, cron_secret: nil,
                       sources: [PgCron.new(cron)])
    cw.check
    cw.check
    assert_equal 20, cw.runs("nightly", 500).length, "only the newest twenty are copied"
    assert_equal [], capture.types, "no alert from history"
  end

  def test_pg_cron_ignores_fields_past_the_fifth_and_so_does_the_reader
    assert_equal "0 5 * * *", PgCron.schedule("0 5 * * * *")
    assert_equal "* * * * *", PgCron.schedule("* * * * * *")
    assert_equal "0 0 L * *", PgCron.schedule("0 0 $ * * extra")
    assert_equal "@hourly", PgCron.schedule("@hourly")
  end

  def test_a_job_paused_or_renamed_while_missed_closes_missed_with_a_recovery
    clock = Clock.new
    cron = FakeCron.new
    cron.job(1, "hourly", "0 * * * *")
    cron.job(2, "rollup", "0 * * * *")
    cron.add(1, "succeeded", T0 - (3 * HOUR), T0 - (3 * HOUR) + 1000)
    cron.add(2, "succeeded", T0 - (3 * HOUR), T0 - (3 * HOUR) + 1000)
    capture = Capture.new
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [capture], now: clock.to_proc, cron_secret: nil,
                       sources: [PgCron.new(cron)])
    cw.check
    assert_equal ["missed hourly", "missed rollup"], capture.alerts.map { |a| "#{a.type} #{a.job}" }.sort
    cron.jobs[0]["active"] = false
    cron.jobs[1]["jobname"] = "rollup-v2"
    clock.advance(MIN)
    result = cw.check
    assert_equal ["recovered hourly hourly is no longer scheduled", "recovered rollup rollup is no longer scheduled"],
                 result.alerts.map { |a| "#{a.type} #{a.job} #{a.title}" }.sort
    clock.advance(MIN)
    assert_equal [], cw.check.alerts
  end

  def test_a_renamed_job_leaves_no_scheduled_ghost_in_this_process_or_the_next
    clock = Clock.new
    cron = FakeCron.new
    cron.job(1, "rollup", "*/5 * * * *")
    cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row")
    store = Cronwatch::Stores::Memory.new
    capture = Capture.new
    errors = []
    make = lambda do
      Cronwatch.new(store: store, alerts: [capture], now: clock.to_proc, cron_secret: nil,
                    on_error: ->(e, _where) { errors << e.message }, sources: [PgCron.new(cron)])
    end
    cw = make.call
    cw.check
    cron.jobs[0]["jobname"] = "rollup-v2"
    running = cron.add(1, "running", T0 - 1000, nil)
    cw.check
    summary = cw.jobs
    old = summary.find { |j| j.name == "rollup" }
    assert_nil old.definition.schedule, "the old name has no schedule"
    assert_match(/renamed to rollup-v2/, old.definition.description)
    assert_equal "*/5 * * * *", summary.find { |j| j.name == "rollup-v2" }.definition.schedule
    assert_equal "rollup-v2", cw.get_run("pgcron:#{running.runid}").job
    running.status = "succeeded"
    running.end_time = at(T0)
    clock.advance(HOUR)
    cron.add(1, "succeeded", clock.now - 2000, clock.now - 1000, "1 row")
    cw.check
    assert_equal :ok, cw.get_run("pgcron:#{running.runid}").status
    refute(capture.alerts.any? { |a| a.job == "rollup" }, "the old name is never missed")

    # Renamed again while no process watched: the next process retires the name the store still schedules.
    cron.jobs[0]["jobname"] = "rollup-v3"
    cw = make.call
    clock.advance(MIN)
    cw.check
    summary = cw.jobs
    v2 = summary.find { |j| j.name == "rollup-v2" }
    assert_nil v2.definition.schedule
    assert_match(/renamed to rollup-v3/, v2.definition.description)
    assert_equal "*/5 * * * *", summary.find { |j| j.name == "rollup-v3" }.definition.schedule
    assert_equal 0, cw.runs("rollup-v3").length, "runs already copied under an old name are not copied again"
    clock.advance(HOUR)
    cw.check
    assert_equal [], capture.alerts.reject { |a| a.job == "rollup-v3" }.map { |a| "#{a.type} #{a.job}" },
                 "only the job's current name can be missed"
    assert_equal [], errors.grep_v(/cron\.|row level/)
  end

  def test_a_run_marked_timeout_by_a_check_is_still_read_and_its_late_finish_recorded
    clock = Clock.new
    cron = FakeCron.new
    cron.job(1, "vacuum", "0 3 * * *")
    capture = Capture.new
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [capture], now: clock.to_proc, cron_secret: nil,
                       sources: [PgCron.new(cron, options: { timeout: "30m" })])
    long = cron.add(1, "running", T0, nil)
    cw.check
    assert_equal :running, cw.get_run("pgcron:#{long.runid}").status
    clock.advance(45 * MIN)
    cw.check
    assert_equal :timeout, cw.get_run("pgcron:#{long.runid}").status
    assert_equal [:stuck], capture.types
    clock.advance(10 * MIN)
    long.status = "succeeded"
    long.end_time = at(clock.now - 60_000)
    long.return_message = "VACUUM"
    cw.check
    done = cw.get_run("pgcron:#{long.runid}")
    assert_equal [:ok, "VACUUM"], [done.status, done.output]
    assert_equal %i[stuck recovered], capture.types
    assert_equal :healthy, cw.job_summary("vacuum").health
  end

  def test_settings_a_role_may_not_read_are_assumed_and_reported_once
    cron = FakeCron.new
    cron.settings.delete("cron.timezone")
    cron.settings.delete("cron.log_run")
    cron.job(1, "nightly", "0 3 * * *")
    errors = []
    cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [], cron_secret: nil,
                       on_error: ->(e, _where) { errors << e.message }, sources: [PgCron.new(cron)])
    first = cw.check
    cw.check
    assert_equal "UTC", first.jobs[0].definition.timezone
    assert_equal 1, errors.grep(/cron\.timezone/).length
    refute(errors.any? { |e| e.include?("log_run") }, "log_run unreadable is taken as on")
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
      assert_equal :running, cw.get_run("pgcron:#{running}")&.status
      sleep 3.5
      cw.check
      slept = cw.get_run("pgcron:#{running}")
      assert_equal :ok, slept.status
      assert_operator slept.duration_ms, :>=, 2900

      # New runs keep arriving; nothing is copied twice, even by a fresh client after a restart.
      before = cw.runs(names[:ok], 500).length
      sleep 2
      cw.check
      after = cw.runs(names[:ok], 500)
      assert_operator after.length, :>, before, "later runs imported"
      assert_equal after.length, after.map(&:id).uniq.length

      # The ok job is unscheduled: it is gone, not late, so it is never missed.
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
      refute(late.alerts.any? { |a| a.type == :missed && a.job == names[:ok] }, "unscheduled job not missed: it is gone, not late")
      ok_job = late.jobs.find { |j| j.name == names[:ok] }
      assert_nil ok_job.definition.schedule
      assert_match(/no longer in cron\.job/, ok_job.definition.description)
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

  DETAIL_COLUMNS = "jobid, runid, database, username, command, status, return_message, start_time, end_time"

  def test_against_a_real_pg_cron_restart_rows_a_crowded_job_first_sight_and_a_rename
    skip "set CRONWATCH_TEST_PGCRON to the URL of a Postgres with pg_cron (in cron.database_name) to run" unless PGCRON

    conn = pg_connect
    tag = "cwrbrow#{Process.pid}"
    names = { busy: "#{tag}-busy", quiet: "#{tag}-quiet", hist: "#{tag}-hist" }
    insert = lambda do |jobid, status, times, message|
      conn.exec_params("INSERT INTO cron.job_run_details (#{DETAIL_COLUMNS}) SELECT $1, nextval('cron.runid_seq'), 'postgres', " \
                       "'postgres', 'select 1', $2, $3, #{times} RETURNING runid", [jobid, status, message]).first
    end
    begin
      conn.exec("CREATE EXTENSION IF NOT EXISTS pg_cron")
      ids = {}
      names.each_value do |name|
        ids[name] = conn.exec_params("SELECT cron.schedule($1, '0 3 * * *', 'SELECT 1') AS id", [name]).first["id"].to_i
        # Paused, so pg_cron itself adds no rows while the test writes its own.
        conn.exec_params("SELECT cron.alter_job($1, active := false)", [ids[name]])
      end
      # First sight of a job whose newest rows include a run cut off by a restart, and older failures.
      conn.exec_params("INSERT INTO cron.job_run_details (#{DETAIL_COLUMNS}) SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', " \
                       "'select 1', 'failed', 'ERROR: old', now() - interval '3 days', now() - interval '3 days' FROM generate_series(1, 5)",
                       [ids[names[:hist]]])
      insert.call(ids[names[:hist]], "failed", "NULL, NULL", "server restarted")
      conn.exec_params("INSERT INTO cron.job_run_details (#{DETAIL_COLUMNS}) SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', " \
                       "'select 1', 'succeeded', '1 row', now() - make_interval(mins => 30 - g), now() - make_interval(mins => 30 - g) " \
                       "FROM generate_series(1, 19) g", [ids[names[:hist]]])

      capture = Capture.new
      errors = []
      cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [capture], cron_secret: nil,
                         on_error: ->(e, _where) { errors << e.message },
                         sources: [PgCron.new(conn, jobs: ->(j) { j.jobname.to_s.start_with?(tag) }, timezone: "UTC")])
      cw.check
      assert_equal 20, cw.runs(names[:hist], 500).length, "twenty newest copied"
      assert_equal [], capture.alerts.map(&:job), "history is never judged"
      cw.check
      assert_equal 20, cw.runs(names[:hist], 500).length, "and never read again"

      # A restart cuts off a busy job's queued run; the busy job then runs past a page; then the quiet job fails.
      cut = insert.call(ids[names[:busy]], "failed", "NULL, NULL", "server restarted")
      conn.exec_params("INSERT INTO cron.job_run_details (#{DETAIL_COLUMNS}) SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', " \
                       "'select 1', 'succeeded', '1 row', now() - make_interval(secs => 600 - g), now() - make_interval(secs => 600 - g) " \
                       "FROM generate_series(1, 520) g", [ids[names[:busy]]])
      disk = insert.call(ids[names[:quiet]], "failed", "now(), now()", "ERROR: disk full")
      3.times { cw.check }
      assert_equal "server restarted", cw.get_run("pgcron:#{cut["runid"]}")&.error
      assert_equal :failed, cw.get_run("pgcron:#{disk["runid"]}")&.status, "the quiet job's failure is read"
      assert(capture.alerts.any? { |a| a.type == :failed && a.job == names[:quiet] })

      # Renamed in pg_cron: the old name keeps its runs and loses its schedule.
      conn.exec_params("UPDATE cron.job SET jobname = $1 WHERE jobid = $2", ["#{names[:quiet]}-v2", ids[names[:quiet]]])
      conn.exec_params("SELECT cron.alter_job($1, active := true)", [ids[names[:quiet]]])
      cw.check
      jobs = cw.jobs
      old = jobs.find { |j| j.name == names[:quiet] }
      assert_nil old.definition.schedule
      assert_match(/renamed to/, old.definition.description)
      assert_equal "0 3 * * *", jobs.find { |j| j.name == "#{names[:quiet]}-v2" }.definition.schedule
      assert_equal [], errors.grep_v(/cron\.|row level/)
    ensure
      begin
        conn&.exec_params("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1", ["#{tag}%"])
      rescue StandardError
        nil
      end
      conn&.close
    end
  end

  def test_against_a_real_pg_cron_a_role_that_may_not_read_cron_settings_never_aborts_the_callers_transaction
    skip "set CRONWATCH_TEST_PGCRON to the URL of a Postgres with pg_cron (in cron.database_name) to run" unless PGCRON

    admin = pg_connect
    role = "cwrbrole#{Process.pid}"
    client = nil
    begin
      admin.exec("CREATE EXTENSION IF NOT EXISTS pg_cron")
      admin.exec("CREATE ROLE #{role} LOGIN PASSWORD 'pw'")
      admin.exec("GRANT USAGE ON SCHEMA cron TO #{role}")
      admin.exec("GRANT SELECT ON cron.job, cron.job_run_details TO #{role}")
      url = URI(PGCRON)
      url.user = role
      url.password = "pw"
      client = PG.connect(url.to_s)
      client.set_notice_receiver { |_result| nil }
      client.exec_params("SELECT cron.schedule($1, '0 3 * * *', 'SELECT 1')", ["#{role}-job"])
      errors = []
      cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [], cron_secret: nil,
                         on_error: ->(e, _where) { errors << e.message }, sources: [PgCron.new(client)])
      client.exec("BEGIN")
      result = cw.check
      assert_equal "1", client.exec("SELECT 1 AS one").first["one"], "the transaction is still usable"
      client.exec("ROLLBACK")
      job = result.jobs.find { |j| j.name == "#{role}-job" }
      assert_equal "UTC", job.definition.timezone, "assumed"
      assert_equal "0 3 * * *", job.definition.schedule, "cron.log_run unreadable is taken as on"
      assert(errors.any? { |e| e.include?("could not read cron.timezone") }, errors.inspect)
    ensure
      client&.close
      # Every job of the role goes before the role: pg_cron's scheduler stops on a job whose role is gone.
      ["SELECT cron.unschedule(jobid) FROM cron.job WHERE username = '#{role}'", "DROP OWNED BY #{role}", "DROP ROLE IF EXISTS #{role}"].each do |sql|
        admin.exec(sql)
      rescue StandardError
        nil
      end
      admin&.close
    end
  end
end
