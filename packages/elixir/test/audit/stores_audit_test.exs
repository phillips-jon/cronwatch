defmodule Cronwatch.Audit.StoresTest do
  # The stores pass of the audit: JSON, the pattern engine and the stores.
  use ExUnit.Case, async: true

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.JSRE
  alias Cronwatch.Metrics

  describe "JSON" do
    test "an object of many keys reads in time linear in its keys, in JavaScript's order" do
      n = 100_000
      text = "{" <> Enum.map_join(1..n, ",", &~s("k#{&1}":#{&1})) <> "}"
      {micros, {:ok, %Object{} = o}} = :timer.tc(fn -> JS.parse(text) end)
      # Setting one key at a time walked every key before it: 40,000 keys
      # took twelve seconds, 100,000 some eighty.
      assert micros < 5_000_000
      assert Object.size(o) == n
      assert Object.get(o, "k77") == 77
      assert hd(Object.keys(o)) == "k1"

      # Array indices first in ascending order, then the rest as first set; a
      # key given twice keeps its first place and its last value.
      order = JS.parse!(~s({"b":1,"2":2,"a":3,"1":4,"b":5,"4294967294":6,"4294967295":7}))
      assert JS.stringify(order) == ~s({"1":4,"2":2,"4294967294":6,"b":5,"a":3,"4294967295":7})

      dups =
        "{" <> Enum.map_join(1..n, ",", fn i -> if rem(i, 2) == 0, do: ~s("a":#{i}), else: ~s("k#{i}":0) end) <> "}"

      {micros, {:ok, o}} = :timer.tc(fn -> JS.parse(dups) end)
      assert micros < 5_000_000
      assert Object.get(o, "a") == n
      assert Enum.at(Object.keys(o), 1) == "a"

      # Object.new/1 is built the same way.
      assert Object.new([{"b", 1}, {"3", 2}, {"b", 3}, {:a, 4}]) |> JS.stringify() == ~s({"3":2,"b":3,"a":4})
      assert Metrics.lenient(JS.parse!(text)) |> Object.size() == n
    end

    test "an integer past the doubles is written as null, as JSON writes Infinity" do
      assert JS.stringify(10 ** 400) == "null"
      assert JS.stringify(-(10 ** 400)) == "null"
      assert JS.stringify([10 ** 400, 2 ** 60]) == "[null,1152921504606847000]"
      assert JS.stringify(Object.new([{"m", 10 ** 309}])) == ~s({"m":null})
      # String(n) is still JavaScript's Infinity.
      assert JS.format_number(10 ** 400) == "Infinity"
    end
  end

  describe "the pattern engine" do
    test "a long pattern is held in little memory, whoever reads it" do
      # Each character's set was a bitmap of 2048 words, so a pattern of 4096
      # characters came to some 17 million words (130 MB), copied again
      # whenever a job's definition was read from the instance's table.
      for {source, flags} <- [
            {String.duplicate("a", 4096), ""},
            {String.duplicate("é", 4096), "i"},
            {String.duplicate(".", 4096), ""},
            {String.duplicate("[^a]", 1024), ""},
            {String.duplicate(~S"\S", 2048), ""},
            {String.duplicate("[a-z]", 819), "i"}
          ] do
        {micros, re} = :timer.tc(fn -> JSRE.compile!(source, flags) end)

        assert :erts_debug.flat_size(re) < 1_000_000,
               "#{String.slice(source, 0, 8)}: #{:erts_debug.flat_size(re)} words"

        assert micros < 5_000_000
      end

      re = JSRE.compile!(String.duplicate("ab", 2048))
      assert JSRE.match?(re, "x" <> String.duplicate("ab", 2048))
      refute JSRE.match?(re, String.duplicate("ab", 2047))
    end

    test "/i folds every letter JavaScript folds without the u flag" do
      # Each answer is V8's (node -e 'new RegExp(s, "i").test(x)').
      cases = [
        {"é", "É", true},
        {"[à-ÿ]", "À", true},
        {"[^é]", "É", false},
        {"ß", "ẞ", false},
        {"ſ", "s", false},
        {"k", "K", false},
        {"σ", "Σ", true},
        {"ς", "Σ", true},
        {"σ", "ς", true},
        {"µ", "μ", true},
        {~S"\w", "ſ", false},
        {"[a-z]", "K", true},
        {"[^a-z]", "K", true},
        {"ǅ", "ǆ", true},
        {"ǅ", "Ǆ", true},
        {"İ", "i", false},
        {"ı", "I", false},
        {"Ω", "ω", true},
        {"Ω", "ω", false},
        {~S"\W", "é", true},
        {~S"é", "É", true},
        {~S"[À-Þ]+", "àéî", true}
      ]

      for {source, text, want} <- cases do
        assert JSRE.match?(JSRE.compile!(source, "i"), text) == want, "/#{source}/i on #{text}"
      end

      refute JSRE.match?(JSRE.compile!("é"), "É")
    end

    test "a character outside the BMP is its two halves in a class and after an escape" do
      # [a-😀] is the range a to the first half, then the second, and
      # [😀-a] a range out of order, as V8 reads them without the u flag.
      assert JSRE.match?(JSRE.compile!("[a-😀]"), "x")
      assert JSRE.match?(JSRE.compile!("^[a-😀]+$"), "😀")
      assert {:error, message} = JSRE.compile("[😀-a]")
      assert message =~ "range out of order"
      assert {:error, _} = JSRE.compile("[😀-😁]")
      assert JSRE.match?(JSRE.compile!(~S"^\😀$"), "😀")
      assert JSRE.match?(JSRE.compile!("^a😀+b$"), "a😀" <> "\u{1F600}" <> "b") == false
    end
  end
end

defmodule Cronwatch.Audit.StoresPgTest do
  # A store call inside the app's own transaction runs from a task; a raise
  # there took the calling process (a job's own) down through the task's
  # link, where the same raise outside a transaction is a store error.
  use ExUnit.Case, async: true

  alias Cronwatch.Store
  alias Cronwatch.Store.Ecto, as: EctoStore
  alias Cronwatch.Test.PgRepo
  alias Cronwatch.Test.Servers

  @moduletag Servers.skip_unless(:pg)

  test "a raise in a statement inside the app's transaction is the store's error" do
    {EctoStore, h} = store = Servers.store(:pg)
    :ok = EctoStore.init(h)
    too_big = Bitwise.bsl(1, 70)
    assert {:error, %DBConnection.EncodeError{}} = Store.call(store, :prune, [too_big])

    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        PgRepo.put_dynamic_repo(h.dynamic_repo)

        answer =
          PgRepo.transaction(fn ->
            inside = Store.call(store, :prune, [too_big])
            :ok = EctoStore.insert_run(h, Cronwatch.StoreCase.new_run("kept", "j", "running", 1))
            PgRepo.rollback(inside)
          end)

        send(parent, {:answer, answer})
      end)

    assert_receive {:answer, {:error, {:error, %DBConnection.EncodeError{}}}}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:ok, %{id: "kept"}} = EctoStore.get_run(h, "kept")
  end
end
