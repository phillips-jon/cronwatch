# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../memory_store_test" # StoreConformance
require "cronwatch/active_record"
require "securerandom"
require "tmpdir"
require "fileutils"
require "stringio"

ActiveRecord::Base.logger = nil

# Databases for the ActiveRecord store tests: SQLite in memory and on disk
# always, Postgres when CRONWATCH_TEST_PG names one. Each gets its own
# abstract class, so all three live side by side in one process.
module ARSupport
  PG_URL = ENV.fetch("CRONWATCH_TEST_PG", nil).then { |url| url.nil? || url.empty? ? nil : url }
  NO_PG = "set CRONWATCH_TEST_PG to a Postgres URL to run the Postgres store tests"
  warn "[cronwatch] #{NO_PG}; skipping them" if PG_URL.nil?
  TMP = Dir.mktmpdir("cronwatch-ar-")
  Minitest.after_run { FileUtils.rm_rf(TMP) }

  CONFIGS = {
    sqlite_memory: { adapter: "sqlite3", database: ":memory:", pool: 1 },
    sqlite_file: { adapter: "sqlite3", database: File.join(TMP, "store.sqlite3"), pool: 5, timeout: 5000 },
    postgres: PG_URL,
  }.freeze

  @classes = {}

  def self.connection_class(key)
    @classes[key] ||= begin
      klass = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      Object.const_set("CronwatchTest#{key.to_s.split("_").map(&:capitalize).join}Record", klass)
      klass.establish_connection(CONFIGS.fetch(key))
      klass
    end
  end

  def self.prefix
    "t#{SecureRandom.hex(4)}_"
  end

  # The shared StoreConformance module is the SDK's store test as the gem
  # first ported it. The SDK has since made prune keep each job's newest run,
  # which the SQL stores (and so this one) do; until the memory store and the
  # module catch up, SqlStoreConformance below is the current contract.
  def self.shared_conformance_current?
    memory = Cronwatch::Stores::Memory.new
    memory.insert_run(Cronwatch::Run.new(id: "x", job: "a", status: :ok, started_at: 1, finished_at: 2, duration_ms: 1,
                                         error: nil, output: nil, metrics: {}, trigger: "run"))
    memory.prune(10).zero?
  end
end

# packages/sdk/test/stores.test.ts as it stands, line for line.
module SqlStoreConformance
  def sql_run(id, job, status, started_at)
    Cronwatch::Run.new(id: id, job: job, status: status, started_at: started_at,
                       finished_at: status == :running ? nil : started_at + 10, duration_ms: status == :running ? nil : 10,
                       error: nil, output: nil, metrics: { "n" => 1 }, trigger: "run")
  end

  def test_sql_store_conformance
    check_sql_store(make_store)
  end

  def check_sql_store(store)
    store.init
    d = ->(h) { Cronwatch::JobDefinition.from_h(h) }
    assert_nil store.get_job("a")
    store.upsert_job(d.call("name" => "a", "schedule" => "every 5m"), 100)
    store.upsert_job(d.call("name" => "a", "schedule" => "every 10m", "tags" => ["x"]), 200)
    store.upsert_job(d.call("name" => "b"), 300)
    store.upsert_job(d.call("name" => "B"), 300)
    store.upsert_job(d.call("name" => "_c"), 300)
    a = store.get_job("a")
    assert_equal 100, a.created_at, "createdAt survives upsert"
    assert_equal 200, a.updated_at
    assert_equal({ "name" => "a", "schedule" => "every 10m", "tags" => ["x"] }, a.definition.to_h)
    assert_equal %w[B _c a b], store.list_jobs.map(&:name), "code unit order, not locale"

    store.insert_run(sql_run("r1", "a", :ok, 1000))
    store.insert_run(sql_run("r2", "a", :failed, 2000))
    store.insert_run(sql_run("r3", "a", :running, 3000))
    store.insert_run(sql_run("r4", "b", :ok, 1500))
    store.insert_run(sql_run("rb", "B", :running, 2000))
    store.insert_run(sql_run("rc", "_c", :running, 2000))
    assert_equal %w[r3 r2 r1], store.list_runs("a", 10).map(&:id)
    assert_equal %w[r3 r2], store.list_runs("a", 2).map(&:id)
    assert_equal "r3", store.last_run("a").id
    assert_nil store.last_run("none")
    assert_equal %w[rb rc r3], store.running_runs.map(&:id), "oldest first, then insertion order"
    r1 = store.get_run("r1")
    assert_equal({ "n" => 1 }, r1.metrics)
    assert_equal 10, r1.duration_ms

    store.update_run(sql_run("r3", "a", :ok, 3000).tap do |r|
      r.output = "line1\nline2"
      r.metrics = { "cost" => 0.25 }
    end)
    r3 = store.get_run("r3")
    assert_equal :ok, r3.status
    assert_equal "line1\nline2", r3.output
    assert_equal({ "cost" => 0.25 }, r3.metrics)
    assert_equal %w[rb rc], store.running_runs.map(&:id)

    # Forgetting a job while one of its runs is in flight: the run finishing later changes nothing.
    store.delete_job("B")
    store.update_run(sql_run("rb", "B", :ok, 2000).tap { |r| r.output = "late" })
    assert_nil store.get_run("rb")
    assert_equal [], store.list_runs("B", 10)
    assert_equal %w[rc], store.running_runs.map(&:id)
    store.delete_job("_c")

    state = ->(h) { Cronwatch::JobState.from_h(h) }
    assert_nil store.get_state("a")
    store.set_state(state.call("job" => "a", "open" => { "failed" => 5 }, "consecutiveFailures" => 2, "silencedUntil" => nil, "lastAlertAt" => 6))
    store.set_state(state.call("job" => "a", "open" => {}, "consecutiveFailures" => 0, "silencedUntil" => 99, "lastAlertAt" => 6))
    assert_equal({ "job" => "a", "open" => {}, "consecutiveFailures" => 0, "silencedUntil" => 99, "lastAlertAt" => 6 },
                 store.get_state("a").to_h)
    undelivered = { "type" => "failed", "run" => nil, "details" => { "consecutiveFailures" => 1 }, "job" => "a",
                    "definition" => { "name" => "a" }, "title" => "a failed", "message" => "boom", "at" => 7 }
    full = { "job" => "a", "open" => { "stuck" => 7 }, "consecutiveFailures" => 1, "silencedUntil" => nil, "lastAlertAt" => 6,
             "pendingRecovery" => ["missed"], "undelivered" => [undelivered] }
    store.set_state(state.call(full))
    assert_equal Cronwatch::JS.json(full), store.get_state("a").to_json, "pendingRecovery and undelivered round-trip"
    store.set_state(state.call("job" => "a", "open" => {}, "consecutiveFailures" => 0, "silencedUntil" => 99, "lastAlertAt" => 6))

    store.insert_run(sql_run("r5", "a", :running, 500))
    assert_equal 2, store.prune(2500), "r1 and r2 pruned; running r5 kept, and b's r4 kept as b's newest run"
    assert_equal %w[r3 r5], store.list_runs("a", 10).map(&:id)
    assert_equal %w[r4], store.list_runs("b", 10).map(&:id)
    assert_equal 0, store.prune(1_000_000), "however old, each job keeps its newest run, and running runs stay"

    store.delete_job("a")
    assert_nil store.get_job("a")
    assert_equal [], store.list_runs("a", 10)
    assert_nil store.get_state("a")
    assert_equal "b", store.get_job("b").name
    store.close
  end
end

# A database to test against. The including class defines `database`
# (:sqlite_memory, :sqlite_file or :postgres); tables made through make_store
# are dropped after each test.
module ActiveRecordStoreHarness
  include TestHelpers

  def setup
    skip ARSupport::NO_PG if database == :postgres && ARSupport::PG_URL.nil?
    @prefixes = []
  end

  def teardown
    (@prefixes || []).each do |prefix|
      connection_class.connection_pool.with_connection do |conn|
        Cronwatch::Stores::ActiveRecord.drop_tables!(conn, prefix: prefix)
      end
    end
  end

  def connection_class
    ARSupport.connection_class(database)
  end

  def with_conn(&block)
    connection_class.connection_pool.with_connection(&block)
  end

  # A store on fresh tables of its own.
  def make_store(prefix: ARSupport.prefix, create: true)
    @prefixes << prefix
    with_conn { |conn| Cronwatch::Stores::ActiveRecord.create_tables!(conn, prefix: prefix) } if create
    Cronwatch::Stores::ActiveRecord.new(prefix: prefix, connection_class: connection_class)
  end

  def postgres?
    database == :postgres
  end
end

# Everything run against each database.
module ActiveRecordStoreTests
  def self.included(base)
    base.include ActiveRecordStoreHarness
    base.include StoreConformance
    unless ARSupport.shared_conformance_current?
      base.define_method(:test_store_conformance) do
        skip "StoreConformance (memory_store_test.rb) still expects prune to drop each job's newest run; " \
             "test_sql_store_conformance runs the SDK's current store test instead"
      end
    end
    base.include SqlStoreConformance
  end

  # A state row as another process wrote it: its JSON text, as it is.
  def write_raw_state(store, text)
    with_conn { |conn| conn.execute("INSERT INTO #{store.prefix}state (job, state) VALUES ('v', #{conn.quote(text)})") }
  end

  # Rows another process wrote: a running run that started at the lowest
  # BIGINT, and a state whose version is 1.5. The check writes the run with
  # its duration held at 2**53 - 1, writes over the state, and sends the
  # stuck alert, whose text writes a start before the year 1 in words.
  def test_a_check_over_a_run_that_started_at_the_lowest_bigint_and_a_state_whose_version_is_1_5
    store = make_store
    p = store.prefix
    sent = []
    cw = Cronwatch.new(store: store, alerts: [Cronwatch::Alerts::Custom.new("capture") { |alert| sent << alert }],
                       cron_secret: nil, on_error: ->(e, _where) { raise e })
    store.upsert_job({ "name" => "far", "timeout" => "5m" }, 1)
    with_conn do |conn|
      conn.execute("INSERT INTO #{p}runs (id, job, status, started_at, metrics, trigger) " \
                   "VALUES ('far1', 'far', 'running', -9223372036854775808, '{}', 'run')")
      conn.execute("INSERT INTO #{p}state (job, state) VALUES ('far', '{\"job\":\"far\",\"open\":{},\"consecutiveFailures\":0," \
                   "\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":1.5}')")
    end
    2.times { cw.check }
    run = store.get_run("far1")
    assert_equal :timeout, run.status
    assert_equal 9_007_199_254_740_991, run.duration_ms, "the duration is held at 2**53 - 1"
    state = store.get_state("far")
    assert_equal 2, state.version, "the state's 1.5 counted as 0, then the timeout and the alert each wrote it"
    assert_equal 1, state.consecutive_failures
    assert_equal [:stuck], sent.map { |a| a.type.to_sym }
    assert_equal "Started before 0001-01-01 00:00:00 UTC and never reported finishing. Marked as timed out after 104249991d 8h.",
                 sent.first.message.split("\n").first
  end

  # A cron job's last run as a foreign or damaged row could hold it: before
  # the year 1 (the first fire of the year 1 was missed) or after 9999 (never
  # due again), and at the BIGINT extremes. Neither a check nor the dashboard
  # reports an error.
  def test_a_check_and_the_dashboard_over_a_cron_job_whose_last_run_started_far_off
    require "cronwatch/web"
    require "rack/mock"
    %w[-62135596800001 253402300800000 -9223372036854775808 9223372036854775807].each do |started_at|
      store = make_store
      p = store.prefix
      errors = []
      sent = []
      cw = Cronwatch.new(store: store, alerts: [Cronwatch::Alerts::Custom.new("capture") { |alert| sent << alert }],
                         cron_secret: nil, on_error: ->(e, where) { errors << "#{where}: #{e.message}" })
      store.upsert_job({ "name" => "far", "schedule" => "0 2 * * *", "timezone" => "UTC", "grace" => "10m" }, 1)
      with_conn do |conn|
        conn.execute("INSERT INTO #{p}runs (id, job, status, started_at, finished_at, duration_ms, metrics, trigger) " \
                     "VALUES ('far1', 'far', 'ok', #{started_at}, #{started_at}, 0, '{}', 'run')")
      end
      cw.check
      web = Rack::MockRequest.new(Cronwatch::Web.new(cw, token: "tok", base_path: "/cronwatch"))
      ["/cronwatch/", "/cronwatch/jobs/far", "/cronwatch/api/jobs/far"].each do |path|
        assert_equal 200, web.get(path, "HTTP_AUTHORIZATION" => "Bearer tok").status, "#{started_at} #{path}"
      end
      assert_equal [], errors, started_at
      assert_equal(started_at.start_with?("-") ? [:missed] : [], sent.map { |a| a.type.to_sym }, started_at)
      assert_match(/\ADue 0001-01-01 02:00:00 UTC /, sent.first.message) unless sent.empty?
    end
  end

  def test_names_sort_in_byte_order_as_the_sdk_sql_stores_do
    store = make_store
    ["\u{FF5E}", "\u{1F600}", "z", "Z", "é"].each { |name| store.upsert_job({ "name" => name }, 1) }
    assert_equal ["Z", "z", "é", "\u{FF5E}", "\u{1F600}"], store.list_jobs.map(&:name)
  end

  def test_create_tables_is_idempotent_and_matches_the_sdk_layout
    prefix = ARSupport.prefix
    @prefixes << prefix
    with_conn do |conn|
      2.times { Cronwatch::Stores::ActiveRecord.create_tables!(conn, prefix: prefix) }
      assert_equal %w[created_at definition name updated_at], conn.columns("#{prefix}jobs").map(&:name).sort
      runs = %w[duration_ms error finished_at id job metrics output started_at status trigger]
      runs << "seq" if postgres?
      assert_equal runs.sort, conn.columns("#{prefix}runs").map(&:name).sort
      assert_equal %w[job state], conn.columns("#{prefix}state").map(&:name).sort
      assert_equal %W[#{prefix}runs_job_started #{prefix}runs_running], conn.indexes("#{prefix}runs").map(&:name).sort
      json_type = postgres? ? "jsonb" : "TEXT"
      assert_equal json_type, conn.columns("#{prefix}jobs").find { |c| c.name == "definition" }.sql_type
      assert_equal postgres? ? "bigint" : "INTEGER", conn.columns("#{prefix}runs").find { |c| c.name == "started_at" }.sql_type
    end
  end

  def test_a_prefix_keeps_two_stores_apart_in_one_database
    one = make_store
    two = make_store
    one.upsert_job({ "name" => "a" }, 1)
    assert_nil two.get_job("a")
    assert_equal ["a"], one.list_jobs.map(&:name)
  end

  def test_init_names_the_missing_tables
    store = make_store(create: false)
    error = assert_raises(Cronwatch::Stores::ActiveRecord::MissingTables) { store.init }
    assert_match(/missing tables #{store.prefix}jobs, #{store.prefix}runs, #{store.prefix}state/, error.message)
    assert_match(/cronwatch:install/, error.message)
  end

  def test_stored_json_is_the_sdks
    store = make_store
    definition = Cronwatch::JobDefinition.from_h("grace" => "15m", "name" => "a", "budget" => { "cost" => 2 }, "x" => "\u{1F600}")
    store.upsert_job(definition, 1)
    store.insert_run(sql_run("r1", "a", :ok, 1).tap { |r| r.metrics = { "ratio" => 0.1 + 0.2, "huge" => 1e21, "n" => 3 } })
    cast = postgres? ? "::text" : ""
    row = with_conn { |c| c.select_one("SELECT definition#{cast} AS definition, metrics#{cast} AS metrics FROM #{store.prefix}jobs, #{store.prefix}runs") }
    if postgres?
      # JSONB keeps its own key order and spacing, for Node's writes as for these.
      assert_equal '{"x": "😀", "name": "a", "grace": "15m", "budget": {"cost": 2}}', row["definition"]
      assert_equal '{"n": 3, "huge": 1000000000000000000000, "ratio": 0.30000000000000004}', row["metrics"]
    else
      assert_equal '{"grace":"15m","name":"a","budget":{"cost":2},"x":"😀"}', row["definition"]
      assert_equal '{"ratio":0.30000000000000004,"huge":1e+21,"n":3}', row["metrics"]
    end
    metrics = store.get_run("r1").metrics
    assert_equal({ "ratio" => 0.30000000000000004, "huge" => 1e21, "n" => 3 }, metrics)
    assert_kind_of Float, metrics["huge"], "read as JavaScript reads it"
    assert_kind_of Integer, metrics["n"]
  end

  # Most apps load db/schema.rb rather than run migrations in test and CI:
  # the tables it recreates must behave the same.
  def test_tables_loaded_from_a_dumped_schema_rb_behave_the_same
    store = make_store
    io = StringIO.new
    ignored = ActiveRecord::SchemaDumper.ignore_tables
    begin
      ActiveRecord::SchemaDumper.ignore_tables = [/\A(?!#{store.prefix})/]
      ActiveRecord::SchemaDumper.dump(connection_class.connection_pool, io, connection_class)
    ensure
      ActiveRecord::SchemaDumper.ignore_tables = ignored
    end
    body = io.string[/\.define\(version: [^)]*\) do\n(.*)^end/m, 1]
    %w[jobs runs state].each { |t| assert_includes body, %(create_table "#{store.prefix}#{t}") }
    assert_includes body, %(where: "(status = 'running'::text)") if postgres?
    with_conn do |conn|
      Cronwatch::Stores::ActiveRecord.drop_tables!(conn, prefix: store.prefix)
      conn.instance_eval(body)
    end
    check_sql_store(store)
    store.insert_run(sql_run("same-1", "c", :running, 5))
    store.insert_run(sql_run("same-2", "c", :running, 5))
    assert_equal %w[same-2 same-1], store.list_runs("c", 10).map(&:id), "insertion order still breaks ties"
  end

  def test_reads_see_writes_under_the_query_cache
    store = make_store
    with_conn do |conn|
      conn.cache do
        store.insert_run(sql_run("r1", "a", :running, 1))
        assert_equal :running, store.get_run("r1").status
        store.update_run(sql_run("r1", "a", :ok, 1))
        assert_equal :ok, store.get_run("r1").status
        assert_equal [], store.running_runs
      end
    end
  end

  def test_a_store_error_does_not_abort_the_apps_transaction
    good = make_store
    broken = make_store(create: false)
    with_conn do |conn|
      conn.transaction do
        good.upsert_job({ "name" => "kept" }, 1)
        assert_raises(ActiveRecord::StatementInvalid) { broken.get_job("x") }
        # On Postgres this would fail with "current transaction is aborted" without the savepoint.
        assert_equal "kept", good.get_job("kept").name
      end
    end
    assert_equal "kept", good.get_job("kept").name
  end

  def test_many_threads_share_the_pool
    store = make_store
    threads = Array.new(4) do |t|
      Thread.new do
        10.times do |i|
          store.insert_run(sql_run("t#{t}-#{i}", "a", :running, i))
          store.update_run(sql_run("t#{t}-#{i}", "a", :ok, i))
          store.list_runs("a", 5)
        end
      end
    end
    threads.each(&:join)
    assert_equal 40, store.list_runs("a", 100).length
    assert_equal [], store.running_runs
  end

  # A second store on the same tables, as another process would open.
  def same_tables(store)
    Cronwatch::Stores::ActiveRecord.new(prefix: store.prefix, connection_class: connection_class)
  end

  def test_two_stores_racing_on_one_jobs_state
    one = make_store
    two = same_tables(one)
    state = ->(version, n) { Cronwatch::JobState.from_h("job" => "r", "open" => {}, "consecutiveFailures" => n, "silencedUntil" => nil, "lastAlertAt" => nil, "version" => version) }
    race = lambda do |expected, version|
      [[one, 1], [two, 2]].map { |store, n| Thread.new { store.compare_and_set_state(state.call(version, n), expected) } }.map(&:value)
    end
    assert_equal [false, true], race.call(0, 1).sort_by { |w| w ? 1 : 0 }, "exactly one insert wins"
    assert_equal [false, true], race.call(1, 2).sort_by { |w| w ? 1 : 0 }, "exactly one update wins"
    assert_equal 2, one.get_state("r").version
  end

  # A store whose state reads take a while, as over a network, so two
  # clients reading at about the same time both get the old state.
  class SlowStateReads
    def initialize(store)
      @store = store
    end

    def respond_to_missing?(name, include_private = false) = @store.respond_to?(name, include_private)

    def method_missing(name, *args, &block)
      return super unless @store.respond_to?(name)

      result = @store.public_send(name, *args, &block)
      sleep 0.025 if name == :get_state
      result
    end
  end

  def test_two_clients_failing_a_job_at_once_lose_no_failure_and_alert_once
    store = make_store
    clock = TestHelpers::Clock.new
    a = TestHelpers::Capture.new
    b = TestHelpers::Capture.new
    one = Cronwatch.new(store: SlowStateReads.new(store), now: clock.to_proc, alerts: [a], cron_secret: nil)
    two = Cronwatch.new(store: SlowStateReads.new(same_tables(store)), now: clock.to_proc, alerts: [b], cron_secret: nil)
    one.run("shared", failures_before_alert: 2) { nil }
    [[one, "one"], [two, "two"]].map do |client, message|
      Thread.new do
        client.run("shared", failures_before_alert: 2) { raise message }
      rescue RuntimeError
        nil
      end
    end.each(&:join)
    state = store.get_state("shared")
    assert_equal 2, state.consecutive_failures, "neither failure was lost"
    assert_equal [:failed], state.open.keys
    assert_equal [:failed], a.types + b.types, "one alert, from whichever client counted the second failure"
    assert_operator state.version, :>=, 3
  end

  def test_output_and_errors_with_nul_characters_are_still_recorded
    store = make_store
    cw = Cronwatch.new(store: store, alerts: [], cron_secret: nil, on_error: ->(e, _where) { raise e })
    error = assert_raises(RuntimeError) do
      cw.run("nul") do |job|
        job.log("before\0after")
        raise "bad\0byte"
      end
    end
    assert_match(/bad/, error.message)
    run = cw.runs("nul").first
    assert_equal :failed, run.status
    assert_equal "beforeafter", run.output
    assert_match(/\ARuntimeError: badbyte/, run.error)
    assert_equal 1, store.get_state("nul").consecutive_failures, "the state, with its alert, was written too"
    # So are a trigger, metric names and a definition's text.
    nul2 = cw.job("nul2", description: "a\0b", tags: ["t\0"], budget: { "c\0" => 5 })
    nul2.run(trigger: "cr\0on") { |job| job.metric("ro\0ws", 2) }
    second = cw.runs("nul2").first
    assert_equal [:ok, "cron", { "rows" => 2 }], [second.status, second.trigger, second.metrics]
    definition = store.get_job("nul2").definition
    assert_equal ["ab", ["t"], { "c" => 5 }], [definition.description, definition.tags, definition.budget.transform_keys(&:to_s)]
  end

  def test_a_client_on_the_store_records_runs_and_alerts
    store = make_store
    client, clock, capture = make(store: store)
    nightly = client.job("nightly", schedule: "every 1h", grace: "5m", budget: { cost: 1 })
    nightly.run do |job|
      job.log("hello")
      job.metric(:cost, 0.5)
    end
    assert_raises(RuntimeError) { nightly.run { raise "boom" } }
    runs = client.runs("nightly")
    assert_equal %i[failed ok], runs.map(&:status)
    assert_equal "hello", runs[1].output
    assert_equal({ "cost" => 0.5 }, runs[1].metrics)
    assert_match(/\ARuntimeError: boom\n/, runs[0].error)
    clock.advance(2 * TestHelpers::HOUR)
    client.check
    assert_equal %i[failed missed], capture.types
    assert_equal %i[failed missed], store.get_state("nightly").open.keys.sort
  end
end
