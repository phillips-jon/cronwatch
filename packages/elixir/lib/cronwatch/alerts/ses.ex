defmodule Cronwatch.Alerts.SES do
  @moduledoc """
  Sends alerts as email through Amazon SES, API v2 SendEmail
  (`alerts/ses.ts`): a POST to
  `https://email.<region>.amazonaws.com/v2/email/outbound-emails`, signed
  with AWS Signature Version 4, so no AWS SDK is needed.

      {Cronwatch.Alerts.SES,
       region: "us-east-1",
       access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
       secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
       from: "alerts@example.com", to: "ops@example.com"}

  Options: `:region` (required; the from identity must be verified there),
  `:access_key_id` and `:secret_access_key` (required), `:session_token`
  (for temporary credentials, an assumed role say),
  `:configuration_set_name` (for event publishing), the email options of
  `Cronwatch.Alerts.Email`, `:now` (a clock in epoch milliseconds the
  request is signed with, for tests) and `:transport`.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Email
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.Alerts.SigV4
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @derive {Inspect, except: [:secret_access_key, :session_token, :transport]}
  defstruct [
    :region,
    :access_key_id,
    :secret_access_key,
    :session_token,
    :configuration_set_name,
    :url,
    :email,
    :now,
    :transport
  ]

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         {:ok, region} <- region(Provider.str(opts, :region)),
         # A pasted credential often carries a stray space or newline, which would spoil the signature.
         {:creds, id, secret} when id != "" and secret != "" <-
           {:creds, Provider.secret(opts, :access_key_id), Provider.secret(opts, :secret_access_key)},
         {:ok, email} <- Email.options(__MODULE__, opts),
         {:ok, now} <- Provider.clock(__MODULE__, opts) do
      {:ok,
       %__MODULE__{
         region: region,
         access_key_id: id,
         secret_access_key: secret,
         session_token: Provider.secret(opts, :session_token),
         configuration_set_name: Provider.str(opts, :configuration_set_name),
         url: "https://email.#{region}.amazonaws.com/v2/email/outbound-emails",
         email: email,
         now: now,
         transport: opts[:transport]
       }}
    else
      {:creds, _, _} -> {:error, "#{inspect(__MODULE__)} needs :access_key_id and :secret_access_key"}
      {:error, _} = e -> e
    end
  end

  defp region(""), do: {:error, "#{inspect(__MODULE__)} needs :region"}

  defp region(region) do
    if Regex.match?(~r/\A[a-z0-9-]+\z/, region),
      do: {:ok, region},
      else: {:error, ~s(#{inspect(__MODULE__)} needs :region like "us-east-1")}
  end

  @impl true
  def name(_), do: "ses"

  @impl true
  def send(%__MODULE__{} = s, alert, ctx) do
    m = Email.compose(alert, s.email)
    utf8 = fn data -> Object.new([{"Data", data}, {"Charset", "UTF-8"}]) end

    content =
      Object.new([
        {"Simple",
         Object.new([
           {"Subject", utf8.(m.subject)},
           {"Body", Object.new([{"Text", utf8.(m.text)}, {"Html", utf8.(m.html)}])}
         ])}
      ])

    message =
      [
        {"FromEmailAddress", m.from},
        {"Destination", Object.new([{"ToAddresses", m.to}])},
        {"Content", content}
      ] ++
        if(s.configuration_set_name == "", do: [], else: [{"ConfigurationSetName", s.configuration_set_name}]) ++
        [{"EmailTags", [Object.new([{"Name", "source"}, {"Value", "cronwatch"}])]}]

    body = JS.stringify(Object.new(message))

    request = %{
      method: "POST",
      url: s.url,
      headers: [{"content-type", "application/json"}],
      body: body,
      region: s.region,
      service: "ses",
      now: Provider.now(s.now)
    }

    credentials = %{
      access_key_id: s.access_key_id,
      secret_access_key: s.secret_access_key,
      session_token: s.session_token
    }

    case SigV4.sign(request, credentials) do
      {:ok, headers} ->
        Shared.send(s.transport || ctx.transport, "SES", s.url, headers, body, [s.secret_access_key, s.session_token])

      {:error, message} ->
        {:error, Cronwatch.Error.other(message)}
    end
  end
end
