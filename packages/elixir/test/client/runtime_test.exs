defmodule Cronwatch.RuntimeTest do
  @moduledoc """
  What the BEAM adds to the SDK's client (DESIGN.md's Processes, Runs,
  Timeouts, Telemetry and Delivery): runs whose process dies, isolated runs,
  the timeout flag, current/0 through $callers, Logger metadata, the
  telemetry events, the shared check, and the locks.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Cronwatch.Test.More

  alias Cronwatch.JS.Object
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Flaky
  alias Cronwatch.Test.Wrap

  defp only_run(cw, job) do
    [run] = Cronwatch.runs!(job, 50, instance: cw)
    run
  end

  defp mailbox, do: Process.info(self(), :messages)

  describe "a process that dies inside the function" do
    test "killed, its run is recorded failed at once with the exit reason" do
      %{cw: cw, alerts: alerts} = make()
      test = self()

      pid =
        spawn(fn ->
          Cronwatch.run(
            "killed",
            fn j ->
              Cronwatch.log(j, "got this far")
              send(test, :running)
              Process.sleep(:infinity)
            end,
            instance: cw
          )
        end)

      assert_receive :running
      Process.exit(pid, :kill)
      eventually(fn -> only_run(cw, "killed").status == "failed" end)
      run = only_run(cw, "killed")
      assert run.error == "exit: :killed"
      assert run.output == "got this far"
      # The alert is delivered after the run is written, so wait for it too.
      eventually(fn -> Capture.types(alerts) == ["failed"] end)
    end

    test "taken down by a linked process's crash, its run fails with that reason" do
      %{cw: cw} = make()
      test = self()

      spawn(fn ->
        Cronwatch.run(
          "linked",
          fn _ ->
            spawn_link(fn ->
              receive do
                :crash -> exit(:database_gone)
              end
            end)
            |> then(&send(test, {:helper, &1}))

            Process.sleep(:infinity)
          end,
          instance: cw
        )
      end)

      assert_receive {:helper, helper}
      send(helper, :crash)
      eventually(fn -> only_run(cw, "linked").status == "failed" end)
      assert only_run(cw, "linked").error == "exit: :database_gone"
    end

    test "a caller killed while its run is being recorded leaves the recording to finish" do
      test = self()
      gate = switch(:closed)
      name = shared_memory()

      hold = fn ->
        if self() != test and get(gate) == :closed do
          send(test, :recording)
          eventually(fn -> get(gate) == :open end, 1_000)
        end
      end

      %{cw: cw} = make(store: Wrap.spec(inner: Wrap.memory(name), before: %{update_run_if: hold}))
      caller = spawn(fn -> Cronwatch.run("rec", fn _ -> "done" end, instance: cw) end)
      assert_receive :recording
      Process.exit(caller, :kill)
      put(gate, :open)
      eventually(fn -> only_run(cw, "rec").status == "ok" end)
      assert only_run(cw, "rec").output == "done"
    end
  end

  describe "isolated runs" do
    test "a crash is a failed run, handed back as an exit" do
      %{cw: cw} = make()

      assert catch_exit(Cronwatch.run("iso", fn _ -> Process.exit(self(), :kill) end, isolate: true, instance: cw)) ==
               :killed

      eventually(fn -> only_run(cw, "iso").status == "failed" end)
      assert only_run(cw, "iso").error == "exit: :killed"
    end

    test "a raise or a returned value comes back as it would without isolation" do
      %{cw: cw} = make()

      assert_raise RuntimeError, "boom", fn ->
        Cronwatch.run("iso2", fn _ -> raise "boom" end, isolate: true, instance: cw)
      end

      assert Cronwatch.run("iso2", fn _ -> {:ok, 3} end, isolate: true, instance: cw) == {:ok, 3}
      assert Enum.map(Cronwatch.runs!("iso2", 50, instance: cw), & &1.status) == ["ok", "failed"]
      assert mailbox() == {:messages, []}
    end

    test "kill_at_timeout stops the function at the job's timeout, recorded as a check would mark it" do
      %{cw: cw, alerts: alerts} = make()
      Cronwatch.job!("hang", timeout: "150ms", instance: cw)

      assert catch_exit(
               Cronwatch.run(
                 "hang",
                 fn j ->
                   Cronwatch.log(j, "started")
                   Process.sleep(:infinity)
                 end,
                 isolate: true,
                 kill_at_timeout: true,
                 instance: cw
               )
             ) == :timeout

      run = only_run(cw, "hang")
      assert run.status == "timeout"
      assert run.error == "Still running after 150ms; marked as timed out"
      assert run.output == "started"
      assert Capture.types(alerts) == ["stuck"]
      assert mailbox() == {:messages, []}
    end
  end

  test "cancelled? turns true at the job's timeout, and the function decides" do
    %{cw: cw} = make()
    Cronwatch.job!("patient", timeout: "100ms", instance: cw)

    result =
      Cronwatch.run(
        "patient",
        fn j ->
          refute Cronwatch.cancelled?(j)
          eventually(fn -> Cronwatch.cancelled?(j) end)
          :stopped_early
        end,
        instance: cw
      )

    assert result == :stopped_early
    assert only_run(cw, "patient").status == "ok", "a function that returns after its timeout is not stuck"
  end

  test "current/0 and log/1 work from tasks the job started" do
    %{cw: cw} = make()
    assert Cronwatch.current() == nil

    Cronwatch.run(
      "fanout",
      fn j ->
        assert Cronwatch.current() == j

        1..3
        |> Task.async_stream(fn i ->
          assert Cronwatch.current().run_id == j.run_id
          Cronwatch.log("item #{i}")
          Cronwatch.metric("item#{i}", i)
        end)
        |> Stream.run()
      end,
      instance: cw
    )

    run = only_run(cw, "fanout")
    assert run.output |> String.split("\n") |> Enum.sort() == ["item 1", "item 2", "item 3"]
    assert Enum.sort(Object.keys(run.metrics)) == ["item1", "item2", "item3"]
    assert Cronwatch.current() == nil, "nothing is left behind"
  end

  test "a run sets Logger metadata and puts the app's back" do
    %{cw: cw} = make()
    Logger.metadata(request_id: "r1")

    meta =
      Cronwatch.run(
        "logged",
        fn j ->
          m = Logger.metadata()
          assert m[:cronwatch_run] == j.run_id
          m
        end,
        instance: cw
      )

    assert meta[:cronwatch_job] == "logged"
    assert meta[:request_id] == "r1"
    assert Logger.metadata() == [request_id: "r1"]
  end

  describe "telemetry" do
    test "a run is a span with its status" do
      %{cw: cw} = make()
      ref = events(cw, [[:cronwatch, :run, :start], [:cronwatch, :run, :stop], [:cronwatch, :run, :exception]])
      catch_error(Cronwatch.run("t", fn _ -> raise "x" end, instance: cw))
      assert_received {:event, ^ref, [:cronwatch, :run, :start], _, %{job: "t", trigger: "run", run: id}}
      assert_received {:event, ^ref, [:cronwatch, :run, :stop], %{duration: _}, %{status: "failed", run: ^id}}
      Cronwatch.run("t", fn _ -> nil end, instance: cw)
      assert_received {:event, ^ref, [:cronwatch, :run, :stop], _, %{status: "ok"}}
      refute_received {:event, ^ref, [:cronwatch, :run, :exception], _, _}
    end

    test "a check is a span with its counts, alerts and errors are events" do
      failing = channel("broken", fn _ -> {:error, "no network"} end)
      good = Capture.new()
      %{cw: cw} = make(alerts: [failing, Capture.channel(good)], on_error: fn _, _ -> :ok end)

      ref =
        events(cw, [
          [:cronwatch, :check, :stop],
          [:cronwatch, :alert, :sent],
          [:cronwatch, :alert, :failed],
          [:cronwatch, :alert, :queued],
          [:cronwatch, :error]
        ])

      catch_error(Cronwatch.run("t", fn _ -> raise "x" end, instance: cw))
      assert_received {:event, ^ref, [:cronwatch, :alert, :sent], _, %{channel: "capture", type: "failed", job: "t"}}
      assert_received {:event, ^ref, [:cronwatch, :alert, :failed], _, %{channel: "broken", condition: "failed"}}
      assert_received {:event, ^ref, [:cronwatch, :error], _, %{where: "alert channel broken"}}
      refute_received {:event, ^ref, [:cronwatch, :alert, :queued], _, _}
      Cronwatch.check!(instance: cw)
      assert_received {:event, ^ref, [:cronwatch, :check, :stop], _, %{jobs: 1, alerts: 0, pruned: 0}}
    end

    test "an alert no channel took is queued" do
      %{cw: cw} = make(alerts: [channel("down", fn _ -> {:error, "down"} end)])
      ref = events(cw, [[:cronwatch, :alert, :queued]])
      catch_error(Cronwatch.run("q", fn _ -> raise "x" end, instance: cw))
      assert_received {:event, ^ref, [:cronwatch, :alert, :queued], _, %{job: "q", channel: nil}}
    end
  end

  describe "the check" do
    test "concurrent calls share one check" do
      name = shared_memory()
      slow = fn -> Process.sleep(100) end
      %{cw: cw} = make(store: Wrap.spec(inner: Wrap.memory(name), before: %{list_jobs: slow}))
      Cronwatch.job!("a", schedule: "every 1h", instance: cw)
      Cronwatch.check!(instance: cw)
      ref = events(cw, [[:cronwatch, :check, :start]])
      results = 1..5 |> Enum.map(fn _ -> Task.async(fn -> Cronwatch.check(instance: cw) end) end) |> Task.await_many()
      assert Enum.uniq(results) |> length() == 1
      assert [{:ok, _}] = Enum.uniq(results)
      assert_received {:event, ^ref, _, _, _}
      refute_received {:event, ^ref, _, _, _}
    end

    test "a store failure is that check's error, and the next check starts fresh" do
      name = shared_memory()
      {store, broken} = Flaky.new(Wrap.memory(name))
      %{cw: cw} = make(store: store)
      Flaky.break(broken, :list_jobs)
      assert {:error, %Cronwatch.Error{kind: :store}} = Cronwatch.check(instance: cw)
      Flaky.mend(broken)
      assert {:ok, %Cronwatch.CheckResult{}} = Cronwatch.check(instance: cw)
    end

    test "a check whose process dies is answered as an error, and the next starts fresh" do
      name = shared_memory()
      die = switch(true)
      kill = fn -> if get(die), do: Process.exit(self(), :kill) end
      %{cw: cw} = make(store: Wrap.spec(inner: Wrap.memory(name), before: %{list_jobs: kill}))
      assert {:error, %Cronwatch.Error{message: m}} = Cronwatch.check(instance: cw)
      assert m =~ "the check stopped"
      put(die, false)
      assert {:ok, _} = Cronwatch.check(instance: cw)
    end

    test "check_every checks a second after the instance starts" do
      name = :"cw#{System.unique_integer([:positive])}"
      ref = events(name, [[:cronwatch, :check, :stop]])
      start_supervised!({Cronwatch, name: name, alerts: [], check_every: 5_000}, id: name)
      assert_receive {:event, ^ref, _, _, _}, 2_000
    end

    test "nothing is left in the caller's mailbox" do
      %{cw: cw} = make()
      Cronwatch.run("m", fn _ -> nil end, instance: cw)
      catch_error(Cronwatch.run("m", fn _ -> raise "x" end, instance: cw))
      Cronwatch.check!(instance: cw)
      {:ok, h} = Cronwatch.start("m", instance: cw)
      Cronwatch.finish(h)
      assert mailbox() == {:messages, []}
    end
  end

  test "a lock whose holder died is released" do
    %{cw: cw} = make()
    test = self()

    holder =
      spawn(fn ->
        Cronwatch.Locks.with_lock(cw, :k, fn ->
          send(test, :held)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :held
    waiter = Task.async(fn -> Cronwatch.Locks.with_lock(cw, :k, fn -> :got_it end) end)
    assert Task.yield(waiter, 50) == nil, "the holder still has it"
    Process.exit(holder, :kill)
    assert Task.await(waiter) == :got_it
  end

  test "a waiter that died is taken out of the queue" do
    %{cw: cw} = make()
    test = self()
    release = switch(false)

    spawn(fn ->
      Cronwatch.Locks.with_lock(cw, :q, fn ->
        send(test, :held)
        eventually(fn -> get(release) end, 1_000)
      end)
    end)

    assert_receive :held
    dead = spawn(fn -> Cronwatch.Locks.with_lock(cw, :q, fn -> send(test, :dead_got_it) end) end)
    Process.sleep(20)
    Process.exit(dead, :kill)
    put(release, true)
    assert Cronwatch.Locks.with_lock(cw, :q, fn -> :mine end) == :mine
    refute_received :dead_got_it
  end
end
