defmodule Cronwatch.Alerts.Discord do
  @moduledoc """
  Sends alerts to a Discord channel through a webhook (`alerts/discord.ts`):

      {Cronwatch.Alerts.Discord, webhook_url: System.fetch_env!("DISCORD_WEBHOOK_URL")}

  Options:

    * `:webhook_url` (required): a channel webhook URL from Server
      Settings, Integrations, Webhooks. It is its own credential: errors
      never quote it, and a redirect is refused rather than followed.
    * `:link`: a function of the alert answering a link back to the job in
      your dashboard.
    * `:transport`: a `Cronwatch.Transport` for the request, else the
      instance's, else `Cronwatch.Transport.HTTP`.

  The message goes in a code block cut to 3,800 characters, a triage after
  it cut to 1,000 with Discord's markdown escaped, the block cut again so
  the whole description stays within Discord's 4,096, and the request pings
  no one, whatever the output says (`@everyone` included).
  """

  @behaviour Cronwatch.Channel

  alias Cronwatch.Alert
  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.JS.Units

  @derive {Inspect, except: [:webhook_url]}
  defstruct [:webhook_url, link: nil, transport: nil]

  @type t :: %__MODULE__{webhook_url: String.t(), link: (Alert.t() -> String.t()) | nil, transport: term()}

  @impl true
  def init(opts) do
    with {:ok, o} <- Shared.options(opts, __MODULE__, [:webhook_url, :link, :transport]),
         :ok <- Shared.required(o, :webhook_url, __MODULE__),
         :ok <- Shared.check_link(o, __MODULE__),
         :ok <- Cronwatch.Transport.check(o[:transport], inspect(__MODULE__)) do
      {:ok, struct(__MODULE__, o)}
    end
  end

  @impl true
  def name(_), do: "discord"

  @impl true
  def send(%__MODULE__{} = o, %Alert{} = alert, ctx) do
    link = Shared.link_for(o.link, alert)
    description = description_of(alert)

    embed =
      Object.new(
        [{"title", alert.title}] ++
          if(link != "", do: [{"url", link}], else: []) ++
          [{"description", description}, {"color", color(alert.type)}, {"timestamp", JS.iso_string(alert.at)}]
      )

    payload =
      Object.new([
        {"content", alert.title},
        # Job output can hold anything, "@everyone" included; ping no one.
        {"allowed_mentions", Object.new([{"parse", []}])},
        {"embeds", [embed]}
      ])

    transport = o.transport || (ctx && ctx.transport)
    headers = [{"content-type", "application/json"}]

    # A redirect is refused, not followed: a webhook URL is its own credential.
    with {:ok, answer} <- Post.fetch(transport, Post.timeout(), o.webhook_url, headers, JS.stringify_lone(payload)) do
      if Post.ok?(answer),
        do: :ok,
        else: {:error, Post.fail("Discord webhook answered #{answer.status}: #{JS.head16(answer.body, 200)}")}
    end
  end

  @description_max 4096

  @doc false
  @deprecated "Internal to the Discord channel, public by accident; removed in 1.0"
  def embed_description(alert), do: description_of(alert)

  @doc false
  # The embed's description (discord.ts's `embedDescription`): the message in
  # a code block, then the triage. Each part has its own cap, and escaping can
  # grow both, so the whole is held to 4096 UTF-16 units, the most Discord
  # takes, by cutting the message's block, never the triage: Discord refuses
  # a longer one on every retry.
  @spec description_of(Alert.t()) :: Units.t()
  def description_of(%Alert{} = alert) do
    # codeBlockSafe after the cut, as the SDK does it: it works on code
    # units, so a lone half at the end passes through.
    message = Units.head(alert.message, 3800)
    triage = Shared.triage(alert)

    triage_part =
      if triage != "",
        do: Units.concat(["\n**Triage:** ", escape_markdown(Units.head(triage, 1000))]),
        else: Units.new("")

    room = @description_max - 8 - Units.length(triage_part)
    Units.concat(["```\n", cut(code_block_safe(message), room), "\n```", triage_part])
  end

  # shared.ts's cut over code units: at most `max`, one fewer when the last
  # kept unit would be a high surrogate.
  defp cut(%Units{units: u} = text, max) do
    if byte_size(u) <= 2 * max do
      text
    else
      stop = if match?(<<hi::16>> when hi in 0xD800..0xDBFF, binary_part(u, 2 * max - 2, 2)), do: max - 1, else: max
      Units.head(text, stop)
    end
  end

  defp color(t) when t in ["failed", "stuck"], do: 0xC62828
  defp color("recovered"), do: 0x1F8A4C
  defp color(_), do: 0xB7791F

  @tick 0x60
  @safe Cronwatch.JS.units(Cronwatch.Alerts.Slack.broken())

  @doc false
  # Slack's code_block_safe over code units: ``` broken up so text inside a
  # code block cannot close it.
  def code_block_safe(%Units{units: u}), do: %Units{units: cbs(u, [])}

  defp cbs(<<@tick::16, @tick::16, @tick::16, rest::binary>>, acc), do: cbs(rest, [@safe | acc])
  defp cbs(<<u::16, rest::binary>>, acc), do: cbs(rest, [<<u::16>> | acc])
  defp cbs(_, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  @doc false
  # Escapes the characters Discord reads as markdown, links included.
  def escape_markdown(%Units{units: u}) do
    %Units{
      units:
        for <<c::16 <- u>>, into: "" do
          if c < 0x80 and c in ~c"\\`*_~|[]()<>", do: <<?\\::16, c::16>>, else: <<c::16>>
        end
    }
  end
end
