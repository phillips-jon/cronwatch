defmodule Cronwatch.Conformance.ProviderChannelsTest do
  # Replays the provider sections of conformance/channels.json, the requests
  # the SDK's email, SMS and tracker channels make (scripts/conformance.mjs
  # drives them with a stub fetch): every request's URL, headers (name,
  # value and position) and body, byte for byte, for each sample alert and
  # option set; the error each gives for a refused request; Twilio's partial
  # delivery; and the email subject and SMS cuts. The Slack, Discord and
  # webhook sections and the error body cuts are replayed beside the
  # transport, in channels_test.exs.
  use ExUnit.Case, async: true

  alias Cronwatch.Alert
  alias Cronwatch.Alerts
  alias Cronwatch.ChannelContext
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Test.Conformance
  alias Cronwatch.Test.RecordingTransport

  import Conformance, only: [field: 2, list: 2, digest: 1]

  @modules %{
    "resend" => Alerts.Resend,
    "postmark" => Alerts.Postmark,
    "sendgrid" => Alerts.SendGrid,
    "mailgun" => Alerts.Mailgun,
    "ses" => Alerts.SES,
    "twilio" => Alerts.Twilio,
    "sentry" => Alerts.Sentry,
    "honeybadger" => Alerts.Honeybadger,
    "datadog" => Alerts.Datadog,
    "rollbar" => Alerts.Rollbar,
    "bugsnag" => Alerts.Bugsnag,
    "newrelic" => Alerts.NewRelic
  }

  # A channel from a fixture's options, as the script's materialize() makes
  # it: the SDK's names in snake_case, `link: true` the usual link, `now` a
  # fixed clock.
  defp build(name, %Object{} = o, rec) do
    opts =
      Enum.map(Object.to_list(o), fn
        {"link", true} -> {:link, fn a -> "https://app.example/cronwatch/jobs/#{a.job}" end}
        {"now", n} -> {:now, fn -> n end}
        {key, value} -> {key |> Macro.underscore() |> String.to_atom(), value}
      end)

    module = Map.fetch!(@modules, name)
    {:ok, state} = module.init(opts ++ [transport: RecordingTransport.spec(rec)])
    assert module.name(state) == name
    {module, state}
  end

  defp alerts(f) do
    cases = list(f, "alerts")

    by_name =
      Map.new(cases, fn c ->
        {:ok, a} = Alert.from_value(field(c, "alert"))
        {field(c, "name"), a}
      end)

    {:ok, first} = Alert.from_value(field(hd(cases), "alert"))
    {by_name, first}
  end

  defp ctx(fun \\ fn e -> flunk("reported: #{Cronwatch.Error.describe(e)}") end), do: %ChannelContext{on_error: fun}

  defp form_to(body), do: body |> URI.query_decoder() |> Enum.find_value("", fn {k, v} -> if k == "To", do: v end)

  # A Twilio send's requests in the order of its numbers, since they are made at once.
  defp number_order(requests, numbers) do
    numbers = numbers |> List.wrap() |> Enum.map(&JS.trim/1)
    Enum.sort_by(requests, fn r -> Enum.find_index(numbers, &(&1 == form_to(r.body))) || length(numbers) end)
  end

  defp same_request(got, want) do
    headers = Enum.map(Object.to_list(field(want, "headers")), fn {k, v} -> {k, v} end)
    body = IO.iodata_to_binary(got.body)

    cond do
      got.url != field(want, "url") -> "url #{got.url}, want #{field(want, "url")}"
      got.headers != headers -> "headers #{inspect(got.headers)}, want #{inspect(headers)}"
      JS.stringify(digest(body)) != JS.stringify(field(want, "body")) -> "body #{JS.stringify(digest(body))}\n#{body}"
      true -> nil
    end
  end

  test "conformance/channels.json: the providers' requests, errors, Twilio's partial delivery and the cuts" do
    f = Conformance.fixture("channels")
    {by_name, first} = alerts(f)
    rec = RecordingTransport.start()
    counts = %{}

    {failures, n} =
      Enum.reduce(list(f, "providerSends"), {[], 0}, fn c, {failures, n} ->
        o = field(c, "options")
        {module, state} = build(field(c, "channel"), o, rec)
        RecordingTransport.answer_with(rec, 200, "")
        what = "#{field(c, "channel")} #{JS.stringify(o)} #{field(c, "alert")}"

        case module.send(state, Map.fetch!(by_name, field(c, "alert")), ctx()) do
          :ok ->
            got = rec |> RecordingTransport.taken() |> number_order(field(o, "to"))
            want = list(c, "requests")

            if length(got) != length(want) do
              {["#{what}: #{length(got)} requests, want #{length(want)}" | failures], n + 1}
            else
              errs = got |> Enum.zip(want) |> Enum.map(fn {g, w} -> same_request(g, w) end) |> Enum.reject(&is_nil/1)
              {Enum.map(errs, &"#{what}: #{&1}") ++ failures, n + 1}
            end

          {:error, e} ->
            {["#{what}: #{Cronwatch.Error.describe(e)}" | failures], n + 1}
        end
      end)

    counts = Map.put(counts, "providerSends", n)

    {failures, n} =
      Enum.reduce(list(f, "providerFailures"), {failures, 0}, fn c, {failures, n} ->
        o = field(c, "options")
        {module, state} = build(field(c, "channel"), o, rec)
        RecordingTransport.answer_with(rec, field(c, "status"), field(c, "body"))

        got =
          case module.send(state, first, ctx()) do
            :ok -> nil
            {:error, e} -> Cronwatch.Error.describe(e)
          end

        if got == field(c, "error"),
          do: {failures, n + 1},
          else:
            {[
               "#{field(c, "channel")} #{JS.stringify(o)}: got #{inspect(got)}, want #{inspect(field(c, "error"))}"
               | failures
             ], n + 1}
      end)

    counts = Map.put(counts, "providerFailures", n)

    partial = field(f, "twilioPartial")
    o = field(partial, "options")
    numbers = field(o, "to")

    {failures, n} =
      Enum.reduce(list(partial, "cases"), {failures, 0}, fn c, {failures, n} ->
        statuses = field(c, "statuses")

        RecordingTransport.answer_by(rec, fn body ->
          to = form_to(IO.iodata_to_binary(body))

          case Enum.find_index(numbers, &(&1 == to)) do
            nil ->
              {500, ""}

            i ->
              if Enum.at(statuses, i) < 400,
                do: {Enum.at(statuses, i), "{}"},
                else: {Enum.at(statuses, i), ~s({"message":"refused #{to} with tw-secret"})}
          end
        end)

        {:ok, reported} = Agent.start_link(fn -> [] end)
        {module, state} = build("twilio", o, rec)
        ctx = ctx(fn e -> Agent.update(reported, &(&1 ++ [Cronwatch.Error.describe(e)])) end)

        error =
          case module.send(state, first, ctx) do
            :ok -> nil
            {:error, e} -> Cronwatch.Error.describe(e)
          end

        got_reported = Agent.get(reported, & &1)
        requests = rec |> RecordingTransport.taken() |> number_order(numbers)

        wrong =
          [
            error != field(c, "error") && "error #{inspect(error)}, want #{inspect(field(c, "error"))}",
            got_reported != field(c, "reported") &&
              "reported #{inspect(got_reported)}, want #{inspect(field(c, "reported"))}",
            Enum.map(requests, &{&1.url, form_to(IO.iodata_to_binary(&1.body))}) !=
              Enum.map(list(c, "requests"), &{field(&1, "url"), field(&1, "to")}) && "requests differ"
          ]
          |> Enum.filter(& &1)
          |> Enum.map(&"twilio #{inspect(statuses)}: #{&1}")

        {wrong ++ failures, n + 1}
      end)

    counts = Map.put(counts, "twilioPartial", n)
    cuts = field(f, "textCuts")

    {failures, n} =
      Enum.reduce(list(cuts, "subjects"), {failures, 0}, fn c, {failures, n} ->
        {:ok, email} =
          Alerts.Email.options(Alerts.Resend,
            from: "a@example.com",
            to: "b@example.com",
            subject_prefix: field(c, "subjectPrefix")
          )

        got = Alerts.Email.compose(%{first | title: field(c, "title")}, email).subject

        if got == field(c, "subject"),
          do: {failures, n + 1},
          else:
            {[
               "subject of #{inspect(field(c, "title"))}: #{inspect(got)}, want #{inspect(field(c, "subject"))}"
               | failures
             ], n + 1}
      end)

    {failures, n} =
      Enum.reduce(list(cuts, "smsSegments"), {failures, n}, fn c, {failures, n} ->
        got = Alerts.Twilio.sms_segments(field(c, "text"))

        if got == field(c, "segments"),
          do: {failures, n + 1},
          else: {["smsSegments(#{inspect(field(c, "text"))}) = #{got}, want #{field(c, "segments")}" | failures], n + 1}
      end)

    long = %{
      first
      | title: "nightly failed",
        message: String.duplicate(String.duplicate("a", 152) <> "{\n", 12),
        triage: nil
    }

    {failures, n} =
      Enum.reduce(list(cuts, "smsBodies"), {failures, n}, fn c, {failures, n} ->
        link =
          if field(c, "link") == "long",
            do: "https://app.example/" <> String.duplicate("p", 2000),
            else: "https://app.example/j"

        got = JS.stringify(digest(Alerts.Twilio.sms_body(long, link, field(c, "segments"))))

        if got == JS.stringify(field(c, "body")),
          do: {failures, n + 1},
          else: {["smsBody with #{inspect(field(c, "segments"))} segments: #{got}" | failures], n + 1}
      end)

    counts = Map.put(counts, "textCuts", n)

    assert failures == [],
           "channels.json: #{length(failures)} cases differ:\n" <> Enum.join(Enum.reverse(failures), "\n")

    # Every case of these sections, so a case added there is not skipped here.
    assert counts == %{
             "providerSends" => length(list(f, "providerSends")),
             "providerFailures" => length(list(f, "providerFailures")),
             "twilioPartial" => length(list(partial, "cases")),
             "textCuts" => Enum.sum(for k <- ~w(subjects smsSegments smsBodies), do: length(list(cuts, k)))
           }
  end
end
