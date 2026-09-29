defmodule Cronwatch.Store.MemoryTest do
  use Cronwatch.StoreCase,
    async: true,
    store: {Cronwatch.Store.Memory, []},
    fixture: File.read!(Path.join(Cronwatch.Test.Conformance.dir(), "store.json"))

  alias Cronwatch.Store.Memory

  test "a store started on its own can be shared by name" do
    name = :"cronwatch_shared_#{System.unique_integer([:positive])}"
    start_supervised!({Memory, name: name})
    {:ok, a} = Memory.new([server: name], :one)
    {:ok, b} = Memory.new([server: name], :two)
    run = Cronwatch.StoreCase.new_run("r", "j", "running", 1)
    :ok = Memory.insert_run(a, run)
    assert {:ok, ^run} = Memory.get_run(b, "r")
  end
end
