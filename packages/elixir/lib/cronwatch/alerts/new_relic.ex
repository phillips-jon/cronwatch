defmodule Cronwatch.Alerts.NewRelic do
  @moduledoc """
  Sends alerts to New Relic as custom events through the Event API
  (`alerts/newrelic.ts`): a POST to
  `https://insights-collector.newrelic.com/v1/accounts/<id>/events`
  (`insights-collector.eu01.nr-data.net` for EU accounts) with `api-key`.

      {Cronwatch.Alerts.NewRelic, account_id: 1234567, api_key: System.fetch_env!("NEW_RELIC_LICENSE_KEY")}

  Options: `:account_id` (required, the number in your New Relic URLs, as
  an integer or text), `:api_key` (required, a license key), `:region`
  (`"eu"` for an account in the EU data center), `:event_type` (the event
  type queried with NRQL, default `"CronWatchAlert"`), `:link` (sent as an
  attribute) and `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:api_key, :transport]}
  defstruct [:api_key, :url, :event_type, :link, :transport]

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         # A pasted credential often carries a stray space or newline, which a header would refuse or send.
         {:key, api_key} when api_key != "" <- {:key, Provider.secret(opts, :api_key)},
         {:account, account} <- {:account, account(Keyword.get(opts, :account_id))},
         true <- Regex.match?(~r/\A[0-9]+\z/, account) || {:account, account},
         {:ok, link} <- Provider.link(__MODULE__, opts) do
      host =
        if Provider.str(opts, :region) == "eu",
          do: "https://insights-collector.eu01.nr-data.net",
          else: "https://insights-collector.newrelic.com"

      {:ok,
       %__MODULE__{
         api_key: api_key,
         url: "#{host}/v1/accounts/#{account}/events",
         event_type: Provider.or_default(Provider.str(opts, :event_type), "CronWatchAlert"),
         link: link,
         transport: opts[:transport]
       }}
    else
      {:key, _} -> {:error, "#{inspect(__MODULE__)} needs :api_key"}
      {:account, _} -> {:error, "#{inspect(__MODULE__)} needs a numeric :account_id"}
      {:error, _} = e -> e
    end
  end

  # `String(accountId)`.
  defp account(n) when is_integer(n) or is_float(n), do: JS.format_number(JS.normalize(n))
  defp account(s) when is_binary(s), do: s
  defp account(_), do: ""

  @impl true
  def name(_), do: "newrelic"

  @impl true
  def send(%__MODULE__{} = s, alert, ctx) do
    link = Shared.link_for(s.link, alert)
    triage = Shared.triage(alert)

    run =
      case alert.run do
        nil ->
          []

        r ->
          [{"runId", r.id}, {"runStatus", r.status}] ++
            if(r.duration_ms == nil, do: [], else: [{"durationMs", r.duration_ms}])
      end

    event =
      [
        {"eventType", s.event_type},
        {"timestamp", alert.at},
        {"job", Post.cut(alert.job, 4095)},
        {"alertType", alert.type},
        {"severity", Shared.severity(alert.type)},
        {"title", Post.cut(alert.title, 4095)},
        {"message", Post.cut(alert.message, 4095)}
      ] ++
        if(triage == "", do: [], else: [{"triage", Post.cut(triage, 4095)}]) ++
        if(link == "", do: [], else: [{"link", Post.cut(link, 4095)}]) ++ run

    headers = [{"content-type", "application/json"}, {"api-key", s.api_key}]

    Shared.send(s.transport || ctx.transport, "New Relic", s.url, headers, JS.stringify([Object.new(event)]), [
      s.api_key
    ])
  end
end
