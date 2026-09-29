defmodule Cronwatch.BridgeTest do
  @moduledoc "The bridge the integrations share: the Rust port's bridge tests, with the Go and Rust audits' cases."
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client

  alias Cronwatch.Bridge
  alias Cronwatch.Bridge.Entry
  alias Cronwatch.Bridge.Watch
  alias Cronwatch.JS
  alias Cronwatch.Test.Flaky
  alias Cronwatch.Test.Stores

  test "the app tag is the PHP port's" do
    x39 = String.duplicate("x", 39)

    for {app, want} <- [
          {"Billing", "laravel-scheduler:billing"},
          {"  My App! v2 ", "laravel-scheduler:my-app-v2"},
          {"acme_web.prod-1", "laravel-scheduler:acme_web.prod-1"},
          {"!!!", "laravel-scheduler:6dd07555"},
          {String.duplicate("x", 50), "laravel-scheduler:#{x39}-62f01267"},
          {"Ünïcode Äpp", "laravel-scheduler:n-code-pp"},
          {"K", "laravel-scheduler:f7781178"}
        ] do
      assert Bridge.app_tag("laravel-scheduler", app) == want, inspect(app)
    end
  end

  test "the app name comes from CRONWATCH_APP_ID, else the OTP application" do
    assert is_binary(Bridge.app_name())
  end

  test "every_text is exact to the millisecond" do
    assert Bridge.every_text(90 * 60_000) == "every 1h30m"
    assert Bridge.every_text(36 * 3_600_000 + 1500) == "every 1d12h1s500ms"
    assert Bridge.every_text(0) == "every 0ms"
  end

  test "validate refuses what job/2 refuses" do
    assert Bridge.validate("ok", schedule: "0 2 * * *") == :ok
    assert {:error, %Cronwatch.Error{message: m}} = Bridge.validate("no spaces", [])
    assert m =~ "must be 1 to 120 characters"
    assert {:error, _} = Bridge.validate("x", schedule: "not a cron")
  end

  # A scheduler that runs at hour:00 UTC every `step` days from the epoch.
  defp daily(hour, step) do
    fn start, finish ->
      at = fn day -> day * 86_400_000 + hour * 3_600_000 end
      day = Integer.floor_div(start, 86_400_000)
      day = Enum.find(Stream.iterate(day, &(&1 - 1)), &(at.(&1) <= start and rem(&1, step) == 0))

      out =
        Stream.iterate(day + step, &(&1 + step))
        |> Enum.reduce_while([at.(day)], fn d, out ->
          out = out ++ [at.(d)]

          if (finish == nil and length(out) > 8) or (finish != nil and at.(d) > finish),
            do: {:halt, out},
            else: {:cont, out}
        end)

      {:ok, out}
    end
  end

  test "check_fires compares the scheduler's own runs" do
    now = JS.date_utc(2026, 7, 1)
    assert Bridge.check_fires(daily(2, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now) == :ok
    assert {:error, err} = Bridge.check_fires(daily(2, 2), "0 2 * * *", "UTC", "cronwatch: x", "a scheduler", true, now)
    assert err =~ ~s(cronwatch: x is "0 2 * * *" in UTC, but after a run at)
    assert err =~ "a scheduler runs it next at"
    assert {:error, _} = Bridge.check_fires(daily(3, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now)
    never = fn _, _ -> Bridge.never_fires("no fire time") end
    assert {:error, err} = Bridge.check_fires(never, "0 2 * * *", "UTC", "x", "a scheduler", true, now)
    assert String.ends_with?(err, "which never fires: no fire time")
    assert {:error, err} = Bridge.check_fires(daily(2, 1), "not a cron", "UTC", "x", "a scheduler", true, now)
    assert err =~ "which CronWatch cannot read"
  end

  test "check_fires names a time the clock change skips" do
    # A scheduler that skips 02:30 in New York the night clocks go forward,
    # where CronWatch (croner) moves it past the jump.
    {:ok, tz} = Cronwatch.Zone.load("America/New_York")
    {:ok, cron} = Cronwatch.Schedule.parse("30 2 * * *", "America/New_York")

    runs = fn start, finish ->
      Stream.unfold(start - 3 * 86_400_000, fn at ->
        case Cronwatch.Schedule.fire_after(cron, at) do
          nil -> nil
          fire -> {fire, fire}
        end
      end)
      |> Stream.filter(fn fire -> elem(Cronwatch.Zone.wall_at(div(fire, 1000), tz), 3) == 2 end)
      |> Enum.reduce_while([], fn fire, out ->
        out = if fire <= start, do: [fire], else: out ++ [fire]

        if (finish == nil and length(out) > 8) or (finish != nil and fire > finish),
          do: {:halt, out},
          else: {:cont, out}
      end)
      |> then(&{:ok, &1})
    end

    now = JS.date_utc(2026, 7, 1)
    assert {:error, err} = Bridge.check_fires(runs, "30 2 * * *", "America/New_York", "job", "a scheduler", true, now)

    assert err =~
             "due at a time that does not exist in America/New_York on 2026-03-08, when clocks go forward from 02:00 to 03:00"
  end

  defp stored(cw, name) do
    %{definition: d} = Cronwatch.Config.get(cw) |> Cronwatch.Core.store!(:get_job, [name])
    JS.stringify(d)
  end

  defp entry(name, label, schedule, more \\ []), do: struct(%Entry{name: name, label: label, schedule: schedule}, more)

  defp watch(cw, tag, app, scheduler) do
    pid = start_supervised!({Watch, instance: cw, tag: tag, app: app, scheduler: scheduler}, id: make_ref())
    pid
  end

  defp shared(store) do
    make(store: Stores.option(store), alerts: [])
  end

  test "a watch declares entries and unschedules the gone" do
    %{cw: cw, errors: errors} = make(alerts: [])
    w = watch(cw, "gocron", "billing", "gocron")

    nightly =
      entry("nightly", "entry 1", "0 2 * * *",
        timezone: "UTC",
        defaults: [grace: "5m"],
        options: [budget: [cost: 2], tags: ["reports"]]
      )

    odd = entry("odd", "entry 4", "", problem: "cronwatch: entry 4 cannot be read")
    Watch.declare(w, [nightly, entry("twice", "entry 2", "0 3 * * *"), entry("twice", "entry 3", "0 4 * * *"), odd])
    Cronwatch.check!(instance: cw)

    assert stored(cw, "nightly") ==
             ~s({"grace":"5m","schedule":"0 2 * * *","timezone":"UTC","budget":{"cost":2},"tags":["reports","gocron","gocron:billing"],"name":"nightly"})

    assert stored(cw, "twice") == ~s({"tags":["gocron","gocron:billing"],"name":"twice"})
    assert stored(cw, "odd") == ~s({"tags":["gocron","gocron:billing"],"name":"odd"})

    assert Enum.zip(wheres(errors), messages(errors)) == [
             {"declaring entry 2",
              ~s|cronwatch: "twice" is run by 2 gocron entries on different schedules (0 3 * * *; 0 4 * * *), so it is watched without a schedule; give each a name of its own|},
             {"declaring entry 4", "cronwatch: entry 4 cannot be read"}
           ]

    # Declaring again changes nothing and reports nothing again; an entry
    # gone keeps its runs and loses its schedule.
    first = Watch.job(w, "nightly")
    Watch.declare(w, [nightly, entry("twice", "entry 2", "0 3 * * *"), entry("twice", "entry 3", "0 4 * * *")])
    assert Watch.job(w, "nightly") === first
    assert length(messages(errors)) == 2, "reported once"
    Watch.declare(w, [])
    Watch.settle(w)

    assert stored(cw, "nightly") ==
             ~s|{"description":"A scheduled task (no longer scheduled)","tags":["reports","gocron","gocron:billing"],"grace":"5m","budget":{"cost":2},"name":"nightly"}|
  end

  test "unschedule takes only this app's jobs" do
    store = Stores.memory()
    %{cw: earlier} = shared(store)

    for {name, tag} <- [{"invoices", "gocron:billing"}, {"dunning", "gocron:billing"}, {"reindex", "gocron:search"}] do
      Cronwatch.job!(name,
        schedule: "0 1 * * *",
        tags: ["gocron", tag],
        timeout: "2h",
        description: "Bills",
        instance: earlier
      )
    end

    Cronwatch.check!(instance: earlier)

    %{cw: cw} = shared(store)
    w = watch(cw, "gocron", "billing", "gocron")
    assert Watch.unschedule(w) == {:ok, []}, "a watch that saw no entry takes nothing"
    Watch.declare(w, [entry("invoices", "x", "0 1 * * *")])
    assert Watch.unschedule(w) == {:ok, ["dunning"]}
    # Written without a check (the Go audit: a process that never checks left
    # the schedule in the store).
    assert stored(cw, "dunning") ==
             ~s|{"description":"Bills (no longer scheduled)","tags":["gocron","gocron:billing"],"timeout":"2h","name":"dunning"}|

    assert stored(cw, "reindex") =~ ~s("schedule":"0 1 * * *"), "reindex is search's"
    assert stored(cw, "invoices") =~ ~s("schedule":"0 1 * * *"), "invoices kept"
  end

  test "a fallback keeps the stored definition" do
    store = Stores.memory()
    %{cw: scheduler} = shared(store)

    Cronwatch.job!("report",
      grace: "5m",
      schedule: "0 2 * * *",
      timezone: "UTC",
      timeout: 7_200_000,
      max_duration: "30m",
      budget: [cost: 2, rows: 10],
      failures_before_alert: 2,
      description: "Nightly",
      tags: ["river", "river:billing"],
      expect: "Report written",
      instance: scheduler
    )

    Cronwatch.check!(instance: scheduler)
    before = stored(scheduler, "report")

    %{cw: worker} = shared(store)
    w = watch(worker, "river", "billing", "River")
    job = Watch.fallback(w, "report", [])
    assert JS.stringify(job.definition) == before
    assert Watch.fallback(w, "report", []) === job
    Cronwatch.run(job, fn _ -> :ok end)
    [run] = Cronwatch.runs!("report", 1, instance: worker)
    assert run.error == ~s(Output did not contain "Report written"), "the expect rule holds"
    assert stored(worker, "report") == before, "the stored definition is unchanged"

    # A job of another app's is not taken for this one's.
    %{cw: fresh} = shared(store)
    other = watch(fresh, "river", "search", "River")
    made = Watch.fallback(other, "report", grace: "1m")
    assert JS.stringify(made.definition) == ~s({"grace":"1m","tags":["river","river:search"],"name":"report"})
  end

  test "declaring writes the jobs to the store" do
    %{cw: cw, errors: errors} = make(alerts: [])
    w = watch(cw, "asynq", "billing", "Asynq")
    Watch.declare(w, [entry("invoices", "x", "0 1 * * *")])
    Watch.settle(w)
    assert stored(cw, "invoices") == ~s({"schedule":"0 1 * * *","tags":["asynq","asynq:billing"],"name":"invoices"})
    assert messages(errors) == []
  end

  test "a job another process unscheduled is put back" do
    store = Stores.memory()
    %{cw: newer} = shared(store)
    wn = watch(newer, "gocron", "billing", "gocron")
    Watch.declare(wn, [entry("old", "a", "0 1 * * *"), entry("added", "b", "0 2 * * *")])
    Watch.settle(wn)
    Cronwatch.check!(instance: newer)

    %{cw: older} = shared(store)
    wo = watch(older, "gocron", "billing", "gocron")
    Watch.declare(wo, [entry("old", "a", "0 1 * * *")])
    {:ok, _} = Watch.unschedule(wo)
    refute stored(older, "added") =~ ~s("schedule"), "the older release took it out"

    {:ok, _} = Watch.unschedule(wn)
    assert stored(newer, "added") == ~s({"schedule":"0 2 * * *","tags":["gocron","gocron:billing"],"name":"added"})
  end

  # The Go audit: a lookup that failed once had the fallback declare the job
  # without its schedule, keep that for good, and write it over the
  # scheduler's definition at the next run.
  test "a fallback does not declare over a store it could not read" do
    {flaky, agent} = Flaky.new(Stores.memory())
    %{cw: scheduler} = make(store: Stores.option(flaky), alerts: [])
    Cronwatch.job!("report", schedule: "0 2 * * *", tags: ["river", "river:billing"], instance: scheduler)
    Cronwatch.check!(instance: scheduler)
    before = stored(scheduler, "report")

    %{cw: worker, errors: errors} = make(store: Stores.option(flaky), alerts: [])
    w = watch(worker, "river", "billing", "River")
    Flaky.break(agent, :get_job)
    assert Watch.fallback(w, "report", []) == nil, "declared without reading the store"
    assert length(messages(errors)) == 1
    Flaky.mend(agent)
    job = Watch.fallback(w, "report", [])
    assert job
    Cronwatch.run(job, fn _ -> :ok end)
    assert stored(worker, "report") == before, "the schedule is kept"
  end

  # The audit: a store that failed while a declaration was written left the
  # writer marked busy, so nothing was written again and settle waited for
  # good.
  test "a declaration whose store fails does not stop the next" do
    {hooked, agent} = Stores.hooked(Stores.memory())
    %{cw: cw, errors: errors} = make(store: Stores.option(hooked), alerts: [])
    w = watch(cw, "river", "billing", "River")

    Stores.hook(agent, :get_job, fn _args, _call ->
      Stores.unhook(agent, :get_job)
      raise "the store fell over"
    end)

    Watch.declare(w, [entry("first", "x", "0 1 * * *")])
    Watch.settle(w)
    assert [{"declaring first", _}] = Agent.get(errors, & &1)
    assert hd(messages(errors)) =~ "the store fell over"
    Watch.declare(w, [entry("first", "x", "0 1 * * *"), entry("second", "y", "0 2 * * *")])
    Watch.settle(w)
    assert stored(cw, "second") =~ "0 2 * * *"
  end

  test "a declaration whose store hangs gives up at the deadline" do
    Application.put_env(:cronwatch, :bridge_save_timeout, 200)
    on_exit(fn -> Application.delete_env(:cronwatch, :bridge_save_timeout) end)
    {hooked, agent} = Stores.hooked(Stores.memory())
    %{cw: cw, errors: errors} = make(store: Stores.option(hooked), alerts: [])
    w = watch(cw, "river", "billing", "River")
    Stores.hook(agent, :get_job, fn _args, _call -> Process.sleep(:infinity) end)
    Watch.declare(w, [entry("first", "x", "0 1 * * *")])
    Watch.settle(w)

    assert messages(errors) == [
             ~s(writing the declaration of "first" took longer than 0.2 seconds; gave up)
           ]
  end

  # The Go audit: an entry declared while unschedule read the store was taken
  # for gone, and its job lost its schedule for the life of the process.
  test "unschedule keeps an entry declared meanwhile" do
    {hooked, agent} = Stores.hooked(Stores.memory())
    %{cw: earlier} = make(store: Stores.option(hooked), alerts: [])
    Cronwatch.job!("added", schedule: "0 2 * * *", tags: ["gocron", "gocron:billing"], instance: earlier)
    Cronwatch.check!(instance: earlier)

    %{cw: cw} = make(store: Stores.option(hooked), alerts: [])
    w = watch(cw, "gocron", "billing", "gocron")
    entries = [entry("first", "x", "0 1 * * *")]
    Watch.declare(w, entries)
    Watch.settle(w)

    Stores.hook(agent, :list_jobs, fn _args, call ->
      Stores.unhook(agent, :list_jobs)
      jobs = call.()
      Watch.declare(w, entries ++ [entry("added", "y", "0 2 * * *")])
      jobs
    end)

    assert Watch.unschedule(w) == {:ok, []}
    added = Enum.find(Cronwatch.defined_jobs(instance: cw), &(&1.name == "added"))
    assert JS.Object.get(added.definition, "schedule") == "0 2 * * *", "kept"
    Watch.settle(w)
    assert stored(cw, "added") =~ ~s("schedule":"0 2 * * *")
  end

  test "options_of rebuilds an expect pattern and a custom function" do
    {:ok, job} = Cronwatch.Job.new(:x, "x", [expect: {:matches, "done \\d+", "i"}], [])
    rebuilt = Bridge.options_of(job.definition)
    {:ok, again} = Cronwatch.Job.new(:x, "x", rebuilt, [])
    assert JS.stringify(again.definition) == JS.stringify(job.definition)
    assert Cronwatch.Serialize.check(again.expect, "Done 12") == nil, "run by the JavaScript engine, /i and all"
    assert Cronwatch.Serialize.check(again.expect, "nothing")

    {:ok, custom} = Cronwatch.Job.new(:x, "x", [expect: fn _ -> false end], [])
    {:ok, back} = Cronwatch.Job.new(:x, "x", Bridge.options_of(custom.definition), [])
    assert JS.stringify(back.definition) == ~s({"name":"x","expect":"custom function"})
  end

  test "a stored pattern the engine cannot read passes and is written back as it was" do
    definition = JS.parse!(~S|{"name":"x","expect":"matches /\\p{L}+/u"}|)
    {:ok, job} = Cronwatch.Job.new(:x, "x", Bridge.options_of(definition), [])
    assert JS.stringify(job.definition) == ~S|{"name":"x","expect":"matches /\\p{L}+/u"}|
    assert Cronwatch.Serialize.check(job.expect, "anything") == nil
  end

  test "a stored pattern that backtracks without end fails" do
    definition = JS.parse!(~s({"name":"x","expect":"matches /.*x/"}))
    {:ok, job} = Cronwatch.Job.new(:x, "x", Bridge.options_of(definition), [])
    assert Cronwatch.Serialize.check(job.expect, String.duplicate("a", 32_000)) == "Output did not match /.*x/"
    assert Cronwatch.Serialize.check(job.expect, "aax") == nil
  end
end
