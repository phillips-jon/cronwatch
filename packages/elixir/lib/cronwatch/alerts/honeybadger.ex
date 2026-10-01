defmodule Cronwatch.Alerts.Honeybadger do
  @moduledoc """
  Reports alerts to Honeybadger as notices (`alerts/honeybadger.ts`), one
  fault per job and alert type: a POST to
  `https://api.honeybadger.io/v1/notices` with `x-api-key`.

      {Cronwatch.Alerts.Honeybadger, api_key: System.fetch_env!("HONEYBADGER_API_KEY")}

  Options: `:api_key` (required, a project API key), `:environment`
  (default `"production"`), `:endpoint` (the API's origin,
  `"https://eu-api.honeybadger.io"` for the EU), `:recovered` (default
  false: a notice is for what broke), `:link` (sent as the notice's URL) and
  `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:api_key, :transport]}
  defstruct [:api_key, :url, :environment, :recovered, :link, :transport]

  @classes %{
    "missed" => "CronWatch::Missed",
    "failed" => "CronWatch::Failed",
    "stuck" => "CronWatch::Stuck",
    "slow" => "CronWatch::Slow",
    "over_budget" => "CronWatch::OverBudget",
    "recovered" => "CronWatch::Recovered"
  }

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         # A pasted credential often carries a stray space or newline, which a header would refuse or send.
         {:key, api_key} when api_key != "" <- {:key, Provider.secret(opts, :api_key)},
         {:ok, recovered} <- Provider.flag(__MODULE__, opts, :recovered, false),
         {:ok, link} <- Provider.link(__MODULE__, opts) do
      endpoint = Provider.or_default(Provider.str(opts, :endpoint), "https://api.honeybadger.io")

      {:ok,
       %__MODULE__{
         api_key: api_key,
         url: String.replace(endpoint, ~r/\/+\z/, "") <> "/v1/notices",
         environment: Provider.or_default(Provider.str(opts, :environment), "production"),
         recovered: recovered,
         link: link,
         transport: opts[:transport]
       }}
    else
      {:key, _} -> {:error, "#{inspect(__MODULE__)} needs :api_key"}
      {:error, _} = e -> e
    end
  end

  @impl true
  def name(_), do: "honeybadger"

  @impl true
  def send(%__MODULE__{recovered: false}, %{type: "recovered"}, _ctx), do: :ok

  def send(%__MODULE__{} = s, alert, ctx) do
    link = Shared.link_for(s.link, alert)
    kind = alert.type
    triage = Shared.triage(alert)

    context =
      [{"job", alert.job}, {"type", kind}] ++
        if(triage == "", do: [], else: [{"triage", triage}]) ++
        [{"details", Shared.details(alert)}, {"run", Shared.run_summary(alert)}]

    request =
      [{"component", "cronwatch"}, {"action", alert.job}] ++
        if(link == "", do: [], else: [{"url", link}]) ++ [{"context", Object.new(context)}]

    error =
      Object.new([
        {"class", Map.get(@classes, kind, "CronWatch::#{kind}")},
        {"message", Post.cut("#{alert.title}\n#{alert.message}", 8000)},
        {"backtrace", [Object.new([{"number", "0"}, {"file", "cronwatch/#{alert.job}"}, {"method", kind}])]},
        {"fingerprint", "cronwatch:#{alert.job}:#{kind}"},
        {"tags", ["cronwatch", kind]}
      ])

    notice =
      Object.new([
        {"notifier", Object.new([{"name", "cronwatch"}, {"url", "https://cronwatch.dev"}])},
        {"error", error},
        {"request", Object.new(request)},
        {"server", Object.new([{"environment_name", s.environment}])}
      ])

    headers = [{"content-type", "application/json"}, {"accept", "application/json"}, {"x-api-key", s.api_key}]
    Shared.send(s.transport || ctx.transport, "Honeybadger", s.url, headers, JS.stringify(notice), [s.api_key])
  end
end
