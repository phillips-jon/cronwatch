defmodule Cronwatch.Alerts.Sentry do
  @moduledoc """
  Sends alerts to Sentry as events through its envelope endpoint
  (`alerts/sentry.ts`), one issue per job and alert type.

      {Cronwatch.Alerts.Sentry, dsn: System.fetch_env!("SENTRY_DSN")}

  Options: `:dsn` (required, `https://<key>@o0.ingest.sentry.io/<project>`),
  `:environment` (default `"production"`), `:release`, `:recovered` (default
  true: recoveries are sent, as info events; `false` leaves them out),
  `:link` (a function of the alert, sent as extra data) and `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:public_key]}
  defstruct [:endpoint, :public_key, :environment, :release, :recovered, :link, :transport]

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         # A pasted credential often carries a stray space or newline, which a header would refuse or send.
         {:dsn, dsn} when dsn != "" <- {:dsn, Provider.secret(opts, :dsn)},
         {:ok, endpoint, public_key} <- parse_dsn(dsn),
         {:ok, recovered} <- Provider.flag(__MODULE__, opts, :recovered, true),
         {:ok, link} <- Provider.link(__MODULE__, opts) do
      {:ok,
       %__MODULE__{
         endpoint: endpoint,
         public_key: public_key,
         environment: Provider.or_default(Provider.str(opts, :environment), "production"),
         release: Provider.str(opts, :release),
         recovered: recovered,
         link: link,
         transport: opts[:transport]
       }}
    else
      {:dsn, _} -> {:error, "#{inspect(__MODULE__)} needs :dsn"}
      {:error, _} = e -> e
    end
  end

  @doc false
  # The envelope endpoint and the public key of a DSN, as the SDK's
  # parseDsn reads them.
  def parse_dsn(dsn) do
    case URI.new(dsn) do
      {:ok, %URI{scheme: scheme, host: host} = url} when is_binary(scheme) and is_binary(host) and host != "" ->
        segments = (url.path || "") |> String.split("/") |> Enum.reject(&(&1 == ""))
        {project, rest} = List.pop_at(segments, -1)
        user = (url.userinfo || "") |> String.split(":", parts: 2) |> hd()

        if user == "" or project == nil or not Regex.match?(~r/\A[0-9]+\z/, project) do
          {:error, "#{inspect(__MODULE__)} needs a :dsn like https://<key>@<host>/<project>"}
        else
          prefix = if rest == [], do: "", else: "/" <> Enum.join(rest, "/")
          host = String.downcase(host)
          host = if url.port == nil or url.port == URI.default_port(scheme), do: host, else: "#{host}:#{url.port}"
          {:ok, "#{scheme}://#{host}#{prefix}/api/#{project}/envelope/", Post.percent_decode(user)}
        end

      _ ->
        {:error, "#{inspect(__MODULE__)} needs a valid :dsn"}
    end
  end

  @impl true
  def name(_), do: "sentry"

  @impl true
  def send(%__MODULE__{recovered: false}, %{type: "recovered"}, _ctx), do: :ok

  def send(%__MODULE__{} = s, alert, ctx) do
    event_id = Shared.alert_id(alert)
    link = Shared.link_for(s.link, alert)
    triage = Shared.triage(alert)

    extra =
      if(triage == "", do: [], else: [{"triage", triage}]) ++
        if(link == "", do: [], else: [{"link", link}]) ++
        [{"details", Shared.details(alert)}, {"run", Shared.run_summary(alert)}]

    event =
      [
        {"event_id", event_id},
        {"timestamp", JS.normalize(alert.at / 1000)},
        {"platform", "other"},
        {"level", Shared.severity(alert.type)},
        {"logger", "cronwatch"},
        {"transaction", alert.job},
        {"environment", s.environment}
      ] ++
        if(s.release == "", do: [], else: [{"release", s.release}]) ++
        [
          # The first line is the issue title.
          {"logentry", Object.new([{"formatted", Post.cut("#{alert.title}\n\n#{alert.message}", 8192)}])},
          {"fingerprint", ["cronwatch", alert.job, alert.type]},
          {"tags", Object.new([{"job", Post.cut(alert.job, 199)}, {"type", alert.type}])},
          {"extra", Object.new(extra)}
        ]

    payload = JS.stringify(Object.new(event))

    header =
      JS.stringify(
        Object.new([{"type", "event"}, {"content_type", "application/json"}, {"length", byte_size(payload)}])
      )

    envelope = "#{JS.stringify(Object.new([{"event_id", event_id}]))}\n#{header}\n#{payload}\n"

    headers = [
      {"content-type", "application/x-sentry-envelope"},
      {"x-sentry-auth", "Sentry sentry_version=7, sentry_key=#{s.public_key}, sentry_client=cronwatch"}
    ]

    Shared.send(s.transport || ctx.transport, "Sentry", s.endpoint, headers, envelope, [s.public_key])
  end
end
