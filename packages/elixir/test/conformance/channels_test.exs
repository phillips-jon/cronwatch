defmodule Cronwatch.Conformance.ChannelsTest do
  @moduledoc """
  Replays `conformance/channels.json`'s requests for Slack, Discord and the
  webhook (`sends`), the errors each gives for a refused request
  (`failures`) and the error bodies' cut (`textCuts.errorBodies`), byte for
  byte, through a recording transport. The providers' sections are
  replayed by `Cronwatch.Conformance.ProviderChannelsTest`.
  """
  use ExUnit.Case, async: true

  alias Cronwatch.Alert
  alias Cronwatch.Alerts.Discord
  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Slack
  alias Cronwatch.Alerts.URL
  alias Cronwatch.Alerts.Webhook
  alias Cronwatch.ChannelContext
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.JS.Units
  alias Cronwatch.Test.Conformance
  alias Cronwatch.Test.RecordingTransport, as: Rec

  import Conformance, only: [field: 2, list: 2, digest: 1]

  @doc "The fixture's alerts, by name, and the first."
  def alerts(f) do
    cases = list(f, "alerts")
    by_name = Map.new(cases, fn c -> {field(c, "name"), alert!(field(c, "alert"))} end)
    {by_name, alert!(field(hd(cases), "alert"))}
  end

  defp alert!(v) do
    {:ok, a} = Alert.from_value(v)
    a
  end

  @doc "A channel from a fixture's options, as the script's materialize() makes it."
  def build("slack", o, t),
    do: init(Slack, webhook_url: field(o, "webhookUrl"), link: link(o), transport: t)

  def build("discord", o, t),
    do: init(Discord, webhook_url: field(o, "webhookUrl"), link: link(o), transport: t)

  def build("webhook", o, t) do
    headers = if h = field(o, "headers"), do: Object.to_list(h), else: []
    init(Webhook, url: field(o, "url"), secret: field(o, "secret"), headers: headers, transport: t)
  end

  defp link(o) do
    if field(o, "link") == true, do: &"https://app.example/cronwatch/jobs/#{&1.job}"
  end

  defp init(module, opts) do
    {:ok, state} = module.init(opts)
    {module, state}
  end

  defp ctx, do: %ChannelContext{on_error: fn e -> raise "reported: #{inspect(e)}" end}

  defp same_request(got, want) do
    headers = Object.to_list(field(want, "headers"))

    cond do
      got.url != field(want, "url") ->
        "url #{got.url}, want #{field(want, "url")}"

      got.headers != headers ->
        "headers #{inspect(got.headers)}, want #{inspect(headers)}"

      JS.stringify(digest(got.body)) != JS.stringify(field(want, "body")) ->
        "body #{JS.stringify(digest(got.body))}, want #{JS.stringify(field(want, "body"))}\n#{got.body}"

      true ->
        nil
    end
  end

  test "conformance/channels.json: Slack, Discord and the webhook" do
    f = Conformance.fixture("channels")
    {alerts, first} = alerts(f)
    rec = Rec.start()
    t = Rec.spec(rec)

    failures =
      Enum.flat_map(list(f, "sends"), fn c ->
        o = field(c, "options")
        {module, state} = build(field(c, "channel"), o, t)
        Rec.answer_with(rec, 200, "")
        what = "#{field(c, "channel")} #{JS.stringify(o)} #{field(c, "alert")}"

        case module.send(state, Map.fetch!(alerts, field(c, "alert")), ctx()) do
          :ok ->
            case Rec.taken(rec) do
              [got] -> if e = same_request(got, c), do: ["#{what}: #{e}"], else: []
              got -> ["#{what}: #{length(got)} requests"]
            end

          {:error, e} ->
            ["#{what}: #{Exception.message(e)}"]
        end
      end)

    failures =
      failures ++
        Enum.flat_map(list(f, "failures"), fn c ->
          o = field(c, "options")
          {module, state} = build(field(c, "channel"), o, t)
          Rec.answer_with(rec, field(c, "status"), field(c, "body"))
          {:error, e} = module.send(state, first, ctx())
          got = Exception.message(e)

          if got == field(c, "error"),
            do: [],
            else: ["#{field(c, "channel")} #{field(c, "status")}: #{got}, want #{field(c, "error")}"]
        end)

    failures =
      failures ++
        Enum.flat_map(list(field(f, "textCuts"), "errorBodies"), fn c ->
          got = Post.error_body(field(c, "text"), list(c, "secrets"))
          if got == field(c, "body"), do: [], else: ["errorBody(#{inspect(field(c, "text"))}): #{inspect(got)}"]
        end)

    failures =
      failures ++
        Enum.flat_map(list(field(f, "textCuts"), "discordDescriptions"), fn c ->
          triage = if t = field(c, "triage"), do: expand(t)
          alert = %{first | message: expand(field(c, "message")), triage: triage}
          got = JS.stringify(digest(Units.to_string(Discord.description_of(alert))))

          if got == JS.stringify(field(c, "description")),
            do: [],
            else: ["discord description #{JS.stringify(field(c, "message"))}: #{got}"]
        end)

    assert failures == [], "channels.json: #{length(failures)} cases differ:\n" <> Enum.join(failures, "\n")

    count =
      length(list(f, "sends")) + length(list(f, "failures")) + length(list(field(f, "textCuts"), "errorBodies")) +
        length(list(field(f, "textCuts"), "discordDescriptions"))

    assert count == 90 + 18 + 6 + 8
  end

  test "conformance/channels.json: the webhook's payload, \"schema\":1 first, and its signature" do
    f = Conformance.fixture("channels")
    {alerts, _} = alerts(f)
    rec = Rec.start()
    cases = list(f, "webhookPayloads")

    failures =
      Enum.flat_map(cases, fn c ->
        {module, state} =
          build(
            "webhook",
            Object.new([{"url", "https://hooks.example.com/x"}, {"secret", field(c, "secret")}]),
            Rec.spec(rec)
          )

        Rec.answer_with(rec, 200, "")
        :ok = module.send(state, Map.fetch!(alerts, field(c, "alert")), ctx())
        [got] = Rec.taken(rec)
        {_, signature} = List.keyfind(got.headers, "x-cronwatch-signature", 0)

        cond do
          got.body != field(c, "body") ->
            ["#{field(c, "alert")}: body #{got.body}\n  want #{field(c, "body")}"]

          signature != field(c, "signature") ->
            ["#{field(c, "alert")}: signature #{signature}, want #{field(c, "signature")}"]

          true ->
            []
        end
      end)

    assert failures == [],
           "channels.json webhookPayloads: #{length(failures)} cases differ:\n" <> Enum.join(failures, "\n")

    assert length(cases) == 15

    assert Webhook.signature("key", "The quick brown fox jumps over the lazy dog") ==
             "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
  end

  test "Discord's description is held to 4096 as a whole, the message cut and the triage whole" do
    {_, first} = alerts(Conformance.fixture("channels"))

    message =
      "Error: long\n" <>
        String.duplicate("```", 1200) <> String.duplicate("x", 400) <> String.duplicate("\u{1F600}", 200)

    triage = String.duplicate("*_`~|[]()<>\\", 100)
    d = Discord.description_of(%{first | message: message, triage: triage})
    text = Units.to_string(d)

    assert Units.length(d) == 4096
    escaped = String.replace(String.slice(triage, 0, 1000), ~r/[\\`*_~|\[\]()<>]/, "\\\\\\0")
    assert String.ends_with?(text, "\n**Triage:** " <> escaped)
    assert String.starts_with?(text, "```\nError: long\n")
    assert length(String.split(text, "```")) == 3

    # Emoji at the cut: never half a surrogate pair.
    d =
      Discord.description_of(%{
        first
        | message: String.duplicate("\u{1F600}", 1900),
          triage: String.duplicate("t", 1001)
      })

    assert Units.length(d) <= 4096
    refute Enum.any?(Units.segments(d), &match?({:lone, _}, &1))
  end

  # The fixture's recipe for long text: a string, or {parts: [[piece, times], ...]} joined.
  defp expand(s) when is_binary(s), do: s

  defp expand(%Object{} = o) do
    o |> Object.get("parts") |> Enum.map_join(fn [piece, times] -> String.duplicate(piece, times) end)
  end

  test "conformance/channels.json: URLs read as Node's new URL reads them" do
    cases = list(Conformance.fixture("channels"), "urls")

    failures =
      Enum.flat_map(cases, fn c ->
        want =
          cond do
            field(c, "invalid") -> "invalid"
            field(c, "other") -> "other " <> field(c, "other")
            true -> "#{field(c, "url")} user? #{field(c, "username") != "" or field(c, "password") != ""}"
          end

        got =
          case URL.parse(field(c, "input")) do
            {:ok, u} -> "#{URL.to_string(u)} user? #{u.user?}"
            {:other, scheme} -> "other " <> scheme
            :error -> "invalid"
          end

        if got == want, do: [], else: ["#{JS.stringify(field(c, "input"))}: node #{want}, elixir #{got}"]
      end)

    assert failures == [], "channels.json: #{length(failures)} URLs differ:\n" <> Enum.join(failures, "\n")
    assert length(cases) > 700
  end

  test "a channel is refused without its URL, in Elixir's words" do
    assert Slack.init([]) == {:error, "Cronwatch.Alerts.Slack needs :webhook_url"}
    assert Discord.init(webhook_url: "") == {:error, "Cronwatch.Alerts.Discord needs :webhook_url"}
    assert Webhook.init(secret: "s") == {:error, "Cronwatch.Alerts.Webhook needs :url"}
    assert {:error, "Cronwatch.Alerts.Slack: unknown option :webhook"} = Slack.init(webhook: "x")
  end

  test "a channel's credentials never print" do
    {:ok, s} = Slack.init(webhook_url: "https://hooks.slack.example/T/B/secret")

    {:ok, w} =
      Webhook.init(url: "https://h.example/?key=secret", secret: "s3cret", headers: [{"a", "tok"}])

    refute inspect(s) =~ "secret"
    refute inspect(w) =~ "secret"
    refute inspect(w) =~ "tok"
  end

  test "the webhook's signature is the HMAC-SHA256 of the body" do
    assert Webhook.signature("key", "The quick brown fox jumps over the lazy dog") ==
             "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
  end
end
