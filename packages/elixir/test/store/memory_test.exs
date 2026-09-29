defmodule Cronwatch.Store.MemoryTest do
  alias Cronwatch.Store.Memory
  alias Cronwatch.Test.Conformance

  use Cronwatch.StoreCase,
    async: true,
    store: {Memory, []},
    fixture: File.read!(Path.join(Conformance.dir(), "store.json"))

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
