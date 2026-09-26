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
end
