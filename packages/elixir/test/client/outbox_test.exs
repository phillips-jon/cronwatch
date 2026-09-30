defmodule Cronwatch.OutboxTest do
  @moduledoc """
  The SDK's outbox.test.ts, ported: an alert is written with the state that
  opens its condition, so a process that dies before sending it does not
  lose it. Several instances on one store stand for several processes.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Cronwatch.Test.More

  alias Cronwatch.Evaluate
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Wrap

  @t0 Clock.t0()
  @min 60_000

  @calls ~w(upsert_job get_job list_jobs delete_job insert_run update_run update_run_if get_run list_runs
            last_run running_runs get_state set_state compare_and_set_state prune)a

  # A store for a process that is about to die: once the answered function
  # is called, nothing it asks of the store ever completes, as when the
  # process is gone.
  defp mortal(inner) do
    dead = :atomics.new(1, [])
    hang = fn -> if :atomics.get(dead, 1) == 1, do: Process.sleep(:infinity) end
    {Wrap.spec(inner: inner, before: Map.new(@calls, &{&1, hang})), fn -> :atomics.put(dead, 1, 1) end}
  end

  # A channel whose sends wait for :release, telling the test when one starts.
  defp held(test, name \\ "held") do
    channel(name, fn alert ->
      send(test, {:sending, self(), alert})

      receive do
        :release -> :ok
      end
    end)
  end

  # A run that fails in a process of its own, never waited on: the caller of
  # a process that dies is gone too.
  defp fail_away(cw, name) do
    spawn(fn ->
      try do
        Cronwatch.run(name, fn _ -> raise "disk full" end, instance: cw)
      catch
        _, _ -> :ok
      end
    end)
  end

  test "the write that opens a condition holds its alert, so a process that dies before sending it does not lose it" do
    clock = Clock.new()
    name = shared_memory()
    shared = Wrap.memory(name)
    {store, kill} = mortal(shared)
    test = self()

    # The process dies while its triage call is out: no channel was ever called.
    dying =
      make(
        store: store,
        clock_ref: clock,
        triage: fn _ ->
          kill.()
          send(test, :triaging)
          Process.sleep(:infinity)
        end
      )

    fail_away(dying.cw, "nightly")
    assert_receive :triaging, 5_000

    s = state(shared, "nightly")
    assert s.open == [{"failed", @t0}]
    assert Enum.map(s.sending, &{&1.alert.type, &1.alert.at, &1.until}) == [{"failed", @t0, @t0 + 300_000}]
    [%{alert: held_alert}] = s.sending
    assert held_alert.triage == nil and not held_alert.triage_tried, "triage is made at send time, never stored here"
    assert s.undelivered == []

    # Another process's checks leave it alone while its sender's lease runs.
    server = make(store: Wrap.spec(inner: shared), clock_ref: clock, triage: fn _ -> {:ok, "The disk is full."} end)
    Clock.advance(clock, @min)
    Cronwatch.check!(instance: server.cw)
    assert Capture.types(server.alerts) == []

    # Once it has run out, the next check sends it, triaged, once.
    Clock.set(clock, @t0 + Evaluate.send_lease_ms() + 1)
    result = Cronwatch.check!(instance: server.cw)
    assert Enum.map(result.alerts, & &1.type) == ["failed"]

    assert Enum.map(Capture.alerts(server.alerts), &{&1.type, &1.at, &1.triage}) == [
             {"failed", @t0, "The disk is full."}
           ]

    after_send = state(shared, "nightly")
    assert after_send.sending == nil, "the key goes once nothing is being sent"
    assert after_send.undelivered == []
    Cronwatch.check!(instance: server.cw)
    assert_raise RuntimeError, fn -> Cronwatch.run("nightly", fn _ -> raise "again" end, instance: server.cw) end
    assert Capture.types(server.alerts) == ["failed"], "the condition still alerts once"
  end

  test "an alert a channel took just before its process died is sent again after the lease: at least once" do
    clock = Clock.new()
    name = shared_memory()
    shared = Wrap.memory(name)
    {store, kill} = mortal(shared)
    test = self()

    # Accepted, then the process is gone before it records that.
    first =
      channel("first", fn alert ->
        send(test, {:took, alert.type})
        kill.()
        :ok
      end)

    dying = make(store: store, clock_ref: clock, alerts: [first])
    fail_away(dying.cw, "nightly")
    assert_receive {:took, "failed"}, 5_000

    server = make(store: Wrap.spec(inner: shared), clock_ref: clock)
    Clock.set(clock, @t0 + Evaluate.send_lease_ms() + 1)
    Cronwatch.check!(instance: server.cw)
    assert Capture.types(server.alerts) == ["failed"], "sent a second time: the one duplicate a crash can cause"
  end

  test "while an alert is being sent, no check anywhere sends it too" do
    clock = Clock.new()
    name = shared_memory()
    shared = Wrap.memory(name)
    worker = make(store: Wrap.spec(inner: shared), clock_ref: clock, alerts: [held(self())])
    server = make(store: Wrap.spec(inner: shared), clock_ref: clock)

    run =
      Task.async(fn ->
        try do
          Cronwatch.run("nightly", fn _ -> raise "x" end, instance: worker.cw)
        rescue
          _ -> :failed
        end
      end)

    assert_receive {:sending, sender, %{type: "failed"}}, 5_000
    Clock.advance(clock, @min)
    Cronwatch.check!(instance: server.cw)
    # The sending process's own check, too, while the send is held.
    Cronwatch.check!(instance: worker.cw)
    refute_received {:sending, _, _}
    send(sender, :release)
    assert Task.await(run) == :failed

    assert Capture.types(server.alerts) == []
    s = state(shared, "nightly")
    assert s.sending == nil
    assert s.undelivered == []
    assert s.last_alert_at == @t0, "the time the run was judged, as before"

    Clock.set(clock, @t0 + Evaluate.send_lease_ms() + @min)
    Cronwatch.check!(instance: server.cw)
    Cronwatch.check!(instance: worker.cw)
    assert Capture.types(server.alerts) == []
    refute_received {:sending, _, _}
  end

  test "an alert no channel took moves from the outbox to the retry queue, with its triage" do
    down = channel("down", fn _ -> {:error, "down"} end)

    %{cw: cw} =
      k =
      make(
        alerts: [down],
        triage: fn _ -> {:ok, "Look at the disk."} end,
        store: Wrap.spec(inner: Wrap.memory(shared_memory()))
      )

    assert_raise RuntimeError, fn -> Cronwatch.run("nightly", fn _ -> raise "x" end, instance: cw) end
    s = state(Cronwatch.Config.get(k.cw).store, "nightly")
    assert s.sending == nil
    assert Enum.map(s.undelivered, &{&1.type, &1.triage}) == [{"failed", "Look at the disk."}]
  end

  test "a process that queues its alerts for a check elsewhere writes them with the state that opens the condition" do
    writes = counter()
    store = Wrap.spec(inner: Wrap.memory(shared_memory()), before: %{compare_and_set_state: fn -> bump(writes) end})
    %{cw: cw} = make(store: store, deliver: :check)
    assert_raise RuntimeError, fn -> Cronwatch.run("backup", fn _ -> raise "disk full" end, instance: cw) end
    s = state(store_of(cw), "backup")
    assert Enum.map(s.undelivered, & &1.type) == ["failed"]
    assert s.sending == nil
    assert count(writes) == 1, "one write: the failure and its alert together"
  end

  defp store_of(cw), do: Cronwatch.Config.get(cw).store
end
