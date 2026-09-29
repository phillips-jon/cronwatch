defmodule Cronwatch.ConcurrencyTest do
  @moduledoc "The SDK's concurrency.test.ts, ported: several instances (as several processes) on one store."
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Cronwatch.Test.More

  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Repo
  alias Cronwatch.Test.Wrap
  alias Cronwatch.Test.WrapNoCas

  # Two instances, as two processes sharing one store, each failing the job
  # once at the same time.
  defp race(store_a, store_b) do
    clock = Clock.new()
    one = make(store: store_a, clock_ref: clock)
    two = make(store: store_b, clock_ref: clock)
    opts = [failures_before_alert: 2]
    Cronwatch.run("shared", fn _ -> nil end, [instance: one.cw] ++ opts)

    tasks =
      for {i, msg} <- [{one, "one"}, {two, "two"}] do
        Task.async(fn -> catch_error(Cronwatch.run("shared", fn _ -> raise msg end, [instance: i.cw] ++ opts)) end)
      end

    Task.await_many(tasks, 10_000)
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

    r =
      race(
        WrapNoCas.spec(inner: Wrap.memory(name), slow_state: 25),
        WrapNoCas.spec(inner: Wrap.memory(name), slow_state: 25)
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
end
