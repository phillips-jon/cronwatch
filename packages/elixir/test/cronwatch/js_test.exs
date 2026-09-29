defmodule Cronwatch.JSTest do
  use ExUnit.Case, async: true

  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  test "numbers print as JavaScript prints them" do
    cases = [
      {2, "2"},
      {2.0, "2"},
      {-2.5, "-2.5"},
      {0.1, "0.1"},
      {1.0e-7, "1e-7"},
      {1.5e-7, "1.5e-7"},
      {0.000001, "0.000001"},
      {1.0e21, "1e+21"},
      {1.0e20, "100000000000000000000"},
      {123_456_789_012_345_680_000.0, "123456789012345680000"},
      {123_456_789_012_345_678_901, "123456789012345680000"},
      {9_007_199_254_740_993, "9007199254740992"},
      {:nan, "NaN"},
      {:infinity, "Infinity"},
      {:neg_infinity, "-Infinity"},
      {-0.0, "0"},
      {1.7976931348623157e308, "1.7976931348623157e+308"},
      {5.0e-324, "5e-324"},
      {1234.56785, "1234.56785"},
      {100.0, "100"},
      {123_456.0, "123456"}
    ]

    for {n, want} <- cases, do: assert(JS.format_number(n) == want, "#{inspect(n)}")
  end

  test "keys keep JavaScript's order" do
    o = Object.new([{"b", 1}, {"10", 2}, {"a", 3}, {"2", 4}, {"b", 5}])
    assert JS.stringify(o) == ~s({"2":4,"10":2,"b":5,"a":3})
    {:ok, parsed} = JS.parse(~s({"z":1,"1":2,"z":3,"4294967295":4}))
    assert JS.stringify(parsed) == ~s({"1":2,"z":3,"4294967295":4})
  end

  test "strings escape as JSON.stringify does" do
    assert JS.quote("a\"b\\c\n\u0001<>&\u2028") == "\"a\\\"b\\\\c\\n\\u0001<>&\u2028\""
    assert JS.parse(~s("😀 \\ud83d x é \\u00e9 \\ud83d\\ude00")) == {:ok, "😀 \uFFFD x é é 😀"}
  end

  test "numbers and errors" do
    assert JS.stringify(JS.parse!("[1e400,-0,2.50,2.0,1e-400]")) == "[null,0,2.5,2,0]"
    assert JS.parse!("2.0") === 2
    assert JS.parse!("12345678901234567") === 12_345_678_901_234_568.0
    assert JS.parse("{") == {:error, "Expected property name at position 1"}
    assert JS.parse("1 2") == {:error, "Unexpected non-whitespace character after JSON at position 2"}
    assert {:error, _} = JS.parse("-")
    assert {:error, _} = JS.parse("\"\u0001\"")
    assert {:error, _} = JS.parse("\"\\x\"")
    assert {:error, _} = JS.parse("\"abc")
    assert {:error, _} = JS.parse("")
  end

  test "nesting is held to 256" do
    nested = fn n -> String.duplicate("[", n) <> String.duplicate("]", n) end
    assert {:ok, _} = JS.parse(nested.(256))
    assert JS.parse(nested.(257)) == {:error, "JSON nested too deeply"}
    assert JS.parse(nested.(1_000_000)) == {:error, "JSON nested too deeply"}
  end

  test "lengths and cuts count UTF-16" do
    assert JS.len16("a😀") == 3
    assert JS.slice16("a😀b", 0, 2) == "a\uFFFD"
    assert JS.slice16("a😀b", 2, 4) == "\uFFFDb"
    assert JS.slice16("abc", -2, 3) == "bc"
    assert JS.head16("abc", 10) == "abc"
    assert JS.tail16("abcdef", 2) == "ef"
    assert JS.from_units(<<0xD83D::16>>) == "\uFFFD"
    assert JS.from_units(JS.units("x😀")) == "x😀"
    assert JS.trim("\uFEFF a \u3000") == "a"
    assert JS.trim_end(" a \n") == " a"
    assert JS.scrub(<<"a", 0xFF, "b">>) == "a\uFFFDb"
  end

  test "dates as JavaScript writes them" do
    assert JS.iso_string(0) == "1970-01-01T00:00:00.000Z"
    assert JS.iso_string(1_767_605_400_000) == "2026-01-05T09:30:00.000Z"
    assert JS.iso_string(-1) == "1969-12-31T23:59:59.999Z"
    assert JS.iso_string(253_402_300_800_000) == "+010000-01-01T00:00:00.000Z"
    assert JS.date_utc(2026, 0, 5, 9, 30, 0, 0) == 1_767_605_400_000
    assert JS.date_utc(2025, 12, 5, 9, 30, 0, 0) == 1_767_605_400_000
    assert JS.civil_from_days(JS.days_from_civil(2024, 2, 29)) == {2024, 2, 29}
  end
end
