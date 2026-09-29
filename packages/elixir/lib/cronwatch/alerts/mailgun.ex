defmodule Cronwatch.Alerts.Mailgun do
  @moduledoc """
  Sends alerts as email through Mailgun (`alerts/mailgun.ts`): a form
  encoded POST to `https://api.mailgun.net/v3/<domain>/messages`
  (`api.eu.mailgun.net` for the EU region) with basic auth `api:<key>`.

      {Cronwatch.Alerts.Mailgun,
       api_key: System.fetch_env!("MAILGUN_API_KEY"), domain: "mg.example.com",
       from: "alerts@mg.example.com", to: "ops@example.com"}

  Options: `:api_key` and `:domain` (required), `:region` (`"eu"` for a
  domain in the EU region), the email options of `Cronwatch.Alerts.Email`,
  and `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Email
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared

  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :url, :email, :transport]

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         {:key, api_key} when api_key != "" <- {:key, Provider.secret(opts, :api_key)},
         {:domain, domain} when domain != "" <- {:domain, Provider.str(opts, :domain)},
         {:ok, email} <- Email.options(__MODULE__, opts) do
      host = if Provider.str(opts, :region) == "eu", do: "https://api.eu.mailgun.net", else: "https://api.mailgun.net"
      url = "#{host}/v3/#{Shared.encode_uri_component(domain)}/messages"
      {:ok, %__MODULE__{api_key: api_key, url: url, email: email, transport: opts[:transport]}}
    else
      {:key, _} -> {:error, "#{inspect(__MODULE__)} needs :api_key"}
      {:domain, _} -> {:error, "#{inspect(__MODULE__)} needs :domain"}
      {:error, _} = e -> e
    end
  end

  @impl true
  def name(_), do: "mailgun"

  @impl true
  def send(%__MODULE__{} = s, alert, ctx) do
    m = Email.compose(alert, s.email)

    pairs =
      [{"from", m.from}] ++
        Enum.map(m.to, &{"to", &1}) ++
        [{"subject", m.subject}, {"text", m.text}, {"html", m.html}, {"o:tag", "cronwatch"}]

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"authorization", Shared.basic_auth("api", s.api_key)}
    ]

    Shared.send(s.transport || ctx.transport, "Mailgun", s.url, headers, Shared.form(pairs), [s.api_key])
  end
end
