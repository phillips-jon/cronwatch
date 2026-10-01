defmodule Cronwatch.Alerts.SendGrid do
  @moduledoc """
  Sends alerts as email through SendGrid (`alerts/sendgrid.ts`): a POST to
  `https://api.sendgrid.com/v3/mail/send` (`api.eu.sendgrid.com` for EU
  subusers) with a bearer API key.

      {Cronwatch.Alerts.SendGrid,
       api_key: System.fetch_env!("SENDGRID_API_KEY"),
       from: "alerts@example.com", to: "ops@example.com"}

  Options: `:api_key` (required, with Mail Send access), `:region` (`"eu"`
  for an EU regional subuser), the email options of `Cronwatch.Alerts.Email`,
  and `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Email
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:api_key, :transport]}
  defstruct [:api_key, :url, :email, :transport]

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         {:key, api_key} when api_key != "" <- {:key, Provider.secret(opts, :api_key)},
         {:ok, email} <- Email.options(__MODULE__, opts) do
      url =
        if Provider.str(opts, :region) == "eu",
          do: "https://api.eu.sendgrid.com/v3/mail/send",
          else: "https://api.sendgrid.com/v3/mail/send"

      {:ok, %__MODULE__{api_key: api_key, url: url, email: email, transport: opts[:transport]}}
    else
      {:key, _} -> {:error, "#{inspect(__MODULE__)} needs :api_key"}
      {:error, _} = e -> e
    end
  end

  @impl true
  def name(_), do: "sendgrid"

  @impl true
  def send(%__MODULE__{} = s, alert, ctx) do
    m = Email.compose(alert, s.email)
    content = fn type, value -> Object.new([{"type", type}, {"value", value}]) end

    body =
      JS.stringify(
        Object.new([
          {"personalizations", [Object.new([{"to", Enum.map(m.to, &Email.parse_address/1)}])]},
          {"from", Email.parse_address(m.from)},
          {"subject", m.subject},
          # text/plain must come before text/html.
          {"content", [content.("text/plain", m.text), content.("text/html", m.html)]},
          {"categories", ["cronwatch"]}
        ])
      )

    headers = [{"content-type", "application/json"}, {"authorization", "Bearer #{s.api_key}"}]
    Shared.send(s.transport || ctx.transport, "SendGrid", s.url, headers, body, [s.api_key])
  end
end
