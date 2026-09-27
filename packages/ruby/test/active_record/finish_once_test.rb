# frozen_string_literal: true

require_relative "../support/active_record_helper"
require_relative "../support/finish_once"

# Several clients, each with a store of its own over one database, as several
# processes would have: a run is still judged once, through update_run_if.
module ActiveRecordFinishOnce
  def self.included(base)
    base.include ActiveRecordStoreHarness
    base.include FinishOnceAcrossProcesses
  end

  # The first call makes fresh tables; each later one another store over them.
  def open_store
    return same_tables(@first) if @first

    @first = make_store
  end

  def same_tables(store)
    Cronwatch::Stores::ActiveRecord.new(prefix: store.prefix, connection_class: connection_class)
  end
end

class ActiveRecordFinishOnceSqliteTest < Minitest::Test
  include ActiveRecordFinishOnce

  def database = :sqlite_file
end

class ActiveRecordFinishOncePostgresTest < Minitest::Test
  include ActiveRecordFinishOnce

  def database = :postgres
end
