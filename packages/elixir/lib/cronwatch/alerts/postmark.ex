defmodule Cronwatch.Alerts.Postmark do
  @moduledoc """
  Sends alerts as email through Postmark (`alerts/postmark.ts`): a POST to
  `https://api.postmarkapp.com/email` with `x-postmark-server-token`.

      {Cronwatch.Alerts.Postmark,
       server_token: System.fetch_env!("POSTMARK_SERVER_TOKEN"),
       from: "alerts@example.com", to: "ops@example.com"}

  Options: `:server_token` (required, from the server's API Tokens tab),
  `:message_stream` (default `"outbound"`, the transactional stream), the
  email options of `Cronwatch.Alerts.Email`, and `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Email
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:token, :transport]}
  defstruct [:token, :stream, :email, :transport]

  @endpoint "https://api.postmarkapp.com/email"

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         {:key, token} when token != "" <- {:key, Provider.secret(opts, :server_token)},
         {:ok, email} <- Email.options(__MODULE__, opts) do
      stream = Provider.or_default(Provider.str(opts, :message_stream), "outbound")
      {:ok, %__MODULE__{token: token, stream: stream, email: email, transport: opts[:transport]}}
    else
      {:key, _} -> {:error, "#{inspect(__MODULE__)} needs :server_token"}
      {:error, _} = e -> e
    end
  end

  @impl true
  def name(_), do: "postmark"

  @impl true
  def send(%__MODULE__{} = s, alert, ctx) do
    m = Email.compose(alert, s.email)

    body =
      JS.stringify(
        Object.new([
          {"From", m.from},
          {"To", Enum.join(m.to, ", ")},
          {"Subject", m.subject},
          {"TextBody", m.text},
          {"HtmlBody", m.html},
          {"MessageStream", s.stream},
          {"Tag", "cronwatch"}
        ])
      )

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"x-postmark-server-token", s.token}
    ]

    Shared.send(s.transport || ctx.transport, "Postmark", @endpoint, headers, body, [s.token])
  end
end
