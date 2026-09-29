defmodule Cronwatch.SerializeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Cronwatch.Test.Conformance

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.JSRE
  alias Cronwatch.Output
  alias Cronwatch.Serialize

  # An expect rule from a fixture: a string, a JavaScript RegExp as
  # {regex: {source, flags}}, or a function as {callable: true}, which the
  # script makes as `(o) => o.length > 3`.
  defp js_rule(s) when is_binary(s), do: {:contains, s}

  defp js_rule(%Object{} = o) do
    case Object.get(o, "regex") do
      %Object{} = re -> {:matches, JSRE.compile!(Object.get(re, "source"), Object.get(re, "flags"))}
      nil -> {:fun, fn out -> JS.len16(out) > 3 end}
    end
  end

  test "conformance: format.json's capOutput, toStored and checkExpectation" do
    f = fixture("format")
    caps = list(f, "capOutput")
    stored = list(f, "toStored")
    checks = list(f, "checkExpectation")
    assert caps != [] and stored != [] and checks != []

    fails =
      Enum.reduce(caps, failures(), fn c, fails ->
        text = field(c, "prefix") <> String.duplicate(field(c, "piece"), field(c, "times"))
        out = Output.cap(text)

        got =
          Object.new([{"length", JS.len16(out)}, {"sha256", Base.encode16(:crypto.hash(:sha256, out), case: :lower)}])

        want = Object.new([{"length", field(c, "length")}, {"sha256", field(c, "sha256")}])
        same(fails, "capOutput(#{inspect(field(c, "piece"))} x #{field(c, "times")})", got, want)
      end)

    fails =
      Enum.reduce(stored, fails, fn c, fails ->
        input = field(c, "definition")

        rule =
          case Object.fetch(input, "expect") do
            {:ok, v} -> js_rule(v)
            :error -> nil
          end

        same(fails, "toStored", Serialize.to_stored(input, rule), field(c, "stored"))
      end)

    Enum.reduce(checks, fails, fn c, fails ->
      got = Serialize.check_expectation(js_rule(field(c, "expect")), field(c, "output"))
      same(fails, "checkExpectation(#{JS.stringify(field(c, "expect"))})", got, field(c, "result"))
    end)
    |> check!("format")
  end

  test "rules check and describe as the SDK's do" do
    contains = {:contains, ~S{done "ok"}}
    assert Serialize.describe(contains) == ~S{contains "done \"ok\""}
    assert Serialize.check(contains, ~S{done "ok" now}) == nil
    assert Serialize.check(contains, "nope") == ~S{Output did not contain "done \"ok\""}

    fun = {:fun, &(byte_size(&1) > 3)}
    assert Serialize.describe(fun) == "custom function"
    assert Serialize.check(fun, "ab") == "Output did not pass the expect() check"
    assert Serialize.check({:fun, fn _ -> raise "bad check" end}, "x") == "Output check threw: bad check"
    assert Serialize.check({:fun, fn _ -> throw(:no) end}, "x") == "Output check threw: :no"
    assert Serialize.check({:fun, fn _ -> exit("gone") end}, "x") == "Output check threw: gone"
    assert Serialize.check_expectation(nil, nil) == nil
    assert Serialize.check_expectation(contains, nil) == ~S{Output did not contain "done \"ok\""}

    {:ok, matches} = Serialize.rule({:matches, ~S"done in \d+s", "i"})
    assert Serialize.describe(matches) == ~S"matches /done in \d+s/i"
    assert Serialize.check(matches, "DONE in 12s") == nil
    assert Serialize.check(matches, "done") == ~S"Output did not match /done in \d+s/i"
    # A stored pattern that runs out of its budget fails.
    {:ok, slow} = Serialize.rule({:matches, ".*x", ""})
    assert Serialize.check(slow, String.duplicate("a", 32_000)) == "Output did not match /.*x/"

    assert Serialize.rule("x") == {:ok, {:contains, "x"}}
    assert {:ok, {:fun, _}} = Serialize.rule(fn _ -> true end)
    assert {:error, message} = Serialize.rule(~r/done/)
    assert message =~ ~S|{:matches, "done", "flags"}|
    assert {:error, message} = Serialize.rule({:matches, "(", ""})
    assert message =~ "missing ')'"
    assert {:error, _} = Serialize.rule(42)

    fields = Object.new([{"expect", "x"}, {"name", "a"}, {"grace", "5m"}])

    assert JS.stringify(Serialize.to_stored(fields, {:contains, "x"})) ==
             ~S|{"name":"a","grace":"5m","expect":"contains \"x\""}|

    assert JS.stringify(Serialize.to_stored(fields, nil)) == ~S|{"name":"a","grace":"5m"}|
  end

  # A stored pattern is an app's own text, run over a job's output: it is
  # refused, answers, or gives up within its budget, and never raises.
  property "a stored pattern runs as a test and as a replacement within its budget" do
    atoms =
      ["a", "b", "x", "\n", ".", ~S"\d", ~S"\s", ~S"\w", ~S"\b", "^", "$", "*", "+", "?", "{2}", "{1,3}"] ++
        ["(", ")", "(?:", "(?=", "(?!", "(?<=", "[", "]", "[^", "-", "|", "\\", "😀", "é"]

    check all(
            pieces <- list_of(member_of(atoms), max_length: 12),
            text <- string(:printable, max_length: 200),
            flags <- member_of(["", "g", "i", "gi"]),
            max_runs: 300
          ) do
      source = Enum.join(pieces)

      case JSRE.compile(source, flags) do
        {:error, "jsre: " <> _} ->
          :ok

        {:ok, re} ->
          assert JSRE.try_match?(re, text) in [{:ok, true}, {:ok, false}, :gave_up]

          case JSRE.try_replace_units(re, JS.units(text), fn _ -> JS.units("-") end) do
            {:ok, units} -> assert is_binary(JS.from_units(units))
            :gave_up -> :ok
          end
      end
    end
  end

  property "redaction never raises and leaves text as UTF-8" do
    check all(text <- string(:printable, max_length: 300), max_runs: 200) do
      assert String.valid?(Output.redact_secrets(text))
    end
  end
end
