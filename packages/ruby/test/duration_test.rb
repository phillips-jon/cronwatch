# frozen_string_literal: true

require_relative "test_helper"

# The cap on a duration string's length, which the conformance cases also
# replay: PART is quadratic on a long run of digits.
class DurationTest < Minitest::Test
  TOO_LONG = "is too long for a duration (more than 64 characters)"

  def test_a_string_over_64_characters_is_refused_quoting_its_first_32
    assert_equal 32 * 60_000, Cronwatch::Duration.parse("1m" * 32)
    long = " #{"1m" * 32}"
    error = assert_raises(ArgumentError) { Cronwatch::Duration.parse(long, "grace") }
    assert_equal "grace \"#{long[0, 32]}...\" #{TOO_LONG}", error.message
    # Characters are code points: forty emoji are eighty UTF-16 units but under the cap.
    error = assert_raises(ArgumentError) { Cronwatch::Duration.parse("\u{1F600}" * 40) }
    assert_match(/\Aduration "(\u{1F600}){40}" is not a duration like/, error.message)
    error = assert_raises(ArgumentError) { Cronwatch::Duration.parse("\u{1F600}" * 65) }
    assert_equal "duration \"#{"\u{1F600}" * 32}...\" #{TOO_LONG}", error.message
  end

  def test_a_megabyte_of_digits_is_refused_at_once
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(ArgumentError) { Cronwatch::Duration.parse("1" * (1 << 20), "silence duration") }
    assert_equal "silence duration \"#{"1" * 32}...\" #{TOO_LONG}", error.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  end
end
