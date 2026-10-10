defmodule Cronwatch.Test.PgCronServer do
  @moduledoc "What the pg_cron server tests share."

  alias Cronwatch.Test.PgRepo
  alias Cronwatch.Test.Servers

  @doc "A name no other test uses, for jobs, roles, and databases."
  def tag(label), do: "cwex#{label}#{System.unique_integer([:positive])}"

  @doc "`url` with its database, user, or password replaced."
  def url_with(url, changes) do
    uri = URI.parse(url)

    uri =
      Enum.reduce(changes, uri, fn
        {:database, db}, u -> %{u | path: "/" <> db}
        {:user, {user, password}}, u -> %{u | userinfo: "#{user}:#{password}"}
      end)

    URI.to_string(uri)
  end

  @doc "Starts a repo on `url`, under the running test, and answers its pid."
  def start(url, opts \\ []) do
    config = Keyword.merge([name: nil, url: url, pool_size: 4, log: false], opts)
    spec = %{id: {PgRepo, System.unique_integer()}, start: {PgRepo, :start_link, [config]}}
    ExUnit.Callbacks.start_supervised!(spec)
  end

  @doc "Runs SQL on the repo `pid`, answering the rows."
  def sql(pid, text, params \\ []), do: Servers.sql(PgRepo, pid, text, params).rows

  @doc "Runs `fun` on a connection of its own to `url`, closed after."
  def with_connection(url, fun) do
    {:ok, pid} = PgRepo.start_link(name: nil, url: url, pool_size: 1, log: false)

    try do
      fun.(pid)
    after
      Supervisor.stop(pid)
    end
  end
end

defmodule Cronwatch.Sources.PgCronPostgresTest do
  @moduledoc """
  The pg_cron source's SQL against a real Postgres, over a fake `cron`
  schema made in a database of the test's own (so it never meets a real
  pg_cron, nor another test), when CRONWATCH_TEST_PG is set.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client

  alias Cronwatch.JS.Object
  alias Cronwatch.Sources.PgCron
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.PgCronServer
  alias Cronwatch.Test.PgRepo
  alias Cronwatch.Test.Servers

  @moduletag Servers.skip_unless(:pg)
  @t0 Clock.t0()
  @day 86_400_000

  # A database of the test's own with pg_cron's two tables, dropped when the
  # test ends. Answers a repo's pid on it.
  defp fake_cron_database do
    base = Servers.url(:pg)
    db = PgCronServer.tag("fake")
    PgCronServer.with_connection(base, &PgCronServer.sql(&1, "CREATE DATABASE #{db}"))

    on_exit(fn ->
      PgCronServer.with_connection(base, &PgCronServer.sql(&1, "DROP DATABASE IF EXISTS #{db} WITH (FORCE)"))
    end)

    pid = PgCronServer.start(PgCronServer.url_with(base, database: db))
    PgCronServer.sql(pid, "CREATE SCHEMA cron")

    PgCronServer.sql(pid, """
    CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, schedule text NOT NULL, command text NOT NULL DEFAULT 'SELECT 1',
      database text NOT NULL DEFAULT 'cw', username text NOT NULL DEFAULT 'postgres', active boolean NOT NULL DEFAULT true,
      jobname text)
    """)

    PgCronServer.sql(pid, """
    CREATE TABLE cron.job_run_details (jobid bigint, runid bigserial PRIMARY KEY, job_pid integer, database text,
      username text, command text, status text, return_message text, start_time timestamptz, end_time timestamptz)
    """)

    pid
  end

  defp add(pid, jobid, status, start, stop, message \\ nil) do
    [[runid]] =
      PgCronServer.sql(
        pid,
        "INSERT INTO cron.job_run_details (jobid, status, return_message, start_time, end_time) " <>
          "VALUES ($1, $2, $3, to_timestamp($4::bigint / 1000.0), to_timestamp($5::bigint / 1000.0)) RETURNING runid",
        [jobid, status, message, start, stop]
      )

    runid
  end

  test "the source's SQL against Postgres: history, cursors, arrays, times, and a run held" do
    pid = fake_cron_database()
    PgCronServer.sql(pid, "INSERT INTO cron.job (jobname, schedule) VALUES ('nightly vacuum', '0 3 * * *')")
    PgCronServer.sql(pid, "INSERT INTO cron.job (jobname, schedule) VALUES (NULL, '10 seconds')")
    three = Cronwatch.JS.date_utc(2026, 0, 5, 3, 0, 0)
    for i <- 24..1//-1, do: add(pid, 1, "succeeded", three - i * @day, three - i * @day + 5000, "VACUUM")
    add(pid, 1, "failed", three + 123, three + 2123, "ERROR:  deadlock detected\n")

    c = Clock.new()
    opts = [repo: PgRepo, dynamic_repo: pid]
    k = make(clock_ref: c, sources: [{PgCron, opts}])
    first = Cronwatch.check!(instance: k.cw)
    assert Enum.map(first.jobs, & &1.name) == ["nightly-vacuum", "pg_cron:2"]
    [job | _] = first.jobs
    assert {Object.get(job.definition, "schedule"), Object.get(job.definition, "timezone")} == {"0 3 * * *", "UTC"}
    assert Enum.count(messages(k.errors), &(&1 =~ "could not read cron.timezone")) == 1

    [newest | _] = all = Cronwatch.runs!("nightly-vacuum", 100, instance: k.cw)
    assert length(all) == 20
    assert newest.id == "pgcron:25"
    assert {newest.started_at, newest.duration_ms} == {three + 123, 2000}
    assert newest.error == "ERROR:  deadlock detected"
    assert Capture.types(k.alerts) == ["failed"]

    # A run going, one queued, then more than a page of runs.
    going = add(pid, 2, "running", @t0 - 3000, nil)
    queued = add(pid, 2, "starting", nil, nil)

    last =
      Enum.reduce(1..520, nil, fn i, _ -> add(pid, 2, "succeeded", @t0 - 60_000 + i, @t0 - 60_000 + i + 1, "1 row") end)

    Clock.advance(c, 1000)
    Cronwatch.check!(instance: k.cw)
    Cronwatch.check!(instance: k.cw)
    assert Cronwatch.get_run!("pgcron:#{going}", instance: k.cw).status == "running"
    assert Cronwatch.get_run!("pgcron:#{queued}", instance: k.cw) == nil
    # The reads stop at 500, the SDK's limit; the last of the page after is there.
    assert length(Cronwatch.runs!("pg_cron:2", 1000, instance: k.cw)) == 500
    assert Cronwatch.get_run!("pgcron:#{last}", instance: k.cw).output == "1 row"

    PgCronServer.sql(
      pid,
      "UPDATE cron.job_run_details SET status = 'succeeded', end_time = to_timestamp($1::bigint / 1000.0) WHERE runid = $2",
      [@t0 - 1000, going]
    )

    # A check made from inside the app's own transaction: the source reads
    # on a connection of its own, and the transaction carries on.
    PgRepo.put_dynamic_repo(pid)

    assert {:ok, [[1]]} =
             PgRepo.transaction(fn ->
               PgRepo.query!("SELECT 1")
               {:ok, _} = PgCron.sync(opts, k.cw)
               PgRepo.query!("SELECT 1").rows
             end)

    done = Cronwatch.get_run!("pgcron:#{going}", instance: k.cw)
    assert {done.status, done.duration_ms} == {"ok", 2000}
    others = Enum.reject(messages(k.errors), &(&1 =~ "cron."))
    assert others == []
  end
end

defmodule Cronwatch.Sources.PgCronRealTest do
  @moduledoc """
  The pg_cron source against a real pg_cron, as the SDK's pgcron.test.ts and
  the Go and Rust ports run it, when CRONWATCH_TEST_PGCRON is the URL of a
  Postgres with pg_cron preloaded (cron.database_name naming that database).
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client

  alias Cronwatch.JS.Object
  alias Cronwatch.Sources.PgCron
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.PgCronServer
  alias Cronwatch.Test.PgRepo
  alias Cronwatch.Test.Servers
  alias Cronwatch.Test.Stores

  @moduletag Servers.skip_unless(:pgcron)
  @moduletag timeout: 300_000

  defp admin do
    pid = PgCronServer.start(Servers.url(:pgcron))
    previous = PgRepo.put_dynamic_repo(pid)

    # The tests start at once, and two CREATE EXTENSIONs race.
    try do
      {:ok, _} =
        PgRepo.transaction(fn ->
          PgRepo.query!("SELECT pg_advisory_xact_lock(7307)")
          PgRepo.query!("CREATE EXTENSION IF NOT EXISTS pg_cron")
        end)
    after
      PgRepo.put_dynamic_repo(previous)
    end

    pid
  end

  defp sql(pid, text, params \\ []), do: PgCronServer.sql(pid, text, params)
  defp ids(pid, text), do: pid |> sql(text) |> Enum.map(&hd/1)

  defp picks(tag), do: fn job -> is_binary(job.job_name) and String.starts_with?(job.job_name, tag) end

  defp unschedule_at_exit(tag) do
    on_exit(fn ->
      PgCronServer.with_connection(Servers.url(:pgcron), fn pid ->
        sql(pid, "SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE '#{tag}%'")
      end)
    end)
  end

  defp find(jobs, name), do: Enum.find(jobs, &(&1.name == name))

  # Tries `fun` every half second for up to 30 seconds, answering its first
  # truthy answer.
  defp until(fun, tries \\ 60) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ when tries > 0 ->
        Process.sleep(500)
        until(fun, tries - 1)

      _ ->
        flunk("not true in 30 seconds")
    end
  end

  defp others(errors), do: Enum.reject(messages(errors), &(&1 =~ "cron." or &1 =~ "row level"))

  test "the source against a real pg_cron" do
    pool = admin()
    tag = PgCronServer.tag("real")
    unschedule_at_exit(tag)
    {ok, fail, sleep} = {"#{tag}-ok", "#{tag}-fail", "#{tag}-sleep"}
    store = Stores.memory()
    offset = :atomics.new(1, signed: true)

    new_kit = fn ->
      make(
        store: Stores.option(store),
        clock: fn -> System.system_time(:millisecond) + :atomics.get(offset, 1) end,
        sources: [{PgCron, repo: PgRepo, dynamic_repo: pool, pick: picks(tag), options: [grace: "30s"]}]
      )
    end

    sql(pool, "SELECT cron.schedule('#{ok}', '1 seconds', 'SELECT 1')")
    sql(pool, "SELECT cron.schedule('#{fail}', '1 seconds', 'SELECT 1/0')")
    sql(pool, "SELECT cron.schedule('#{sleep}', '1 seconds', 'SELECT pg_sleep(3)')")
    Process.sleep(3500)

    k = new_kit.()
    first = Cronwatch.check!(instance: k.cw)
    ok_job = find(first.jobs, ok) || flunk("the ok job")
    assert {Object.get(ok_job.definition, "schedule"), Object.get(ok_job.definition, "timezone")} == {"every 1s", "UTC"}
    ok_runs = Cronwatch.runs!(ok, 20, instance: k.cw)
    assert length(ok_runs) >= 2, "ok runs imported (#{length(ok_runs)})"

    for r <- ok_runs do
      assert String.starts_with?(r.id, "pgcron:") and r.trigger == "pg_cron", "run #{r.id} from #{r.trigger}"
    end

    assert Enum.any?(ok_runs, &(&1.status == "ok" and &1.output == "1 row")), "no run with its output"

    assert Enum.any?(
             Cronwatch.runs!(fail, 20, instance: k.cw),
             &(&1.status == "failed" and &1.error =~ "division by zero")
           ),
           "the failure and its message were not imported"

    assert Enum.map(first.alerts, &"#{&1.type} #{&1.job}") == ["failed #{fail}"]
    assert ok_job.health == "healthy"

    # A run imported while it was going is updated when it finishes.
    running =
      Enum.find_value(1..120, fn _ ->
        found =
          ids(
            pool,
            "SELECT d.runid FROM cron.job_run_details d JOIN cron.job j USING (jobid) " <>
              "WHERE j.jobname = '#{sleep}' AND d.status = 'running' AND d.start_time IS NOT NULL"
          )

        case found do
          [id | _] -> id
          [] -> Process.sleep(250) && nil
        end
      end)

    assert running, "never saw the sleeping job running"
    id = "pgcron:#{running}"
    Cronwatch.check!(instance: k.cw)
    assert Cronwatch.get_run!(id, instance: k.cw).status == "running"
    # pg_sleep(3), then its finish, read by a check: polled, since a CI
    # runner can be slow.
    slept =
      until(fn ->
        Cronwatch.check!(instance: k.cw)
        r = Cronwatch.get_run!(id, instance: k.cw)
        r.status != "running" && r
      end)

    assert slept.status == "ok", inspect(slept)
    assert slept.duration_ms >= 2900, inspect(slept)

    # New runs keep arriving; nothing is copied twice, even by a fresh
    # instance after a restart.
    before = length(Cronwatch.runs!(ok, 500, instance: k.cw))

    after_ =
      until(fn ->
        Cronwatch.check!(instance: k.cw)
        list = Cronwatch.runs!(ok, 500, instance: k.cw)
        length(list) > before && list
      end)

    assert length(Enum.uniq_by(after_, & &1.id)) == length(after_), "a run copied twice"

    # The ok job is unscheduled and the failing one paused: neither is missed.
    sql(pool, "SELECT cron.unschedule('#{ok}')")
    sql(pool, "SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = '#{fail}'")
    Process.sleep(1500)
    k = new_kit.()
    Cronwatch.check!(instance: k.cw)
    settled = length(Cronwatch.runs!(fail, 500, instance: k.cw))
    Cronwatch.check!(instance: k.cw)
    assert length(Cronwatch.runs!(fail, 500, instance: k.cw)) == settled, "re-import added runs"
    :atomics.put(offset, 1, 2 * 60_000)
    late = Cronwatch.check!(instance: k.cw)

    for a <- late.alerts do
      refute a.type == "missed" and a.job in [ok, fail], "#{a.job} missed"
    end

    ok_job = find(late.jobs, ok) || flunk("the unscheduled job")
    assert Object.get(ok_job.definition, "schedule") == nil
    assert Object.get(ok_job.definition, "description") =~ "no longer in cron.job"
  end

  test "restart rows, a crowded job, first sight, and a rename" do
    pool = admin()
    tag = PgCronServer.tag("row")
    unschedule_at_exit(tag)
    {busy, quiet, hist} = {"#{tag}-busy", "#{tag}-quiet", "#{tag}-hist"}

    columns =
      "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time) "

    insert = fn jobid, status, times, message ->
      [runid] =
        ids(
          pool,
          columns <>
            "SELECT #{jobid}, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', '#{status}', '#{message}', #{times} RETURNING runid"
        )

      runid
    end

    jobids =
      Map.new([busy, quiet, hist], fn name ->
        [id] = ids(pool, "SELECT cron.schedule('#{name}', '0 3 * * *', 'SELECT 1')")
        # Paused, so pg_cron itself adds no rows while the test writes its own.
        sql(pool, "SELECT cron.alter_job(#{id}, active := false)")
        {name, id}
      end)

    # First sight of a job whose newest rows include a run cut off by a
    # restart, and older failures.
    sql(
      pool,
      columns <>
        "SELECT #{jobids[hist]}, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'failed', 'ERROR: old', " <>
        "now() - interval '3 days', now() - interval '3 days' FROM generate_series(1, 5)"
    )

    insert.(jobids[hist], "failed", "NULL, NULL", "server restarted")

    sql(
      pool,
      columns <>
        "SELECT #{jobids[hist]}, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', " <>
        "now() - make_interval(mins => 30 - g), now() - make_interval(mins => 30 - g) FROM generate_series(1, 19) g"
    )

    k = make(sources: [{PgCron, repo: PgRepo, dynamic_repo: pool, pick: picks(tag), timezone: "UTC"}])
    Cronwatch.check!(instance: k.cw)
    assert length(Cronwatch.runs!(hist, 500, instance: k.cw)) == 20, "the twenty newest are copied"
    assert Capture.types(k.alerts) == [], "history was judged"
    Cronwatch.check!(instance: k.cw)
    assert length(Cronwatch.runs!(hist, 500, instance: k.cw)) == 20, "after a second read"

    # A restart cuts off a busy job's queued run; the busy job then runs past
    # a page; then the quiet job fails.
    cut = insert.(jobids[busy], "failed", "NULL, NULL", "server restarted")

    sql(
      pool,
      columns <>
        "SELECT #{jobids[busy]}, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', " <>
        "now() - make_interval(secs => 600 - g), now() - make_interval(secs => 600 - g) FROM generate_series(1, 520) g"
    )

    disk = insert.(jobids[quiet], "failed", "now(), now()", "ERROR: disk full")
    for _ <- 1..3, do: Cronwatch.check!(instance: k.cw)
    assert Cronwatch.get_run!("pgcron:#{cut}", instance: k.cw).error == "server restarted"
    assert Cronwatch.get_run!("pgcron:#{disk}", instance: k.cw).status == "failed"

    assert Enum.any?(Capture.alerts(k.alerts), &(&1.type == "failed" and &1.job == quiet)),
           "the quiet job's failure did not alert"

    # Renamed in pg_cron: the old name keeps its runs and loses its schedule.
    sql(pool, "UPDATE cron.job SET jobname = '#{quiet}-v2' WHERE jobid = #{jobids[quiet]}")
    sql(pool, "SELECT cron.alter_job(#{jobids[quiet]}, active := true)")
    Cronwatch.check!(instance: k.cw)
    jobs = Cronwatch.jobs!(instance: k.cw)
    old = find(jobs, quiet) || flunk("the old name")
    assert Object.get(old.definition, "schedule") == nil
    assert Object.get(old.definition, "description") =~ "renamed to"
    assert Object.get(find(jobs, "#{quiet}-v2").definition, "schedule") == "0 3 * * *"
    assert others(k.errors) == []
  end

  test "a role that may not read cron's settings is given UTC, told once, and its transaction never aborted" do
    admin = admin()
    role = PgCronServer.tag("role")
    sql(admin, "CREATE ROLE #{role} LOGIN PASSWORD 'pw'")
    sql(admin, "GRANT USAGE ON SCHEMA cron TO #{role}")
    sql(admin, "GRANT SELECT ON cron.job, cron.job_run_details TO #{role}")

    # Every job of the role goes before the role: pg_cron's scheduler stops
    # on a job whose role is gone.
    on_exit(fn ->
      PgCronServer.with_connection(Servers.url(:pgcron), fn pid ->
        sql(pid, "SELECT cron.unschedule(jobid) FROM cron.job WHERE username = '#{role}'")
        sql(pid, "DROP OWNED BY #{role}")
        sql(pid, "DROP ROLE IF EXISTS #{role}")
      end)
    end)

    url = PgCronServer.url_with(Servers.url(:pgcron), user: {role, "pw"})
    pool = PgCronServer.start(url)
    sql(pool, "SELECT cron.schedule('#{role}-job', '0 3 * * *', 'SELECT 1')")

    opts = [repo: PgRepo, dynamic_repo: pool]
    k = make(alerts: [], sources: [{PgCron, opts}])
    result = Cronwatch.check!(instance: k.cw)
    Cronwatch.check!(instance: k.cw)
    job = find(result.jobs, "#{role}-job") || flunk("the role's job")

    assert {Object.get(job.definition, "timezone"), Object.get(job.definition, "schedule")} == {"UTC", "0 3 * * *"},
           "assumed UTC, and cron.log_run unreadable taken as on"

    assert Enum.count(messages(k.errors), &(&1 =~ "could not read cron.timezone")) == 1

    # The source's reads from inside the role's own transaction never abort
    # it.
    PgRepo.put_dynamic_repo(pool)

    assert {:ok, [[1]]} =
             PgRepo.transaction(fn ->
               {:ok, _} = PgCron.sync(opts, k.cw)
               PgRepo.query!("SELECT 1").rows
             end)
  end
end
