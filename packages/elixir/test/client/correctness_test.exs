defmodule Cronwatch.CorrectnessTest do
  @moduledoc "The SDK's correctness.test.ts, ported (the routes' 404 case comes with the dashboard)."
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Cronwatch.Test.More

  alias Cronwatch.Format
  alias Cronwatch.JS
  alias Cronwatch.Run
  alias Cronwatch.Schedule
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock

  @min 60_000

  defp store_state(cw, job), do: state(Cronwatch.Config.get(cw).store, job)

  # Starts a job whose function waits for :go (then answers what `then` does)
  # in a process of its own; answers the task once the run is going.
  defp held(cw, name, then) do
    test = self()

    job = fn _ ->
      send(test, {:running, self()})

      receive do
        :go -> then.()
      end
    end

    task =
      Task.async(fn ->
        try do
          Cronwatch.run(name, job, instance: cw)
        rescue
          e -> {:raised, e}
        end
      end)

    assert_receive {:running, pid}
    {task, pid}
  end

  test "an alert still being sent cannot overwrite what a run did meanwhile" do
    sent = switch([])
    gate = switch(:closed)

    slow =
      channel("slow-for-missed", fn a ->
        if a.type == "missed" do
          push(sent, :entered)
          eventually(fn -> get(gate) == :open end, 1000)
        end

        push(sent, a.type)
        :ok
      end)

    %{cw: cw, clock: c} = make(alerts: [slow])
    job = Cronwatch.job!("sync", schedule: "every 5m", grace: "1m", instance: cw)
    Cronwatch.run(job, fn _ -> nil end)
    Clock.advance(c, 7 * @min)
    checking = Task.async(fn -> Cronwatch.check!(instance: cw) end)
    eventually(fn -> :entered in get(sent) end)
    # The job turns up while the missed alert is in flight.
    Cronwatch.run(job, fn _ -> nil end)
    put(gate, :open)
    Task.await(checking)
    assert get(sent) -- [:entered] == ["recovered", "missed"]
    assert store_state(cw, "sync").open == [], "missed stays closed"
    Clock.advance(c, @min)
    Cronwatch.run(job, fn _ -> nil end)
    assert get(sent) -- [:entered] == ["recovered", "missed"], "no second recovered"
  end

  test "pruning keeps each job's newest run, so a monthly job is not reported missed" do
    clock = Clock.new(JS.date_utc(2026, 0, 1))
    %{cw: cw, clock: c, alerts: alerts} = make(clock_ref: clock, retention: "30d")
    monthly = Cronwatch.job!("monthly", schedule: "0 0 1 * *", timezone: "UTC", instance: cw)
    Cronwatch.run(monthly, fn _ -> nil end)
    Clock.set(c, JS.date_utc(2026, 0, 31, 12))
    assert Cronwatch.check!(instance: cw).pruned == 0
    Clock.advance(c, 120 * @min)
    Cronwatch.check!(instance: cw)
    assert Capture.types(alerts) == []
    assert Cronwatch.job_summary!("monthly", instance: cw).health == "healthy"
  end

  test "an expect pattern with the g flag gives the same answer every run" do
    %{cw: cw} = make()
    job = Cronwatch.job!("g", expect: {:matches, "done", "g"}, instance: cw)
    for _ <- 1..4, do: Cronwatch.run(job, fn j -> Cronwatch.log(j, "done") end)
    assert Enum.map(Cronwatch.runs!("g", 50, instance: cw), & &1.status) == ["ok", "ok", "ok", "ok"]
  end

  test "expect sees a line logged early, even after the stored output has dropped it" do
    %{cw: cw} = make()

    Cronwatch.run(
      "report",
      fn j ->
        Cronwatch.log(j, "Report written: /tmp/r.pdf")
        for i <- 0..2999, do: Cronwatch.log(j, "row #{i} #{String.duplicate("x", 40)}")
      end,
      expect: "Report written",
      instance: cw
    )

    [run] = Cronwatch.runs!("report", 50, instance: cw)
    assert run.status == "ok"
    refute run.output =~ "Report written", "the stored output is still only the tail"
  end

  test "an interval job whose run is still going is busy, not missed" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    Cronwatch.job!("long", schedule: "every 5m", grace: "2m", instance: cw)
    {task, pid} = held(cw, "long", fn -> nil end)
    Clock.advance(c, 8 * @min)
    Cronwatch.check!(instance: cw)
    assert Capture.types(alerts) == []
    send(pid, :go)
    Task.await(task)
    assert Capture.types(alerts) == [], "and no recovered for a miss that never was"
  end

  test "a run a check marked stuck, that then fails, counts once" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    Cronwatch.job!("slowpoke", timeout: "1m", failures_before_alert: 2, instance: cw)
    {task, pid} = held(cw, "slowpoke", fn -> raise "gave up" end)
    Clock.advance(c, 2 * @min)
    Cronwatch.check!(instance: cw)
    assert store_state(cw, "slowpoke").consecutive_failures == 1
    send(pid, :go)
    assert {:raised, %RuntimeError{}} = Task.await(task)
    assert store_state(cw, "slowpoke").consecutive_failures == 1
    assert Capture.types(alerts) == [], "one run is one failure, under the threshold of two"

    [run] = Cronwatch.runs!("slowpoke", 50, instance: cw)
    assert run.error |> String.split("\n") |> hd() == "RuntimeError: gave up", "the run keeps its real error"
  end

  test "a late success after a stuck mark closes stuck and recovers" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    Cronwatch.job!("late", timeout: "30s", instance: cw)
    {task, pid} = held(cw, "late", fn -> nil end)
    Clock.advance(c, @min)
    %{alerts: [first | _]} = Cronwatch.check!(instance: cw)
    assert first.run.error =~ ~r/\AStill running after 30s;/
    send(pid, :go)
    Task.await(task)
    assert Capture.types(alerts) == ["stuck", "recovered"]
  end

  test "stop cancels the first check start scheduled" do
    %{cw: cw} = make()
    ref = events(cw, [[:cronwatch, :check, :start]])
    :ok = Cronwatch.start(instance: cw)
    :ok = Cronwatch.stop(instance: cw)
    Process.sleep(1_300)
    refute_received {:event, ^ref, _, _, _}
  end

  test "fire times around the autumn clock change are never in the past" do
    days = [{"Europe/London", JS.date_utc(2026, 9, 24, 22)}, {"America/New_York", JS.date_utc(2026, 10, 1, 3)}]

    for {tz, day} <- days, expr <- ["*/15 * * * *", "30 1 * * *", "0 * * * *"] do
      {:ok, p} = Schedule.parse(expr, tz)

      for t <- day..(day + 8 * 3_600_000)//(5 * @min) do
        assert Schedule.next_fire(p, t, nil) > t, "#{tz} #{expr} after #{JS.iso_string(t)}"
      end
    end
  end

  test "a failed alert names the error once" do
    now = Clock.t0()

    alert = fn error ->
      run = %Run{
        id: "r",
        job: "j",
        status: "failed",
        started_at: now,
        finished_at: now,
        duration_ms: 5,
        error: error
      }

      Format.compose_alert(
        {"failed", run, %{consecutive_failures: 1, threshold: 1}},
        JS.Object.new([{"name", "j"}]),
        now
      ).message
    end

    assert alert.("Error: connect ECONNREFUSED 10.0.0.12:5432") =~ ~r/^Error: connect ECONNREFUSED/m
    refute alert.("Error: connect ECONNREFUSED 10.0.0.12:5432") =~ "Error: Error:"
    assert alert.("TypeError: x is undefined") =~ ~r/^TypeError: x is undefined/m
    assert alert.(~s(Output did not contain "wrote")) =~ ~r/^Error: Output did not contain "wrote"/m
    assert alert.("HTTP 503 Service Unavailable") =~ ~r/^Error: HTTP 503/m
  end
end
