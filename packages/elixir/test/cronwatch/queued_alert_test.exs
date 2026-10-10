defmodule Cronwatch.QueuedAlertTest do
  # The SDK keeps the alerts it queues (undelivered, and the outbox's
  # entries) as the objects it read, so a field a newer release added to an
  # alert, its details, or an outbox entry is written back and sent on retry.
  use ExUnit.Case, async: true

  alias Cronwatch.Alert
  alias Cronwatch.Alerts.Webhook
  alias Cronwatch.Evaluate
  alias Cronwatch.JobState
  alias Cronwatch.JS

  @run ~s({"id":"r1","job":"a","status":"failed","startedAt":1,"finishedAt":2,"durationMs":1,) <>
         ~s("error":"boom","output":null,"metrics":{"rows":2},"trigger":"schedule","exitCode":1})

  defp alert(type, details, extra \\ "") do
    ~s({"type":"#{type}","run":#{@run},"details":#{details},"job":"a","definition":{"name":"a"},) <>
      ~s("title":"t","message":"m","at":5#{extra}})
  end

  defp round_trip(json) do
    {:ok, state} = JobState.from_json(json)
    JobState.to_json(state)
  end

  # The SDK never writes `sending` as [].
  defp state(undelivered, sending) do
    out = if sending == [], do: "", else: ~s(,"sending":[#{Enum.join(sending, ",")}])

    ~s({"job":"a","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,) <>
      ~s("undelivered":[#{Enum.join(undelivered, ",")}]#{out}})
  end

  test "a queued alert keeps the top-level fields it does not know" do
    a = alert("failed", ~s({"consecutiveFailures":3,"threshold":3}), ~s(,"futureAlertField":{"x":[1,"y"]}))
    json = state([a], [~s({"until":9,"alert":#{a}})])
    assert round_trip(json) == json
  end

  test "an outbox entry keeps the keys it does not know" do
    a = alert("failed", ~s({"consecutiveFailures":3,"threshold":3}))
    json = state([], [~s({"until":9,"alert":#{a},"futureEntryKey":true})])
    assert round_trip(json) == json
  end

  test "the details of an alert of a type a newer release added are kept as read" do
    a = alert("paused", ~s({"since":5,"by":"ops"}))
    json = state([a], [~s({"until":9,"alert":#{a}})])
    assert round_trip(json) == json
  end

  test "details keep the keys a newer release added, in every known type" do
    for {type, details} <- [
          {"failed", ~s({"consecutiveFailures":3,"threshold":3,"a_b":1})},
          {"stuck", ~s({"consecutiveFailures":0,"threshold":0,"extra":"x"})},
          {"missed", ~s({"dueAt":1,"deadline":2,"graceMs":3,"lastRunAt":null,"extra":[1]})},
          {"slow", ~s({"durationMs":10,"thresholdMs":5,"basis":"p95","extra":null})},
          {"over_budget",
           ~s({"breaches":[{"metric":"rows","value":2,"limit":1,"basis":"limit","unit":"n"}],"extra":2})},
          {"recovered", ~s({"after":["failed"],"reason":"unscheduled","since":4,"extra":{}})}
        ] do
      json = state([alert(type, details)], [])
      assert {type, round_trip(json)} == {type, json}
    end
  end

  test "a retried alert is sent with the fields it was read with" do
    a = alert("paused", ~s({"since":5}), ~s(,"futureAlertField":1))
    {:ok, read} = Alert.from_json(a)
    assert Webhook.payload(read) == ~s({"schema":1,) <> String.slice(a, 1..-1//1)
  end

  test "a queued alert that carries a schema of its own is sent with one schema key, first" do
    # { schema: 1, ...alert }: the alert's own value, in the first place.
    a = alert("failed", ~s({"consecutiveFailures":3,"threshold":3}), ~s(,"schema":2))
    {:ok, read} = Alert.from_json(a)
    body = Webhook.payload(read)
    assert String.starts_with?(body, ~s({"schema":2,"type":"failed",))
    assert length(String.split(body, ~s("schema":))) == 2, "one schema key"
    refute body =~ ~s("at":5,"schema")
  end

  test "the fields survive the outbox being let go into the retry queue" do
    a = alert("failed", ~s({"consecutiveFailures":3,"threshold":3,"more":1}), ~s(,"futureAlertField":1))
    {:ok, state} = JobState.from_json(state([], [~s({"until":9,"alert":#{a}})]))
    {state, _} = Evaluate.release_sending(state, 10)
    assert [queued] = state.undelivered
    assert JS.stringify(Alert.to_value(queued)) == a
  end
end
