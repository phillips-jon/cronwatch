defmodule Cronwatch.Alerts.Rollbar do
  @moduledoc """
  Sends alerts to Rollbar as items (`alerts/rollbar.ts`), one item per job
  and alert type: a POST to `https://api.rollbar.com/api/1/item/` with
  `x-rollbar-access-token`.

      {Cronwatch.Alerts.Rollbar, access_token: System.fetch_env!("ROLLBAR_ACCESS_TOKEN")}

  Options: `:access_token` (required, with the `post_server_item` scope),
  `:environment` (default `"production"`), `:recovered` (default true:
  recoveries are sent, as info items; `false` leaves them out), `:link`
  (sent as custom data), and `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:token, :transport]}
  defstruct [:token, :environment, :recovered, :link, :transport]

  @endpoint "https://api.rollbar.com/api/1/item/"

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         # A pasted credential often carries a stray space or newline, which a header would refuse or send.
         {:key, token} when token != "" <- {:key, Provider.secret(opts, :access_token)},
         {:ok, recovered} <- Provider.flag(__MODULE__, opts, :recovered, true),
         {:ok, link} <- Provider.link(__MODULE__, opts) do
      {:ok,
       %__MODULE__{
         token: token,
         environment: Provider.or_default(Provider.str(opts, :environment), "production"),
         recovered: recovered,
         link: link,
         transport: opts[:transport]
       }}
    else
      {:key, _} -> {:error, "#{inspect(__MODULE__)} needs :access_token"}
      {:error, _} = e -> e
    end
  end

  @impl true
  def name(_), do: "rollbar"

  @impl true
  def send(%__MODULE__{recovered: false}, %{type: "recovered"}, _ctx), do: :ok

  def send(%__MODULE__{} = s, alert, ctx) do
    link = Shared.link_for(s.link, alert)
    triage = Shared.triage(alert)

    custom =
      [{"job", alert.job}, {"type", alert.type}] ++
        if(triage == "", do: [], else: [{"triage", triage}]) ++
        if(link == "", do: [], else: [{"link", link}]) ++
        [{"details", Shared.details(alert)}, {"run", Shared.run_summary(alert)}]

    data =
      Object.new([
        {"environment", Post.cut(s.environment, 255)},
        {"level", Shared.severity(alert.type)},
        {"timestamp", JS.floor_div(alert.at, 1000)},
        {"title", Post.cut(alert.title, 255)},
        {"fingerprint", "cronwatch:#{alert.job}:#{alert.type}"},
        {"uuid", Shared.as_uuid(Shared.alert_id(alert))},
        {"body", Object.new([{"message", Object.new([{"body", alert.message}])}])},
        {"custom", Object.new(custom)},
        {"notifier", Object.new([{"name", "cronwatch"}])}
      ])

    headers = [{"content-type", "application/json"}, {"x-rollbar-access-token", s.token}]

    Shared.send(
      s.transport || ctx.transport,
      "Rollbar",
      @endpoint,
      headers,
      JS.stringify(Object.new([{"data", data}])),
      [s.token]
    )
  end
end
