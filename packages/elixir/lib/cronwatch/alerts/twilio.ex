defmodule Cronwatch.Alerts.Twilio do
  @moduledoc """
  Texts alerts through Twilio (`alerts/twilio.ts`): a form encoded POST to
  `https://api.twilio.com/2010-04-01/Accounts/<AccountSid>/Messages.json`
  with basic auth, one per number, every number at once.

      {Cronwatch.Alerts.Twilio,
       account_sid: System.fetch_env!("TWILIO_ACCOUNT_SID"),
       auth_token: System.fetch_env!("TWILIO_AUTH_TOKEN"),
       from: "+15005550006", to: ["+15551230000"]}

  Options: `:account_sid` (required, `AC...`), `:auth_token`, or
  `:api_key_sid` (`SK...`) and `:api_key_secret` in its place; `:from` (a
  Twilio number in E.164 form) or `:messaging_service_sid` (`MG...`); `:to`
  (one number in E.164 form, or a list; each gets its own message);
  `:recovered` (default false: a text is for what needs a person);
  `:segments` (how many SMS segments a message may use, 1 to 10, default
  3); `:link` (kept whole at the end of the text) and `:transport`.

  The alert counts as delivered when any number took it; each number that
  refused it is reported to the instance's error handler. It fails only
  when every number did.
  """
  @behaviour Cronwatch.Channel

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Provider
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.ChannelContext
  alias Cronwatch.JS

  @derive {Inspect, except: [:password, :authorization]}
  defstruct [
    :url,
    :authorization,
    :password,
    :from,
    :messaging_service_sid,
    :to,
    :recovered,
    :budget,
    :link,
    :transport
  ]

  @doc false
  # The most segments a message may use, which keeps it inside Twilio's 1600 character Body limit.
  def max_segments, do: 10

  # The longest Body Twilio takes.
  @max_body 1600

  @impl true
  def init(opts) do
    with {:ok, opts} <- Provider.keyword(__MODULE__, opts),
         # A pasted credential often carries a stray space or newline, which the
         # Authorization header would refuse or send.
         {:sid, sid} when sid != "" <- {:sid, Provider.secret(opts, :account_sid)},
         key_sid = Provider.secret(opts, :api_key_sid),
         {user, password} =
           if(key_sid == "",
             do: {sid, Provider.secret(opts, :auth_token)},
             else: {key_sid, Provider.secret(opts, :api_key_secret)}
           ),
         {:password, true} <- {:password, password != ""},
         from = Provider.str(opts, :from),
         service = Provider.str(opts, :messaging_service_sid),
         {:from, true} <- {:from, from != "" or service != ""},
         to = numbers(Keyword.get(opts, :to)),
         {:to, true} <- {:to, to != []},
         {:ok, recovered} <- Provider.flag(__MODULE__, opts, :recovered, false),
         {:ok, link} <- Provider.link(__MODULE__, opts) do
      {:ok,
       %__MODULE__{
         url: "https://api.twilio.com/2010-04-01/Accounts/#{Shared.encode_uri_component(sid)}/Messages.json",
         authorization: Shared.basic_auth(user, password),
         password: password,
         from: from,
         messaging_service_sid: service,
         to: to,
         recovered: recovered,
         budget: segment_budget(Keyword.get(opts, :segments)),
         link: link,
         transport: opts[:transport]
       }}
    else
      {:sid, _} -> {:error, "#{inspect(__MODULE__)} needs :account_sid"}
      {:password, _} -> {:error, "#{inspect(__MODULE__)} needs :auth_token, or :api_key_sid and :api_key_secret"}
      {:from, _} -> {:error, "#{inspect(__MODULE__)} needs a :from number or a :messaging_service_sid"}
      {:to, _} -> {:error, "#{inspect(__MODULE__)} needs at least one :to number"}
      {:error, _} = e -> e
    end
  end

  defp numbers(to) do
    to |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.map(&JS.trim/1) |> Enum.reject(&(&1 == ""))
  end

  @impl true
  def name(_), do: "twilio"

  @impl true
  def send(%__MODULE__{recovered: false}, %{type: "recovered"}, _ctx), do: :ok

  def send(%__MODULE__{} = s, alert, ctx) do
    body = sms_body(alert, Shared.link_for(s.link, alert), s.budget)
    n = length(s.to)
    transport = s.transport || ctx.transport

    # Every number at once, a task each, linked, so the channel's own task
    # stopped at its deadline takes them with it.
    errors =
      s.to
      |> Enum.map(fn number -> Task.async(fn -> text(s, transport, number, body) end) end)
      |> Task.await_many(:infinity)

    failed = for {number, error} <- Enum.zip(s.to, errors), error != nil, do: {number, error}

    cond do
      failed == [] ->
        :ok

      length(failed) == n ->
        [{_, message} | _] = failed
        message = if n > 1, do: "#{message} (#{length(failed)} of #{n} numbers failed)", else: message
        {:error, Cronwatch.Error.other(message)}

      true ->
        # Delivered to someone: counted as sent, so a retry never texts the numbers that took it again.
        for {number, message} <- failed do
          ChannelContext.report(
            ctx,
            Cronwatch.Error.other(
              "#{message} (to #{mask_number(number)}; #{n - length(failed)} of #{n} numbers took the alert)"
            )
          )
        end

        :ok
    end
  end

  # One number's text: nil when it went out, else the error's message. A
  # raise or exit (in an app's transport, say) is that number's failure.
  defp text(s, transport, number, body) do
    sender =
      if s.messaging_service_sid == "", do: {"From", s.from}, else: {"MessagingServiceSid", s.messaging_service_sid}

    form = Shared.form([{"To", number}, sender, {"Body", body}])
    headers = [{"content-type", "application/x-www-form-urlencoded"}, {"authorization", s.authorization}]

    case Shared.send(transport, "Twilio", s.url, headers, form, [s.password]) do
      :ok -> nil
      {:error, reason} -> Cronwatch.Error.describe(reason)
    end
  rescue
    e -> Exception.message(e)
  catch
    kind, reason -> Cronwatch.Error.describe({kind, reason})
  end

  # A number with all but its last four digits hidden, for an error message.
  defp mask_number(number) do
    n = JS.len16(number)
    if n <= 4, do: number, else: String.duplicate("*", min(n - 4, 8)) <> JS.tail16(number, 4)
  end

  # The GSM 03.38 alphabet: a message in it takes 153 characters a segment
  # (when split), anything else is UCS-2 at 67. The extension table costs two.
  @gsm String.to_charlist(
         "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
       )
       |> MapSet.new()
  @gsm_extended MapSet.new(String.to_charlist("^{}\\[~]|€\f"))

  @doc false
  # How many SMS segments `text` takes. A character is never split across
  # two: an extension character (two septets) or a surrogate pair (two UCS-2
  # units) that would straddle a boundary starts the next segment, as phones
  # pack them.
  @spec sms_segments(String.t()) :: pos_integer()
  def sms_segments(text) do
    chars = String.to_charlist(text)

    gsm =
      Enum.reduce_while(chars, [], fn c, acc ->
        cond do
          MapSet.member?(@gsm, c) -> {:cont, [1 | acc]}
          MapSet.member?(@gsm_extended, c) -> {:cont, [2 | acc]}
          true -> {:halt, nil}
        end
      end)

    {sizes, single, per} =
      case gsm do
        nil -> {Enum.map(chars, &if(&1 > 0xFFFF, do: 2, else: 1)), 70, 67}
        sizes -> {Enum.reverse(sizes), 160, 153}
      end

    if Enum.sum(sizes) <= single do
      1
    else
      {count, _} =
        Enum.reduce(sizes, {1, 0}, fn u, {count, used} ->
          if used + u > per, do: {count + 1, u}, else: {count, used + u}
        end)

      count
    end
  end

  # Whether text fits within `segments` SMS segments and Twilio's Body limit.
  defp fits?(text, segments), do: JS.len16(text) <= @max_body and sms_segments(text) <= segments

  # A segment count clamped to 1 to max_segments/0; 3 for anything not a number.
  defp segment_budget(n) when is_integer(n), do: n |> max(1) |> min(10)
  defp segment_budget(n) when is_float(n), do: n |> Float.floor() |> trunc() |> segment_budget()
  defp segment_budget(_), do: 3

  @doc false
  # The text of an alert: the title, then as many lines of the message (and
  # the triage) as fit in `segments` SMS segments, then the link. The link is
  # kept whole; the text before it is cut to make room. `segments` is clamped
  # to 1 to 10, and 3 for anything not a number.
  @spec sms_body(Cronwatch.Alert.t(), String.t() | nil, term()) :: String.t()
  def sms_body(alert, link, segments \\ 3) do
    budget = segment_budget(segments)
    tail = if link in [nil, ""], do: "", else: "\n" <> link
    triage = Shared.triage(alert)

    lines =
      [alert.title] ++
        (alert.message |> String.split("\n") |> Enum.reject(&(JS.trim(&1) == ""))) ++
        if(triage == "", do: [], else: ["Triage: " <> triage])

    text =
      Enum.reduce_while(lines, "", fn line, text ->
        next = join(text, line)

        if fits?(next <> tail, budget) do
          {:cont, next}
        else
          # Part of this line, cut on a code point and marked.
          chars = String.codepoints(line)
          lo = widest(chars, text, tail, budget, 0, length(chars))
          {:halt, if(lo > 0, do: join(text, Enum.join(Enum.take(chars, lo)) <> "..."), else: text)}
        end
      end)

    # Only a link too long for any budget gets here too long; Twilio would refuse it whole.
    Post.cut(text <> tail, @max_body)
  end

  defp join("", line), do: line
  defp join(text, line), do: text <> "\n" <> line

  defp widest(_chars, _text, _tail, _budget, lo, hi) when lo >= hi, do: lo

  defp widest(chars, text, tail, budget, lo, hi) do
    mid = div(lo + hi + 1, 2)
    candidate = join(text, Enum.join(Enum.take(chars, mid)) <> "...") <> tail

    if fits?(candidate, budget),
      do: widest(chars, text, tail, budget, mid, hi),
      else: widest(chars, text, tail, budget, lo, mid - 1)
  end
end
