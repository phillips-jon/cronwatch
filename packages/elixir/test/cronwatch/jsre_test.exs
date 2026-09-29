defmodule Cronwatch.JSRETest do
  # JavaScript's semantics the redaction patterns rely on, each checked
  # against what V8 answers for the same pattern and input (written beside
  # each case as the JavaScript expression it mirrors).
  use ExUnit.Case, async: true

  alias Cronwatch.JS
  alias Cronwatch.JSRE
  alias Cronwatch.JSRE.Match

  defp replace(source, flags, input, template), do: JSRE.replace(JSRE.compile!(source, flags), input, template)

  test "semantics" do
    cases = [
      # "abcd".replace(/ab|abc/g, "X"): the first alternative that matches wins, not the longest.
      {"ab|abc", "g", "abcd", "X", "Xcd"},
      # "aaab".replace(/a{1,3}ab/, "X"): greedy, then walked back.
      {"a{1,3}ab", "", "aaab", "X", "X"},
      # "xaaa".replace(/a{2}/g, "[$&]")
      {"a{2}", "g", "xaaa", "[$&]", "x[aa]a"},
      # "a1b2".replace(/\d/g, "#"), and only the first without g.
      {~S"\d", "g", "a1b2", "#", "a#b#"},
      {~S"\d", "", "a1b2", "#", "a#b2"},
      # \b is between ASCII word characters and anything else.
      {~S"\bab", "g", "ab xab -ab éab", "X", "X xab -X éX"},
      {~S"\Bab", "g", "ab xab", "X", "ab xX"},
      # Lookbehind: "maxtokens=1 mytoken=2".replace(/\w+(?<!tokens)=\d/g, "X")
      {~S"\w+(?<!tokens)=\d", "g", "maxtokens=1 mytoken=2", "X", "maxtokens=1 X"},
      # Lookahead, negative and positive.
      {"a(?!b)", "g", "ab ac a", "X", "ab Xc X"},
      {"a(?=b)", "g", "ab ac", "X", "Xb ac"},
      # Groups that did not take part are "" in a template.
      {"(a)|(b)", "g", "ab", "[$1|$2]", "[a|][|b]"},
      # Optional groups and quantified groups.
      {"passw(?:or)?d", "g", "passwd password passwod", "X", "X X passwod"},
      {"(?:ab ){0,3}c", "g", "ab ab ab ab c", "X", "ab X"},
      # /i folds ASCII letters only: the long s and the Kelvin sign stay themselves.
      {"secret|key", "gi", "SECRET Key ſecret Key", "X", "X X ſecret Key"},
      {"[a-z]+", "gi", "AbCÉ", "X", "XÉ"},
      # \s is JavaScript's set: no-break space, ideographic space, line separator, BOM.
      {~S"a\sb", "g", "a\u00A0b a\u3000b a\u2028b a\uFEFFb a\u0085b", "X", "X X X X a\u0085b"},
      # A negated class counts an emoji as two code units.
      {~S"x[^\s]{3}", "g", "x😀😀", "X", "X�"},
      {~S"x[^\s]{1,4}", "g", "xab😀😀", "X", "X😀"},
      # Escaped punctuation, and "-" at the edge of a class.
      {~S"a\/b\.c[+/=-]", "g", "a/b.c- a/b.c=", "X", "X X"},
      # An empty match moves on one unit.
      {"x*", "g", "ab", "-", "-a-b-"},
      # "{" that is not a quantifier is a literal (Annex B).
      {"a{b", "g", "a{b", "X", "X"},
      # $$ is a dollar.
      {"a", "g", "a", "$$", "$"},
      # Anchors, a backspace in a class, hex and unicode escapes.
      {"^a|b$", "g", "aab", "X", "XaX"},
      {~S"[\b]", "g", "a\bb", "X", "aXb"},
      {~S"\x41B", "g", "AB", "X", "X"},
      {~S"\x4", "g", "x4", "X", "X"},
      # A loop of passes wider than one unit, and one with a capture.
      {"(?:ab)+c", "g", "ababc", "X", "X"},
      {"(ab)+c", "g", "ababc", "[$1]", "[ab]"},
      {~S"(?<=\$)\d+", "g", "$12 and 34", "X", "$X and 34"}
    ]

    for {source, flags, input, template, want} <- cases do
      assert replace(source, flags, input, template) == want,
             "#{inspect(input)}.replace(/#{source}/#{flags}, #{inspect(template)})"
    end
  end

  test "replace with a function" do
    re = JSRE.compile!(~S{(k)=(?:(")[^"]*"|(')[^']*'|\w+)}, "g")

    got =
      re
      |> JSRE.replace_units(JS.units(~S{k="a b" k='c' k=d}), fn m ->
        q = JS.from_units(Match.group(m, 2) || Match.group(m, 3) || "")
        JS.units("#{Match.text(m, 1)}=#{q}_#{q}")
      end)
      |> JS.from_units()

    assert got == ~S{k="_" k='_' k=_}
  end

  test "long bounded runs stay shallow" do
    re = JSRE.compile!("<(?:[a-z]|-(?!--)){0,16384}>?", "g")
    body = String.duplicate("ab-", 5000)
    assert JSRE.replace(re, "<#{body}>", "X") == "X"
    assert JSRE.replace(re, "<ab---", "X") == "X---"
    # 4096, then the rest, then the empty match at the end.
    assert JSRE.replace(JSRE.compile!("a{0,4096}", "g"), String.duplicate("a", 5000), "X") == "XXX"
  end

  test "compile errors" do
    for source <- [
          "(a",
          "a)",
          "*a",
          "[a",
          "a{3,1}",
          "a+?",
          "(?<!a+)b",
          "[z-a]",
          "(?<n>a)",
          # JavaScript reads these as something other than the letter.
          ~S"(a)\1",
          ~S"\cJ",
          ~S"\k<x>",
          ~S"\p{L}",
          ~S"\u{41}",
          ~S"[\2]"
        ] do
      assert {:error, "jsre: " <> _} = JSRE.compile(source, "g"), "/#{source}/ compiled"
    end

    assert {:error, _} = JSRE.compile("a", "y")
    assert_raise ArgumentError, fn -> JSRE.compile!("(", "") end
  end

  test "matches and writes itself" do
    re = JSRE.compile!("b+", "gi")
    assert JSRE.try_match?(re, "aBc") == {:ok, true}
    assert JSRE.try_match?(re, "ac") == {:ok, false}
    assert JSRE.match?(re, "abbc")
    refute JSRE.match?(re, "ac")
    assert JSRE.source(re) == "/b+/gi"
  end

  test "deep matches give up rather than recurse without end" do
    long = String.duplicate("ab", 16_384) <> "c"
    short = String.duplicate("ab", 100) <> "c"
    re = JSRE.compile!("(?:ab)*c", "")
    counted = JSRE.compile!("(?:xy){100000}", "")
    assert JSRE.try_match?(re, long) == :gave_up
    assert JSRE.try_match?(re, short) == {:ok, true}
    assert JSRE.try_match?(counted, String.duplicate("xy", 100_000)) == :gave_up
    refute JSRE.match?(re, long)
  end

  @tag timeout: 300_000
  test "a match that backtracks without end gives up within its steps" do
    # `\n*\n*\n*\n*\n*x` over newlines is some n^5 / 120 attempts; past the
    # budget the match gives up, while a pattern with work to do over a long
    # output answers in full.
    newlines = String.duplicate("\n", 32_000)

    {micros, answers} =
      :timer.tc(fn ->
        {JSRE.try_match?(JSRE.compile!(~S"\n*\n*\n*\n*\n*x"), newlines),
         JSRE.try_match?(JSRE.compile!(".*x"), String.duplicate("a", 32_000))}
      end)

    assert answers == {:gave_up, :gave_up}
    IO.puts("two budgets of #{Match.max_steps()} steps ran out in #{div(micros, 1000)} ms")
    assert micros < 20_000_000

    assert JSRE.try_match?(JSRE.compile!(~S"\n*\n*\n*\n*\n*x"), String.duplicate("\n", 20)) == {:ok, false}
    assert JSRE.try_match?(JSRE.compile!(~S"\n*\n*\n*\n*\n*x"), newlines <> "x") == {:ok, true}
    assert JSRE.try_match?(JSRE.compile!(".*done"), String.duplicate("a", 32_000) <> "done") == {:ok, true}
    # Redaction has no budget: its patterns are the SDK's own, bounded.
    units = JS.units(String.duplicate("a", 4000))
    assert JSRE.replace_units(JSRE.compile!(".*x", "g"), units, fn _ -> "" end) == units

    assert JSRE.try_replace_units(JSRE.compile!(".*x", "g"), JS.units(String.duplicate("a", 32_000)), fn _ -> "" end) ==
             :gave_up
  end

  test "a character outside the BMP is its two units in turn" do
    assert JSRE.try_match?(JSRE.compile!("a😀b"), "a😀b") == {:ok, true}
    assert JSRE.try_match?(JSRE.compile!("a😀b"), "ab") == {:ok, false}
    assert replace("😀+", "g", "x😀😀y", "-") == "x--y"
    assert replace("😀{2}", "g", "x😀😀y", "-") == "x😀😀y"
  end

  test "patterns too deep or long are refused" do
    nested = String.duplicate("(", 2000) <> "a" <> String.duplicate(")", 2000)
    assert {:error, message} = JSRE.compile(nested)
    assert message =~ "nested too deeply"
    assert {:ok, _} = JSRE.compile(String.duplicate("(", 100) <> "a" <> String.duplicate(")", 100))
    assert {:error, message} = JSRE.compile(String.duplicate("a", 5000))
    assert message =~ "more than 4096 characters"
  end
end
