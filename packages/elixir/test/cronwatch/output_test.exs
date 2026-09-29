defmodule Cronwatch.OutputTest do
  # Replays conformance/output.json, written by scripts/conformance.mjs from
  # the TypeScript SDK (the cap, every redaction case, error text and what an
  # expect rule sees), and the SDK's redaction tests that exercise
  # redactSecrets and the cap directly. Fake keys are built from pieces, so no
  # string here looks like a real credential to a scanner.
  use ExUnit.Case, async: true

  import Cronwatch.Test.Conformance

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Output
  alias Cronwatch.Lines

  # The fixture's recipe for long text: a string, or {parts: [[piece, times], ...]} joined.
  defp expand(s) when is_binary(s), do: s

  defp expand(%Object{} = o) do
    o |> Object.get("parts") |> Enum.map_join(fn [piece, times] -> String.duplicate(piece, times) end)
  end

  # The fixture's form of a result: the text when it is 400 code units or
  # fewer, else its length and the SHA-256 of its UTF-8.
  defp digest(nil), do: nil

  defp digest(text) do
    n = JS.len16(text)

    if n <= 400 do
      Object.new([{"text", text}])
    else
      Object.new([{"length", n}, {"sha256", Base.encode16(:crypto.hash(:sha256, text), case: :lower)}])
    end
  end

  test "the output cap" do
    assert field(fixture("output"), "outputCap") == Output.output_cap()
  end

  test "conformance: every redaction case" do
    cases = list(fixture("output"), "redact")
    assert length(cases) == 204

    cases
    |> Enum.with_index()
    |> Enum.reduce(failures(), fn {c, i}, f ->
      input = expand(field(c, "input"))

      same(
        f,
        "redact case #{i} #{inspect(JS.head16(input, 60))}",
        digest(Output.redact_secrets(input)),
        field(c, "result")
      )
    end)
    |> check!("output")
  end

  test "conformance: error messages" do
    cases = list(fixture("output"), "errorMessage")
    assert length(cases) == 16

    cases
    |> Enum.with_index()
    |> Enum.reduce(failures(), fn {c, i}, f ->
      text =
        case Object.fetch(c, "value") do
          {:ok, %Object{} = v} ->
            if Object.has_key?(v, "parts"), do: Output.value_message(expand(v)), else: Output.value_message(v)

          {:ok, v} ->
            Output.value_message(v)

          :error ->
            Output.error_message(field(c, "name"), expand(field(c, "message")), list(c, "frames"))
        end

      same(f, "errorMessage case #{i}", digest(text), field(c, "result"))
    end)
    |> check!("output")
  end

  # A recorder case's lines: plain strings, recipes, and {numbered, count,
  # width} runs of numbered lines padded to a width.
  defp lines(spec) do
    Enum.flat_map(spec, fn
      %Object{} = o ->
        if Object.has_key?(o, "numbered") do
          prefix = Object.get(o, "numbered")
          width = Object.get(o, "width")

          for i <- 0..(Object.get(o, "count") - 1)//1 do
            head = "#{prefix}#{i} "
            head <> String.duplicate("x", max(width - JS.len16(head), 0))
          end
        else
          [expand(o)]
        end

      s ->
        [s]
    end)
  end

  test "conformance: what an expect rule sees" do
    cases = list(fixture("output"), "expectText")
    assert length(cases) == 11

    cases
    |> Enum.reduce(failures(), fn c, f ->
      name = field(c, "name")
      t = lines_table()
      Lines.open(t, :run)
      for line <- c |> list("lines") |> lines(), do: Lines.log(t, :run, line)
      snap = Lines.snapshot(t, :run)
      text = Lines.expect_text(snap)
      f = same(f, "#{name}: expectText", digest(text), field(c, "expectText"))
      f = same(f, "#{name}: output", digest(Lines.output(snap)), field(c, "output"))

      Enum.reduce(list(c, "checks"), f, fn ch, f ->
        needle = field(ch, "expect")
        got = Cronwatch.Serialize.check_expectation({:contains, needle}, text)
        same(f, "#{name}: expect #{needle}", got, field(ch, "result"))
      end)
    end)
    |> check!("output")
  end

  test "redacts what the SDK's tests redact" do
    smile = "😀"

    cases = [
      {"DB_PASSWORD=hunter2 tokens: 1200", "DB_PASSWORD=[redacted] tokens: 1200"},
      {"connect ECONNREFUSED postgres://app:s3cr3t@10.0.0.12:5432/db",
       "connect ECONNREFUSED postgres://app:[redacted]@10.0.0.12:5432/db"},
      {"key AKIA" <> "IOSFODNN7EXAMPLE" <> " and ghp_" <> String.duplicate("a", 36), "key [redacted] and [redacted]"},
      {"Authorization: Bearer abcdefgh12345", "Authorization: Bearer [redacted]"},
      {"max_tokens: 800", "max_tokens: 800"},
      {"SLACK_TOKEN='xoxb-123'", "SLACK_TOKEN='[redacted]'"},
      {~S{PASSWORD = "two words here"}, ~S{PASSWORD = "[redacted]"}},
      {~S'{"client_secret": "abc def", "other": "x"}', ~S'{"client_secret": "[redacted]", "other": "x"}'},
      {~S{password="a" user="b"}, ~S{password="[redacted]" user="b"}},
      {~S{password="unterminated}, "password=[redacted]"},
      {~S{:password=>"hunter2"}, ~S{:password=>"[redacted]"}},
      {"{:api_key => 'abc', user: 1}", "{:api_key => '[redacted]', user: 1}"},
      {"Authorization: Basic dXNlcjpwYXNz", "Authorization: Basic [redacted]"},
      {~S'{"Authorization": "Token abc123", "x": 1}', ~S'{"Authorization": "Token [redacted]", "x": 1}'},
      {"-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nIBAAK==\n-----END RSA PRIVATE KEY-----\nafter", "[redacted]\nafter"},
      {"-----BEGIN PRIVATE KEY-----\nMIIE\nabc", "[redacted]"},
      {"jwt eyJ" <> "hbGciOiJIUzI1NiJ9" <> ".eyJzdWIiOiIxIn0.abc_def-123 done", "jwt [redacted] done"},
      {"https://hooks.slack.com/services/T0/B0/xyz ok", "https://hooks.slack.com/services/[redacted] ok"},
      {"https://discord.com/api/webhooks/123/abc-def", "https://discord.com/api/webhooks/[redacted]"},
      {"key AI" <> "za" <> String.duplicate("Sy", 17) <> "A", "key [redacted]"},
      {"wh" <> "sec_" <> String.duplicate("abcd1234", 3), "[redacted]"},
      {"postgres://user:p@ss@host/db", "postgres://user:[redacted]@host/db"},
      # JavaScript's /i folds ASCII only: these are not secret names there.
      {"\u017Fecret=x", "\u017Fecret=x"},
      {"api_\u212Aey=x", "api_\u212Aey=x"},
      # An emoji is two code units to the bounded run, as in JavaScript.
      {"token=" <> String.duplicate(smile, 3000), "token=[redacted]" <> String.duplicate(smile, 952)},
      {"token=a" <> String.duplicate(smile, 3000), "token=[redacted]\uFFFD" <> String.duplicate(smile, 952)}
    ]

    for {input, want} <- cases do
      assert Output.redact_secrets(input) == want, "redact_secrets(#{inspect(JS.head16(input, 60))})"
    end
  end

  @tag timeout: 300_000
  test "adversarial lines redact in bounded time" do
    shapes =
      [
        "password",
        "token-",
        "secret_",
        "a-",
        "password_x-",
        "-token",
        "tokens-",
        "token\"  ",
        "token  =",
        "password=\"",
        "x=>",
        "=>",
        "authorization: ",
        "authorization: basic ",
        "Authorization-",
        "a://",
        "a://x:",
        "postgres://u:",
        "https://u:@@@",
        "@",
        ":",
        "Bearer ",
        "eyJ",
        "eyJa.",
        "eyJaaaa.aaaa",
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN A B C ",
        "-----BEGIN PRIVATE KEY----------",
        "hooks.slack.com/services/",
        "x.discord.com/api/webhooks/",
        "-",
        " "
      ] ++
        [
          "a://" <> String.duplicate("b", 250) <> ":",
          "a://b:" <> String.duplicate("c", 250),
          "eyJ" <> String.duplicate("a", 4090) <> ".",
          "-----BEGIN PRIVATE KEY-----" <> String.duplicate("a", 100),
          "AI" <> "za",
          "wh" <> "sec_"
        ]

    {worst, slowest} =
      Enum.reduce(shapes, {0, ""}, fn shape, {worst, slowest} ->
        line = binary_part(String.duplicate(shape, div(16_384, byte_size(shape)) + 1), 0, 16_384)
        {micros, _} = :timer.tc(fn -> {Output.redact_secrets(line), Output.redact_secrets(line <> "!")} end)
        if micros > worst, do: {micros, shape}, else: {worst, slowest}
      end)

    assert worst <= 20_000_000, "#{inspect(slowest)} took #{div(worst, 1000)} ms"
  end

  @tag timeout: 300_000
  test "a megabyte redacts in bounded time" do
    pieces = [
      "INFO processed 1200 rows in 3.2s tokens: 1200 max_tokens: 800\n",
      "password=hunter2 user=bob url=postgres://app:pw@db.internal:5432/app\n",
      "Authorization: Bearer abcdefgh12345 and eyJ" <> "hbGciOi" <> ".eyJzdWIi.sig\n",
      "r\u00E9sum\u00E9 🚀 done, " <> String.duplicate("x", 200) <> "\n",
      "-----BEGIN PRIVATE KEY-----\n" <> String.duplicate("QUJD", 100) <> "\n-----END PRIVATE KEY-----\n"
    ]

    block = Enum.join(pieces)
    text = String.duplicate(block, div(1_048_576, byte_size(block)) + 1)
    {micros, out} = :timer.tc(fn -> Output.redact_secrets(text) end)
    refute out =~ "hunter2"
    assert micros <= 60_000_000, "a megabyte took #{div(micros, 1000)} ms"
  end

  test "caps output" do
    assert Output.cap("a\0b") == "ab"
    long = String.duplicate("x", Output.output_cap() + 5)
    assert Output.cap(long) == "[earlier output trimmed]\n" <> String.duplicate("x", Output.output_cap())
    assert Output.describe("ReportError", "no rows", []) == "ReportError: no rows"
    assert Output.value_message(42) == "42"
    assert Output.value_message(nil) == "null"
    assert Output.value_message("a\0b") == "ab"
  end

  defmodule ReportError do
    defexception message: "no rows"
  end

  test "exceptions, throws, exits and returned errors read as a JavaScript stack does" do
    {kind, reason, stack} =
      try do
        raise "boom"
      catch
        kind, reason -> {kind, reason, __STACKTRACE__}
      end

    text = Output.describe_exception(kind, reason, stack)

    assert text =~
             ~r/\ARuntimeError: boom\n    at Cronwatch\.OutputTest\.[^\n]+ \(test\/cronwatch\/output_test\.exs:\d+\)/

    assert length(String.split(text, "\n")) <= 6

    assert Output.describe_exception(:error, %ReportError{}, []) == "Cronwatch.OutputTest.ReportError: no rows"
    assert Output.describe_exception(:error, :badarith, []) == "ArithmeticError: bad argument in arithmetic expression"
    assert Output.describe_exception(:throw, :done, []) == "throw: :done"
    assert Output.describe_exception(:throw, "text", []) == "throw: text"
    assert Output.describe_exception(:exit, :killed, []) == "exit: :killed"
    assert Output.describe_exception(:exit, "gone", []) == "exit: gone"

    assert Output.describe_exception(
             :exit,
             {%RuntimeError{message: "in a task"}, [{Mod, :fun, 2, [file: ~c"a.ex", line: 3]}]},
             []
           ) ==
             "RuntimeError: in a task\n    at Mod.fun/2 (a.ex:3)"

    assert Output.describe_exception(:returned, :timeout, []) == ":timeout"
    assert Output.describe_exception(:returned, "no rows", []) == "no rows"
    assert Output.describe_exception(:returned, %ReportError{message: "x"}, []) == "Cronwatch.OutputTest.ReportError: x"

    frames = for i <- 1..8, do: {:mod, :"f#{i}", [1, 2], [file: ~c"m.erl", line: i]}
    text = Output.describe_exception(:error, %RuntimeError{message: "m"}, frames)
    assert text == "RuntimeError: m\n" <> Enum.map_join(1..5, "\n", &"    at :mod.f#{&1}/2 (m.erl:#{&1})")
  end

  test "the recorder's metrics and lines" do
    assert_raise Cronwatch.Error, ~s(metric "cost" must be a finite number), fn ->
      Cronwatch.check_metric!("cost", Process.get(:no_such_key, :infinity))
    end

    assert_raise Cronwatch.Error, fn -> Cronwatch.check_metric!("cost", "1") end

    t = lines_table()
    Lines.open(t, :run)
    for name <- ["zeta", "200", "10"], do: Lines.metric(t, :run, name, 2.0)
    assert Object.keys(Lines.metrics(t, :run)) == ["10", "200", "zeta"]
    snap = Lines.snapshot(t, :run)
    assert Lines.output(snap) == nil and Lines.expect_text(snap) == nil
    Lines.log(t, :run, "a 1 Error: e")
    Lines.log(t, :run, "second")
    assert Lines.output(Lines.snapshot(t, :run)) == "a 1 Error: e\nsecond"
    assert JS.stringify(Lines.metrics(t, :run)) == ~s({"10":2.0,"200":2.0,"zeta":2.0}) |> String.replace(".0", "")
  end

  test "the recorder keeps the head for expect and drops the window's front" do
    t = lines_table()
    Lines.open(t, :run)
    Lines.log(t, :run, "done early")
    for _ <- 1..100, do: Lines.log(t, :run, String.duplicate("x", 1000))
    snap = Lines.snapshot(t, :run)
    assert snap.dropped
    assert String.starts_with?(Lines.expect_text(snap), "done early\n")
    assert JS.len16(Lines.output(snap)) == 16 * 1024 + JS.len16("[earlier output trimmed]\n")
  end

  defp lines_table, do: :ets.new(:lines, [:ordered_set, :public])
end
