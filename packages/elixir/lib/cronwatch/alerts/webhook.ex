defmodule Cronwatch.Alerts.Webhook do
  @moduledoc """
  Posts each alert as JSON to any URL (`alerts/webhook.ts`), signed when
  given a secret:

      {Cronwatch.Alerts.Webhook,
       url: "https://hooks.example.com/cronwatch",
       secret: System.fetch_env!("CRONWATCH_WEBHOOK_SECRET"),
       headers: [{"authorization", "Bearer " <> token}]}

  The body is `{"schema":1,` followed by the alert as the SDK writes it
  (`Cronwatch.Alert.to_json/1`): `schema` is the payload's version, which
  goes up only if a major release changes the payload in a way that is not
  additive. The payload's JSON Schema is
  <https://cronwatch.dev/schemas/webhook/1.json>; a receiver reads its
  fields, not `title` and `message`, whose wording is not promised.

  Options:

    * `:url` (required): where the alert is posted. Errors name only its
      origin, since a webhook URL's path or query is often the credential.
      A redirect is an error: point the URL at where the receiver really is.
    * `:headers`: extra request headers, a list of `{name, value}` pairs in
      the order they are sent (a map is sent in its keys' order). Values
      are trimmed of the spaces and newlines a paste leaves.
    * `:secret`: when set, each request carries `x-cronwatch-signature:
      sha256=<hex>`, the HMAC-SHA256 of the raw body with this secret, so
      the receiver can verify it (see `signature/2`).
    * `:transport`: a `Cronwatch.Transport` for the request, else the
      instance's, else `Cronwatch.Transport.HTTP`.
  """

  @behaviour Cronwatch.Channel

  alias Cronwatch.Alert
  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS

  @derive {Inspect, except: [:url, :headers, :secret, :transport]}
  defstruct [:url, headers: [], secret: "", transport: nil]

  @type t :: %__MODULE__{url: String.t(), headers: [{String.t(), String.t()}], secret: String.t(), transport: term()}

  @impl true
  def init(opts) do
    with {:ok, o} <- Shared.options(opts, __MODULE__, [:url, :headers, :secret, :transport]),
         :ok <- Shared.required(o, :url, __MODULE__),
         {:ok, headers} <- headers(Map.get(o, :headers)),
         {:ok, secret} <- secret(Map.get(o, :secret)),
         :ok <- Cronwatch.Transport.check(o[:transport], inspect(__MODULE__)) do
      {:ok, %__MODULE__{url: o.url, headers: headers, secret: secret, transport: o[:transport]}}
    end
  end

  defp headers(nil), do: {:ok, []}

  defp headers(list) when is_list(list) or is_map(list) do
    if Enum.all?(list, &match?({n, v} when (is_binary(n) or is_atom(n)) and is_binary(v), &1)),
      do: {:ok, Enum.map(list, fn {n, v} -> {to_string(n), v} end)},
      else: {:error, "Cronwatch.Alerts.Webhook: :headers must be {name, value} pairs of strings"}
  end

  defp headers(_), do: {:error, "Cronwatch.Alerts.Webhook: :headers must be {name, value} pairs of strings"}

  defp secret(nil), do: {:ok, ""}
  defp secret(s) when is_binary(s), do: {:ok, s}
  defp secret(_), do: {:error, "Cronwatch.Alerts.Webhook: :secret must be a string"}

  @impl true
  def name(_), do: "webhook"

  # The payload's version, sent as its first field.
  @schema 1

  @doc false
  @deprecated "Internal to the webhook channel, public by accident; removed in 1.0"
  def body(alert), do: payload(alert)

  @doc false
  @spec payload(Alert.t()) :: String.t()
  def payload(%Alert{} = alert) do
    # { schema: 1, ...alert }: a queued alert another writer stored with a
    # schema of its own keeps one key, first, with its value.
    [{"schema", @schema}]
    |> JS.Object.new()
    |> JS.Object.merge(Alert.to_value(alert))
    |> JS.stringify()
  end

  @doc """
  The webhook's signature of a body: the HMAC-SHA256 of the body with the
  secret, as lowercase hex. The request carries it as
  `x-cronwatch-signature: sha256=<signature>`; a receiver compares it in
  constant time.
  """
  @spec signature(String.t(), String.t()) :: String.t()
  def signature(secret, body), do: Shared.hex(Shared.hmac_sha256(secret, body))

  @impl true
  def send(%__MODULE__{} = o, %Alert{} = alert, ctx) do
    body = payload(alert)
    headers = [{"content-type", "application/json"}, {"user-agent", "cronwatch"}]

    # A pasted Authorization value often carries a stray space or newline,
    # which fetch would refuse.
    headers = Enum.reduce(o.headers, headers, fn {n, v}, acc -> assign(acc, n, JS.trim(v)) end)

    headers =
      if o.secret != "",
        do: assign(headers, "x-cronwatch-signature", "sha256=" <> signature(o.secret, body)),
        else: headers

    transport = o.transport || (ctx && ctx.transport)

    # A redirect is refused, not followed: the headers (and the signature)
    # would go with it.
    with {:ok, answer} <- Post.fetch(transport, Post.timeout(), o.url, headers, body) do
      if Post.ok?(answer),
        do: :ok,
        # Only the origin: a webhook URL's path or query often is the credential.
        else: {:error, Post.fail("Webhook #{Post.origin(o.url)} answered #{answer.status}")}
    end
  end

  # Sets a header as a JavaScript object's key is set: an exact name already
  # there takes the new value in its place, a new one goes last.
  defp assign(headers, name, value) do
    if List.keymember?(headers, name, 0),
      do: List.keyreplace(headers, name, 0, {name, value}),
      else: headers ++ [{name, value}]
  end
end
