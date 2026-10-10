defmodule Cronwatch.Test.RewriteTransport do
  @moduledoc """
  A transport that sends every request to a local test server instead of
  where it was addressed (the scheme, host, and port rewritten, the path and
  query kept) through `Cronwatch.Transport.HTTP`, so a provider's channel
  can be pointed at `Cronwatch.Test.HTTPServer`. Options: `to:` the
  server's URL, and any `Cronwatch.Transport.HTTP` options.
  """

  @behaviour Cronwatch.Transport

  alias Cronwatch.Alerts.URL
  alias Cronwatch.Transport.HTTP

  def spec(server, opts \\ []), do: {__MODULE__, Keyword.put(opts, :to, server.url)}

  @impl true
  def post(opts, request) do
    {:ok, to} = URL.parse(Keyword.fetch!(opts, :to))
    {:ok, u} = URL.parse(request.url)
    url = URL.to_string(%{u | scheme: to.scheme, host: to.host, port: to.port})
    HTTP.post(Keyword.delete(opts, :to), %{request | url: url})
  end
end

defmodule Cronwatch.Test.EveryChannel do
  @moduledoc """
  One of each alert channel, for the tests every channel must pass (a
  redirect refused by all of them): `specs(webhook_url, transport)` answers
  `{module, opts}` for each, posting through `transport`, the webhook-shaped
  ones to `webhook_url`. A channel added to the package is added here.
  """

  @doc "The channels, as `{module, opts}`."
  def specs(webhook_url, transport) do
    [
      {Cronwatch.Alerts.Webhook,
       url: webhook_url, headers: [{"authorization", "Bearer wh-secret"}], secret: "s", transport: transport},
      {Cronwatch.Alerts.Slack, webhook_url: webhook_url, transport: transport},
      {Cronwatch.Alerts.Discord, webhook_url: webhook_url, transport: transport}
    ] ++ providers(transport)
  end

  # The provider channels, when they are compiled in.
  defp providers(transport) do
    [
      {Cronwatch.Alerts.Datadog, api_key: "dd-secret-key-123"},
      {Cronwatch.Alerts.Resend, api_key: "re_secret", from: "a@b.c", to: ["d@e.f"]},
      {Cronwatch.Alerts.Postmark, server_token: "pm-secret", from: "a@b.c", to: ["d@e.f"]},
      {Cronwatch.Alerts.SendGrid, api_key: "SG.secret", from: "a@b.c", to: ["d@e.f"]},
      {Cronwatch.Alerts.Mailgun, api_key: "key-secret", domain: "mg.example.com", from: "a@b.c", to: ["d@e.f"]},
      {Cronwatch.Alerts.SES,
       region: "us-east-1",
       access_key_id: "AKIDEXAMPLE",
       secret_access_key: "sekret-sekret",
       from: "a@b.c",
       to: ["d@e.f"]},
      {Cronwatch.Alerts.Twilio, account_sid: "AC1", auth_token: "tw-secret", from: "+1", to: ["+2"]},
      {Cronwatch.Alerts.Sentry, dsn: "https://pubkey@o1.ingest.sentry.example/42"},
      {Cronwatch.Alerts.Honeybadger, api_key: "hb-secret"},
      {Cronwatch.Alerts.Rollbar, access_token: "rb-secret"},
      {Cronwatch.Alerts.Bugsnag, api_key: "bs-secret"},
      {Cronwatch.Alerts.NewRelic, account_id: "1", api_key: "nr-secret"}
    ]
    |> Enum.filter(fn {m, _} -> Code.ensure_loaded?(m) end)
    |> Enum.map(fn {m, opts} -> {m, opts ++ [transport: transport]} end)
  end

  @doc "The channels, each started with its init/1: `{module, state}`."
  def started(webhook_url, transport) do
    Enum.map(specs(webhook_url, transport), fn {m, opts} ->
      {:ok, state} = m.init(opts)
      {m, state}
    end)
  end
end
