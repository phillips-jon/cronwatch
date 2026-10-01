defmodule Cronwatch.Alerts.Bugsnag do
  @moduledoc """
  Reports alerts to Bugsnag as handled events through its Error Reporting
  API (`alerts/bugsnag.ts`), grouped per job and alert type: a POST to
  `https://notify.bugsnag.com/` with `bugsnag-api-key`, payload version 5.

      {Cronwatch.Alerts.Bugsnag, api_key: System.fetch_env!("BUGSNAG_API_KEY")}

  Options: `:api_key` (required, a project's notifier API key),
  `:release_stage` (default `"production"`), `:endpoint` (the notify
  endpoint, for on-premise Bugsnag), `:recovered` (default false: an event
  is for what broke), `:now` (the clock `bugsnag-sent-at` is read from, in
  epoch milliseconds, for tests), `:link` (sent as metadata) and
  `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:api_key, :transport]}
  defstruct [:api_key, :url, :stage, :recovered, :now, :link, :transport]

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         # A pasted credential often carries a stray space or newline, which a header would refuse or send.
         {:key, api_key} when api_key != "" <- {:key, Provider.secret(opts, :api_key)},
         {:ok, recovered} <- Provider.flag(__MODULE__, opts, :recovered, false),
         {:ok, now} <- Provider.clock(__MODULE__, opts),
         {:ok, link} <- Provider.link(__MODULE__, opts) do
      {:ok,
       %__MODULE__{
         api_key: api_key,
         url: Provider.or_default(Provider.str(opts, :endpoint), "https://notify.bugsnag.com/"),
         stage: Provider.or_default(Provider.str(opts, :release_stage), "production"),
         recovered: recovered,
         now: now,
         link: link,
         transport: opts[:transport]
       }}
    else
      {:key, _} -> {:error, "#{inspect(__MODULE__)} needs :api_key"}
      {:error, _} = e -> e
    end
  end

  @impl true
  def name(_), do: "bugsnag"

  @impl true
  def send(%__MODULE__{recovered: false}, %{type: "recovered"}, _ctx), do: :ok

  def send(%__MODULE__{} = s, alert, ctx) do
    link = Shared.link_for(s.link, alert)
    kind = alert.type
    triage = Shared.triage(alert)

    meta =
      [{"job", alert.job}, {"type", kind}] ++
        if(triage == "", do: [], else: [{"triage", triage}]) ++
        if(link == "", do: [], else: [{"link", link}]) ++
        [{"details", Shared.details(alert)}, {"run", Shared.run_summary(alert)}]

    exception =
      Object.new([
        {"errorClass", "CronWatch #{kind}"},
        {"message", Post.cut("#{alert.title}\n#{alert.message}", 8000)},
        {"stacktrace", []},
        {"type", "nodejs"}
      ])

    event =
      Object.new([
        {"exceptions", [exception]},
        {"severity", Shared.severity(kind)},
        {"unhandled", false},
        {"severityReason", Object.new([{"type", "handledException"}])},
        {"context", alert.job},
        {"groupingHash", "cronwatch:#{alert.job}:#{kind}"},
        {"metaData", Object.new([{"cronwatch", Object.new(meta)}])},
        {"app", Object.new([{"releaseStage", s.stage}])},
        {"device", Object.new([{"time", JS.iso_string(alert.at)}])}
      ])

    payload =
      Object.new([
        {"apiKey", s.api_key},
        {"payloadVersion", "5"},
        {"notifier", Object.new([{"name", "cronwatch"}, {"version", "1.0.0"}, {"url", "https://cronwatch.dev"}])},
        {"events", [event]}
      ])

    headers = [
      {"content-type", "application/json"},
      {"bugsnag-api-key", s.api_key},
      {"bugsnag-payload-version", "5"},
      {"bugsnag-sent-at", JS.iso_string(Provider.now(s.now))}
    ]

    Shared.send(s.transport || ctx.transport, "Bugsnag", s.url, headers, JS.stringify(payload), [s.api_key])
  end
end
