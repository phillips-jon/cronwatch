# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/client_fixture"

# conformance/client.json over the memory store. The ActiveRecord store
# replays unknownFields in test/active_record/store_test.rb.
class ClientConformanceTest < Minitest::Test
  def test_run_ids
    failures = ClientFixture::FIXTURE["runIds"].filter_map do |c|
      got = ClientFixture.run_id_outcome(c["method"], c["id"])
      expected = ClientFixture.expected_error(c)
      next if got == expected

      "#{c["method"]}(#{c["id"][0, 20].inspect}, #{Cronwatch::JS.length16(c["id"])}): expected #{expected.inspect}, got #{got.inspect}"
    end
    assert_empty failures
  end

  def test_unknown_fields_survive_over_the_memory_store
    steps = 0
    ClientFixture.replay_unknown_fields(Cronwatch::Stores::Memory.new) do |op, expected, got|
      assert_equal expected, got, op
      steps += 1
    end
    assert_equal ClientFixture::FIXTURE["unknownFields"]["steps"].length + 1, steps
  end
end
