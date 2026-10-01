defmodule Cronwatch.APITest do
  # What 1.x promises is what the README and the docs name: the port's
  # machinery is hidden from HexDocs, Cronwatch.Bridge says it is outside the
  # promise, and Cronwatch.StoreCase's helpers are deprecated.
  use ExUnit.Case, async: true

  @internal [
    Cronwatch.JS,
    Cronwatch.JS.Units,
    Cronwatch.JSRE,
    Cronwatch.JSRE.Match,
    Cronwatch.Cron,
    Cronwatch.Cron.Date,
    Cronwatch.Cron.Pattern,
    Cronwatch.Zone,
    Cronwatch.Duration,
    Cronwatch.Schedule,
    Cronwatch.Output,
    Cronwatch.Serialize,
    Cronwatch.Alerts.Post,
    Cronwatch.Store.SQL,
    Cronwatch.StoreCase.Shared
  ]

  @hidden_functions [
    {Cronwatch.Alerts.Email, :compose, 2},
    {Cronwatch.Alerts.Email, :escape_html, 1},
    {Cronwatch.Alerts.Email, :options, 2},
    {Cronwatch.Alerts.Email, :parse_address, 1},
    {Cronwatch.Alerts.Twilio, :max_segments, 0},
    {Cronwatch.Alerts.Twilio, :sms_body, 3},
    {Cronwatch.Alerts.Twilio, :sms_segments, 1},
    {Cronwatch.Alerts.Discord, :embed_description, 1},
    {Cronwatch.Sources.PgCron, :hold_ms, 0},
    {Cronwatch.Sources.PgCron, :schedule, 1},
    {Cronwatch.Sources.PgCron, :job_name, 1},
    {Cronwatch.Sources.PgCron, :run_of, 4},
    {Cronwatch.Transport, :check, 2},
    {Cronwatch.Transport, :resolve, 2},
    {Cronwatch.Triage.Anthropic, :default_model, 0},
    {Cronwatch.Triage.Anthropic, :system, 0},
    {Cronwatch.JS.Object, :array_index, 1},
    {Cronwatch.JobState, :sending, 2},
    {Cronwatch.Metrics, :lenient, 1}
  ]

  defp docs(module) do
    {:docs_v1, _, _, _, moduledoc, _, docs} = Code.fetch_docs(module)
    {moduledoc, docs}
  end

  defp doc_of(docs, name, arity) do
    Enum.find_value(docs, fn
      {{kind, ^name, ^arity}, _, _, doc, meta} when kind in [:function, :macro] -> {doc, meta}
      _ -> nil
    end)
  end

  test "the port's machinery is hidden from the docs" do
    for module <- @internal do
      assert {:hidden, _} = docs(module), inspect(module)
    end

    for {module, name, arity} <- @hidden_functions do
      {_, docs} = docs(module)
      assert {:hidden, _} = doc_of(docs, name, arity), "#{inspect(module)}.#{name}/#{arity}"
    end
  end

  test "the bridge says it is outside the 1.x promise" do
    for module <- [Cronwatch.Bridge, Cronwatch.Bridge.Watch, Cronwatch.Bridge.Entry] do
      {%{"en" => text}, _} = docs(module)
      assert text =~ "outside the 1.x", inspect(module)
    end
  end

  # Functions that were public by accident before 1.0: deprecated, still
  # working, and removed in 1.0. The rest of @hidden_functions are called
  # across the package's modules, so they stay, hidden and internal.
  @removed_in_1_0 [
    {Cronwatch.Alerts.Email, :escape_html, 1},
    {Cronwatch.Alerts.Twilio, :max_segments, 0},
    {Cronwatch.Alerts.Twilio, :sms_body, 3},
    {Cronwatch.Alerts.Twilio, :sms_segments, 1},
    {Cronwatch.Alerts.Discord, :embed_description, 1},
    {Cronwatch.Alerts.Webhook, :body, 1},
    {Cronwatch.Sources.PgCron, :hold_ms, 0},
    {Cronwatch.Sources.PgCron, :schedule, 1},
    {Cronwatch.Sources.PgCron, :job_name, 1},
    {Cronwatch.Sources.PgCron, :run_of, 4},
    {Cronwatch.Triage.Anthropic, :default_model, 0},
    {Cronwatch.Triage.Anthropic, :system, 0}
  ]

  test "the helpers public by accident are deprecated, to go in 1.0" do
    for {module, name, arity} <- @removed_in_1_0 do
      Code.ensure_loaded!(module)

      assert {_, message} = List.keyfind(module.__info__(:deprecated), {name, arity}, 0),
             "#{inspect(module)}.#{name}/#{arity}"

      assert message =~ "removed in 1.0"
    end

    # Called through apply/3 so the deprecated functions compile without a warning.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    assert apply(Cronwatch.Alerts.Email, :escape_html, ["<a&b>"]) == "&lt;a&amp;b&gt;"
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    assert apply(Cronwatch.Alerts.Twilio, :sms_segments, ["hi"]) == 1
  end

  test "StoreCase promises its use; the helpers it had are deprecated, and still work" do
    deprecated = Enum.map(Cronwatch.StoreCase.__info__(:deprecated), &elem(&1, 0))

    for fun <- [contract: 1, replay_fixture: 2, make: 1, scenarios: 0, new_run: 4, canonical: 1] do
      assert fun in deprecated, inspect(fun)
    end

    {_, docs} = docs(Cronwatch.StoreCase)
    assert {:hidden, _} = doc_of(docs, :run_contract, 1)
    # Called through apply/3 so the deprecated functions compile without a warning.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    assert apply(Cronwatch.StoreCase, :canonical, [~s({"b":1,"a":[2]})]) == ~s({"a":[2],"b":1})
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    assert %Cronwatch.Run{id: "r", status: "ok"} = apply(Cronwatch.StoreCase, :new_run, ["r", "j", "ok", 1])
  end
end
