defmodule Cronwatch.Test.ForeignRows do
  @moduledoc """
  Rows another process wrote, on a SQL store: a state whose version is 1.5
  or "x" (`conformance/store.json`'s `foreignVersion`, held as its text), and
  a running run that started at the lowest BIGINT. Neither may make a
  statement fail, or refuse every write of the job for good. stores.test.ts
  has the same tests.
  """

  import ExUnit.Assertions

  alias Cronwatch.Evaluate
  alias Cronwatch.JobState
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Serialize
  alias Cronwatch.Store.Ecto, as: EctoStore
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Client
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Conformance
  alias Cronwatch.Test.Repo
  alias Cronwatch.Test.Servers
  alias Cronwatch.Test.Stores

  @doc "Defines both tests, each on a fresh store from `store:`, a function."
  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)

    quote do
      test "a foreign state's version counts as the SDK's stateVersion() reads it (store.json foreignVersion)" do
        unquote(__MODULE__).replay_versions(unquote(store).())
      end

      test "a check over a run that started at the lowest BIGINT, and a state whose version is 1.5" do
        unquote(__MODULE__).check_over(unquote(store).())
      end

      for started_at <- unquote(__MODULE__).far_starts() do
        @far_start started_at
        test "a check and the dashboard over a cron job whose last run started at #{started_at}" do
          unquote(__MODULE__).cron_over(unquote(store).(), @far_start)
        end
      end
    end
  end

  @doc "Starts a foreign or damaged row could hold: before the year 1, after 9999, and the BIGINT extremes."
  def far_starts, do: [-62_135_596_800_001, 253_402_300_800_000, -9_223_372_036_854_775_808, 9_223_372_036_854_775_807]

  @doc """
  A cron job whose last run started at `started_at`, written as a raw row:
  a check and the job's dashboard pages report no error. Before the year 1
  the first fire of the year 1 was missed; after 9999 nothing is due again.
  stores.test.ts has the same test.
  """
  def cron_over({EctoStore, h} = store, started_at) do
    %{cw: cw, errors: errors, alerts: alerts} = Client.make(store: Stores.option(store))
    :ok = EctoStore.init(h)
    definition = ~s({"name":"far","schedule":"0 2 * * *","timezone":"UTC","grace":"10m"})
    :ok = EctoStore.upsert_job(h, JS.parse!(definition), 1)
    trigger = if h.dialect == :mysql, do: "`trigger`", else: "trigger"

    sql(
      h,
      "INSERT INTO #{h.prefix}runs (id, job, status, started_at, finished_at, duration_ms, metrics, #{trigger}) " <>
        "VALUES ('far1', 'far', 'ok', #{started_at}, #{started_at}, 0, '{}', 'run')"
    )

    Cronwatch.check!(instance: cw)
    opts = Cronwatch.Web.init(instance: cw, token: "tok")

    for path <- ["/cronwatch", "/cronwatch/jobs/far", "/cronwatch/api/jobs/far"] do
      conn =
        Plug.Test.conn("GET", path)
        |> Map.put(:host, "app.test")
        |> Map.put(:req_headers, [{"authorization", "Bearer tok"}])
        |> Cronwatch.Web.call(opts)

      assert conn.status == 200, path
    end

    assert Agent.get(errors, & &1) == [], "#{started_at}"
    want = if started_at < 0, do: ["missed"], else: []
    assert Capture.types(alerts) == want, "#{started_at}"

    if started_at < 0 do
      [sent] = Capture.alerts(alerts)
      assert String.starts_with?(sent.message, "Due 0001-01-01 02:00:00 UTC ")
    end
  end

  @doc "Replays `foreignVersion` on the store, writing each stored text as it is."
  def replay_versions({EctoStore, h}) do
    :ok = EctoStore.init(h)
    cases = Conformance.fixture("store") |> Object.get("foreignVersion")
    assert length(cases) >= 16

    for c <- cases do
      stored = Object.get(c, "stored")
      :ok = EctoStore.delete_job(h, "v")
      insert = "INSERT INTO #{h.prefix}state (job, state) VALUES ('v', #{param(h.dialect)})"
      sql(h, insert, [stored])

      for step <- Object.get(c, "steps") do
        {:ok, cas} = JobState.from_value(Object.get(step, "cas"))
        expected = Object.get(step, "expected")
        wrote = EctoStore.compare_and_set_state(h, cas, expected)
        assert wrote == {:ok, Object.get(step, "written")}, "#{stored} expecting #{expected}"

        if want = Object.get(step, "state") do
          {:ok, got} = EctoStore.get_state(h, "v")
          assert JS.stringify(JobState.to_value(got)) == JS.stringify(want), stored
        end
      end
    end
  end

  @doc """
  A check over a running run that started at the lowest BIGINT and a state
  whose version is 1.5: the run is marked timed out, its duration held at
  2^53 - 1, and the state's 1.5 counted as 0. The stuck alert is sent: its
  text writes a start before the year 1 as words, not as a date, and the
  timeout and the alert each write the state, so it ends at version 2.
  """
  def check_over({EctoStore, h} = store) do
    %{cw: cw, errors: errors, alerts: alerts} = Client.make(store: Stores.option(store))
    :ok = EctoStore.init(h)
    :ok = EctoStore.upsert_job(h, JS.parse!(~s({"name":"far","timeout":"5m"})), 1)
    trigger = if h.dialect == :mysql, do: "`trigger`", else: "trigger"

    sql(
      h,
      "INSERT INTO #{h.prefix}runs (id, job, status, started_at, metrics, #{trigger}) " <>
        "VALUES ('far1', 'far', 'running', -9223372036854775808, '{}', 'run')"
    )

    state =
      ~s({"job":"far","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"version":1.5})

    sql(h, "INSERT INTO #{h.prefix}state (job, state) VALUES ('far', #{param(h.dialect)})", [state])

    for _ <- 1..2, do: Cronwatch.check!(instance: cw)
    assert Agent.get(errors, & &1) == []
    {:ok, run} = EctoStore.get_run(h, "far1")
    assert run.status == "timeout"
    assert run.duration_ms == 9_007_199_254_740_991, "the duration is held at 2^53 - 1"
    {:ok, st} = EctoStore.get_state(h, "far")
    assert st.version == 2, "the state's 1.5 counted as 0, then the timeout and the alert each wrote it"
    assert st.consecutive_failures == 1
    assert Capture.types(alerts) == ["stuck"]
    [sent] = Capture.alerts(alerts)

    assert hd(String.split(sent.message, "\n")) ==
             "Started before 0001-01-01 00:00:00 UTC and never reported finishing. " <>
               "Marked as timed out after 104249991d 8h."
  end

  ## store.json foreignRows, on SQLite (its values are as SQLite holds them)

  @doc """
  `foreignRows.rows`: each row alone in a fresh SQLite store, read
  leniently: a job as the client reads it (from get and list), a run as the
  store reads it (from get and list), a state as normalize_state reads it.
  stores.test.ts has the same test.
  """
  def replay_rows(new_store) do
    rows = foreign_rows() |> Object.get("rows")
    assert length(rows) >= 28

    for c <- rows do
      {{EctoStore, h} = store, pid} = new_store.()
      :ok = EctoStore.init(h)
      table = Object.get(c, "table")
      row = Object.get(c, "row")
      insert(pid, table, row)
      want = JS.stringify(Object.get(c, "read"))
      label = "#{table} #{JS.stringify(row)}"

      case table do
        "jobs" ->
          name = Object.get(row, "name")
          {:ok, got} = Cronwatch.Store.call(store, :get_job, [name])
          {job, readable} = Serialize.read_stored_job(got)
          assert JS.stringify(stored_value(job)) == want, label
          assert readable == Object.get(c, "readable"), label
          {:ok, listed} = Cronwatch.Store.call(store, :list_jobs, [])
          assert Enum.map(listed, &JS.stringify(stored_value(elem(Serialize.read_stored_job(&1), 0)))) == [want], label

        "runs" ->
          {:ok, got} = Cronwatch.Store.call(store, :get_run, [Object.get(row, "id")])
          assert JS.stringify(Run.to_value(got)) == want, label
          {:ok, listed} = Cronwatch.Store.call(store, :list_runs, [Object.get(row, "job"), 10])
          assert Enum.map(listed, &JS.stringify(Run.to_value(&1))) == [want], label

        "state" ->
          job = Object.get(row, "job")
          {:ok, got} = Cronwatch.Store.call(store, :get_state, [job])
          assert JS.stringify(JobState.to_value(Evaluate.normalize_state(got, job))) == want, label
      end
    end
  end

  @doc """
  `foreignRows.check`: every row in one SQLite store beside a healthy job
  with a failed run, and a client that declares nothing checks at `now`,
  silences the job whose state does not parse, and reads every page. Only
  the jobs whose definition is not an object are reported; the rest are
  checked as usual. stores.test.ts has the same test.
  """
  def replay_check(new_store) do
    f = foreign_rows()
    c = Object.get(f, "check")
    rows = Object.get(f, "rows")
    {{EctoStore, h} = store, pid} = new_store.()
    :ok = EctoStore.init(h)
    of = fn table -> for r <- rows, Object.get(r, "table") == table, do: Object.get(r, "row") end
    jobs = of.("jobs") ++ Object.get(c, "extraJobs")
    for row <- jobs, do: insert(pid, "jobs", row)
    for row <- of.("runs") ++ Object.get(c, "extraRuns"), do: insert(pid, "runs", row)
    for row <- of.("state"), do: insert(pid, "state", row)
    names = Enum.map(jobs, &Object.get(&1, "name"))

    %{cw: cw, errors: errors, alerts: alerts} =
      Client.make(store: Stores.option(store), clock_ref: Clock.new(Object.get(c, "now")))

    reported = fn ->
      wheres = Agent.get_and_update(errors, &{&1, []})

      wheres
      |> Enum.map(fn {where, _} -> Enum.find(names, where, &String.ends_with?(where, " " <> &1)) end)
      |> Enum.uniq()
      |> Enum.sort()
    end

    result = Cronwatch.check!(instance: cw)
    assert reported.() == Object.get(c, "reported")

    sent = for a <- Capture.alerts(alerts), do: Object.new([{"type", a.type}, {"job", a.job}, {"at", a.at}])
    assert JS.stringify(sent) == JS.stringify(Object.get(c, "alerts"))

    health = Object.new(for j <- result.jobs, do: {j.name, j.health})
    assert JS.stringify(health) == JS.stringify(Object.get(c, "health"))

    silence = Object.get(c, "silence")
    Cronwatch.silence!(Object.get(silence, "job"), Object.get(silence, "for"), instance: cw)
    assert reported.() == Object.get(silence, "reported")
    assert raw_state(pid, Object.get(silence, "job")) == JS.stringify(Object.get(silence, "state"))

    # As stored: a read that changes nothing writes nothing, so some are
    # still the foreign values.
    for {job, state} <- Object.to_list(Object.get(c, "states")) do
      assert raw_state(pid, job) == JS.stringify(state), job
    end

    opts = Cronwatch.Web.init(instance: cw, token: "tok")

    for page <- c |> Object.get("read") |> Object.get("pages") do
      path = Object.get(page, "path")

      conn =
        Plug.Test.conn("GET", path)
        |> Map.put(:host, "app.test")
        |> Map.put(:req_headers, [{"host", "app.test"}, {"authorization", "Bearer tok"}])
        |> Cronwatch.Web.call(opts)

      assert conn.status == Object.get(page, "status"), path
    end

    assert reported.() == c |> Object.get("read") |> Object.get("reported")
  end

  defp foreign_rows, do: Conformance.fixture("store") |> Object.get("foreignRows")

  defp insert(pid, table, %Object{} = row) do
    keys = Object.keys(row)
    marks = Enum.map_join(keys, ", ", fn _ -> "?" end)

    Repo.sql(
      pid,
      "INSERT INTO cronwatch_#{table} (#{Enum.join(keys, ", ")}) VALUES (#{marks})",
      Enum.map(keys, &Object.get(row, &1))
    )
  end

  # The state's row as stored, as the JSON it holds.
  defp raw_state(pid, job) do
    %{rows: [[text]]} = Repo.sql(pid, "SELECT state FROM cronwatch_state WHERE job = ?", [job])
    JS.stringify(JS.parse!(text))
  end

  defp stored_value(job) do
    Object.new([
      {"name", job.name},
      {"definition", job.definition},
      {"createdAt", job.created_at},
      {"updatedAt", job.updated_at}
    ])
  end

  defp param(:postgres), do: "$1::text::jsonb"
  defp param(_), do: "?"

  defp sql(h, text, params \\ []), do: Servers.sql(h.repo, h.dynamic_repo, text, params)
end
