defmodule Cronwatch.Alerts.Email do
  @moduledoc """
  What every email channel sends (`alerts/email.ts`): one subject, a plain
  text body and a small HTML body, so an alert reads the same whichever
  provider carries it.

  The email channels (`Cronwatch.Alerts.Resend`, `Postmark`, `SendGrid`,
  `Mailgun` and `SES`) take these options, beside their own, either at the
  top level or under `email:`:

    * `:from` (required): the sender, `"alerts@example.com"` or
      `"CronWatch <alerts@example.com>"`. The provider must allow it.
    * `:to` (required): one address or a list.
    * `:subject_prefix`: put in front of the title in the subject, `"[prod]"`
      say.
    * `:link`: a function of the alert answering a link back to the job in
      your dashboard. Only an http or https link is put in a mail.
  """

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  defstruct from: "", to: [], subject_prefix: "", link: nil

  @type t :: %__MODULE__{
          from: String.t(),
          to: [String.t()],
          subject_prefix: String.t(),
          link: (Cronwatch.Alert.t() -> String.t()) | nil
        }

  @keys [:from, :to, :subject_prefix, :link]

  @doc """
  Reads and checks the shared options once, when the channel is made: the
  to addresses with blanks dropped and each trimmed. `module` names the
  channel in a refusal.
  """
  @spec options(module(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def options(module, opts) do
    given = Keyword.merge(Keyword.take(opts, @keys), Keyword.get(opts, :email) || [])
    from = Keyword.get(given, :from)

    to =
      given
      |> Keyword.get(:to)
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&JS.trim/1)
      |> Enum.reject(&(&1 == ""))

    link = Keyword.get(given, :link)

    cond do
      not is_binary(from) or from == "" ->
        {:error, "#{inspect(module)} needs a :from address"}

      to == [] ->
        {:error, "#{inspect(module)} needs at least one :to address"}

      link != nil and not is_function(link, 1) ->
        {:error, "#{inspect(module)} needs :link to be a function of the alert"}

      true ->
        prefix = Keyword.get(given, :subject_prefix)
        {:ok, %__MODULE__{from: from, to: to, subject_prefix: if(is_binary(prefix), do: prefix, else: ""), link: link}}
    end
  end

  @doc "The mail for an alert: `%{from, to, subject, text, html}`."
  @spec compose(Cronwatch.Alert.t(), t()) :: %{
          from: String.t(),
          to: [String.t()],
          subject: String.t(),
          text: String.t(),
          html: String.t()
        }
  def compose(alert, %__MODULE__{} = o) do
    link = safe_link(Shared.link_for(o.link, alert))
    prefix = if o.subject_prefix == "", do: "", else: o.subject_prefix <> " "
    # One line: a newline in a subject is a header injection or a rejected send.
    subject = Post.cut(one_line(prefix <> alert.title), 250)
    %{from: o.from, to: o.to, subject: subject, text: Shared.plain_text(alert, link), html: html(alert, link)}
  end

  @doc false
  # `.replace(/[\r\n]+/g, " ")`.
  def one_line(text), do: Regex.replace(~r/[\r\n]+/, text, " ")

  @doc "Escapes text for HTML content and double quoted attributes."
  @spec escape_html(String.t()) :: String.t()
  def escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  @doc false
  # Keeps only an http or https link.
  def safe_link(link) do
    if Regex.match?(~r/\Ahttps?:\/\//i, link), do: link, else: ""
  end

  defp html(alert, link) do
    triage = Shared.triage(alert)

    parts =
      [
        "<!doctype html>",
        ~s(<html><body style="margin:0;padding:16px;font-family:Georgia,serif;color:#1d1b16;background:#ffffff">),
        ~s(<p style="margin:0 0 12px;font-size:18px"><strong>#{escape_html(alert.title)}</strong></p>),
        ~s(<pre style="margin:0 0 12px;padding:12px;background:#f6f3ec;white-space:pre-wrap;) <>
          ~s(word-break:break-word;font:13px/1.45 Menlo,Consolas,monospace">#{escape_html(alert.message)}</pre>)
      ] ++
        if(triage == "", do: [], else: [~s(<p style="margin:0 0 12px"><em>Triage:</em> #{escape_html(triage)}</p>)]) ++
        if(link == "",
          do: [],
          else: [~s(<p style="margin:0"><a href="#{escape_html(link)}">Open #{escape_html(alert.job)}</a></p>)]
        ) ++ ["</body></html>"]

    Enum.join(parts, "\n")
  end

  @doc """
  `Name <a@b.c>` split into its parts as a JSON object; a bare address has
  no name (email.ts's `parseAddress`: `/^\\s*(.*?)\\s*<([^<>]+)>\\s*$/`, then
  the name without the double quotes around it).
  """
  @spec parse_address(String.t()) :: Object.t()
  def parse_address(text) do
    bare = Object.new([{"email", JS.trim(text)}])
    s = JS.trim_end(text)

    with true <- String.ends_with?(s, ">"),
         inner = binary_part(s, 0, byte_size(s) - 1),
         [_ | _] = found <- :binary.matches(inner, "<"),
         {at, 1} = List.last(found),
         address = binary_part(inner, at + 1, byte_size(inner) - at - 1),
         true <- address != "" and not String.contains?(address, ">"),
         name = JS.trim(binary_part(inner, 0, at)),
         # JavaScript's . matches no line terminator.
         false <- String.contains?(name, ["\n", "\r", <<0x2028::utf8>>, <<0x2029::utf8>>]) do
      name =
        if byte_size(name) >= 2 and String.starts_with?(name, "\"") and String.ends_with?(name, "\""),
          do: binary_part(name, 1, byte_size(name) - 2),
          else: name

      o = Object.new([{"email", JS.trim(address)}])
      if name == "", do: o, else: Object.put(o, "name", name)
    else
      _ -> bare
    end
  end
end
