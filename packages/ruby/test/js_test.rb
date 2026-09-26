# frozen_string_literal: true

require_relative "test_helper"

# The JavaScript behaviours the gem reproduces. Each expectation is what
# Node prints for the same input.
class JSTest < Minitest::Test
  def test_numbers_print_as_javascript_prints_them
    {
      0 => "0", -0.0 => "0", 1.0 => "1", 1.5 => "1.5", 0.1 + 0.2 => "0.30000000000000004", 1e21 => "1e+21",
      1.5e-7 => "1.5e-7", 0.000001 => "0.000001", 123_456_789_012_345_680_000.0 => "123456789012345680000",
      100.0 => "100", 2.5e-5 => "0.000025", 1.7976931348623157e308 => "1.7976931348623157e+308", -42.25 => "-42.25",
      Float::NAN => "NaN", Float::INFINITY => "Infinity", 10**25 => "1e+25", (2**53) + 1 => "9007199254740992",
    }.each do |value, text|
      assert_equal text, Cronwatch::JS.number(value), value.inspect
    end
  end

  def test_json_matches_json_stringify
    value = { "b" => 1.0, "a" => [nil, true, "q\"\\\n\u0001\u007f\u2028/"], "10" => 1, "2" => 2, x: :y, "n" => Float::NAN }
    assert_equal '{"2":2,"10":1,"b":1,"a":[null,true,"q\"\\\\\\n\\u0001' + "\u007f\u2028" + '/"],"x":"y","n":null}', Cronwatch::JS.json(value)
  end

  def test_integers_past_2_to_the_53_are_written_as_node_holds_them
    value = { "big" => (2**53) + 1, "huge" => 10**21, "neg" => -(2**60), "safe" => (2**53) - 1 }
    # node -e 'console.log(JSON.stringify({big: 2**53 + 1, huge: 1e21, neg: -(2**60), safe: 2**53 - 1}))'
    assert_equal '{"big":9007199254740992,"huge":1e+21,"neg":-1152921504606847000,"safe":9007199254740991}',
                 Cronwatch::JS.json(value)
  end

  def test_round_is_math_round
    { 0.5 => 1, -0.5 => 0, 1.5 => 2, -1.5 => -1, 2.4999 => 2, 0.49999999999999994 => 0, 7 => 7 }.each do |value, rounded|
      assert_equal rounded, Cronwatch::JS.round(value), value.inspect
    end
  end

  def test_trim_uses_javascripts_whitespace
    assert_equal "a b", Cronwatch::JS.trim("\u00a0\u2003\ufeff\t a b \n\u3000")
    assert_equal "\u0085a", Cronwatch::JS.trim("\u0085a"), "NEL is not whitespace in JavaScript"
  end

  def test_lengths_are_utf16_code_units
    assert_equal 3, Cronwatch::JS.length16("a\u{1F600}")
    assert_equal "a", Cronwatch::JS.head16("a\u{1F600}", 2), "a half character is left out"
    assert_equal "\u{1F600}b", Cronwatch::JS.tail16("a\u{1F600}b", 3)
    assert_equal "b", Cronwatch::JS.tail16("a\u{1F600}b", 2)
  end
end
