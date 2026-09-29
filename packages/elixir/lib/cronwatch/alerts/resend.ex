defmodule Cronwatch.Alerts.Resend do
  @moduledoc """
  Sends alerts as email through Resend (`alerts/resend.ts`): a POST to
  `https://api.resend.com/emails` with a bearer API key.

      {Cronwatch.Alerts.Resend,
       api_key: System.fetch_env!("RESEND_API_KEY"),
       from: "CronWatch <alerts@example.com>", to: ["ops@example.com"]}

  Options: `:api_key` (required, `re_...`), the email options of
  `Cronwatch.Alerts.Email` (`:from`, `:to`, `:subject_prefix`, `:link`, at
  the top level or under `email:`), and `:transport` (a
  `Cronwatch.Transport`; the default is `:httpc`). The same alert sent twice
  within 24 hours is delivered once, through Resend's idempotency key.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Email
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :email, :transport]

  @endpoint "https://api.resend.com/emails"

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         # A pasted credential often carries a stray space or newline, which a header would refuse or send.
         {:key, api_key} when api_key != "" <- {:key, Provider.secret(opts, :api_key)},
         {:ok, email} <- Email.options(__MODULE__, opts) do
      {:ok, %__MODULE__{api_key: api_key, email: email, transport: opts[:transport]}}
    else
      {:key, _} -> {:error, "#{inspect(__MODULE__)} needs :api_key"}
      {:error, _} = e -> e
    end
  end

  @impl true
  def name(_), do: "resend"

  @impl true
  def send(%__MODULE__{} = s, alert, ctx) do
    m = Email.compose(alert, s.email)

    body =
      JS.stringify(
        Object.new([{"from", m.from}, {"to", m.to}, {"subject", m.subject}, {"text", m.text}, {"html", m.html}])
      )

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{s.api_key}"},
      # The same alert sent twice within 24 hours is delivered once.
      {"idempotency-key", "cronwatch-#{Shared.alert_id(alert)}"}
    ]

    Shared.send(s.transport || ctx.transport, "Resend", @endpoint, headers, body, [s.api_key])
  end
end
