defmodule Cronwatch.FinishOnceTest do
  @moduledoc """
  The SDK's finish-once.test.ts, ported. Its scenarios over several
  processes sharing one store are Cronwatch.StoreCase's, run over the memory
  store and SQLite by test/store; these are the ones on one instance.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client

  alias Cronwatch.Run
  alias Cronwatch.Store
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Stores

  @min 60_000
  @hour 3_600_000

  test "a store without update_run_if falls back to a read and a write" do
    inner = Stores.memory()
    %{cw: cw, errors: errors} = make(store: {Cronwatch.Test.PlainStore, store: inner})
    job = Cronwatch.job!("plain", instance: cw)
    {:ok, h} = Cronwatch.start(job, id: "p1")
    assert Cronwatch.finish(h, "done").status == "ok"
    {:ok, again} = Cronwatch.resume(job, "p1")
    assert Cronwatch.finish(again, "again") == nil
    assert Enum.any?(messages(errors), &(&1 =~ "already finished"))
  end

  test "record_run: a run a check marked timeout takes its late finish, as a handle's would" do
    c = Clock.new(Cronwatch.JS.date_utc(2026, 0, 1, 3, 0))
    store = Stores.memory()
    %{cw: cw, alerts: alerts} = make(clock_ref: c, store: Stores.option(store))
    Cronwatch.job!("db:vacuum", schedule: "0 3 * * *", timeout: "30m", instance: cw)
    base = %Run{id: "pgcron:77", job: "db:vacuum", status: "running", started_at: Clock.now(c), trigger: "pg_cron"}
    {:ok, _} = Cronwatch.record_run(base, instance: cw)
    Clock.advance(c, 45 * @min)
    Cronwatch.check!(instance: cw)
    assert Cronwatch.get_run!("pgcron:77", instance: cw).status == "timeout"
    Clock.advance(c, 15 * @min)

    {:ok, _} =
      Cronwatch.record_run(
        %{base | status: "ok", finished_at: Clock.now(c) - 5 * @min, duration_ms: 55 * @min, output: "VACUUM"},
        instance: cw
      )

    Cronwatch.check!(instance: cw)
    run = Cronwatch.get_run!("pgcron:77", instance: cw)
    assert run.status == "ok"
    assert run.output == "VACUUM"
    assert Cronwatch.job_summary!("db:vacuum", instance: cw).health == "healthy"
    assert Capture.types(alerts) == ["stuck", "recovered"]

    # A late failure is written but not counted twice.
    other = %{base | id: "pgcron:78", started_at: Clock.now(c)}
    {:ok, _} = Cronwatch.record_run(other, instance: cw)
    Clock.advance(c, 45 * @min)
    Cronwatch.check!(instance: cw)

    {:ok, _} =
      Cronwatch.record_run(
        %{other | status: "failed", finished_at: Clock.now(c), duration_ms: 45 * @min, error: "ERROR: canceled"},
        instance: cw
      )

    assert Cronwatch.get_run!("pgcron:78", instance: cw).status == "failed"
    {:ok, state} = Store.call(store, :get_state, ["db:vacuum"])
    assert state.consecutive_failures == 1
    assert Capture.types(alerts) == ["stuck", "recovered", "stuck"]
  end

  test "record_run leaves a stored run of another job alone, and reports it" do
    %{cw: cw, alerts: alerts, errors: errors} = make()
    a = Cronwatch.job!("webhook-job", instance: cw)
    Cronwatch.job!("db:nightly", instance: cw)
    {:ok, h} = Cronwatch.start(a, id: "run-43")
    now = Clock.t0()

    sent =
      Cronwatch.record_run!(
        %Run{
          id: "run-43",
          job: "db:nightly",
          status: "ok",
          started_at: now - 1000,
          finished_at: now,
          duration_ms: 1000,
          trigger: "pg_cron"
        },
        instance: cw
      )

    assert sent == []
    stored = Cronwatch.get_run!("run-43", instance: cw)
    assert stored.job == "webhook-job"
    assert stored.status == "running"
    assert Enum.any?(messages(errors), &(&1 =~ ~s(run-43 of db:nightly belongs to job "webhook-job"; ignored)))
    assert Cronwatch.finish(h).status == "ok"
    assert Capture.types(alerts) == []
  end

  test "start and resume refuse ids in the pg_cron source's pgcron: namespace" do
    %{cw: cw} = make()
    job = Cronwatch.job!("webhook-job", instance: cw)
    assert {:error, %{message: m}} = Cronwatch.start(job, id: "pgcron:42")
    assert m =~ ~s(cannot take a run id starting with "pgcron:")
    assert {:error, %{message: m}} = Cronwatch.resume(job, "pgcron:42")
    assert m =~ ~s(cannot take a run id starting with "pgcron:")
    assert {:error, %{message: m}} = Cronwatch.resume_run("webhook-job", "pgcron:db:42", instance: cw)
    assert m =~ "pgcron:"
    {:ok, h} = Cronwatch.start(job, id: "pgcron-42")
    assert Cronwatch.active?(h), "only the prefix with its colon is reserved"
  end

  test "start with an id another job holds fails the same whether its start is in flight or done" do
    %{cw: cw} = make()
    a = Cronwatch.job!("import-a", instance: cw)
    b = Cronwatch.job!("import-b", instance: cw)

    results =
      Task.await_many([
        Task.async(fn -> Cronwatch.start(a, id: "evt_123") end),
        Task.async(fn -> Cronwatch.start(b, id: "evt_123") end)
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert [{:error, %{message: m}}] = Enum.filter(results, &match?({:error, _}, &1))
    assert m =~ ~r/belongs to job "import-[ab]", not "import-[ab]"/
    holder = Cronwatch.get_run!("evt_123", instance: cw).job
    loser = if holder == "import-a", do: b, else: a
    assert {:error, %{message: m}} = Cronwatch.start(loser, id: "evt_123")
    assert m =~ ~s(belongs to job "#{holder}", not "#{loser.name}")
    # The same job at once still records one start.
    [{:ok, x}, {:ok, y}] =
      Task.await_many([
        Task.async(fn -> Cronwatch.start(a, id: "evt_9") end),
        Task.async(fn -> Cronwatch.start(a, id: "evt_9") end)
      ])

    assert x.id == y.id
    assert length(Cronwatch.runs!("import-a", 50, instance: cw) |> Enum.filter(&(&1.id == "evt_9"))) == 1
  end

  test "a handle resumed while the store failed cannot finish or flush another job's run" do
    inner = Stores.memory()
    {store, hooks} = Stores.hooked(inner)
    %{cw: cw, errors: errors} = make(store: store)
    billing = Cronwatch.job!("billing", instance: cw)
    webhook = Cronwatch.job!("webhook", instance: cw)
    {:ok, _} = Cronwatch.start(billing, id: "run-7")

    Stores.hook(hooks, :get_run, fn _args, _real ->
      Stores.unhook(hooks, :get_run)
      {:error, %RuntimeError{message: "blip"}}
    end)

    {:ok, h} = Cronwatch.resume(webhook, "run-7")
    assert Cronwatch.active?(h), "unknown yet: the read failed"
    Cronwatch.log(h, "attacker line")
    :ok = Cronwatch.flush(h)
    assert Enum.any?(messages(errors), &(&1 =~ ~s(run-7 of webhook belongs to job "billing"; ignored)))
    assert Cronwatch.finish(h, "ok") == nil
    {:ok, stored} = Store.call(inner, :get_run, ["run-7"])
    assert {stored.job, stored.status, stored.output} == {"billing", "running", nil}
  end

  test "expect at finish sees an early line even after flushes, as run() would" do
    %{cw: cw} = make()
    job = Cronwatch.job!("export", expect: "connected to warehouse", instance: cw)
    batch = fn i -> String.pad_trailing("row batch #{i} ", 60, ".") end

    Cronwatch.run(job, fn ctx ->
      Cronwatch.log(ctx, "connected to warehouse")
      for i <- 0..399, do: Cronwatch.log(ctx, batch.(i))
    end)

    assert hd(Cronwatch.runs!("export", 50, instance: cw)).status == "ok"
    {:ok, h} = Cronwatch.start(job)
    Cronwatch.log(h, "connected to warehouse")

    for i <- 0..399 do
      Cronwatch.log(h, batch.(i))
      if rem(i, 100) == 99, do: :ok = Cronwatch.flush(h)
    end

    run = Cronwatch.finish(h)
    assert run.status == "ok", run.error || ""
    refute run.output =~ "connected to warehouse", "the stored output kept only the tail"
  end

  test "a flush never undoes a finish written while it read" do
    inner = Stores.memory()
    {store, hooks} = Stores.hooked(inner)
    %{cw: cw} = make(store: store)
    job = Cronwatch.job!("sync", instance: cw)
    {:ok, h} = Cronwatch.start(job, id: "s1")
    Cronwatch.log(h, "halfway")
    {:ok, other} = Cronwatch.resume(job, "s1")

    Stores.hook(hooks, :get_run, fn _args, real ->
      Stores.unhook(hooks, :get_run)
      result = real.()
      # Another process finishes the run while this flush reads it.
      Task.await(Task.async(fn -> Cronwatch.finish(other, "done elsewhere") end))
      result
    end)

    :ok = Cronwatch.flush(h)
    {:ok, stored} = Store.call(inner, :get_run, ["s1"])
    assert stored.status == "ok", "still finished"
    assert stored.output == "done elsewhere"
  end

  test "a run finished while a check marks it timeout is judged once" do
    inner = Stores.memory()
    {store, hooks} = Stores.hooked(inner)
    %{cw: cw, clock: c, alerts: alerts} = make(store: store)
    job = Cronwatch.job!("long", timeout: "5m", instance: cw)
    {:ok, h} = Cronwatch.start(job)
    Clock.advance(c, 10 * @min)
    test = self()

    Stores.hook(hooks, :running_runs, fn _args, real ->
      Stores.unhook(hooks, :running_runs)
      result = real.()
      send(test, {:finish_now, self()})

      receive do
        :finished -> result
      end
    end)

    check = Task.async(fn -> Cronwatch.check!(instance: cw) end)
    assert_receive {:finish_now, checker}, 5_000
    Cronwatch.finish(h, "finally")
    send(checker, :finished)
    Task.await(check)
    assert Cronwatch.get_run!(h.id, instance: cw).status == "ok"
    assert Capture.types(alerts) == [], "not marked stuck over a finish"
    _ = @hour
  end
end
