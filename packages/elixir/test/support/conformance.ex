defmodule Cronwatch.Test.Conformance do
  @moduledoc """
  What the replays of `conformance/*.json` share: the fixtures, read in
  JavaScript's key order, and a collector that reports every case that is not
  the SDK's JSON, byte for byte, at once.
  """

  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @doc "The repository's `conformance/` directory."
  def dir, do: Path.expand("../../../../conformance", __DIR__)

  @doc "`conformance/<name>.json`, in JavaScript's key order."
  def fixture(name) do
    path = Path.join(dir(), "#{name}.json")
    %Object{} = JS.parse!(File.read!(path))
  end

  @doc "`o[key]`, or nil when it is absent."
  def field(%Object{} = o, key), do: Object.get(o, key)

  @doc "`o[key]` as a list."
  def list(%Object{} = o, key), do: Object.get(o, key) || []

  @doc "Starts collecting failures for one fixture."
  def failures, do: []

  @doc "Adds a failure when `got` and `want` are not the same JSON."
  def same(failures, what, got, want) do
    {g, w} = {JS.stringify(got), JS.stringify(want)}
    if g == w, do: failures, else: ["#{what}:\n  got  #{g}\n  want #{w}" | failures]
  end

  @doc "Raises with every failure collected, when there are any."
  def check!(failures, fixture) do
    if failures != [] do
      raise ExUnit.AssertionError,
        message: "#{fixture}.json: #{length(failures)} cases differ:\n" <> Enum.join(Enum.reverse(failures), "\n")
    end

    :ok
  end
end
