# frozen_string_literal: true

require_relative "test_helper"

# record_run and the sources option: runs that happen somewhere the client
# cannot wrap, recorded as the SDK's CronWatch.recordRun records them.
class SourcesTest < Minitest::Test
  include TestHelpers

  def outside(id, status, started_at, finished_at: nil, output: nil, error: nil, job: "db-job")
    Cronwatch::Run.new(id: id, job: job, status: status, started_at: started_at, finished_at: finished_at,
                       duration_ms: finished_at && (finished_at - started_at), error: error, output: output, metrics: {}, trigger: "outside")
  end

  def test_a_job_must_be_declared_first
    client, = make
    error = assert_raises(ArgumentError) { client.record_run(outside("x", :ok, T0, finished_at: T0 + 1)) }
    assert_equal 'record_run: job "db-job" is not declared; call job first', error.message
  end

  def test_runs_are_keyed_by_id_judged_once_and_redacted
    client, clock, capture = make
    client.job("db-job", expect: "done")
    clock.advance(1000)
    assert_equal [], client.record_run(outside("r1", :ok, T0, finished_at: T0 + 500, output: "done password=hunter2"))
    stored = client.get_run("r1")
    assert_equal [:ok, "done password=[redacted]"], [stored.status, stored.output]

    alerts = client.record_run(outside("r2", :ok, T0 + 600, finished_at: T0 + 700, output: "nope\0"))
    assert_equal [:failed], alerts.map(&:type), "expect applies to an outside run"
    assert_equal [:failed, 'Output did not contain "done"', "nope"], [client.get_run("r2").status, client.get_run("r2").error, client.get_run("r2").output]
    assert_equal [], client.record_run(outside("r2", :ok, T0 + 600, finished_at: T0 + 700, output: "done")), "a stored finished run is left alone"
    assert_equal :failed, client.get_run("r2").status
    assert_equal [:failed], capture.types
  end

  def test_a_running_run_is_updated_once_it_finishes
    client, clock, capture = make
    client.job("db-job")
    assert_equal [], client.record_run(outside("r1", :running, T0))
    assert_equal [], client.record_run(outside("r1", :running, T0)), "still running: nothing changes"
    clock.advance(2000)
    alerts = client.record_run({ id: "r1", job: "db-job", status: "failed", started_at: T0, finished_at: T0 + 2000,
                                 duration_ms: 2000, error: "boom", output: nil, metrics: {}, trigger: "outside" })
    assert_equal [:failed], alerts.map(&:type)
    assert_equal [:failed, 2000], [client.get_run("r1").status, client.get_run("r1").duration_ms]
    assert_equal [], client.record_run(outside("r1", :ok, T0, finished_at: T0 + 1)), "a finished run is not reopened"
    assert_equal [:failed], capture.types
  end

  def test_evaluate_false_stores_without_judging
    client, _clock, capture = make
    client.job("db-job")
    assert_equal [], client.record_run(outside("h1", :failed, T0 - 5000, finished_at: T0 - 4000, error: "old"), evaluate: false)
    assert_equal [], client.record_run(outside("h2", :running, T0 - 3000), evaluate: false)
    assert_equal [], client.record_run(outside("h2", :failed, T0 - 3000, finished_at: T0 - 1000, error: "old"), evaluate: false)
    assert_equal %w[h2 h1], client.runs("db-job").map(&:id)
    assert_equal :failed, client.get_run("h2").status
    assert_empty capture.types
    assert_equal 0, client.store.get_state("db-job")&.consecutive_failures.to_i
  end

  def test_a_run_another_process_inserted_first_is_left_alone
    # Between this client's read and its insert, another process inserts the run.
    racing = Class.new(Cronwatch::Stores::Memory) do
      def insert_run(run)
        super
        raise "duplicate key"
      end
    end.new
    client, _clock, capture = make(store: racing)
    client.job("db-job")
    assert_equal [], client.record_run(outside("r1", :failed, T0, finished_at: T0 + 1, error: "x"))
    assert_empty capture.types, "the process that inserted it judges it"

    broken = Class.new(Cronwatch::Stores::Memory) { def insert_run(_run) = raise("store down") }.new
    client, = make(store: broken)
    client.job("db-job")
    assert_raises(RuntimeError) { client.record_run(outside("r1", :failed, T0, finished_at: T0 + 1, error: "x")) }
  end

  # A source that records one outside run each check.
  class OneRun
    attr_reader :name, :hosts

    def initialize
      @name = "one"
      @hosts = []
      @n = 0
    end

    def sync(host)
      @hosts << host
      host.job("db-job", schedule: "every 1m")
      @n += 1
      host.record_run(Cronwatch::Run.new(id: "s#{@n}", job: "db-job", status: :failed, started_at: host.now - 10, finished_at: host.now,
                                         duration_ms: 10, error: "boom", output: nil, metrics: {}, trigger: "outside"))
    end
  end

  def test_sources_sync_first_and_their_alerts_are_returned
    source = OneRun.new
    broken = Struct.new(:name) { def sync(_host) = raise("cannot connect") }.new("broken")
    errors = []
    client, = make(sources: [broken, source], on_error: ->(e, where) { errors << "#{where}: #{e.message}" })
    result = client.check
    assert_same client, source.hosts.first
    assert_equal ["failed db-job"], result.alerts.map { |a| "#{a.type} #{a.job}" }
    assert_equal ["db-job"], result.jobs.map(&:name)
    assert_equal ["source broken: cannot connect"], errors
    assert_raises(ArgumentError) { Cronwatch.new(sources: [Object.new]) }
  end

  def test_configure_takes_sources
    source = OneRun.new
    client = Cronwatch.configure do |c|
      c.sources = [source]
      c.alerts = []
    end
    assert_equal [source], client.sources
  ensure
    Cronwatch.client = nil
  end
end
