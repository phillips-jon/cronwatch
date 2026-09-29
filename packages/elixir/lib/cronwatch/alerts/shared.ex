defmodule Cronwatch.Alerts.Shared do
  @moduledoc false
  # What the channels share (alerts/shared.ts): severity, the stable alert
  # id, the run summary trackers attach, the plain text every channel reads,
  # the encodings the requests use, and the POST itself.

  import Bitwise

  alias Cronwatch.Alert
  alias Cronwatch.Alerts.Post
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @doc """
  A channel's options as a map, a keyword list or a map given; an option
  the channel does not know is refused, naming it.
  """
  def options(opts, module, known) when is_list(opts) or is_map(opts) do
    o = Map.new(opts)

    case Enum.find(Map.keys(o), &(&1 not in known)) do
      nil -> {:ok, o}
      key -> {:error, "#{inspect(module)}: unknown option #{inspect(key)}"}
    end
  end

  def options(other, module, _known),
    do: {:error, "#{inspect(module)}: options must be a keyword list, not #{inspect(other)}"}

  @doc "Refuses a missing or empty option with the SDK's refusal in Elixir's words: `Cronwatch.Alerts.Slack needs :webhook_url`."
  def required(o, key, module) do
    case Map.get(o, key) do
      v when is_binary(v) and v != "" -> :ok
      _ -> {:error, "#{inspect(module)} needs #{inspect(key)}"}
    end
  end

  @doc "Refuses a `:link` that is not a function of one argument."
  def check_link(o, module) do
    case Map.get(o, :link) do
      nil -> :ok
      f when is_function(f, 1) -> :ok
      _ -> {:error, "#{inspect(module)}: :link must be a function of the alert"}
    end
  end

  @doc "The level for trackers that have levels. Recovered is informational."
  def severity("recovered"), do: "info"
  def severity(t) when t in ["slow", "over_budget"], do: "warning"
  def severity(_), do: "error"

  @doc "Lowercase hex."
  def hex(bytes), do: Base.encode16(bytes, case: :lower)

  @doc "SHA-256 of UTF-8 text, as lowercase hex."
  def sha256_hex(text), do: hex(:crypto.hash(:sha256, text))

  @doc "HMAC-SHA256, raw bytes."
  def hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  @doc """
  A stable 32 hex character id for one alert: the same job, type and time
  always give the same id, so a provider that deduplicates on it drops a
  resend of an alert it already took.
  """
  def alert_id(%Alert{} = a) do
    "#{a.job}\n#{a.type}\n#{JS.format_number(a.at)}" |> sha256_hex() |> binary_part(0, 32)
  end

  @doc "The same id laid out as a UUID, for APIs that ask for one."
  def as_uuid(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12, _::binary>>),
    do: "#{a}-#{b}-#{c}-#{d}-#{e}"

  @doc "The run fields worth attaching to a tracker event, or nil."
  def run_summary(%Alert{run: nil}), do: nil

  def run_summary(%Alert{run: r}) do
    Object.new([
      {"id", r.id},
      {"status", r.status},
      {"startedAt", JS.iso_string(r.started_at)},
      {"durationMs", r.duration_ms},
      {"trigger", r.trigger}
    ])
  end

  @doc "The alert's details as the SDK writes them."
  def details(%Alert{} = a), do: Alert.details_value(a.type, a.details)

  @doc "The alert's diagnosis, \"\" for none."
  def triage(%Alert{triage: t}) when is_binary(t), do: t
  def triage(_), do: ""

  @doc "The link option's answer for this alert, \"\" for none."
  def link_for(nil, _alert), do: ""

  def link_for(link, alert) when is_function(link, 1) do
    case link.(alert) do
      s when is_binary(s) -> s
      nil -> ""
      other -> to_string(other)
    end
  end

  @doc "The title, message, triage and link as one plain text block, the way every channel reads."
  def plain_text(%Alert{} = a, link) do
    t = triage(a)

    [a.title, "", a.message]
    |> Kernel.++(if t != "", do: ["", "Triage: " <> t], else: [])
    |> Kernel.++(if link != "", do: ["", "Open: " <> link], else: [])
    |> Enum.join("\n")
  end

  @doc "A credential with the spaces and newlines a paste leaves around it taken off; \"\" for anything but text."
  def trimmed(value) when is_binary(value), do: JS.trim(value)
  def trimmed(_), do: ""

  @doc "Base64 of UTF-8."
  def base64(text), do: Base.encode64(text)

  @doc "An HTTP Basic authorization value."
  def basic_auth(user, password), do: "Basic " <> base64("#{user}:#{password}")

  @doc "JavaScript's `encodeURIComponent`."
  def encode_uri_component(text), do: percent(text, ~c"-_.!~*'()", false)

  @doc "`URLSearchParams#toString` for these pairs: application/x-www-form-urlencoded, a space as `+`."
  def form(pairs) do
    Enum.map_join(pairs, "&", fn {k, v} -> percent(k, ~c"*-._", true) <> "=" <> percent(v, ~c"*-._", true) end)
  end

  @doc "Percent-encodes every byte but ASCII letters, digits and `safe`; a space as `+` when `plus`."
  def percent(text, safe, plus) do
    for <<c <- text>>, into: "" do
      cond do
        c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in safe -> <<c>>
        c == ?\s and plus -> "+"
        true -> <<?%, digit(c >>> 4), digit(c &&& 15)>>
      end
    end
  end

  defp digit(n) when n < 10, do: ?0 + n
  defp digit(n), do: ?A + n - 10

  @doc """
  Posts a JSON or form body within the ten second deadline and fails on an
  answer outside 2xx: `:ok` or `{:error, %Cronwatch.Error{}}`.
  """
  def send(transport, provider, url, headers, body, secrets) do
    case Post.post(transport, provider, url, headers, body, secrets) do
      {:ok, _} -> :ok
      {:error, _} = e -> e
    end
  end
end
