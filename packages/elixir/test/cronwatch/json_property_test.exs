defmodule Cronwatch.JSONPropertyTest do
  # The Rust port's `json` and `rows` fuzz targets as properties: any text
  # JSON.parse reads is read here without raising, and what it reads is
  # written back as JSON that reads to the same text; a stored run, state
  # and alert, each read, written, and read back to the same text, whatever
  # shape another writer gave it. `CRONWATCH_PROPERTY_RUNS` asks for more.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cronwatch.Alert
  alias Cronwatch.JobState
  alias Cronwatch.JS
  alias Cronwatch.Run

  @moduletag :property

  @runs String.to_integer(System.get_env("CRONWATCH_PROPERTY_RUNS", "200"))

  defp scalar do
    one_of([
      constant(nil),
      boolean(),
      integer(),
      float(),
      string(:utf8, max_length: 12),
      member_of(["running", "ok", "failed", "timeout", "missed", "over_budget", "recovered", "", "\u2028", "😀"])
    ])
  end

  defp json do
    tree(scalar(), fn inner ->
      one_of([
        list_of(inner, max_length: 4),
        list_of(tuple({member_of(keys()), inner}), max_length: 5) |> map(&JS.Object.new/1)
      ])
    end)
  end

  defp keys do
    ~w(id job status startedAt finishedAt durationMs error output metrics trigger open consecutiveFailures
       silencedUntil lastAlertAt pendingRecovery undelivered version type run details definition title
       message at triage 10 2 x)
  end

  property "what JSON.parse reads reads back the same" do
    check all(value <- json(), max_runs: @runs) do
      text = JS.stringify(value)
      assert {:ok, read} = JS.parse(text)
      assert JS.stringify(read) == text
    end
  end

  property "any text is read or refused, never raised on" do
    check all(text <- one_of([string(:printable, max_length: 60), map(json(), &mangle/1)]), max_runs: @runs) do
      case JS.parse(text) do
        {:ok, v} -> assert {:ok, _} = JS.parse(JS.stringify(v))
        {:error, message} -> assert is_binary(message)
      end
    end
  end

  property "stored rows of any shape are read, written, and read back the same" do
    check all(value <- json(), max_runs: @runs) do
      for {module, reader} <- [
            {Run, &Run.from_value/1},
            {JobState, &JobState.from_value/1},
            {Alert, &Alert.from_value/1}
          ] do
        case reader.(value) do
          {:ok, row} ->
            text = module.to_json(row)
            assert {:ok, again} = reader.(JS.parse!(text))
            assert module.to_json(again) == text

          {:error, message} ->
            assert is_binary(message)
        end
      end
    end
  end

  # JSON with a character dropped or doubled somewhere.
  defp mangle(value) do
    text = JS.stringify(value)
    n = byte_size(text)

    if n < 2,
      do: text <> "}",
      else: binary_part(text, 0, div(n, 2)) <> binary_part(text, div(n, 2) + 1, n - div(n, 2) - 1)
  end
end
