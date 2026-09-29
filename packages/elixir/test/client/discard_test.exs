defmodule Cronwatch.Test.NoDelete do
  @moduledoc "A store over another that cannot take a run back: it has no delete_run_if."
  @behaviour Cronwatch.Store

  alias Cronwatch.StoreCase.Shared

  @impl true
  defdelegate new(opts, instance), to: Shared
  @impl true
  defdelegate init(s), to: Shared
  @impl true
  defdelegate upsert_job(s, d, now), to: Shared
  @impl true
  defdelegate get_job(s, name), to: Shared
  @impl true
  defdelegate list_jobs(s), to: Shared
  @impl true
  defdelegate delete_job(s, name), to: Shared
  @impl true
  defdelegate insert_run(s, run), to: Shared
  @impl true
  defdelegate update_run(s, run), to: Shared
  @impl true
  defdelegate update_run_if(s, run, from), to: Shared
  @impl true
  defdelegate get_run(s, id), to: Shared
  @impl true
  defdelegate list_runs(s, job, limit), to: Shared
  @impl true
  defdelegate last_run(s, job), to: Shared
  @impl true
  defdelegate running_runs(s), to: Shared
  @impl true
  defdelegate get_state(s, job), to: Shared
  @impl true
  defdelegate set_state(s, state), to: Shared
  @impl true
  defdelegate compare_and_set_state(s, state, expected), to: Shared
  @impl true
  defdelegate prune(s, before), to: Shared
  @impl true
  defdelegate close(s), to: Shared
end

defmodule Cronwatch.DiscardTest do
  @moduledoc """
  discard_when: an attempt a queue gives back without failing (an Oban
  snooze) leaves no run behind, neither a failure nor a success, as the Go
  port's DiscardWhen and the Rust port's run_or_discard have it.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client

  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Stores

  @min 60_000
  @hour 3_600_000

  defp snoozed?(reason), do: reason == :snoozed

  defp state(cw, name) do
    Cronwatch.Config.get(cw) |> Cronwatch.Core.read_state!(name)
  end

  # The Go audit: a run given back used to close missed at its start all the
  # same, so an overdue job that snoozed had missed opened again by the next
  # check, one alert per snooze.
  test "a run given back leaves missed open" do
    %{cw: cw, clock: c, alerts: alerts} = make()
    job = Cronwatch.job!("q", schedule: "every 1h", grace: "5m", instance: cw)
    Cronwatch.run(job, fn _ -> :ok end)
    Clock.advance(c, @hour + 10 * @min)
    Cronwatch.check!(instance: cw)
    assert Capture.types(alerts) == ["missed"]

    for _ <- 1..3 do
      Clock.advance(c, @min)
      assert Cronwatch.run(job, fn _ -> {:error, :snoozed} end, discard_when: &snoozed?/1) == {:error, :snoozed}
      Clock.advance(c, @min)
      Cronwatch.check!(instance: cw)
    end

    assert Capture.types(alerts) == ["missed"], "one missed alert, still open"
    Cronwatch.run(job, fn _ -> :ok end)
    assert Capture.types(alerts) == ["missed", "recovered"], "the run not given back recovers it"
  end

  test "discard_when takes the run back" do
    %{cw: cw, clock: c, alerts: alerts, errors: errors} = make()
    job = Cronwatch.job!("q", failures_before_alert: 2, instance: cw)

    attempt = fn result ->
      Clock.advance(c, 1000)

      Cronwatch.run(
        job,
        fn j ->
          Cronwatch.log(j, "attempt")
          result
        end,
        discard_when: &snoozed?/1
      )
    end

    # A failure, a snooze, then another failure: two in a row, so an alert.
    assert attempt.({:error, :down}) == {:error, :down}
    assert attempt.({:error, :snoozed}) == {:error, :snoozed}
    assert length(Cronwatch.runs!("q", 50, instance: cw)) == 1, "the snooze is not a run"
    assert state(cw, "q").consecutive_failures == 1, "failures in a row kept"
    assert Capture.types(alerts) == []
    attempt.({:error, :down_again})
    assert Capture.types(alerts) == ["failed"]
    assert length(Cronwatch.runs!("q", 50, instance: cw)) == 2

    # A snooze does not close the alert; a success does.
    attempt.({:error, :snoozed})
    assert Capture.types(alerts) == ["failed"]
    assert attempt.(:ok) == :ok
    assert Capture.types(alerts) == ["failed", "recovered"]
    assert length(Cronwatch.runs!("q", 50, instance: cw)) == 3
    assert messages(errors) == []

    # A raise the predicate answers true for is taken back too, and raised.
    assert_raise RuntimeError, fn ->
      Cronwatch.run(job, fn _ -> raise "given back" end, discard_when: &match?(%RuntimeError{}, &1))
    end

    assert length(Cronwatch.runs!("q", 50, instance: cw)) == 3

    # A throw is never taken back.
    catch_throw(Cronwatch.run(job, fn _ -> throw(:snoozed) end, discard_when: fn _ -> true end))
    assert hd(Cronwatch.runs!("q", 50, instance: cw)).status == "failed"
  end

  test "without delete_run_if the run is recorded as it ended" do
    store = {Cronwatch.Test.NoDelete, store: Stores.memory()}
    %{cw: cw, errors: errors} = make(store: store)
    job = Cronwatch.job!("q", instance: cw)
    assert Cronwatch.run(job, fn _ -> {:error, :snoozed} end, discard_when: &snoozed?/1) == {:error, :snoozed}
    assert hd(Cronwatch.runs!("q", 50, instance: cw)).status == "failed"

    assert Enum.zip(wheres(errors), messages(errors)) == [
             {"discarding q", "the store cannot take back a run (it has no delete_run_if/4); recorded as it ended"}
           ]
  end

  test "a run a check marked stuck is left as it is" do
    %{cw: cw, clock: c, errors: errors} = make()
    job = Cronwatch.job!("q", timeout: "1m", instance: cw)

    result =
      Cronwatch.run(
        job,
        fn _ ->
          Clock.advance(c, 2 * @min)
          Cronwatch.check!(instance: cw)
          {:error, :snoozed}
        end,
        discard_when: &snoozed?/1
      )

    assert result == {:error, :snoozed}
    assert hd(Cronwatch.runs!("q", 50, instance: cw)).status == "timeout"
    assert [message] = messages(errors)
    assert message =~ "is no longer running; left as it is"
  end

  test "a predicate that raises is reported and the run recorded" do
    %{cw: cw, errors: errors} = make()
    job = Cronwatch.job!("q", instance: cw)
    Cronwatch.run(job, fn _ -> {:error, :x} end, discard_when: fn _ -> raise "bad predicate" end)
    assert hd(Cronwatch.runs!("q", 50, instance: cw)).status == "failed"
    assert wheres(errors) == ["discarding q"]
  end
end
