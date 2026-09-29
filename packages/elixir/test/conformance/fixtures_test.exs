defmodule Cronwatch.Conformance.FixturesTest do
  use ExUnit.Case, async: true

  alias Cronwatch.Test.Conformance

  # Every fixture the SDK writes, and where this port replays it. The three
  # the phase 2 work replays (the alert channels, Claude triage and the
  # pg_cron source) are named here so a new fixture still fails the test
  # below until it is placed.
  @replayed ~w(duration evaluate format health output schedule store)
  @phase_2 ~w(channels pgcron triage)

  test "every fixture in conformance/ is known to this port" do
    names =
      Conformance.dir()
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(&String.trim_trailing(&1, ".json"))

    unknown = (names -- @replayed) -- @phase_2
    assert unknown == [], "conformance/ has fixtures this port does not replay: #{inspect(Enum.sort(unknown))}"
    assert Enum.sort(@replayed ++ @phase_2) -- names == [], "a fixture this port expects is gone"
  end

  test "the tests run in UTC" do
    assert System.get_env("TZ") == "UTC"
  end
end
