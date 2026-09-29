defmodule Cronwatch.Test.ForeignRows do
  @moduledoc """
  Rows another process wrote, on a SQL store: a state whose version is 1.5
  or "x" (`conformance/store.json`'s `foreignVersion`, held as its text), and
  a running run that started at the lowest BIGINT. Neither may make a
  statement fail, or refuse every write of the job for good. stores.test.ts
  has the same tests.
  """

  import ExUnit.Assertions

  alias Cronwatch.JobState
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Store.Ecto, as: EctoStore
  alias Cronwatch.Test.Client
  alias Cronwatch.Test.Conformance
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
  2^53 - 1, and the state written over at version 1. The job is silenced: an
  alert's text shows the start as a date, and no date is that far back.
  """
  def check_over({EctoStore, h} = store) do
    %{cw: cw, errors: errors} = Client.make(store: Stores.option(store))
    :ok = EctoStore.init(h)
    :ok = EctoStore.upsert_job(h, JS.parse!(~s({"name":"far","timeout":"5m"})), 1)
    trigger = if h.dialect == :mysql, do: "`trigger`", else: "trigger"

    sql(
      h,
      "INSERT INTO #{h.prefix}runs (id, job, status, started_at, metrics, #{trigger}) " <>
        "VALUES ('far1', 'far', 'running', -9223372036854775808, '{}', 'run')"
    )

    state =
      ~s({"job":"far","open":{},"consecutiveFailures":0,"silencedUntil":4102444800000,"lastAlertAt":null,"version":1.5})

    sql(h, "INSERT INTO #{h.prefix}state (job, state) VALUES ('far', #{param(h.dialect)})", [state])

    for _ <- 1..2, do: Cronwatch.check!(instance: cw)
    assert Agent.get(errors, & &1) == []
    {:ok, run} = EctoStore.get_run(h, "far1")
    assert run.status == "timeout"
    assert run.duration_ms == 9_007_199_254_740_991, "the duration is held at 2^53 - 1"
    {:ok, st} = EctoStore.get_state(h, "far")
    assert st.version == 1, "the state's 1.5 counted as 0 and was written over"
    assert st.consecutive_failures == 1
  end

  defp param(:postgres), do: "$1::text::jsonb"
  defp param(_), do: "?"

  defp sql(h, text, params \\ []), do: Servers.sql(h.repo, h.dynamic_repo, text, params)
end
