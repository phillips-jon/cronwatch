defmodule Cronwatch.HardeningTest do
  @moduledoc "The SDK's client-hardening.test.ts, ported (the handler's case comes with the handler)."
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Cronwatch.Test.More
  import ExUnit.CaptureLog

  alias Cronwatch.JS.Object
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Flaky
  alias Cronwatch.Test.Wrap

  @t0 Clock.t0()
  @min 60_000
  @hour 3_600_000

  defp store_state(cw, job), do: state(Cronwatch.Config.get(cw).store, job)
  defp fail!(cw, name, message \\ "x"), do: catch_error(Cronwatch.run(name, fn _ -> raise message end, instance: cw))

  test "a cron firing more often than its grace is still missed" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("often", schedule: "*/5 * * * *", instance: cw)
    Cronwatch.run(job, fn _ -> nil end)
    Clock.advance(c, 14 * @min)
    assert Cronwatch.check!(instance: cw).alerts == [], "09:35 is due, grace runs to 09:45"
    Clock.advance(c, 2 * @min)
    assert Enum.map(Cronwatch.check!(instance: cw).alerts, & &1.type) == ["missed"]
    Cronwatch.run(job, fn _ -> nil end)
    assert Capture.types(alerts) == ["missed", "recovered"]
  end

  test "a missed run whose next run fails below the threshold still recovers later" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("quiet", schedule: "every 1h", failures_before_alert: 3, instance: cw)
    Cronwatch.check!(instance: cw)
    Clock.advance(c, 2 * @hour)
    Cronwatch.check!(instance: cw)
    fail!(cw, "quiet")
    assert Capture.types(alerts) == ["missed"]
    Cronwatch.run(job, fn _ -> nil end)
    assert Capture.types(alerts) == ["missed", "recovered"]
    assert Enum.at(Capture.alerts(alerts), 1).message =~ "after: missed"
  end

  test "a store outage never stops the job, and store errors go to the error handler" do
    name = shared_memory()
    {store, broken} = Flaky.new(Wrap.memory(name))
    Flaky.break(broken, [:upsert_job, :insert_run, :get_state, :set_state, :update_run, :list_runs])
    %{cw: cw, errors: errors} = make(store: store)
    ran = counter()

    assert Cronwatch.run(
             "s",
             fn _ ->
               bump(ran)
               7
             end,
             instance: cw
           ) == 7

    assert_raise RuntimeError, "the job's own", fn ->
      Cronwatch.run(
        "s",
        fn _ ->
          bump(ran)
          raise "the job's own"
        end,
        instance: cw
      )
    end

    assert count(ran) == 2
    assert wheres(errors) != [] and Enum.all?(wheres(errors), &(&1 == "recording s")), inspect(wheres(errors))
    Flaky.mend(broken)
    Cronwatch.run("s", fn _ -> "back" end, instance: cw)
    assert length(Cronwatch.runs!("s", 50, instance: cw)) == 1
  end

  test "a store that fails to initialise is tried again on the next call" do
    inits = counter()
    name = shared_memory()
    init = fn -> if bump(inits) == 1, do: {:error, %RuntimeError{message: "not yet"}}, else: :ok end
    %{cw: cw, errors: errors} = make(store: Wrap.spec(inner: Wrap.memory(name), init: init))
    assert Cronwatch.run("i", fn _ -> 1 end, instance: cw) == 1
    assert wheres(errors) == ["recording i"]
    # The finished run was written on the retry, once init went through.
    assert count(inits) == 2
    Cronwatch.run("i", fn _ -> 2 end, instance: cw)
    assert count(inits) == 2
    assert length(Cronwatch.runs!("i", 50, instance: cw)) == 2
  end

  test "dispatch does not overwrite a silence made while an alert was being sent" do
    me = switch(nil)
    silencer = channel("silencer", fn _ -> Cronwatch.silence!("loud", "1h", instance: get(me)) && :ok end)
    %{cw: cw} = make(alerts: [silencer])
    put(me, cw)
    fail!(cw, "loud")
    s = store_state(cw, "loud")
    assert s.silenced_until != nil, "the silence survived"
    assert s.open == [{"failed", @t0}]
    assert s.last_alert_at == @t0
  end

  test "an alert no channel took is retried once per check until one does" do
    down = switch(true)
    attempts = counter()
    got = switch([])

    flaky =
      channel("flaky", fn a ->
        bump(attempts)
        if get(down), do: {:error, "down"}, else: push(got, a)
      end)

    %{cw: cw, clock: c} = make(alerts: [flaky])
    fail!(cw, "r")
    s = store_state(cw, "r")
    assert length(s.undelivered) == 1
    assert s.last_alert_at == nil, "nothing was delivered"
    Clock.advance(c, @min)
    Cronwatch.check!(instance: cw)
    assert count(attempts) == 2, "one retry per check"
    put(down, false)
    Clock.advance(c, @min)
    result = Cronwatch.check!(instance: cw)
    assert Enum.map(result.alerts, & &1.type) == ["failed"]
    assert Enum.map(get(got), & &1.type) == ["failed"]
    assert hd(get(got)).at == @t0, "the same alert, not a new one"
    s = store_state(cw, "r")
    assert s.undelivered == []
    assert s.last_alert_at == @t0 + 2 * @min
    Cronwatch.check!(instance: cw)
    assert count(attempts) == 3, "not sent again"
  end

  test "deliver: :check queues alerts for another process's check, which sends them with triage" do
    clock = Clock.new()
    store = shared_memory()
    triaged = counter()

    # The recording process: no network, so it sends nothing itself.
    recorder =
      make(
        store: {Cronwatch.Store.Memory, server: store},
        clock_ref: clock,
        deliver: :check,
        triage: fn _ -> {:ok, "never asked"} end
      )

    job = Cronwatch.job!("backup", schedule: "40 3 * * *", timezone: "UTC", instance: recorder.cw)
    assert_raise RuntimeError, fn -> Cronwatch.run(job, fn _ -> raise "disk full" end) end
    assert Capture.types(recorder.alerts) == [], "nothing sent from the recording process"
    s = store_state(recorder.cw, "backup")
    assert Enum.map(s.undelivered, & &1.type) == ["failed"]
    assert s.last_alert_at == nil
    assert Cronwatch.check!(instance: recorder.cw).alerts == [], "its own check does not send either"

    # The web server: can send, and has not declared the job.
    server =
      make(
        store: {Cronwatch.Store.Memory, server: store},
        clock_ref: clock,
        triage: fn _ ->
          bump(triaged)
          {:ok, "The disk is full."}
        end
      )

    Clock.advance(clock, @min)
    result = Cronwatch.check!(instance: server.cw)
    assert Enum.map(result.alerts, & &1.type) == ["failed"]
    assert Capture.types(server.alerts) == ["failed"]
    assert hd(Capture.alerts(server.alerts)).triage == "The disk is full."
    assert hd(Capture.alerts(server.alerts)).at == @t0, "the alert from the run, not a new one"
    assert count(triaged) == 1
    s = store_state(server.cw, "backup")
    assert s.undelivered == []
    assert s.last_alert_at == @t0 + @min
    Cronwatch.check!(instance: server.cw)
    assert Capture.types(server.alerts) == ["failed"], "sent once"

    # The recovery takes the same route.
    Cronwatch.run(job, fn _ -> nil end)
    Cronwatch.check!(instance: server.cw)
    assert Capture.types(server.alerts) == ["failed", "recovered"]
    assert count(triaged) == 1, "recoveries are not triaged"
  end

  test "deliver takes only :now or :check" do
    assert {:error, %Cronwatch.Error{message: m}} = Cronwatch.start_link(name: :deliver_later, deliver: :later)
    assert m =~ ~s(deliver must be "now" or "check")
  end

  test "overlapping runs of one job share its state without losing updates" do
    %{cw: cw, alerts: alerts} = make()
    job = Cronwatch.job!("par", failures_before_alert: 2, instance: cw)

    1..3
    |> Enum.map(fn _ -> Task.async(fn -> catch_error(Cronwatch.run(job, fn _ -> raise "x" end)) end) end)
    |> Task.await_many()

    assert store_state(cw, "par").consecutive_failures == 3
    assert Capture.types(alerts) == ["failed"], "one alert, not one per run"
  end

  test "job() refuses numbers that would quietly turn a check off" do
    %{cw: cw} = make()

    refused = fn opts ->
      with {:error, %Cronwatch.Error{message: m}} <- Cronwatch.job("a", [instance: cw] ++ opts), do: m
    end

    assert refused.(failures_before_alert: :nan) =~ "failuresBeforeAlert"
    assert refused.(failures_before_alert: 0) =~ "failuresBeforeAlert"
    assert refused.(failures_before_alert: 1.5) =~ "failuresBeforeAlert"
    assert refused.(budget: [cost: :nan]) =~ "budget.cost"
    assert refused.(budget: [cost: :infinity]) =~ "budget.cost"
    assert refused.(budget: [cost: -1]) =~ "budget.cost"
    assert refused.(floor: [rows: :infinity]) =~ "floor.rows"
    assert refused.(floor: 5) =~ "floor must be an object of { metric: floor }"
    assert refused.(grace: :nan) =~ "grace"
    assert refused.(timeout: 0) =~ "timeout"
    assert refused.(max_duration: "0s") =~ "maxDuration"
    assert refused.(schedule: "0 2 * * *", timezone: "Mars/Olympus") =~ "timezone"
    %{cw: cw2} = make(defaults: [failures_before_alert: :nan])
    assert {:error, %{message: m}} = Cronwatch.job("a", instance: cw2)
    assert m =~ "failuresBeforeAlert"
    assert {:ok, _} = Cronwatch.job("a", budget: [errors: 0], failures_before_alert: 2, timeout: "5m", instance: cw)
  end

  test "a returned string is capped like logged output" do
    %{cw: cw} = make()
    Cronwatch.run("big", fn _ -> String.duplicate("x", 40_000) end, instance: cw)
    [run] = Cronwatch.runs!("big", 50, instance: cw)
    assert Cronwatch.JS.len16(run.output) < 17 * 1024
    assert run.output =~ ~r/\A\[earlier output trimmed\]/
  end

  test "runs() takes a whole number of runs in range" do
    %{cw: cw} = make()
    for _ <- 1..3, do: Cronwatch.run("n", fn _ -> nil end, instance: cw)
    assert length(Cronwatch.runs!("n", 2.7, instance: cw)) == 2
    assert length(Cronwatch.runs!("n", -4, instance: cw)) == 1
    assert length(Cronwatch.runs!("n", :nan, instance: cw)) == 3
    [{job, runs}] = Cronwatch.jobs_with_runs!(2, instance: cw)
    assert length(runs) == 2
    assert job.last_run.id == hd(runs).id
  end

  test "an error names itself once, frames after its message" do
    %{cw: cw, alerts: alerts} = make()
    fail!(cw, "db", "connect ECONNREFUSED 10.0.0.12:5432")
    [run] = Cronwatch.runs!("db", 50, instance: cw)
    assert run.error =~ ~r/\ARuntimeError: connect ECONNREFUSED 10.0.0.12:5432\n    at /
    refute hd(Capture.alerts(alerts)).message =~ "Error: RuntimeError:"
    assert hd(Capture.alerts(alerts)).message =~ ~r/^RuntimeError: connect ECONNREFUSED/m
    fail!(cw, "db", "two\nlines")
    assert hd(Cronwatch.runs!("db", 50, instance: cw)).error =~ ~r/\ARuntimeError: two\nlines\n    at /
  end

  test "the baseline reads past recent failures to twenty successful runs" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("base", instance: cw)

    failed_at = fn ms ->
      catch_error(
        Cronwatch.run(job, fn _ ->
          Clock.advance(c, ms)
          raise "x"
        end)
      )

      Clock.advance(c, @min)
    end

    ok_at = fn ms ->
      Cronwatch.run(job, fn _ -> Clock.advance(c, ms) end)
      Clock.advance(c, @min)
    end

    for _ <- 1..5, do: ok_at.(100_000)
    for _ <- 1..15, do: ok_at.(1_000)
    for _ <- 1..10, do: failed_at.(1_000)
    # Fifteen 1s runs alone would make 10s the limit; with the five 100s runs, p95 is 100s.
    ok_at.(30_000)
    assert Capture.types(alerts) == ["failed", "recovered"]
  end

  test "stop also cancels the first check start_checking schedules, and start_checking checks a second in" do
    %{cw: cw} = make()
    ref = events(cw, [[:cronwatch, :check, :start]])
    Cronwatch.start_checking(instance: cw)
    Cronwatch.stop(instance: cw)
    Process.sleep(1_200)
    refute_received {:event, ^ref, _, _, _}
    Cronwatch.start_checking(instance: cw)
    assert_receive {:event, ^ref, _, _, _}, 2_000
    Cronwatch.stop(instance: cw)
  end

  test "the run's execution is not part of the public API" do
    refute function_exported?(Cronwatch, :execute, 2)
    refute function_exported?(Cronwatch, :execute, 3)
  end

  # A job's failure queued by a deliver: :check instance, so a check
  # elsewhere must triage and send it.
  defp queued(store, clock, name \\ "backup") do
    recorder = make(store: {Cronwatch.Store.Memory, server: store}, clock_ref: clock, deliver: :check)
    fail!(recorder.cw, name, "disk full")
    recorder
  end

  test "a diagnosis made on a retry is kept with the queued alert, and triage runs once per alert" do
    clock = Clock.new()
    store = shared_memory()
    queued(store, clock)
    asked = counter()
    down = switch(true)
    sent = switch([])
    flaky = channel("flaky", fn a -> if get(down), do: {:error, "down"}, else: push(sent, a) end)

    server =
      make(
        store: {Cronwatch.Store.Memory, server: store},
        clock_ref: clock,
        alerts: [flaky],
        triage: fn _ ->
          bump(asked)
          {:ok, "The disk is full."}
        end
      )

    Cronwatch.check!(instance: server.cw)
    assert count(asked) == 1
    assert hd(store_state(server.cw, "backup").undelivered).triage == "The disk is full.", "the stored copy has it"
    Cronwatch.check!(instance: server.cw)
    Cronwatch.check!(instance: server.cw)
    assert count(asked) == 1, "not asked again on later retries"
    put(down, false)
    Cronwatch.check!(instance: server.cw)
    assert Enum.map(get(sent), &{&1.type, &1.triage}) == [{"failed", "The disk is full."}]
  end

  test "a triage that raises or answers nothing is tried once, recorded as nil" do
    for triage <- [fn -> raise "api down" end, fn -> {:ok, ""} end, fn -> nil end] do
      clock = Clock.new()
      store = shared_memory()
      queued(store, clock)
      asked = counter()

      server =
        make(
          store: {Cronwatch.Store.Memory, server: store},
          clock_ref: clock,
          alerts: [channel("down", fn _ -> {:error, "down"} end)],
          triage: fn _ ->
            bump(asked)
            triage.()
          end
        )

      for _ <- 1..3, do: Cronwatch.check!(instance: server.cw)
      assert count(asked) == 1
      [alert] = store_state(server.cw, "backup").undelivered
      assert alert.triage == nil and alert.triage_tried
      assert Cronwatch.JS.stringify(Cronwatch.Alert.to_value(alert)) =~ ~s("triage":null)
    end
  end

  test "an alert whose condition closed is dropped from the retry queue; a recovery whose conditions stay closed is sent" do
    down = switch(true)
    sent = switch([])
    flaky = channel("flaky", fn a -> if get(down), do: {:error, "down"}, else: push(sent, "#{a.type}@#{a.at}") end)
    %{cw: cw, clock: c} = make(alerts: [flaky])
    fail!(cw, "s")
    Clock.advance(c, @min)
    Cronwatch.run("s", fn _ -> nil end, instance: cw)
    assert Enum.map(store_state(cw, "s").undelivered, & &1.type) == ["failed", "recovered"]
    put(down, false)
    Clock.advance(c, @min)
    Cronwatch.check!(instance: cw)
    assert get(sent) == ["recovered@#{@t0 + @min}"], "the failure is over, so only its recovery goes"
    assert store_state(cw, "s").undelivered == []
  end

  test "an alert whose condition opened again at another time is dropped, and so is a recovery it undoes" do
    down = switch(true)
    sent = switch([])
    flaky = channel("flaky", fn a -> if get(down), do: {:error, "down"}, else: push(sent, "#{a.type}@#{a.at}") end)
    %{cw: cw, clock: c} = make(alerts: [flaky])
    fail!(cw, "s")
    Clock.advance(c, @min)
    Cronwatch.run("s", fn _ -> nil end, instance: cw)
    Clock.advance(c, @min)
    fail!(cw, "s", "again")
    assert Enum.map(store_state(cw, "s").undelivered, & &1.type) == ["failed", "recovered", "failed"]
    put(down, false)
    Clock.advance(c, @min)
    Cronwatch.check!(instance: cw)
    assert get(sent) == ["failed@#{@t0 + 2 * @min}"]
  end

  test "a job that cannot be evaluated is reported and shown as failing, and the others are checked" do
    %{cw: cw, clock: c, alerts: alerts, errors: errors} = make()
    good = Cronwatch.job!("good", schedule: "every 1h", instance: cw)
    Cronwatch.run(good, fn _ -> nil end)
    {m, h} = Cronwatch.Config.get(cw).store
    obj = &Object.new/1
    :ok = m.upsert_job(h, obj.([{"name", "bad"}, {"schedule", "not a schedule"}]), @t0)
    :ok = m.upsert_job(h, obj.([{"name", "odd"}, {"timeout", "soon"}]), @t0)
    :ok = m.insert_run(h, %Cronwatch.Run{id: "hung", job: "odd", status: "running", started_at: @t0})
    Clock.advance(c, 2 * @hour)
    result = Cronwatch.check!(instance: cw)
    assert Enum.map(result.alerts, &"#{&1.job}:#{&1.type}") == ["good:missed"]
    assert Map.new(result.jobs, &{&1.name, &1.health}) == %{"bad" => "failing", "good" => "late", "odd" => "failing"}
    assert wheres(errors) == ["checking odd", "checking bad", "checking odd"]
    assert Capture.types(alerts) == ["missed"]

    Agent.update(errors, fn _ -> [] end)
    jobs = Cronwatch.jobs!(instance: cw)

    assert Enum.map(jobs, &{&1.name, &1.health, &1.next_expected_at == nil}) == [
             {"bad", "failing", true},
             {"good", "late", false},
             {"odd", "failing", true}
           ]

    assert wheres(errors) == ["reading bad", "reading odd"]
    assert Cronwatch.job_summary!("bad", instance: cw).health == "failing"
    Cronwatch.silence!("bad", "1h", instance: cw)
    assert Cronwatch.job_summary!("bad", instance: cw).health == "silenced"
  end

  test "trimming the undelivered queue past twenty is reported" do
    %{cw: cw, errors: errors} = make(deliver: :check)

    for _ <- 1..10 do
      fail!(cw, "q")
      Cronwatch.run("q", fn _ -> nil end, instance: cw)
    end

    assert length(store_state(cw, "q").undelivered) == 20
    assert wheres(errors) == []
    fail!(cw, "q")
    assert length(store_state(cw, "q").undelivered) == 20
    assert wheres(errors) == ["alert queue for q"]
  end

  test "start_checking with deliver: :check says once that another process must send" do
    %{cw: cw} = make(deliver: :check)

    log =
      capture_log(fn ->
        Cronwatch.start_checking(instance: cw)
        Cronwatch.stop(instance: cw)
        Cronwatch.start_checking(instance: cw)
        Cronwatch.stop(instance: cw)
      end)

    assert length(String.split(log, "send no alerts")) == 2
    assert log =~ ~r/deliver: :check.*send no alerts.*Another process/s

    %{cw: cw2} = make()

    assert capture_log(fn ->
             Cronwatch.start_checking(instance: cw2)
             Cronwatch.stop(instance: cw2)
           end) == "",
           "a delivering instance says nothing"
  end

  test "a timeout longer than a timer can hold does not cancel the job at once" do
    %{cw: cw} = make()

    for timeout <- ["30d", "60d"] do
      job = Cronwatch.job!("monthly", timeout: timeout, instance: cw)

      cancelled =
        Cronwatch.run(job, fn ctx ->
          Process.sleep(20)
          Cronwatch.cancelled?(ctx)
        end)

      refute cancelled
    end
  end

  test "start/0 and start/1 with a keyword list still start the checks, deprecated" do
    %{cw: cw} = make()
    ref = events(cw, [[:cronwatch, :check, :start]])

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Cronwatch.start(instance: cw) == :ok
      end)

    assert warning =~ "Cronwatch.start/1 with a keyword list is deprecated, use Cronwatch.start_checking/1 instead"
    assert_receive {:event, ^ref, _, _, _}, 2_000
    assert Cronwatch.start_checking(instance: cw) == :ok, "a second start is ignored"
    Cronwatch.stop(instance: cw)

    assert {:start, 0} in Enum.map(Cronwatch.__info__(:deprecated), &elem(&1, 0))
  end

  test "start_checking with an interval longer than a timer can hold does not check every millisecond" do
    %{cw: cw} = make()
    ref = events(cw, [[:cronwatch, :check, :start]])
    Cronwatch.start_checking(every: "30d", instance: cw)
    assert_receive {:event, ^ref, _, _, _}, 2_000
    Process.sleep(300)
    refute_received {:event, ^ref, _, _, _}
    Cronwatch.stop(instance: cw)
  end
end

defmodule Cronwatch.HardeningTimingTest do
  @moduledoc """
  The hardening cases that wait on the delivery limits (a channel's 15
  seconds, triage's 25, a check's 20 of retries), with the limits shortened
  through the application environment; not async, since it is global.
  """
  use ExUnit.Case, async: false

  import Cronwatch.Test.Client
  import Cronwatch.Test.More

  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock

  setup do
    on_exit(fn ->
      for k <- [:channel_timeout, :triage_timeout, :retry_budget], do: Application.delete_env(:cronwatch, k)
    end)
  end

  test "a hung channel times out without holding up the others" do
    Application.put_env(:cronwatch, :channel_timeout, 300)
    hung = channel("hung", fn _ -> Process.sleep(:infinity) end)
    good = Capture.new()
    %{cw: cw, errors: errors} = make(alerts: [hung, Capture.channel(good)])
    pending = Task.async(fn -> catch_error(Cronwatch.run("h", fn _ -> raise "x" end, instance: cw)) end)
    eventually(fn -> Capture.types(good) == ["failed"] end)
    assert Task.yield(pending, 0) == nil, "still waiting on the hung channel"
    Task.await(pending)
    assert wheres(errors) == ["alert channel hung"]
    assert state(Cronwatch.Config.get(cw).store, "h").undelivered == [], "one channel took it: delivered"
  end

  test "triage is stopped when the client stops waiting for it" do
    Application.put_env(:cronwatch, :triage_timeout, 300)
    triager = switch(nil)

    %{cw: cw, alerts: alerts, errors: errors} =
      make(
        triage: fn _ ->
          put(triager, self())
          Process.sleep(:infinity)
        end
      )

    catch_error(Cronwatch.run("t", fn _ -> raise "x" end, instance: cw))
    refute Process.alive?(get(triager)), "the triage was stopped"
    assert wheres(errors) == ["triage for t"]
    assert Capture.types(alerts) == ["failed"]
  end

  test "retries stop once a check has spent its budget, and the rest wait" do
    Application.put_env(:cronwatch, :retry_budget, 1_000)
    clock = Clock.new()
    store = shared_memory()

    for name <- ["a", "b", "c"] do
      recorder = make(store: {Cronwatch.Store.Memory, server: store}, clock_ref: clock, deliver: :check)
      catch_error(Cronwatch.run(name, fn _ -> raise "disk full" end, instance: recorder.cw))
    end

    tried = switch([])

    # Each attempt takes 600 ms of wall clock and fails.
    slow =
      channel("slow", fn a ->
        push(tried, a.job)
        Process.sleep(600)
        {:error, "timed out"}
      end)

    server = make(store: {Cronwatch.Store.Memory, server: store}, clock_ref: clock, alerts: [slow])
    Cronwatch.check!(instance: server.cw)
    assert get(tried) == ["a", "b"], "the budget covers two attempts"
    assert length(state(Cronwatch.Config.get(server.cw).store, "c").undelivered) == 1, "c is still queued"
    put(tried, [])
    Cronwatch.check!(instance: server.cw)
    assert get(tried) == ["a", "b"], "each check has a fresh budget"
  end
end
