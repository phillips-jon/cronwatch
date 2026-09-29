defmodule Cronwatch.Alerts.Datadog do
  @moduledoc """
  Sends alerts to Datadog as events (`alerts/datadog.ts`), one aggregation
  per job and alert type: a POST to `https://api.<site>/api/v1/events` with
  `dd-api-key`.

      {Cronwatch.Alerts.Datadog, api_key: System.fetch_env!("DD_API_KEY"), tags: ["env:prod"]}

  Options: `:api_key` (required, an API key, not an application key),
  `:site` (default `"datadoghq.com"`; `"datadoghq.eu"`,
  `"us3.datadoghq.com"`, `"us5.datadoghq.com"`, `"ap1.datadoghq.com"`,
  `"ddog-gov.com"`), `:tags` (added to every event), `:host` (the host the
  event is about), `:link` (put in the event's text) and `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :url, :tags, :host, :link, :transport]

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         # A pasted credential often carries a stray space or newline, which a header would refuse or send.
         {:key, api_key} when api_key != "" <- {:key, Provider.secret(opts, :api_key)},
         {:ok, site} <- site(Keyword.get(opts, :site, "datadoghq.com")),
         {:ok, link} <- Provider.link(__MODULE__, opts) do
      {:ok,
       %__MODULE__{
         api_key: api_key,
         url: "https://api.#{site}/api/v1/events",
         tags: opts |> Keyword.get(:tags, []) |> List.wrap() |> Enum.filter(&is_binary/1),
         host: Provider.str(opts, :host),
         link: link,
         transport: opts[:transport]
       }}
    else
      {:key, _} -> {:error, "#{inspect(__MODULE__)} needs :api_key"}
      {:error, _} = e -> e
    end
  end

  @doc false
  # The site as the SDK reads it: no scheme, no `api.` or `app.` in front, no
  # slashes after.
  def clean_site(site) do
    site
    |> String.replace(~r/\Ahttps?:\/\//, "")
    |> String.replace(~r/\A(api|app)\./, "")
    |> String.replace(~r/\/+\z/, "")
  end

  defp site(site) when is_binary(site) do
    site = clean_site(site)

    if Regex.match?(~r/\A[a-z0-9.-]+\z/i, site),
      do: {:ok, site},
      else: {:error, ~s(#{inspect(__MODULE__)} needs :site like "datadoghq.com")}
  end

  defp site(_), do: {:error, ~s(#{inspect(__MODULE__)} needs :site like "datadoghq.com")}

  @impl true
  def name(_), do: "datadog"

  @impl true
  def send(%__MODULE__{} = s, alert, ctx) do
    link = Shared.link_for(s.link, alert)

    event =
      [
        {"title", Post.cut(alert.title, 500)},
        {"text", Post.cut(Shared.plain_text(alert, link), 4000)},
        {"alert_type", alert_type(alert.type)},
        {"aggregation_key", aggregation_key(alert)},
        {"date_happened", JS.floor_div(alert.at, 1000)},
        {"priority", "normal"},
        {"tags", ["cronwatch", "job:#{alert.job}", "alert:#{alert.type}" | s.tags]}
      ] ++ if(s.host == "", do: [], else: [{"host", s.host}])

    headers = [{"content-type", "application/json"}, {"accept", "application/json"}, {"dd-api-key", s.api_key}]
    Shared.send(s.transport || ctx.transport, "Datadog", s.url, headers, JS.stringify(Object.new(event)), [s.api_key])
  end

  defp alert_type(type) when type in ["slow", "over_budget"], do: "warning"
  defp alert_type("recovered"), do: "success"
  defp alert_type(_), do: "error"

  # Datadog's aggregation key is at most 100 characters: a long job name is
  # hashed.
  defp aggregation_key(alert) do
    key = "cronwatch:#{alert.job}:#{alert.type}"
    if JS.len16(key) <= 100, do: key, else: "cronwatch:" <> binary_part(Shared.sha256_hex(key), 0, 40)
  end
end
