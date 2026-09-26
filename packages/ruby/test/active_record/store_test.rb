# frozen_string_literal: true

require_relative "../support/active_record_helper"

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
