defmodule Cronwatch.Conformance.TriageTest do
  @moduledoc """
  Replays `conformance/triage.json`: the parameters the SDK hands the
  official client for each context and option set, the diagnosis read from
  each answer, and (the `wire` cases) the HTTP request that client sends,
  which this port makes itself.
  """
  use ExUnit.Case, async: true

  alias Cronwatch.Alert
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Test.Conformance
  alias Cronwatch.Test.RecordingTransport, as: Rec
  alias Cronwatch.Triage.Anthropic

  import Conformance, only: [field: 2, list: 2]

  @answer ~s({"id":"msg_1","type":"message","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}],"usage":{}})

  defp contexts(f) do
    Map.new(list(f, "contexts"), fn c ->
      {:ok, alert} = Alert.from_value(field(c, "alert"))

      runs =
        Enum.map(list(c, "recentRuns"), fn r ->
          {:ok, run} = Run.from_value(r)
          run
        end)

      {field(c, "name"), %{alert: alert, recent_runs: runs}}
    end)
  end

  defp options(o) do
    [
      model: field(o, "model"),
      effort: field(o, "effort"),
      context: field(o, "context"),
      max_tokens: field(o, "maxTokens"),
      fallbacks: field(o, "fallbacks") != false
    ]
  end

  test "conformance/triage.json" do
    f = Conformance.fixture("triage")
    by_name = contexts(f)

    failures =
      Enum.flat_map(list(f, "requests"), fn c ->
        {:ok, t} = Anthropic.init([api_key: "k"] ++ options(field(c, "options")))
        got = JS.stringify_lone(Anthropic.client_params(t, by_name[field(c, "context")]))
        want = JS.stringify(field(c, "params"))
        ro = field(c, "requestOptions")
        assert field(ro, "timeout") == 24_000
        assert field(ro, "maxRetries") == 0
        if got == want, do: [], else: ["params #{field(c, "context")}:\n  got  #{got}\n  want #{want}"]
      end)

    failures =
      failures ++
        Enum.flat_map(list(f, "responses"), fn c ->
          got = Anthropic.diagnosis(field(c, "response"))
          want = field(c, "result") || ""
          if got == want, do: [], else: ["diagnosis #{JS.stringify(field(c, "response"))}: #{inspect(got)}"]
        end)

    failures =
      failures ++
        Enum.flat_map(list(f, "wire"), fn c ->
          rec = Rec.start()
          Rec.answer_with(rec, 200, @answer)

          {:ok, t} =
            Anthropic.init(
              [api_key: "test-key", base_url: "https://api.anthropic.com", transport: Rec.spec(rec)] ++
                options(field(c, "options"))
            )

          assert Anthropic.triage(t, by_name[field(c, "context")]) == {:ok, "ok"}
          [got] = Rec.taken(rec)
          want = field(c, "request")
          assert field(want, "method") == "POST"
          kept = ~w(accept anthropic-beta anthropic-version content-type x-api-key)
          headers = Enum.filter(got.headers, fn {n, _} -> n in kept end)
          assert {"user-agent", "cronwatch-elixir/#{Cronwatch.version()}"} in got.headers
          body = Conformance.digest(got.body)

          cond do
            got.url != field(want, "url") -> ["wire url #{got.url}"]
            headers != Object.to_list(field(want, "headers")) -> ["wire headers #{inspect(headers)}"]
            JS.stringify(body) != JS.stringify(field(want, "body")) -> ["wire body #{JS.stringify(body)}"]
            true -> []
          end
        end)

    assert failures == [], "triage.json: #{length(failures)} cases differ:\n" <> Enum.join(failures, "\n")
    assert length(list(f, "requests")) + length(list(f, "responses")) + length(list(f, "wire")) == 17
  end
end
