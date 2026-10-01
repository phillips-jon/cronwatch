defmodule Cronwatch.Conformance.FixturesTest do
  use ExUnit.Case, async: true

  alias Cronwatch.Test.Conformance

  # Every fixture the SDK writes; this port replays each of them, so a new
  # fixture fails the test below until it is placed.
  @replayed ~w(channels client duration evaluate format health output pgcron schedule store triage)

  test "every fixture in conformance/ is known to this port" do
    names =
      Conformance.dir()
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(&String.trim_trailing(&1, ".json"))

    unknown = names -- @replayed
    assert unknown == [], "conformance/ has fixtures this port does not replay: #{inspect(Enum.sort(unknown))}"
    assert Enum.sort(@replayed) -- names == [], "a fixture this port expects is gone"
  end

  test "the tests run in UTC" do
    assert System.get_env("TZ") == "UTC"
  end
end
