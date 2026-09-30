# frozen_string_literal: true

require_relative "../support/active_record_helper"
require_relative "../web/helpers"

class ActiveRecordStoreSqliteMemoryTest < Minitest::Test
  include ActiveRecordStoreTests

  def database = :sqlite_memory
end

class ActiveRecordStoreSqliteFileTest < Minitest::Test
  include ActiveRecordStoreTests

  def database = :sqlite_file
end

class ActiveRecordStorePostgresTest < Minitest::Test
  include ActiveRecordStoreTests

  def database = :postgres
end

class ActiveRecordStoreOptionsTest < Minitest::Test
  def test_a_prefix_that_is_not_a_plain_lowercase_identifier_is_refused
    ["1cw_", "cw-", "Cw_", "cw_;drop", "", "x" * 48, nil, :cw_].each do |prefix|
      error = assert_raises(ArgumentError, prefix.inspect) { Cronwatch::Stores::ActiveRecord.new(prefix: prefix) }
      assert_match(/invalid table prefix/, error.message)
    end
    assert_equal "_cw2_", Cronwatch::Stores::ActiveRecord.new(prefix: "_cw2_").prefix
    assert_equal "cronwatch_", Cronwatch::Stores::ActiveRecord.new.prefix
  end

  def test_the_message_matches_the_sdk
    error = assert_raises(ArgumentError) { Cronwatch::Stores::ActiveRecord.new(prefix: "Cw_") }
    assert_equal 'cronwatch: invalid table prefix "Cw_". Use lowercase letters, digits and underscores, ' \
                 "not starting with a digit, at most 47 characters.", error.message
  end

  def test_a_connection_class_can_be_named
    klass = ARSupport.connection_class(:sqlite_memory)
    store = Cronwatch::Stores::ActiveRecord.new(prefix: "named_", connection_class: klass.name)
    klass.connection_pool.with_connection { |c| Cronwatch::Stores::ActiveRecord.create_tables!(c, prefix: "named_") }
    store.upsert_job({ "name" => "a" }, 1)
    assert_equal "a", store.get_job("a").name
  ensure
    klass.connection_pool.with_connection { |c| Cronwatch::Stores::ActiveRecord.drop_tables!(c, prefix: "named_") }
  end

  def test_an_adapter_other_than_postgres_or_sqlite_is_refused_by_name
    mysql = Struct.new(:adapter_name).new("Mysql2")
    %w[Mysql2 Trilogy SQLServer].each do |adapter|
      error = assert_raises(Cronwatch::Stores::ActiveRecord::UnsupportedAdapter) { Cronwatch::Stores::ActiveRecord.dialect(adapter) }
      assert_match(/supports PostgreSQL and SQLite, not #{adapter}/, error.message)
    end
    assert_raises(Cronwatch::Stores::ActiveRecord::UnsupportedAdapter) { Cronwatch::Stores::ActiveRecord.create_tables!(mysql) }
    assert_equal :postgres, Cronwatch::Stores::ActiveRecord.dialect("PostGIS")
    assert_equal :sqlite, Cronwatch::Stores::ActiveRecord.dialect("SQLite")
  end
end

# Rows a foreign or hand-edited writer left: one bad row is that job's
# problem, never every job's.
class ActiveRecordStoreForeignRowsTest < Minitest::Test
  include ActiveRecordStoreHarness
  include WebHelpers

  def database = :sqlite_file

  def test_a_job_whose_stored_definition_is_not_an_object_is_reported_and_the_others_carry_on
    prefix = ARSupport.prefix
    store = make_store(prefix: prefix)
    errors = []
    cw, clock, = make(store: store, on_error: ->(e, where) { errors << [where, e.message] })
    cw.job("good", schedule: "every 1h").run { nil }
    with_conn do |conn|
      conn.execute("INSERT INTO #{prefix}jobs VALUES ('null-def', 'null', 0, 0)")
      conn.execute("INSERT INTO #{prefix}jobs VALUES ('text-def', '\"x\"', 0, 0)")
      conn.execute("INSERT INTO #{prefix}jobs VALUES ('deep-def', '#{"[" * 200}#{"]" * 200}', 0, 0)")
    end
    clock.advance(2 * HOUR)
    result = cw.check
    by_name = result.jobs.to_h { |j| [j.name, j.health] }
    assert_equal({ "deep-def" => :failing, "good" => :late, "null-def" => :failing, "text-def" => :failing }, by_name)
    assert_equal ["checking deep-def", "checking null-def", "checking text-def"], errors.map(&:first).sort
    assert_equal 4, cw.jobs.length
    web = Cronwatch::Web.new(cw, token: "tok", base_path: "/cronwatch")
    assert_equal 200, send_request(web, "GET", "/cronwatch/api/jobs", BEARER).status
    assert_equal 200, send_request(web, "GET", "/cronwatch/", BEARER).status
  end

  def test_a_run_whose_metrics_are_not_an_object_or_hold_no_number_still_shows_on_its_job_page
    prefix = ARSupport.prefix
    store = make_store(prefix: prefix)
    cw, = make(store: store)
    cw.job("good").run { nil }
    with_conn do |conn|
      conn.execute("INSERT INTO #{prefix}runs (id, job, status, started_at, metrics) VALUES ('r1', 'good', 'ok', 1, '\"x\"')")
      conn.execute("INSERT INTO #{prefix}runs (id, job, status, started_at, metrics) VALUES ('r2', 'good', 'ok', 2, '[1]')")
      conn.execute("INSERT INTO #{prefix}runs (id, job, status, started_at, metrics) " \
                   "VALUES ('r3', 'good', 'ok', 3, '{\"rows\":null,\"label\":\"abc\",\"cost\":1.25,\"n\":3}')")
    end
    assert_equal({}, store.get_run("r1").metrics)
    assert_equal({}, store.get_run("r2").metrics)
    web = Cronwatch::Web.new(cw, token: "tok", base_path: "/cronwatch")
    page = send_request(web, "GET", "/cronwatch/jobs/good", BEARER)
    assert_equal 200, page.status
    assert_includes page.body, %(<span class="metrics"><span><span class="k">cost</span> 1.2500</span><span><span class="k">n</span> 3</span></span>)
    refute_includes page.body, %(<span class="k">rows</span>)
    refute_includes page.body, %(<span class="k">label</span>)
  end
end

# The store writes on connections of its own, never inside a transaction the
# app has open: a job run inside one is recorded even when it rolls back, and
# a check running beside it cannot deadlock with it.
class ActiveRecordStoreOwnConnectionTest < Minitest::Test
  include ActiveRecordStoreHarness

  def database = :postgres

  def test_a_run_inside_a_transaction_that_rolls_back_is_still_recorded_and_alerts_once
    store = make_store
    client, _clock, capture = make(store: store)
    once = client.job("once", failures_before_alert: 1)
    3.times do
      connection_class.transaction { once.run { raise "boom" } }
    rescue RuntimeError
      nil
    end
    assert_equal 3, store.list_runs("once", 10).length
    assert_equal [:failed], capture.types, "open once, even though every run's transaction rolled back"
    assert_equal 3, store.get_state("once").consecutive_failures
  end

  def test_the_app_transaction_does_not_see_or_hold_the_stores_writes
    store = make_store
    connection_class.transaction do
      store.upsert_job({ "name" => "outside" }, 1)
      raise ActiveRecord::Rollback
    end
    assert_equal "outside", store.get_job("outside").name
  end

  def test_a_check_beside_a_job_inside_a_transaction_does_not_deadlock
    store = make_store
    failing = true
    channel = Cronwatch::Alerts::Custom.new("flaky") { |_alert| raise "down" if failing }
    clock = TestHelpers::Clock.new(Time.utc(2026, 1, 1, 12).to_i * 1000)
    client = Cronwatch.new(store: store, alerts: [channel], now: clock.to_proc, on_error: ->(*) {}, cron_secret: nil)
    job = client.job("j", schedule: "0 * * * *", grace: "5m")
    client.check
    clock.advance(70 * TestHelpers::MIN)
    client.check # missed, and the alert is left undelivered for the next check
    failing = false
    worker = Thread.new do
      connection_class.transaction do
        job.run do
          checker = Thread.new { client.check }
          sleep 0.5
          checker.join(5)
          "ok"
        end
      end
    end
    assert worker.join(10), "the job and the check finish"
    assert_equal :ok, store.list_runs("j", 1).first.status
  end
end

# Rails' automatic role switching runs reads (a GET) inside
# connected_to(role: :reading, prevent_writes: true). The store still writes,
# on the writing database.
module ActiveRecordStoreRoleTests
  def replica_class
    config = ARSupport::CONFIGS.fetch(database)
    config = config.is_a?(String) ? { url: config } : config
    name = "CronwatchTest#{database.to_s.split("_").map(&:capitalize).join}ReplicaRecord"
    return Object.const_get(name) if Object.const_defined?(name)

    klass = Class.new(ActiveRecord::Base) { self.abstract_class = true }
    Object.const_set(name, klass)
    klass.connects_to(database: { writing: config, reading: config.merge(replica: true) })
    klass
  end

  def test_the_store_writes_on_the_writing_role_inside_a_reading_block
    prefix = ARSupport.prefix
    @prefixes << prefix
    with_conn { |conn| Cronwatch::Stores::ActiveRecord.create_tables!(conn, prefix: prefix) }
    store = Cronwatch::Stores::ActiveRecord.new(prefix: prefix, connection_class: replica_class)
    client, clock, capture = make(store: store)
    client.job("r", schedule: "0 * * * *")
    client.check
    clock.advance(2 * TestHelpers::HOUR)
    ActiveRecord::Base.connected_to(role: :reading, prevent_writes: true) do
      assert_equal [:missed], client.check.alerts.map(&:type)
      assert_equal ["r"], client.jobs_with_runs.map { |entry| entry.job.name }
      client.job("declared-in-a-get", schedule: "0 * * * *")
      assert_includes client.jobs.map(&:name), "declared-in-a-get"
    end
    assert_equal [:missed], capture.types
  end
end

class ActiveRecordStoreSqliteFileRoleTest < Minitest::Test
  include ActiveRecordStoreHarness
  include ActiveRecordStoreRoleTests

  def database = :sqlite_file
end

class ActiveRecordStorePostgresRoleTest < Minitest::Test
  include ActiveRecordStoreHarness
  include ActiveRecordStoreRoleTests

  def database = :postgres
end
