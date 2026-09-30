defmodule Cronwatch.Test.FakeCron do
  @moduledoc """
  `cron.job`, `cron.job_run_details` and the settings a role can read, in
  memory, answering the source's queries through its `query:` option with
  ids as text, as the SDK's fakeCron() gives them.
  """

  def new do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          jobs: [],
          details: [],
          settings: %{"cron.timezone" => "GMT", "cron.log_run" => "on"},
          runid: 0,
          queries: []
        }
      end)

    agent
  end

  def job(f, jobid, jobname, schedule, active \\ true) do
    Agent.update(f, fn t ->
      %{t | jobs: t.jobs ++ [%{jobid: jobid, jobname: jobname, schedule: schedule, active: active}]}
    end)
  end

  @doc "A run detail; times are epoch milliseconds or nil for NULL. Answers its runid."
  def add(f, jobid, status, start, stop, message \\ nil) do
    Agent.get_and_update(f, fn t ->
      runid = t.runid + 1
      d = %{runid: runid, jobid: jobid, status: status, message: message, start: start, end: stop}
      {runid, %{t | runid: runid, details: t.details ++ [d]}}
    end)
  end

  def update(f, runid, change) do
    Agent.update(f, fn t ->
      %{t | details: Enum.map(t.details, fn d -> if d.runid == runid, do: change.(d), else: d end)}
    end)
  end

  def update_job(f, jobid, change) do
    Agent.update(f, fn t -> %{t | jobs: Enum.map(t.jobs, fn j -> if j.jobid == jobid, do: change.(j), else: j end)} end)
  end

  def remove_job(f, jobid), do: Agent.update(f, fn t -> %{t | jobs: Enum.reject(t.jobs, &(&1.jobid == jobid))} end)
  def settings(f, settings), do: Agent.update(f, &%{&1 | settings: settings})
  def queries(f), do: Agent.get(f, & &1.queries)

  @doc "The source's `query:` option over the fake."
  def query(f), do: fn sql, params -> Agent.get_and_update(f, &answer(&1, sql, params)) end

  defp answer(t, sql, params) do
    t = %{t | queries: t.queries ++ [sql]}

    rows =
      cond do
        sql =~ "pg_settings" ->
          case t.settings[hd(params)] do
            nil -> []
            v -> [%{"setting" => v}]
          end

        sql =~ "FROM cron.job ORDER BY" ->
          for j <- t.jobs do
            %{
              "jobid" => Integer.to_string(j.jobid),
              "jobname" => j.jobname,
              "schedule" => j.schedule,
              "database" => "postgres",
              "username" => "postgres",
              "active" => j.active
            }
          end

        sql =~ "ORDER BY d.runid DESC" ->
          [jobid] = params

          t.details
          |> Enum.filter(&(&1.jobid == jobid))
          |> Enum.sort_by(& &1.runid, :desc)
          |> Enum.take(20)
          |> rows()

        sql =~ "unnest" ->
          [ids, afters, open] = Enum.map(params, &array/1)
          after_of = Map.new(Enum.zip(ids, afters))

          t.details
          |> Enum.filter(fn d ->
            (Map.has_key?(after_of, d.jobid) and d.runid > after_of[d.jobid]) or d.runid in open
          end)
          |> Enum.sort_by(& &1.runid)
          |> Enum.take(500)
          |> rows()

        true ->
          raise "unexpected query #{sql}"
      end

    {{:ok, rows}, t}
  end

  defp rows(details) do
    for d <- details do
      %{
        "runid" => Integer.to_string(d.runid),
        "jobid" => Integer.to_string(d.jobid),
        "status" => d.status,
        "return_message" => d.message,
        "start_time" => d.start,
        "end_time" => d.end
      }
    end
  end

  defp array("{" <> rest) do
    rest |> String.trim_trailing("}") |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)
  end
end

defmodule Cronwatch.Sources.PgCronTest do
  @moduledoc """
  The pg_cron source against a fake, as the SDK's pgcron.test.ts and the Go
  and Rust ports have it, and the replay of conformance/pgcron.json. The
  tests against a real pg_cron are in pg_cron_server_test.exs.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client

  alias Cronwatch.Alert
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Sources.PgCron
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Conformance
  alias Cronwatch.Test.FakeCron
  alias Cronwatch.Test.Repo
  alias Cronwatch.Test.Stores

  @t0 Clock.t0()
  @min 60_000
  @hour 60 * @min
  @day 24 * @hour

  defp utc(y, m, d, h, mi, s), do: JS.date_utc(y, m - 1, d, h, mi, s)
  defp pid(runid), do: "pgcron:#{runid}"

  # An instance watching the fake through the source.
  defp kit(cron, opts \\ []) do
    {clock, opts} = Keyword.pop(opts, :clock)
    {store, opts} = Keyword.pop(opts, :store)
    source = {PgCron, [query: FakeCron.query(cron)] ++ opts}
    base = [sources: [source]]
    base = if clock, do: base ++ [clock_ref: clock], else: base
    base = if store, do: base ++ [store: Stores.option(store)], else: base
    make(base)
  end

  defp check(k), do: Cronwatch.check!(instance: k.cw)
  defp runs(k, name, limit \\ 100), do: Cronwatch.runs!(name, limit, instance: k.cw)
  defp run(k, id), do: Cronwatch.get_run!(id, instance: k.cw)

  defp summary(result, name) do
    Enum.find(result.jobs, &(&1.name == name)) || flunk("no job #{name}")
  end

  defp schedule(s), do: Object.get(s.definition, "schedule")
  defp description(s), do: Object.get(s.definition, "description")

  defp types_and_jobs(alerts), do: alerts |> Enum.map(&"#{&1.type} #{&1.job}") |> Enum.sort()

  # The errors that are not about settings or row level security.
  defp others(k), do: Enum.reject(messages(k.errors), &(&1 =~ "cron." or &1 =~ "row level"))

  test "conformance/pgcron.json" do
    f = Conformance.fixture("pgcron")
    failures = Conformance.failures()

    failures =
      Enum.reduce(Conformance.list(f, "schedules"), failures, fn c, acc ->
        input = Conformance.field(c, "schedule")
        Conformance.same(acc, "schedule #{JS.quote(input)}", PgCron.schedule(input), Conformance.field(c, "result"))
      end)

    failures =
      Enum.reduce(Conformance.list(f, "names"), failures, fn c, acc ->
        j = Conformance.field(c, "job")
        job = %PgCron.Job{job_id: Object.get(j, "jobid"), job_name: Object.get(j, "jobname")}
        Conformance.same(acc, "name of #{JS.stringify(j)}", PgCron.job_name(job), Conformance.field(c, "name"))
      end)

    failures =
      Enum.reduce(Conformance.list(f, "runs"), failures, fn c, acc ->
        row = c |> Conformance.field("row") |> Object.to_list() |> Map.new()
        fallback = Conformance.field(c, "fallbackAt") || @t0

        got =
          case PgCron.run_of(row, "db:j", "pgcron:db:", fallback) do
            nil -> nil
            r -> Run.to_value(r)
          end

        Conformance.same(acc, "run of #{JS.stringify(Object.new(Map.to_list(row)))}", got, Conformance.field(c, "run"))
      end)

    Conformance.check!(failures, "pgcron")
    assert PgCron.hold_ms() == Conformance.field(f, "holdMs")

    count =
      length(Conformance.list(f, "schedules")) + length(Conformance.list(f, "names")) +
        length(Conformance.list(f, "runs"))

    assert count == 29
  end

  test "a pick, job_name or options function that fails fails only its job, reported once" do
    c = Clock.new()
    cron = FakeCron.new()
    for {id, name} <- [{1, "one"}, {2, "two"}, {3, "three"}, {4, "four"}], do: FakeCron.job(cron, id, name, "0 * * * *")
    {:ok, broken} = Agent.start_link(fn -> MapSet.new() end)
    fault? = fn what, id -> Agent.get(broken, &MapSet.member?(&1, {what, id})) end
    set = fn faults -> Agent.update(broken, fn _ -> MapSet.new(faults) end) end

    k =
      kit(cron,
        clock: c,
        store: Stores.memory(),
        pick: fn j ->
          if fault?.(:pick, j.job_id), do: raise("pick broke")
          true
        end,
        job_name: fn j ->
          cond do
            fault?.(:raise, j.job_id) -> raise "name broke"
            fault?.(:throw, j.job_id) -> throw(:no_name)
            fault?.(nil, j.job_id) -> nil
            true -> "j-#{j.job_name}"
          end
        end,
        options: fn j ->
          if fault?.(:options, j.job_id), do: exit(:options_broke)
          []
        end
      )

    names = fn result -> Enum.map(result.jobs, & &1.name) end
    tail = "; it keeps its last declaration until that works"

    # First sight, with job 1's name function raising and job 2's answering nil: only those two are skipped.
    set.([{:raise, 1}, {nil, 2}])
    first = FakeCron.add(cron, 3, "succeeded", @t0 - 60_000, @t0 - 59_000, "ok")
    assert names.(check(k)) == ["j-four", "j-three"]
    assert run(k, pid(first)).job == "j-three"

    assert others(k) == [
             "pg_cron job 1: job_name raised RuntimeError: name broke" <> tail,
             "pg_cron job 2: job_name returned nil, not a name" <> tail
           ]

    # Once they work, both are declared; then every function fails for jobs already declared.
    set.([])
    assert names.(check(k)) == ["j-four", "j-one", "j-three", "j-two"]
    set.([{:pick, 1}, {:throw, 2}, {:options, 3}, {nil, 4}])
    before = length(others(k))
    one = FakeCron.add(cron, 1, "failed", @t0 + 1000, @t0 + 2000, "ERROR:  one")
    three = FakeCron.add(cron, 3, "succeeded", @t0 + 1000, @t0 + 2000, "ok")
    Clock.advance(c, 5000)
    check(k)
    result = check(k)

    assert Enum.drop(others(k), before) == [
             "pg_cron job 1: the pick function raised RuntimeError: pick broke" <> tail,
             "pg_cron job 2: job_name threw :no_name" <> tail,
             "pg_cron job 3: the options function exited with :options_broke" <> tail,
             "pg_cron job 4: job_name returned nil, not a name" <> tail
           ],
           "each reported once, over two syncs"

    # Each keeps its name and schedule, is not retired, and its runs are still copied.
    for s <- result.jobs do
      assert schedule(s) == "0 * * * *", s.name
      refute description(s) =~ ~r/no longer|renamed/, s.name
    end

    assert run(k, pid(one)).job == "j-one"
    assert run(k, pid(three)).job == "j-three"

    # Working again and then failing again is reported again.
    set.([])
    check(k)
    set.([{:pick, 1}])
    check(k)
    assert length(others(k)) == before + 5
    assert List.last(others(k)) =~ ~r/^pg_cron job 1: the pick function raised/
  end

  test "jobs are declared, history is copied quietly, and imports are idempotent" do
    c = Clock.new()
    cron = FakeCron.new()
    FakeCron.job(cron, 1, "nightly vacuum", "0 3 * * *")
    FakeCron.job(cron, 2, nil, "10 seconds")
    FakeCron.job(cron, 3, "paused", "0 * * * *", false)
    FakeCron.job(cron, 4, "other", "0 * * * *")
    three = utc(2026, 1, 5, 3, 0, 0)
    for i <- 24..1//-1, do: FakeCron.add(cron, 1, "succeeded", three - i * @day, three - i * @day + 5000, "VACUUM")
    FakeCron.add(cron, 1, "failed", three, three + 2000, "ERROR:  deadlock detected\n")
    store = Stores.memory()
    opts = [clock: c, store: store, pick: &(&1.job_id != 4), prefix: "db:"]
    k = kit(cron, opts)

    first = check(k)
    assert Enum.map(first.jobs, & &1.name) == ["db:nightly-vacuum", "db:paused", "db:pg_cron:2"]
    vacuum = summary(first, "db:nightly-vacuum")
    assert schedule(vacuum) == "0 3 * * *"
    assert Object.get(vacuum.definition, "timezone") == "UTC"
    assert Object.get(vacuum.definition, "tags") == ["pg_cron"]
    assert schedule(summary(first, "db:pg_cron:2")) == "every 10s"
    assert schedule(summary(first, "db:paused")) == nil, "a paused job is not expected to run"
    [newest, next | _] = all = runs(k, "db:nightly-vacuum")
    assert length(all) == 20, "twenty newest runs copied on first sight"
    assert newest.id == "pgcron:db:25"
    assert newest.status == "failed"
    assert newest.error == "ERROR:  deadlock detected"
    assert newest.duration_ms == 2000
    assert newest.trigger == "pg_cron"
    assert next.output == "VACUUM"
    assert Capture.types(k.alerts) == ["failed"], "only the newest finished run is judged; history does not alert"

    check(k)
    # A new instance over the same store.
    k = kit(cron, opts)
    check(k)
    assert length(runs(k, "db:nightly-vacuum")) == 20, "a re-import, even after a restart, adds nothing"
    assert Capture.types(k.alerts) == [], "no new alerts"

    # A run not yet started holds the cursor; the run after it is copied
    # now and it is copied once it starts.
    starting = FakeCron.add(cron, 2, "starting", nil, nil)
    FakeCron.add(cron, 2, "succeeded", @t0 - 5000, @t0 - 4000, "1 row")
    Clock.advance(c, 1000)
    check(k)
    assert Enum.map(runs(k, "db:pg_cron:2", 20), & &1.id) == ["pgcron:db:27"]
    FakeCron.update(cron, starting, &%{&1 | status: "running", start: @t0 - 3000})
    check(k)
    assert run(k, "pgcron:db:26").status == "running"
    FakeCron.update(cron, starting, &%{&1 | status: "failed", end: @t0 - 1000, message: "ERROR:  boom"})
    Clock.advance(c, 1000)
    check(k)
    done = run(k, "pgcron:db:26")
    assert done.status == "failed"
    assert done.duration_ms == 2000
    assert Capture.types(k.alerts) == ["failed"], "a run that was running and then failed is judged when it finishes"

    # The nightly job stops running: missed, from its schedule, with no run
    # details at all.
    Clock.set(c, utc(2026, 1, 6, 3, 11, 0))
    FakeCron.add(cron, 2, "succeeded", Clock.now(c) - 2000, Clock.now(c) - 1000, "1 row")
    later = check(k)
    assert types_and_jobs(later.alerts) == ["missed db:nightly-vacuum", "recovered db:pg_cron:2"]
    assert check(k).alerts == [], "each condition alerts once"

    # Unscheduled: its name keeps its history but loses its schedule, so it
    # is never missed again, and the missed alert it had open closes with a
    # recovery that says so.
    FakeCron.remove_job(cron, 1)
    Clock.set(c, utc(2026, 1, 8, 3, 11, 0))
    gone = check(k)
    now = summary(gone, "db:nightly-vacuum")
    assert schedule(now) == nil
    assert description(now) =~ "no longer watched"
    assert now.open == ["failed"], "its failure stays open until a successful run"
    [closed] = Enum.filter(gone.alerts, &(&1.job == "db:nightly-vacuum"))
    assert closed.type == "recovered"
    assert closed.title == "db:nightly-vacuum is no longer scheduled"

    assert JS.stringify(Object.get(Alert.to_value(closed), "details")) ==
             ~s({"after":["missed"],"reason":"unscheduled","since":#{utc(2026, 1, 6, 3, 11, 0)}})

    assert Enum.all?(check(k).alerts, &(&1.job != "db:nightly-vacuum")), "once"
    assert length(runs(k, "db:nightly-vacuum")) == 20, "its history is kept"
  end

  test "a job's options apply, and a schedule it cannot read is reported" do
    cron = FakeCron.new()
    FakeCron.job(cron, 1, "odd", "not a schedule")
    k = kit(cron, options: [grace: "1m", expect: {:matches, "rows?", ""}])
    now = System.system_time(:millisecond)
    FakeCron.add(cron, 1, "succeeded", now - 1000, now, "nothing")
    [job] = check(k).jobs
    assert schedule(job) == nil
    assert Object.get(job.definition, "grace") == "1m"
    assert Enum.join(messages(k.errors), "\n") =~ "watching it without a schedule"
    [r] = runs(k, "odd", 20)
    assert r.status == "failed", "expect applies to imported output"
    assert r.error =~ "did not match"
  end

  test "a run cut off by a restart is recorded, and one held run never stops the others" do
    c = Clock.new()
    cron = FakeCron.new()
    FakeCron.job(cron, 1, "fast", "30 seconds")
    FakeCron.job(cron, 2, "other", "0 * * * *")
    k = kit(cron, clock: c)
    FakeCron.add(cron, 1, "succeeded", @t0 - 60_000, @t0 - 59_000, "1 row")
    check(k)
    # pg_cron restarts while a run is queued: it marks it failed, "server
    # restarted", with no times at all.
    restarted = FakeCron.add(cron, 1, "failed", nil, nil, "server restarted")
    # The fast job then runs far more than a page's worth, and the other job
    # fails after all of them.
    for i <- 0..519, do: FakeCron.add(cron, 1, "succeeded", @t0 - 50_000 + i, @t0 - 50_000 + i + 1, "1 row")
    failure = FakeCron.add(cron, 2, "failed", @t0 - 1000, @t0 - 500, "ERROR:  disk full")
    queued = FakeCron.add(cron, 1, "starting", nil, nil)
    Clock.advance(c, 1000)
    check(k)
    check(k)
    cut = run(k, pid(restarted))
    assert cut.status == "failed"
    assert cut.error == "server restarted"
    assert cut.started_at == @t0 - 60_000, "placed at the job's newest run before it"
    assert run(k, pid(failure)).status == "failed", "the other job's failure is not starved"
    assert Enum.any?(Capture.alerts(k.alerts), &(&1.type == "failed" and &1.job == "other"))
    assert run(k, pid(queued)) == nil, "a queued run is held"

    # Held only so long: then it is copied as running from when it was
    # first seen, and a late start updates nothing but its end.
    Clock.advance(c, 11 * @min)
    check(k)
    waiting = run(k, pid(queued))
    assert waiting.status == "running"
    assert waiting.started_at == @t0 + 1000
    now = Clock.now(c)
    FakeCron.update(cron, queued, &%{&1 | status: "succeeded", start: now - 2000, end: now - 1000})
    Clock.advance(c, 1000)
    check(k)
    assert run(k, pid(queued)).status == "ok"
    assert others(k) == []
  end

  test "first sight never judges history" do
    c = Clock.new()
    cron = FakeCron.new()
    FakeCron.job(cron, 1, "nightly", "0 3 * * *")

    for i <- 0..29,
        do: FakeCron.add(cron, 1, "failed", @t0 - (40 - i) * @hour, @t0 - (40 - i) * @hour + 1000, "ERROR:  old")

    FakeCron.add(cron, 1, "failed", nil, nil, "server restarted")

    for i <- 0..18 do
      start = @t0 - (10 * @hour - div(i * @hour, 2))
      FakeCron.add(cron, 1, "succeeded", start, start + 1000, "ok")
    end

    k = kit(cron, clock: c)
    check(k)
    check(k)
    assert length(runs(k, "nightly", 500)) == 20, "only the newest twenty are copied"
    assert Capture.types(k.alerts) == [], "no alert from history"
  end

  test "a renamed job leaves no scheduled ghost" do
    c = Clock.new()
    cron = FakeCron.new()
    FakeCron.job(cron, 1, "rollup", "*/5 * * * *")
    FakeCron.add(cron, 1, "succeeded", @t0 - 60_000, @t0 - 59_000, "1 row")
    store = Stores.memory()
    k = kit(cron, clock: c, store: store)
    check(k)
    FakeCron.update_job(cron, 1, &%{&1 | jobname: "rollup-v2"})
    running = FakeCron.add(cron, 1, "running", @t0 - 1000, nil)
    check(k)
    find = fn list, n -> Enum.find(list, &(&1.name == n)) end
    jobs = Cronwatch.jobs!(instance: k.cw)
    old = find.(jobs, "rollup")
    assert schedule(old) == nil, "the old name has no schedule"
    assert description(old) =~ "renamed to rollup-v2"
    assert schedule(find.(jobs, "rollup-v2")) == "*/5 * * * *"
    run_id = pid(running)
    assert run(k, run_id).job == "rollup-v2", "the running run is the new name's"
    FakeCron.update(cron, running, &%{&1 | status: "succeeded", end: @t0})
    Clock.advance(c, @hour)
    FakeCron.add(cron, 1, "succeeded", Clock.now(c) - 2000, Clock.now(c) - 1000, "1 row")
    check(k)
    assert run(k, run_id).status == "ok"
    assert Enum.all?(Capture.alerts(k.alerts), &(&1.job != "rollup")), "the old name alerted"

    # Renamed again while no process watched: the next instance retires the
    # name the store still schedules.
    FakeCron.update_job(cron, 1, &%{&1 | jobname: "rollup-v3"})
    next = kit(cron, clock: c, store: store)
    Clock.advance(c, @min)
    check(next)
    jobs = Cronwatch.jobs!(instance: next.cw)
    assert schedule(find.(jobs, "rollup-v2")) == nil, "v2 unscheduled"
    assert description(find.(jobs, "rollup-v2")) =~ "renamed to rollup-v3"
    assert schedule(find.(jobs, "rollup-v3")) == "*/5 * * * *", "v3 scheduled"
    assert runs(next, "rollup-v3", 20) == [], "runs already copied under an old name are not copied again"
    Clock.advance(c, @hour)
    result = check(next)

    for a <- Capture.alerts(k.alerts) ++ Capture.alerts(next.alerts) ++ result.alerts do
      assert a.job == "rollup-v3", "only the job's current name can be missed: #{a.type} #{a.job}"
    end

    assert others(k) == [] and others(next) == []
  end

  test "a job paused or renamed while missed closes missed with a recovery" do
    c = Clock.new()
    cron = FakeCron.new()
    FakeCron.job(cron, 1, "hourly", "0 * * * *")
    FakeCron.job(cron, 2, "rollup", "0 * * * *")
    FakeCron.add(cron, 1, "succeeded", @t0 - 3 * @hour, @t0 - 3 * @hour + 1000)
    FakeCron.add(cron, 2, "succeeded", @t0 - 3 * @hour, @t0 - 3 * @hour + 1000)
    k = kit(cron, clock: c)
    check(k)
    assert types_and_jobs(Capture.alerts(k.alerts)) == ["missed hourly", "missed rollup"]
    FakeCron.update_job(cron, 1, &%{&1 | active: false})
    FakeCron.update_job(cron, 2, &%{&1 | jobname: "rollup-v2"})
    Clock.advance(c, @min)
    r = check(k)

    assert r.alerts |> Enum.map(&"#{&1.type} #{&1.job} #{&1.title}") |> Enum.sort() == [
             "recovered hourly hourly is no longer scheduled",
             "recovered rollup rollup is no longer scheduled"
           ]

    Clock.advance(c, @min)
    assert check(k).alerts == [], "nothing more"
  end

  test "a run marked timeout by a check is still read, and its late finish recorded" do
    c = Clock.new()
    cron = FakeCron.new()
    FakeCron.job(cron, 1, "vacuum", "0 3 * * *")
    k = kit(cron, clock: c, options: [timeout: "30m"])
    long = FakeCron.add(cron, 1, "running", @t0, nil)
    id = pid(long)
    check(k)
    assert run(k, id).status == "running"
    Clock.advance(c, 45 * @min)
    check(k)
    assert run(k, id).status == "timeout"
    assert Capture.types(k.alerts) == ["stuck"]
    Clock.advance(c, 10 * @min)
    now = Clock.now(c)
    FakeCron.update(cron, long, &%{&1 | status: "succeeded", end: now - 60_000, message: "VACUUM"})
    check(k)
    done = run(k, id)
    assert done.status == "ok"
    assert done.output == "VACUUM"
    assert Capture.types(k.alerts) == ["stuck", "recovered"]
    assert Cronwatch.job_summary!("vacuum", instance: k.cw).health == "healthy"
  end

  test "settings a role may not read are assumed and reported once" do
    cron = FakeCron.new()
    FakeCron.settings(cron, %{})
    FakeCron.job(cron, 1, "nightly", "0 3 * * *")
    k = kit(cron)
    [job] = check(k).jobs
    check(k)
    assert Object.get(job.definition, "timezone") == "UTC"
    errors = messages(k.errors)
    assert Enum.count(errors, &(&1 =~ "cron.timezone")) == 1, "reported once: #{inspect(errors)}"
    refute Enum.any?(errors, &(&1 =~ "log_run")), "log_run unreadable is taken as on"
  end

  test "the source's queries, and jobs picked by name or id" do
    cron = FakeCron.new()
    FakeCron.settings(cron, %{"cron.timezone" => "GMT", "cron.log_run" => "off"})
    FakeCron.job(cron, 1, "nightly", "0 3 * * *")
    FakeCron.add(cron, 1, "succeeded", @t0 - 1000, @t0)
    k = kit(cron, clock: Clock.new(), timezone: "America/New_York", job_ids: [1])
    [job] = check(k).jobs
    assert schedule(job) == nil, "no schedule when pg_cron records no runs"
    assert runs(k, "nightly", 20) == [], "no runs read"

    for q <- FakeCron.queries(cron) do
      refute q =~ "current_setting" or q =~ "COMMIT" or q =~ "ROLLBACK",
             "a query that could end the caller's transaction: #{q}"
    end

    assert Enum.join(messages(k.errors), "\n") =~ "cron.log_run is off"

    # A job not picked by name or id is not declared.
    cron2 = FakeCron.new()
    FakeCron.job(cron2, 1, "a", "0 3 * * *")
    FakeCron.job(cron2, 2, "b", "0 3 * * *")
    k2 = kit(cron2, clock: Clock.new(), jobs: ["b"])
    assert Enum.map(check(k2).jobs, & &1.name) == ["b"]
  end

  test "the options are checked, and a repo that is not Postgres is refused" do
    cron = FakeCron.new()
    k = kit(cron, clock: Clock.new(), colour: "red")
    check(k)
    assert Enum.join(messages(k.errors), "\n") =~ "Cronwatch.Sources.PgCron: unknown option :colour"
    assert wheres(k.errors) == ["source pg_cron"]

    k = make(sources: [{PgCron, repo: Repo}])
    check(k)

    assert Enum.join(messages(k.errors), "\n") =~
             "needs a Postgres repo: Cronwatch.Test.Repo uses Ecto.Adapters.SQLite3"

    k = make(sources: [{PgCron, []}])
    check(k)
    assert Enum.join(messages(k.errors), "\n") =~ "needs :repo"
    assert PgCron.name([]) == "pg_cron"
  end

  test "the helpers read as the SDK does" do
    assert PgCron.schedule(" 1  2 * * * 7 ") == "1 2 * * *"
    assert PgCron.schedule("0 0 $ * *") == "0 0 L * *"
    assert PgCron.schedule("5 Seconds") == "every 5s"
    assert PgCron.schedule("05 seconds") == "every 5s"
    assert PgCron.schedule("@REBOOT") == nil
    assert PgCron.schedule("") == ""
    assert PgCron.description_job_id("pg_cron job 12 in cw as postgres") == 12
    assert PgCron.description_job_id("pg_cron job x in cw") == nil
    assert PgCron.description_job_id(nil) == nil
    assert PgCron.array_of([1, 22, 3]) == "{1,22,3}"
    assert PgCron.array_of([]) == "{}"
    assert PgCron.run_id_of("pgcron:db:42", "pgcron:db:") == 42
    assert PgCron.run_id_of("pgcron:db: 7 ", "pgcron:db:") == 7
    assert PgCron.run_id_of("pgcron:db:", "pgcron:db:") == 0
    assert PgCron.run_id_of("pgcron:db:1.5", "pgcron:db:") == nil
    assert PgCron.run_id_of("pgcron:other:1", "pgcron:db:") == nil
    assert PgCron.job_name(%PgCron.Job{job_id: 3, job_name: "  --weird name!! v2 "}) == "weird-name-v2-"
  end
end
