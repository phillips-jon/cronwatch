defmodule Cronwatch.ConcurrencyTest do
  @moduledoc "The SDK's concurrency.test.ts, ported: several instances (as several processes) on one store."
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Cronwatch.Test.More

  alias Cronwatch.JS.Object
  alias Cronwatch.Store
  alias Cronwatch.Test.Barrier
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Repo
  alias Cronwatch.Test.Stores
  alias Cronwatch.Test.Wrap
  alias Cronwatch.Test.WrapNoCas

  # Two instances, as two processes sharing one store, each failing the job
  # once at the same time.
  defp race(store_a, store_b, barrier \\ nil) do
    clock = Clock.new()
    one = make(store: store_a, clock_ref: clock)
    two = make(store: store_b, clock_ref: clock)
    opts = [failures_before_alert: 2]
    Cronwatch.run("shared", fn _ -> nil end, [instance: one.cw] ++ opts)
    if barrier, do: Barrier.on(barrier)

    tasks =
      for {i, msg} <- [{one, "one"}, {two, "two"}] do
        Task.async(fn -> catch_error(Cronwatch.run("shared", fn _ -> raise msg end, [instance: i.cw] ++ opts)) end)
      end

    Task.await_many(tasks, 10_000)
    if barrier, do: Barrier.off(barrier)
    %{one: one, two: two, types: Capture.types(one.alerts) ++ Capture.types(two.alerts)}
  end

  defp state_of(%{cw: cw}, job) do
    c = Cronwatch.Config.get(cw)
    state(c.store, job)
  end

  test "two processes failing a job at once: both failures count and the alert goes out once" do
    name = shared_memory()
    r = race(Wrap.spec(inner: Wrap.memory(name), slow_state: 25), Wrap.spec(inner: Wrap.memory(name), slow_state: 25))
    s = state_of(r.one, "shared")
    assert s.consecutive_failures == 2, "neither failure was lost"
    assert Enum.map(s.open, &elem(&1, 0)) == ["failed"], "the condition opened"
    assert r.types == ["failed"], "one alert, from whichever process counted the second failure"
    assert s.version >= 3, "every write bumped the version (#{s.version})"
  end

  test "the same race through two SQLite repos on one file" do
    file = Path.join(Repo.tmp_dir(), "cw.db")
    first = Repo.store(file)
    second = Repo.store(file)
    r = race(Wrap.spec(inner: first, slow_state: 25), Wrap.spec(inner: second, slow_state: 25))
    s = state_of(r.one, "shared")
    assert s.consecutive_failures == 2
    assert r.types == ["failed"]
  end

  test "a custom store without compare_and_set_state still works, but cannot keep two processes apart" do
    name = shared_memory()
    # Both processes read each state before either writes, every time, so
    # the lost update is certain rather than left to timing.
    barrier = Barrier.new()

    r =
      race(
        WrapNoCas.spec(inner: Wrap.memory(name), barrier: barrier),
        WrapNoCas.spec(inner: Wrap.memory(name), barrier: barrier),
        barrier
      )

    # The documented caveat: the later write wins, so one failure is lost.
    s = state_of(r.one, "shared")
    assert s.consecutive_failures == 1
    assert r.types == []
  end

  test "a silence made by one process survives another process's run" do
    name = shared_memory()
    clock = Clock.new()
    runner = make(store: Wrap.spec(inner: Wrap.memory(name), slow_state: 25), clock_ref: clock)
    admin = make(store: Wrap.spec(inner: Wrap.memory(name), slow_state: 25), clock_ref: clock)
    Cronwatch.run("s", fn _ -> nil end, instance: runner.cw)

    a = Task.async(fn -> catch_error(Cronwatch.run("s", fn _ -> raise "x" end, instance: runner.cw)) end)
    b = Task.async(fn -> Cronwatch.silence!("s", "1h", instance: admin.cw) end)
    Task.await_many([a, b], 10_000)

    s = state_of(runner, "s")
    assert s.silenced_until != nil, "the silence was not overwritten"
    assert s.consecutive_failures == 1, "nor was the failure"
  end

  test "an update that keeps losing gives up and reports, and the run still finishes" do
    name = shared_memory()
    %{cw: cw, errors: errors} = make(store: Wrap.spec(inner: Wrap.memory(name), refuse_cas: true))
    assert_raise RuntimeError, "x", fn -> Cronwatch.run("busy", fn _ -> raise "x" end, instance: cw) end
    assert wheres(errors) == ["evaluating busy"]
    assert hd(Cronwatch.runs!("busy", 50, instance: cw)).status == "failed"
  end

  # A store whose first write of a job's definition waits until it is let
  # go, so a test can declare the job again, or ask for another write, while
  # that one is under way. Answers the store and the one under it.
  defp held_upsert do
    inner = Stores.memory()
    {store, hooks} = Stores.hooked(inner)
    test = self()

    Stores.hook(hooks, :upsert_job, fn _args, real ->
      Stores.unhook(hooks, :upsert_job)
      send(test, {:writing, self()})

      receive do
        :release -> real.()
      end
    end)

    {store, inner}
  end

  defp schedule(store, name) do
    {:ok, %{definition: definition}} = Store.call(store, :get_job, [name])
    Object.get(definition, "schedule")
  end

  # The test is sent every message the instance's locks receive, so it can
  # wait until a process has asked for its turn at a declaration's write.
  defp trace_turns(cw) do
    locks = Process.whereis(Cronwatch.Locks.server(cw))
    :erlang.trace(locks, true, [:receive])
    locks
  end

  test "a handle kept from an earlier declaration writes the one that stands, not its own" do
    inner = Stores.memory()
    %{cw: cw} = make(store: Stores.option(inner))
    earlier = Cronwatch.job!("a", instance: cw)
    Cronwatch.job!("a", schedule: "every 5m", instance: cw)
    Cronwatch.run(earlier, fn _ -> nil end)
    assert schedule(inner, "a") == "every 5m"
    Cronwatch.check!(instance: cw)
    assert schedule(inner, "a") == "every 5m"
  end

  test "a handle whose job was forgotten writes its own definition" do
    inner = Stores.memory()
    %{cw: cw} = make(store: Stores.option(inner))
    handle = Cronwatch.job!("a", schedule: "every 5m", instance: cw)
    Cronwatch.forget!("a", instance: cw)
    Cronwatch.run(handle, fn _ -> nil end)
    assert schedule(inner, "a") == "every 5m"
  end

  test "a forget that lands while a job's first write is under way leaves it to be written on its next run" do
    inner = Stores.memory()
    {store, hooks} = Stores.hooked(inner)
    test = self()

    # The write lands, then waits: the forget deletes the row it wrote.
    Stores.hook(hooks, :upsert_job, fn _args, real ->
      Stores.unhook(hooks, :upsert_job)
      result = real.()
      send(test, {:writing, self()})

      receive do
        :release -> result
      end
    end)

    %{cw: cw} = make(store: store)
    handle = Cronwatch.job!("nightly", schedule: "every 5m", instance: cw)
    first = Task.async(fn -> Cronwatch.run(handle, fn _ -> nil end) end)
    assert_receive {:writing, writer}, 5_000
    Cronwatch.forget!("nightly", instance: cw)
    send(writer, :release)
    Task.await(first)
    assert Store.call(inner, :get_job, ["nightly"]) == {:ok, nil}, "forgotten after it was written"
    Cronwatch.run(handle, fn _ -> nil end)
    assert schedule(inner, "nightly") == "every 5m", "its next run brings it back"
    assert Enum.map(Cronwatch.jobs!(instance: cw), & &1.name) == ["nightly"]
  end

  test "a job forgotten by another process comes back in a long-lived one that still declares it" do
    name = shared_memory()
    clock = Clock.new()
    worker = make(store: Wrap.spec(inner: Wrap.memory(name)), clock_ref: clock)
    web = make(store: Wrap.spec(inner: Wrap.memory(name)), clock_ref: clock)
    store = Wrap.memory(name)
    nightly = Cronwatch.job!("nightly", schedule: "every 5m", instance: worker.cw)
    Cronwatch.run(nightly, fn _ -> nil end)

    forgotten = fn ->
      Cronwatch.forget!("nightly", instance: web.cw)
      assert Store.call(store, :get_job, ["nightly"]) == {:ok, nil}
    end

    # Its next run writes it again, so the run is not left without its job.
    forgotten.()
    Cronwatch.run(nightly, fn _ -> nil end)
    assert schedule(store, "nightly") == "every 5m"
    assert length(Cronwatch.runs!("nightly", 50, instance: web.cw)) == 1

    # So does a started run, a check, the board and the job's page in the
    # process that declares it.
    forgotten.()
    {:ok, handle} = Cronwatch.start(nightly)
    assert schedule(store, "nightly") == "every 5m"
    Cronwatch.finish(handle)
    forgotten.()
    Cronwatch.check!(instance: worker.cw)
    assert schedule(store, "nightly") == "every 5m"
    forgotten.()
    assert Enum.map(Cronwatch.jobs!(instance: worker.cw), & &1.name) == ["nightly"]
    forgotten.()
    assert Object.get(Cronwatch.job_summary!("nightly", instance: worker.cw).definition, "schedule") == "every 5m"

    # A process that never declared it does not bring it back.
    forgotten.()
    Cronwatch.check!(instance: web.cw)
    assert Cronwatch.jobs!(instance: web.cw) == []
  end

  test "a declaration made while the earlier one is being written is still to be written" do
    {store, inner} = held_upsert()
    %{cw: cw} = make(store: store)
    run = Task.async(fn -> Cronwatch.run("a", fn _ -> nil end, instance: cw) end)
    assert_receive {:writing, writer}, 5_000
    Cronwatch.job!("a", schedule: "every 5m", instance: cw)
    send(writer, :release)
    Task.await(run)
    Cronwatch.check!(instance: cw)
    assert schedule(inner, "a") == "every 5m"
  end

  test "a declaration's write waits for the earlier one's, so the later one stays" do
    {store, inner} = held_upsert()
    %{cw: cw} = make(store: store)
    locks = trace_turns(cw)
    run = Task.async(fn -> Cronwatch.run("a", fn _ -> nil end, instance: cw) end)
    assert_receive {:writing, writer}, 5_000
    Cronwatch.job!("a", schedule: "every 5m", instance: cw)
    %{pid: asking} = later = Task.async(fn -> Cronwatch.job_summary!("a", instance: cw) end)
    # Were the later write not to wait its turn, it would land here, under the earlier one.
    assert_receive {:trace, ^locks, :receive, {:"$gen_call", {^asking, _}, {:acquire, {:sync, "a"}}}}, 5_000
    send(writer, :release)
    Task.await(run)
    assert Object.get(Task.await(later).definition, "schedule") == "every 5m"
    assert schedule(inner, "a") == "every 5m"
  end

  test "sync_job takes its turn behind a write under way, and writes the declaration that stands" do
    {store, inner} = held_upsert()
    %{cw: cw} = make(store: store)
    locks = trace_turns(cw)
    run = Task.async(fn -> Cronwatch.run("a", fn _ -> nil end, instance: cw) end)
    assert_receive {:writing, writer}, 5_000
    Cronwatch.job!("a", schedule: "every 5m", instance: cw)
    %{pid: asking} = later = Task.async(fn -> Cronwatch.sync_job("a", instance: cw) end)
    assert_receive {:trace, ^locks, :receive, {:"$gen_call", {^asking, _}, {:acquire, {:sync, "a"}}}}, 5_000
    send(writer, :release)
    Task.await(run)
    assert Task.await(later) == {:ok, true}
    assert schedule(inner, "a") == "every 5m"
    Cronwatch.check!(instance: cw)
    assert schedule(inner, "a") == "every 5m"
  end
end
