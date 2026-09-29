defmodule Cronwatch.ClientTest do
  @moduledoc "The SDK's client.test.ts, ported (the handler's cases come with the handler)."
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock

  @t0 Clock.t0()
  @min 60_000
  @hour 3_600_000

  test "run records output, metrics and duration, and returns the result" do
    %{cw: cw, clock: c} = make()
    job = Cronwatch.job!("report", schedule: "0 2 * * *", instance: cw)

    result =
      Cronwatch.run(job, fn j ->
        Cronwatch.log(j, "hello")
        Cronwatch.log(j, %{n: 1})
        Cronwatch.metric(j, "rows", 42)
        Clock.advance(c, 1500)
        "done"
      end)

    assert result == "done"
    [run] = Cronwatch.runs!("report", 50, instance: cw)
    assert run.status == "ok"
    assert run.duration_ms == 1500
    assert run.output == "hello\n%{n: 1}"
    assert JS.stringify(run.metrics) == ~s({"rows":42})
    summary = Cronwatch.job_summary!("report", instance: cw)
    assert summary.health == "healthy"
    assert summary.next_expected_at == JS.date_utc(2026, 0, 6, 2, 0)
  end

  test "a raising job is recorded as failed, alerts, and raises again" do
    %{cw: cw, alerts: alerts} = make()
    job = Cronwatch.job!("nightly", instance: cw)
    assert_raise RuntimeError, "db down", fn -> Cronwatch.run(job, fn _ -> raise "db down" end) end
    [run] = Cronwatch.runs!("nightly", 50, instance: cw)
    assert run.status == "failed"
    assert run.error =~ "RuntimeError: db down"
    assert Capture.types(alerts) == ["failed"]
    assert hd(Capture.alerts(alerts)).message =~ "db down"
    assert Cronwatch.job_summary!("nightly", instance: cw).health == "failing"
  end

  test "throws, exits, {:error, reason} and :error fail the run and are handed back" do
    %{cw: cw} = make()
    job = Cronwatch.job!("ways", instance: cw)
    assert catch_throw(Cronwatch.run(job, fn _ -> throw(:nope) end)) == :nope
    assert catch_exit(Cronwatch.run(job, fn _ -> exit(:bye) end)) == :bye
    assert Cronwatch.run(job, fn _ -> {:error, :timeout} end) == {:error, :timeout}
    assert Cronwatch.run(job, fn _ -> :error end) == :error
    assert Cronwatch.run(job, fn _ -> {:ok, 1} end) == {:ok, 1}
    statuses = Cronwatch.runs!("ways", 50, instance: cw) |> Enum.map(& &1.status) |> Enum.frequencies()
    assert statuses == %{"failed" => 4, "ok" => 1}
    errors = Cronwatch.runs!("ways", 50, instance: cw) |> Enum.map(& &1.error) |> Enum.reject(&is_nil/1)
    assert Enum.any?(errors, &String.starts_with?(&1, "throw: :nope"))
    assert Enum.any?(errors, &String.starts_with?(&1, "exit: :bye"))
    assert ":timeout" in errors
  end

  test "expect turns a quiet success into a failure" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("export", expect: "wrote", instance: cw)
    Cronwatch.run(job, fn j -> Cronwatch.log(j, "wrote 12 files") end)
    assert Capture.types(alerts) == []
    Clock.advance(c, @hour)
    Cronwatch.run(job, fn j -> Cronwatch.log(j, "nothing to do") end)
    [run | _] = Cronwatch.runs!("export", 50, instance: cw)
    assert run.status == "failed"
    assert run.error =~ ~s(did not contain "wrote")
    assert Capture.types(alerts) == ["failed"]
    # A returned string counts as output too.
    Cronwatch.run(job, fn _ -> "wrote 3 files" end)
    assert Capture.types(alerts) == ["failed", "recovered"]
  end

  test "run defines on first use and names, schedules and durations are checked" do
    %{cw: cw} = make()
    assert Cronwatch.run("adhoc", fn _ -> 1 end, schedule: "every 5m", instance: cw) == 1
    assert length(Cronwatch.jobs!(instance: cw)) == 1
    assert {:error, %Cronwatch.Error{kind: :invalid, message: m}} = Cronwatch.job("bad name!", instance: cw)
    assert m =~ "job name"
    assert {:error, %{message: m}} = Cronwatch.job("x", schedule: "nope", instance: cw)
    assert m =~ "not a cron expression"
    assert {:error, %{message: m}} = Cronwatch.job("x", grace: "soon", instance: cw)
    assert m =~ "grace"
    assert {:error, %{message: m}} = Cronwatch.job("x", failures_before_alert: 0, instance: cw)
    assert m == ~s[job "x": failuresBeforeAlert must be a whole number, 1 or more (got 0)]
    assert {:error, %{message: m}} = Cronwatch.job("x", timezone: "Mars/Olympus", instance: cw)
    assert m == ~s(job "x": timezone "Mars/Olympus" is not an IANA timezone)
    assert {:error, %{message: m}} = Cronwatch.job("x", expect: ~r/done/, instance: cw)
    assert m =~ "{:matches"
  end

  test "a definition keeps its fields in the order given, expect last" do
    %{cw: cw} = make(defaults: [grace: "5m"])

    job =
      Cronwatch.job!("ordered",
        expect: "ok",
        schedule: "0 2 * * *",
        timeout: %Duration{minute: 30},
        budget: [cost: 2, rows: 1.5],
        grace: 900_000,
        instance: cw
      )

    assert JS.stringify(job.definition) ==
             ~s({"grace":900000,"schedule":"0 2 * * *","timeout":1800000,"budget":{"cost":2,"rows":1.5},"name":"ordered","expect":"contains \\"ok\\""})
  end

  test "check finds a missed run, once, and a later run recovers" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("sync", schedule: "every 1h", grace: "10m", instance: cw)
    Cronwatch.check!(instance: cw)
    Clock.advance(c, 30 * @min)
    assert Cronwatch.check!(instance: cw).alerts == []
    Clock.set(c, @t0 + 70 * @min + 1)
    r = Cronwatch.check!(instance: cw)
    assert Enum.map(r.alerts, & &1.type) == ["missed"]
    assert hd(r.jobs).health == "late"
    assert Cronwatch.check!(instance: cw).alerts == [], "no repeat"
    Cronwatch.run(job, fn _ -> nil end)
    assert Capture.types(alerts) == ["missed", "recovered"]
    assert Cronwatch.job_summary!("sync", instance: cw).health == "healthy"
  end

  test "a job declared again without its schedule closes missed with a recovery, once" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    Cronwatch.job!("sync", schedule: "every 1h", grace: "10m", instance: cw)
    Cronwatch.check!(instance: cw)
    Clock.set(c, @t0 + 70 * @min + 1)
    assert Enum.map(Cronwatch.check!(instance: cw).alerts, & &1.type) == ["missed"]
    job = Cronwatch.job!("sync", instance: cw)
    Clock.advance(c, @min)
    r = Cronwatch.check!(instance: cw)
    assert Enum.map(r.alerts, & &1.type) == ["recovered"]
    alert = hd(r.alerts)
    assert alert.title == "sync is no longer scheduled"

    assert alert.message ==
             "Missed since 2026-01-05 10:40:00 UTC (1m ago). It has no schedule now, so nothing is due; the missed alert is closed."

    assert JS.stringify(Cronwatch.Alert.to_value(alert) |> Object.get("details")) ==
             ~s({"after":["missed"],"reason":"unscheduled","since":#{@t0 + 70 * @min + 1}})

    assert hd(r.jobs).health == "never_ran"
    assert Cronwatch.check!(instance: cw).alerts == [], "no repeat"
    Cronwatch.run(job, fn _ -> nil end)
    assert Capture.types(alerts) == ["missed", "recovered"], "the next run owes nothing"
  end

  test "a schedule removed while silenced closes missed quietly" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    Cronwatch.job!("sync", schedule: "every 1h", grace: "10m", instance: cw)
    Cronwatch.check!(instance: cw)
    Clock.set(c, @t0 + 70 * @min + 1)
    Cronwatch.check!(instance: cw)
    Cronwatch.silence!("sync", "1h", instance: cw)
    Cronwatch.job!("sync", instance: cw)
    Clock.advance(c, @min)
    assert Cronwatch.check!(instance: cw).alerts == []
    assert Cronwatch.job_summary!("sync", instance: cw).open == []
    Clock.advance(c, 2 * @hour)
    assert Cronwatch.check!(instance: cw).alerts == []
    assert Capture.types(alerts) == ["missed"]
  end

  test "check marks a run that never finished as stuck" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("long", timeout: "5m", instance: cw)
    test = self()

    spawn(fn ->
      Cronwatch.run(job, fn _ ->
        send(test, :running)
        Process.sleep(:infinity)
      end)
    end)

    assert_receive :running
    assert hd(Cronwatch.runs!("long", 50, instance: cw)).status == "running"
    Clock.advance(c, 4 * @min)
    assert Cronwatch.check!(instance: cw).alerts == []
    Clock.advance(c, 2 * @min)
    r = Cronwatch.check!(instance: cw)
    assert Enum.map(r.alerts, & &1.type) == ["stuck"]
    assert hd(Cronwatch.runs!("long", 50, instance: cw)).status == "timeout"
    assert hd(r.jobs).health == "stuck"
    assert hd(Capture.alerts(alerts)).message =~ "never reported finishing"
  end

  test "slow and over-budget alerts come from the job's own baseline" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("agent", budget: [cost: 1], instance: cw)

    metrics = fn j, tokens, cost ->
      Cronwatch.metric(j, "tokens", tokens)
      Cronwatch.metric(j, "cost", cost)
    end

    for _ <- 1..5 do
      Cronwatch.run(job, fn j ->
        Clock.advance(c, 1000)
        metrics.(j, 1000, 0.5)
      end)

      Clock.advance(c, @hour)
    end

    assert Capture.types(alerts) == []

    Cronwatch.run(job, fn j ->
      Clock.advance(c, 15_000)
      metrics.(j, 1000, 0.5)
    end)

    assert Capture.types(alerts) == ["slow"]
    Clock.advance(c, @hour)

    Cronwatch.run(job, fn j ->
      Clock.advance(c, 1000)
      metrics.(j, 5000, 1.2)
    end)

    assert Capture.types(alerts) == ["slow", "over_budget"]
    last = Enum.at(Capture.alerts(alerts), 1)
    assert last.message =~ "cost: 1.2, limit 1 (budget)"
    assert last.message =~ "tokens: 5,000, limit 3,000 (three times the usual 1,000)"
    Clock.advance(c, @hour)

    Cronwatch.run(job, fn j ->
      Clock.advance(c, 1000)
      metrics.(j, 1000, 0.5)
    end)

    assert Capture.types(alerts) == ["slow", "over_budget", "recovered"]
  end

  test "silence swallows alerts and nothing opens underneath; unsilence alerts again" do
    %{cw: cw, alerts: alerts} = make()
    job = Cronwatch.job!("flaky", instance: cw)
    Cronwatch.silence!("flaky", "1h", instance: cw)
    assert_raise RuntimeError, fn -> Cronwatch.run(job, fn _ -> raise "x" end) end
    assert Capture.types(alerts) == []
    assert Cronwatch.job_summary!("flaky", instance: cw).health == "silenced"
    Cronwatch.unsilence!("flaky", instance: cw)
    assert_raise RuntimeError, fn -> Cronwatch.run(job, fn _ -> raise "y" end) end
    assert Capture.types(alerts) == ["failed"]
  end

  test "triage output is attached to failure alerts and never blocks them" do
    %{cw: cw, alerts: alerts} = make(triage: fn %{alert: a} -> {:ok, "Probably #{a.job}'s database."} end)
    assert_raise RuntimeError, fn -> Cronwatch.run("t", fn _ -> raise "x" end, instance: cw) end
    assert hd(Capture.alerts(alerts)).triage == "Probably t's database."

    %{cw: cw2, alerts: alerts2, errors: errors} = make(triage: fn _ -> raise "api down" end)
    assert_raise RuntimeError, fn -> Cronwatch.run("t", fn _ -> raise "x" end, instance: cw2) end
    assert Capture.types(alerts2) == ["failed"]
    alert = hd(Capture.alerts(alerts2))
    assert alert.triage == nil and alert.triage_tried, "tried, and gave nothing"
    assert wheres(errors) == ["triage for t"]
  end

  test "forget removes the job and its runs" do
    %{cw: cw} = make()
    Cronwatch.run("gone", fn _ -> nil end, instance: cw)
    assert length(Cronwatch.jobs!(instance: cw)) == 1
    assert :ok = Cronwatch.forget("gone", instance: cw)
    assert Cronwatch.jobs!(instance: cw) == []
    assert Cronwatch.job_summary!("gone", instance: cw) == nil
  end

  test "a failing alert channel does not break the run" do
    broken = Cronwatch.Alerts.fun("broken", fn _ -> raise "no network" end)
    %{cw: cw, errors: errors} = make(alerts: [broken])
    assert_raise RuntimeError, "job", fn -> Cronwatch.run("x", fn _ -> raise "job" end, instance: cw) end
    assert wheres(errors) == ["alert channel broken"]
  end

  test "a bad option fails the instance's start with the SDK's message" do
    assert {:error, %Cronwatch.Error{message: m}} = Cronwatch.start_link(name: :bad_cw, retention: "soon")
    assert m =~ "retention"

    assert {:error, %Cronwatch.Error{message: m}} =
             Cronwatch.start_link(name: :bad_cw, jobs: [{"x", schedule: "nope"}])

    assert m =~ "not a cron expression"
  end
end
