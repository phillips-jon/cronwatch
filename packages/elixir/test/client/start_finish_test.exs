defmodule Cronwatch.StartFinishTest do
  @moduledoc "The SDK's start-finish.test.ts, ported: runs that span calls, through start, resume, flush and finish."
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client

  alias Cronwatch.JS
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Flaky
  alias Cronwatch.Test.Repo
  alias Cronwatch.Test.Stores
  alias Cronwatch.Test.Wrap

  @min 60_000
  @hour 3_600_000

  test "start records a running run and finish records it ok" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("sync", schedule: "@hourly", instance: cw)
    {:ok, run} = Cronwatch.start(job, trigger: "queue")
    assert run.job == "sync"
    assert Cronwatch.active?(run)
    stored = Cronwatch.get_run!(run.id, instance: cw)
    assert stored.status == "running"
    assert stored.trigger == "queue"
    Cronwatch.log(run, "imported 12 rows")
    Cronwatch.metric(run, "rows", 12)
    Clock.advance(c, 90_000)
    finished = Cronwatch.finish(run)
    assert finished.status == "ok"
    assert finished.duration_ms == 90_000
    refute Cronwatch.active?(run)
    [recorded] = Cronwatch.runs!("sync", 50, instance: cw)
    assert recorded.status == "ok"
    assert recorded.output == "imported 12 rows"
    assert JS.stringify(recorded.metrics) == ~s({"rows":12})
    assert Capture.types(alerts) == []
    assert Cronwatch.job_summary!("sync", instance: cw).health == "healthy"
  end

  test "fail and finish({:error, reason}) record a failure and alert once" do
    %{cw: cw, alerts: alerts} = make()
    job = Cronwatch.job!("import", failures_before_alert: 2, instance: cw)
    {:ok, first} = Cronwatch.start(job)
    Cronwatch.fail(first, %RuntimeError{message: "api down"})
    {:ok, second} = Cronwatch.start(job)
    run = Cronwatch.finish(second, {:error, %RuntimeError{message: "still down"}})
    assert run.status == "failed"
    assert run.error =~ ~r/\ARuntimeError: still down/
    assert Capture.types(alerts) == ["failed"]
    {:ok, third} = Cronwatch.start(job, trigger: "retry")
    Cronwatch.finish(third)
    assert Capture.types(alerts) == ["failed", "recovered"]
  end

  test "a second finish is ignored and reported, not raised" do
    %{cw: cw, alerts: alerts, errors: errors} = make()
    job = Cronwatch.job!("once", instance: cw)
    {:ok, run} = Cronwatch.start(job)
    a = Cronwatch.fail(run, "boom")
    b = Cronwatch.finish(run)
    assert a.status == "failed"
    assert b == nil
    assert Cronwatch.finish(run) == nil
    assert Capture.types(alerts) == ["failed"]
    assert hd(Cronwatch.runs!("once", 50, instance: cw)).status == "failed"
    assert length(messages(errors)) == 2
    assert hd(messages(errors)) =~ "was already finished by this handle; ignored"
    assert hd(wheres(errors)) == "finishing once"
  end

  test "start with an id twice records one run and answers a handle on it" do
    %{cw: cw, errors: errors} = make()
    job = Cronwatch.job!("inngest-fn", instance: cw)

    [{:ok, one}, {:ok, two}] =
      Task.await_many([
        Task.async(fn -> Cronwatch.start(job, id: "01HX-run") end),
        Task.async(fn -> Cronwatch.start(job, id: "01HX-run") end)
      ])

    assert one.id == "01HX-run" and two.id == "01HX-run"
    {:ok, one} = Cronwatch.start(job, id: "01HX-run")
    {:ok, again} = Cronwatch.start(job, id: "01HX-run", trigger: "ignored")
    assert Cronwatch.active?(again)
    assert length(Cronwatch.runs!("inngest-fn", 50, instance: cw)) == 1
    assert Cronwatch.get_run!("01HX-run", instance: cw).trigger == "start"
    Cronwatch.finish(again, "done")
    # Finished elsewhere: this handle's finish is a reported no-op.
    assert Cronwatch.finish(one) == nil
    assert List.last(messages(errors)) =~ "already finished as ok; ignored"
    {:ok, late} = Cronwatch.start(job, id: "01HX-run")
    refute Cronwatch.active?(late)
    assert Cronwatch.finish(late) == nil
    assert length(Cronwatch.runs!("inngest-fn", 50, instance: cw)) == 1
    other = Cronwatch.job!("other", instance: cw)
    assert {:error, %{message: m}} = Cronwatch.start(other, id: "01HX-run")
    assert m =~ ~s(belongs to job "inngest-fn")
    assert {:error, %{message: m}} = Cronwatch.start(job, id: "")
    assert m =~ "run id of 1 to 200 characters"
    # No store could hold a NUL (Postgres refuses it), so such an id is refused wherever one is taken.
    assert {:error, %{message: m}} = Cronwatch.start(job, id: "01HX\0run")
    assert m =~ "start() cannot take a run id containing a NUL character"
    assert {:error, %{message: m}} = Cronwatch.resume(job, "01HX\0run")
    assert m =~ "resume() cannot take a run id containing a NUL character"

    nul_run = %Cronwatch.Run{
      id: "x\0y",
      job: "inngest-fn",
      status: "ok",
      started_at: 1,
      finished_at: 2,
      duration_ms: 1,
      trigger: "run"
    }

    assert {:error, %{message: m}} = Cronwatch.record_run(nul_run, instance: cw)
    assert m =~ "record_run: run ids cannot contain a NUL character"
    assert length(Cronwatch.runs!("inngest-fn", 50, instance: cw)) == 1
  end

  for backend <- [:memory, :sqlite] do
    test "resume in a second instance on the same store (#{backend}) appends and finishes" do
      {a, b} =
        case unquote(backend) do
          :memory ->
            s = Stores.memory()
            {s, s}

          :sqlite ->
            file = Path.join(Repo.tmp_dir(), "cw.db")
            {Repo.store(file), Repo.store(file)}
        end

      c = Clock.new()
      %{cw: first, alerts: alerts1, errors: errors1} = make(store: Stores.option(a), clock_ref: c)
      %{cw: second, alerts: alerts2, errors: errors2} = make(store: Stores.option(b), clock_ref: c)
      options = [expect: "sent", budget: [emails: 100]]
      {:ok, started} = Cronwatch.start(Cronwatch.job!("digest", [instance: first] ++ options), id: "evt-1")
      Cronwatch.log(started, "loaded 40 recipients")
      Cronwatch.log(started, "token=abc123")
      Cronwatch.metric(started, "recipients", 40)
      :ok = Cronwatch.flush(started)
      midway = Cronwatch.get_run!("evt-1", instance: first)
      assert midway.status == "running"
      assert midway.output == "loaded 40 recipients\ntoken=[redacted]"

      Clock.advance(c, 5 * @min)
      Cronwatch.job!("digest", [instance: second] ++ options)
      {:ok, resumed} = Cronwatch.resume_run("digest", "evt-1", instance: second)
      assert Cronwatch.active?(resumed)
      assert resumed.started_at == midway.started_at
      Cronwatch.log(resumed, "sent 40 emails")
      Cronwatch.metric(resumed, "emails", 40)
      run = Cronwatch.finish(resumed)
      assert run.status == "ok"
      assert run.duration_ms == 5 * @min
      stored = Cronwatch.get_run!("evt-1", instance: first)
      assert stored.status == "ok"
      assert stored.output == "loaded 40 recipients\ntoken=[redacted]\nsent 40 emails"
      assert JS.stringify(stored.metrics) == ~s({"recipients":40,"emails":40})
      assert Capture.types(alerts1) ++ Capture.types(alerts2) == []
      assert messages(errors1) ++ messages(errors2) == []
    end
  end

  test "resume of an unknown or finished run answers a handle whose finish is a reported no-op" do
    %{cw: cw, errors: errors} = make()
    job = Cronwatch.job!("webhook", instance: cw)
    {:ok, missing} = Cronwatch.resume(job, "nope")
    refute Cronwatch.active?(missing)
    assert missing.started_at == nil
    Cronwatch.log(missing, "dropped")
    :ok = Cronwatch.flush(missing)
    assert Cronwatch.finish(missing) == nil
    assert Enum.at(messages(errors), 0) =~ "run nope of webhook was not found; ignored"
    Cronwatch.run(job, fn _ -> "done" end)
    [done] = Cronwatch.runs!("webhook", 50, instance: cw)
    {:ok, finished} = Cronwatch.resume(job, done.id)
    refute Cronwatch.active?(finished)
    assert Cronwatch.fail(finished, "late") == nil
    assert Enum.at(messages(errors), 1) =~ "already finished as ok; ignored"
    assert hd(Cronwatch.runs!("webhook", 50, instance: cw)).status == "ok"
    assert {:error, %{message: m}} = Cronwatch.resume_run("undeclared", "x", instance: cw)
    assert m =~ "not declared"
  end

  test "a run never finished is marked stuck after the job's timeout" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("callback", timeout: "30m", instance: cw)
    {:ok, run} = Cronwatch.start(job)
    Clock.advance(c, 29 * @min)
    Cronwatch.check!(instance: cw)
    assert Cronwatch.get_run!(run.id, instance: cw).status == "running"
    Clock.advance(c, 2 * @min)
    Cronwatch.check!(instance: cw)
    stored = Cronwatch.get_run!(run.id, instance: cw)
    assert stored.status == "timeout"
    assert stored.error =~ "Still running after 30m"
    assert Capture.types(alerts) == ["stuck"]
  end

  # A channel whose sends wait for :release, telling the test when one starts.
  defp held(test) do
    Cronwatch.Alerts.fun("held", fn alert ->
      send(test, {:sending, self(), alert.job})

      receive do
        :release -> :ok
      end
    end)
  end

  test "stopping the instance waits for a check under way before the store and the rest stop" do
    name = :"store#{System.unique_integer([:positive])}"
    start_supervised!({Cronwatch.Store.Memory, name: name}, id: name)
    shared = Wrap.memory(name)
    clock = Clock.new()
    cw = :"cw#{System.unique_integer([:positive])}"

    # Started here rather than under the test's supervisor, so it can be
    # stopped from another process while the test watches.
    {:ok, sup} =
      Cronwatch.start_link(
        name: cw,
        clock: Clock.fun(clock),
        alerts: [held(self())],
        cron_secret: false,
        store: Wrap.spec(inner: shared)
      )

    Process.unlink(sup)
    {:ok, _} = Cronwatch.start(Cronwatch.job!("callback", timeout: "30m", instance: cw))
    Clock.advance(clock, 31 * @min)
    check = Task.async(fn -> Cronwatch.check(instance: cw) end)
    assert_receive {:sending, sender, "callback"}, 5_000

    checker = Process.whereis(Cronwatch.Checker.server(cw))
    runs = Process.whereis(Cronwatch.Runs.server(cw))
    :erlang.trace(checker, true, [:receive])
    stopping = Task.async(fn -> Supervisor.stop(sup) end)
    assert_receive {:trace, ^checker, :receive, {:EXIT, ^sup, :shutdown}}, 5_000

    # The check is waited for: nothing after it in the instance has stopped.
    assert Process.alive?(runs)
    assert Task.yield(stopping, 0) == nil
    send(sender, :release)
    assert Task.await(stopping) == :ok
    refute Process.alive?(runs)

    assert {:ok, result} = Task.await(check)
    assert Enum.map(result.alerts, & &1.type) == ["stuck"]
    # Its delivery was recorded before the store went: nothing left to send.
    {:ok, s} = Cronwatch.Store.call(shared, :get_state, ["callback"])
    assert s.sending == nil
    assert s.last_alert_at == Clock.now(clock)
  end

  test "lines flushed while a check marks earlier runs stuck are kept on the run it marks next" do
    %{cw: cw, clock: c} = make(alerts: [held(self())])
    {:ok, first} = Cronwatch.start(Cronwatch.job!("first", timeout: "30m", instance: cw))
    Clock.advance(c, 1000)
    {:ok, second} = Cronwatch.start(Cronwatch.job!("second", timeout: "30m", instance: cw))
    Cronwatch.log(second, "early line")
    Cronwatch.metric(second, "rows", 1)
    Cronwatch.flush(second)
    Clock.advance(c, 31 * @min)
    check = Task.async(fn -> Cronwatch.check!(instance: cw) end)

    # The first stuck run's alert is being sent; the second is still running, and flushes.
    assert_receive {:sending, sender, "first"}, 5_000
    Cronwatch.log(second, "important progress line")
    Cronwatch.metric(second, "rows", 2)
    Cronwatch.flush(second)
    send(sender, :release)
    assert_receive {:sending, sender, "second"}, 5_000
    send(sender, :release)
    Task.await(check)

    stored = Cronwatch.get_run!(second.id, instance: cw)
    assert stored.status == "timeout"
    assert stored.output == "early line\nimportant progress line"
    assert JS.stringify(stored.metrics) == ~s({"rows":2})
    assert Cronwatch.get_run!(first.id, instance: cw).status == "timeout"
  end

  test "a late success after a timeout mark closes stuck and recovers; a late failure does not count twice" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("slowpoke", timeout: "10m", failures_before_alert: 2, instance: cw)
    {:ok, first} = Cronwatch.start(job)
    Clock.advance(c, 11 * @min)
    Cronwatch.check!(instance: cw)
    assert Capture.types(alerts) == []
    failed = Cronwatch.fail(first, %RuntimeError{message: "gave up"})
    assert failed.status == "failed"

    assert Cronwatch.get_run!(first.id, instance: cw).error |> String.split("\n") |> hd() ==
             "RuntimeError: gave up",
           "the run keeps its real error"

    assert Capture.types(alerts) == [], "the late failure did not count as a second one"

    {:ok, second} = Cronwatch.start(job)
    Clock.advance(c, 11 * @min)
    Cronwatch.check!(instance: cw)
    assert Capture.types(alerts) == ["stuck"]
    {:ok, resumed} = Cronwatch.resume_run("slowpoke", second.id, instance: cw)
    assert Cronwatch.active?(resumed), "a run marked timeout can still be finished late"
    late = Cronwatch.finish(resumed)
    assert late.status == "ok"
    assert Capture.types(alerts) == ["stuck", "recovered"]
    assert Cronwatch.finish(second) == nil, "the handle that started it sees it finished elsewhere"
  end

  test "expect is applied at finish, to the logged lines or the text passed" do
    %{cw: cw, alerts: alerts} = make()
    job = Cronwatch.job!("export", expect: {:matches, "wrote \\d+ files", ""}, instance: cw)
    {:ok, quiet} = Cronwatch.start(job)
    run = Cronwatch.finish(quiet, {:ok, "nothing to do"})
    assert run.status == "failed"
    assert run.output == "nothing to do"
    assert run.error =~ "did not match"
    assert Capture.types(alerts) == ["failed"]

    {:ok, busy} = Cronwatch.start(job)
    Cronwatch.log(busy, "wrote 3 files")
    :ok = Cronwatch.flush(busy)
    {:ok, resumed} = Cronwatch.resume(job, busy.id)
    assert Cronwatch.finish(resumed, "uploaded").status == "ok", "lines flushed earlier count toward expect"
    assert Capture.types(alerts) == ["failed", "recovered"]

    {:ok, http} = Cronwatch.start(job)
    bad = Cronwatch.finish(http, {:ok, %{__struct__: Req.Response, status: 502}})
    # The reason is Plug's, so it is named only where Plug is loaded.
    assert bad.error == if(Code.ensure_loaded?(Plug.Conn.Status), do: "HTTP 502 Bad Gateway", else: "HTTP 502")
  end

  test "a store failing during start does not raise; finish records the run once the store is back" do
    {store, broken} = Flaky.new(Stores.memory())
    Flaky.break(broken, :insert_run)
    %{cw: cw, clock: c, alerts: alerts, errors: errors} = make(store: store)
    job = Cronwatch.job!("backup", schedule: "@hourly", instance: cw)
    {:ok, run} = Cronwatch.start(job)
    assert Cronwatch.active?(run)
    assert hd(wheres(errors)) == "recording backup"
    assert Cronwatch.get_run!(run.id, instance: cw) == nil
    Cronwatch.log(run, "copied")
    # Nothing stored to append to; kept for finish.
    :ok = Cronwatch.flush(run)
    Flaky.mend(broken)
    Clock.advance(c, div(@hour, 2))
    finished = Cronwatch.finish(run)
    assert finished.status == "ok"
    stored = Cronwatch.get_run!(run.id, instance: cw)
    assert stored.status == "ok"
    assert stored.output == "copied"
    assert stored.duration_ms == div(@hour, 2)
    assert Capture.types(alerts) == []
  end

  test "a store failing at finish is reported, not raised, and the handle can finish again" do
    {store, broken} = Flaky.new(Stores.memory())
    %{cw: cw, errors: errors} = make(store: store)
    job = Cronwatch.job!("flaky", instance: cw)
    {:ok, run} = Cronwatch.start(job)
    Cronwatch.log(run, "working")
    Flaky.break(broken, [:get_run, :update_run, :update_run_if])
    :ok = Cronwatch.flush(run)
    assert List.last(wheres(errors)) == "flushing flaky"
    assert Cronwatch.finish(run) == nil, "nothing recorded"
    assert "finishing flaky" in wheres(errors)
    assert Cronwatch.active?(run), "still active, to finish again"
    # The read works but the write fails: still retryable.
    Flaky.mend(broken, :get_run)
    assert Cronwatch.finish(run) == nil
    assert Cronwatch.active?(run)
    Flaky.mend(broken)
    assert Cronwatch.get_run!(run.id, instance: cw).status == "running", "nothing written yet"
    finished = Cronwatch.finish(run)
    assert finished.status == "ok"
    assert finished.output == "working", "the lines logged before the failures are kept"
    refute Cronwatch.active?(run)
    assert Cronwatch.finish(run) == nil, "finished once only"
  end
end
