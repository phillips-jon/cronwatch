# frozen_string_literal: true

require_relative "../support/active_record_helper"
require_relative "../support/resume_across_clients"

# The SDK's "resume in a second client on the same store" test for the SQL
# stores (start-finish.test.ts): a run started by one client and finished by
# another, each with a store on a connection pool of its own, as two
# processes would have.
module StartFinishAcrossPools
  include ActiveRecordStoreHarness
  include ResumeAcrossClients

  # One per database for the whole run.
  SECOND = {} # rubocop:disable Style/MutableConstant

  # A second abstract class on the same database, so the second store opens
  # connections of its own.
  def second_connection_class
    key = "#{database}_second"
    SECOND[key] ||= begin
      klass = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      Object.const_set("CronwatchTest#{key.split("_").map(&:capitalize).join}Record", klass)
      klass.establish_connection(ARSupport::CONFIGS.fetch(database))
      klass
    end
  end

  def test_resume_in_a_second_client_on_the_same_store_appends_and_finishes
    first = make_store
    second = Cronwatch::Stores::ActiveRecord.new(prefix: first.prefix, connection_class: second_connection_class)
    refute_same connection_class.connection_pool, second_connection_class.connection_pool
    check_resume_across_clients(first, second)
  end

  # A run started inside the app's transaction that then rolls back: on
  # SQLite the store joins the transaction, so the start is lost and finish
  # inserts the run; on Postgres the store writes through its own pool, so
  # the start survives. Either way finish records it once.
  def test_a_run_started_in_a_transaction_that_rolls_back_is_recorded_at_finish
    errors = []
    cw = Cronwatch.new(store: make_store, alerts: [], on_error: ->(e, w) { errors << "#{w}: #{e.message}" })
    job = cw.job("sync", timeout: "5m")
    run = nil
    connection_class.transaction do
      run = job.start
      raise ActiveRecord::Rollback
    end
    if postgres?
      assert_equal :running, cw.get_run(run.id).status
    else
      assert_nil cw.get_run(run.id)
    end
    run.log("done")
    finished = run.finish
    assert_equal :ok, finished.status
    stored = cw.get_run(run.id)
    assert_equal :ok, stored.status
    assert_equal "done", stored.output
    assert_equal 1, cw.runs("sync").size
    assert_equal [], errors
  end
end

class StartFinishSqliteTest < Minitest::Test
  include StartFinishAcrossPools

  def database = :sqlite_file
end

class StartFinishPostgresTest < Minitest::Test
  include StartFinishAcrossPools

  def database = :postgres
end
