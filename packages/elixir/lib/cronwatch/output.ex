defmodule Cronwatch.Output do
  @moduledoc """
  The SDK's `output.ts`: the output cap, error text and secret redaction.

  Lengths and cuts are in UTF-16 code units, as JavaScript counts them, so the
  same output is capped at the same character here and in every other port.
  An error is written as a JavaScript stack reads, `Name: message` and up to
  five frames, with Elixir's own names and frames (see `describe_exception/3`).
  """

  alias Cronwatch.JS
  alias Cronwatch.JSRE
  alias Cronwatch.JSRE.Match

  @output_cap 16 * 1024
  @redacted "[redacted]"
  @trimmed "[earlier output trimmed]\n"

  @doc "How much output a run keeps: 16 KB of UTF-16 code units, the tail."
  @spec output_cap() :: pos_integer()
  def output_cap, do: @output_cap

  @doc "What replaces a secret."
  @spec redacted() :: String.t()
  def redacted, do: @redacted

  @doc """
  Removes every U+0000. Postgres refuses NUL in TEXT and JSONB, and the whole
  run row would be lost with it.
  """
  @spec strip_nul(String.t()) :: String.t()
  def strip_nul(s), do: if(String.contains?(s, <<0>>), do: String.replace(s, <<0>>, ""), else: s)

  @doc """
  Removes every U+0000 from JSON text, keys and strings alike, by dropping
  each `\\u0000` escape (a NUL can appear in JSON no other way). Escapes are
  read left to right in pairs, so an escaped backslash followed by `u0000`
  is left as it is (the SDK's `stripJsonNul`).
  """
  @spec strip_json_nul(String.t()) :: String.t()
  def strip_json_nul(json) do
    if String.contains?(json, "\\u0000"),
      do: Regex.replace(~r/\\(u0000|[\s\S])/, json, fn escape, next -> if next == "u0000", do: "", else: escape end),
      else: json
  end

  @doc """
  Removes NULs, then keeps the last 16 KB of code units behind a line saying
  the rest was trimmed (the SDK's `capOutput`). A cut through a surrogate pair
  leaves U+FFFD, the character JavaScript's lone half becomes once written
  out as UTF-8, so the stored bytes are the same.
  """
  @spec cap(String.t()) :: String.t()
  def cap(s) do
    clean = strip_nul(s)

    # Each byte is at most one code unit, so a short text needs no count.
    if byte_size(clean) <= @output_cap or JS.len16(clean) <= @output_cap do
      clean
    else
      @trimmed <> JS.tail16(clean, @output_cap)
    end
  end

  @redact_edge 3 * (@output_cap + 1024)

  @doc """
  How much text before the kept tail redaction reads, and never keeps: three
  times the longest secret a default pattern can match (a PEM key's 16 KB
  body with its header and footer, under the cap plus 1024), since a
  replacement grows what it replaces at most threefold (the SDK's
  `REDACT_EDGE`).
  """
  @spec redact_edge() :: pos_integer()
  def redact_edge, do: @redact_edge

  @doc """
  Output or an error as it is stored: redacted with `redact`, then capped
  like `cap/1`, so the cut cannot fall inside a secret and keep what follows
  its label (the SDK's `redactAndCap`). Text of at most the cap plus
  `redact_edge/0` code units is redacted whole. Longer text is cut to that
  many units from its end first, and after redacting, the first
  `redact_edge/0` units are never kept: a secret whose label fell before
  that cut is left out with them. NULs go before and after `redact`.
  """
  @spec redact_and_cap(String.t(), (String.t() -> String.t())) :: String.t()
  def redact_and_cap(text, redact) do
    clean = strip_nul(text)
    window = @output_cap + @redact_edge

    # Each byte is at most one code unit, so a short text needs no count.
    if byte_size(clean) <= window or JS.len16(clean) <= window do
      cap(redact.(clean))
    else
      redacted = strip_nul(redact.(JS.tail16(clean, window)))
      n = JS.len16(redacted)
      @trimmed <> JS.slice16(redacted, max(n - @output_cap, @redact_edge), n)
    end
  end

  @doc """
  An error as a JavaScript stack reads: `Name: message`, then up to five
  frames, each `    at <frame>`.
  """
  @spec describe(String.t(), String.t(), [String.t()]) :: String.t()
  def describe(name, message, frames) do
    IO.iodata_to_binary([name, ": ", message | Enum.map(Enum.take(frames, 5), &["\n    at ", &1])])
  end

  @doc "The SDK's `errorMessage` for an error: described, then capped like output."
  @spec error_message(String.t(), String.t(), [String.t()]) :: String.t()
  def error_message(name, message, frames), do: cap(describe(name, message, frames))

  @doc """
  The SDK's `errorMessage` for a thrown value that is not an `Error`: a
  string as it is, anything else as its JSON, capped like output.
  """
  @spec value_message(Cronwatch.JS.value()) :: String.t()
  def value_message(value) when is_binary(value), do: cap(value)
  def value_message(value), do: cap(JS.stringify(value))

  @doc """
  What a failed run records for what went wrong, capped like output:

    * `:error` with an exception is `Name: message` and up to five frames,
      innermost first, each `Module.function/arity (file:line)`; the name is
      the exception's module as Elixir code writes it (`RuntimeError`,
      `DBConnection.ConnectionError`);
    * `:throw` is `throw: <value>` and `:exit` is `exit: <reason>`, a binary as
      itself and anything else through `inspect/1`, and an exit holding
      `{exception, stacktrace}` (a crashed process's reason) is that
      exception;
    * `:error` with a value that is not an exception is the Erlang error, as
      Elixir normalizes it (`ErlangError`, `ArithmeticError`, ...);
    * `:returned` is a function's `{:error, reason}`: the reason written the
      same way, an exception in it as an exception, and `:error` alone is
      `error`.
  """
  @spec describe_exception(:error | :throw | :exit | :returned, term(), Exception.stacktrace()) :: String.t()
  def describe_exception(kind, reason, stacktrace \\ []), do: cap(describe_raw(kind, reason, stacktrace))

  @doc """
  `describe_exception/3` not capped (the SDK's `describeError`): a run's
  error is redacted first and capped after, by `redact_and_cap/2`.
  """
  @spec describe_uncapped(:error | :throw | :exit | :returned, term(), Exception.stacktrace()) :: String.t()
  def describe_uncapped(kind, reason, stacktrace \\ []), do: describe_raw(kind, reason, stacktrace)

  defp describe_raw(:error, reason, stacktrace) do
    exception = Exception.normalize(:error, reason, stacktrace)
    describe(exception_name(exception), exception_text(exception), frames(stacktrace))
  end

  defp describe_raw(:throw, value, _stacktrace), do: "throw: " <> term_text(value)

  defp describe_raw(:exit, {exception, stacktrace}, _stacktrace) when is_exception(exception) and is_list(stacktrace) do
    describe_raw(:error, exception, stacktrace)
  end

  defp describe_raw(:exit, reason, _stacktrace), do: "exit: " <> term_text(reason)

  defp describe_raw(:returned, exception, stacktrace) when is_exception(exception) do
    describe_raw(:error, exception, stacktrace)
  end

  defp describe_raw(:returned, reason, _stacktrace), do: term_text(reason)

  defp term_text(value) when is_binary(value), do: value
  defp term_text(value), do: inspect(value)

  # The module as Elixir code writes it: Elixir.RuntimeError is RuntimeError,
  # an Erlang module keeps its colon.
  defp exception_name(%module{}), do: inspect(module)

  defp exception_text(exception) do
    Exception.message(exception)
  rescue
    e -> "(the exception's message raised #{inspect(e.__struct__)})"
  end

  @doc """
  A stacktrace's frames as a JavaScript stack writes its own, innermost
  first: `Module.function/arity (file:line)`.
  """
  @spec frames(Exception.stacktrace()) :: [String.t()]
  def frames(stacktrace) when is_list(stacktrace) do
    stacktrace |> Enum.take(5) |> Enum.map(&frame/1)
  end

  def frames(_), do: []

  defp frame({module, fun, arity, location}) when is_atom(module) and is_atom(fun) do
    arity = if is_list(arity), do: length(arity), else: arity
    call = "#{inspect(module)}.#{fun_name(fun)}/#{arity}"
    with_location(call, location)
  end

  defp frame({fun, arity, location}) when is_function(fun) do
    arity = if is_list(arity), do: length(arity), else: arity
    with_location("#{inspect(fun)}/#{arity}", location)
  end

  defp frame(other), do: inspect(other)

  defp fun_name(fun) do
    name = Atom.to_string(fun)
    if Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/, name), do: name, else: inspect(fun)
  end

  defp with_location(call, location) when is_list(location) do
    case {Keyword.get(location, :file), Keyword.get(location, :line)} do
      {nil, _} -> call
      {file, nil} -> "#{call} (#{file})"
      {file, line} -> "#{call} (#{file}:#{line})"
    end
  end

  defp with_location(call, _), do: call

  ## Redaction

  # The SDK's patterns (packages/sdk/src/output.ts, SECRET_PATTERNS), as
  # JavaScript source, character for character, compiled by Cronwatch.JSRE so
  # they match what they match in JavaScript. Bounded quantifiers throughout,
  # so a long line cannot make these backtrack. They apply in this order, each
  # to the text the ones before it left. A replacement is a template in which
  # `$1` stands for group 1 (the only group the SDK's replacements name), or
  # :assignment, the key=value pattern's function.
  @patterns [
    # A PEM private key, header to footer. Without a footer (the output was
    # trimmed) it runs to the end of the base64 body. A "-" that starts five
    # dashes ends the body, so the footer is never swallowed into it.
    {~S"-----BEGIN (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----(?:[A-Za-z0-9+/=\s,:]|-(?!----)){0,16384}(?:-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----)?",
     "g", "[redacted]"},
    # password=..., API_KEY: ..., "client_secret": "...", TOKEN='...',
    # token=..., :password=>"..." (but not max_tokens: 800). A quoted value is
    # blanked to its closing quote, spaces and all, and keeps its quotes.
    {String.trim_trailing(~S"""
     \b([A-Za-z0-9_-]{0,40}(?:secret|token|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])"?\s{0,3}(?:=>|[=:])\s{0,3})(?:(")[^"\n]{1,4096}"|(')[^'\n]{1,4096}'|["']?[^\s"',;&]{1,4096})
     """), "gi", :assignment},
    # Authorization: Basic <base64> and Authorization: Token <token>, also as
    # a JSON or hash entry.
    {String.trim_trailing(~S"""
     \b((?:proxy-)?authorization["']?\s{0,3}(?:=>|[=:])\s{0,3}["']?\s{0,3}(?:basic|token)\s{1,3})[A-Za-z0-9._~+/=:-]{1,4096}
     """), "gi", "$1[redacted]"},
    # Credentials inside a URL: postgres://user:password@host. The password
    # runs to the last "@" before a "/" or a space, so one that contains "@"
    # is blanked whole.
    {~S"(\b[a-z][a-z0-9+.-]{0,30}:\/\/[^\s/:@]{0,256}:)[^\s/]{1,256}@", "gi", "$1[redacted]@"},
    # Authorization: Bearer <token>
    {~S"\b(Bearer\s{1,3})[A-Za-z0-9._~+/=-]{8,4096}", "g", "$1[redacted]"},
    # A bare JWT: three base64url segments, the first starting eyJ.
    {~S"\beyJ[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{0,4096}", "g", "[redacted]"},
    # Incoming webhook URLs carry their secret in the path.
    {~S"(\bhooks\.slack\.com\/(?:services|workflows|triggers)\/)[A-Za-z0-9/_-]{1,255}", "gi", "$1[redacted]"},
    {~S"(\bdiscord(?:app)?\.com\/api\/(?:v\d{1,2}\/)?webhooks\/)[A-Za-z0-9/_-]{1,255}", "gi", "$1[redacted]"},
    # Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic, OpenAI
    # and Google style keys.
    {~S"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b", "g", "[redacted]"},
    {~S"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\b", "g", "[redacted]"},
    {~S"\bxox[abposr]-[A-Za-z0-9-]{10,255}", "g", "[redacted]"},
    {~S"\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\b", "g", "[redacted]"},
    {~S"\bwhsec_[A-Za-z0-9+/=]{16,255}", "g", "[redacted]"},
    {~S"\bsk-[A-Za-z0-9_-]{20,255}", "g", "[redacted]"},
    {~S"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])", "g", "[redacted]"}
  ]

  # The patterns compiled once per node, on first use, and kept in
  # :persistent_term, written that once and read by every process after.
  defp compiled do
    case :persistent_term.get({__MODULE__, :patterns}, nil) do
      nil ->
        patterns =
          for {source, flags, replacement} <- @patterns do
            replacement =
              case replacement do
                :assignment -> :assignment
                text -> {:template, text |> :binary.split("$1", [:global]) |> Enum.map(&JS.units/1)}
              end

            {JSRE.compile!(source, flags), replacement}
          end

        :persistent_term.put({__MODULE__, :patterns}, patterns)
        patterns

      patterns ->
        patterns
    end
  end

  @doc """
  The default redaction: blanks values that look like secrets (key=value
  pairs with secret-ish names, Authorization headers, URL credentials, bearer
  tokens, JWTs, PEM private keys, webhook URLs and well-known token formats)
  before output or an error is stored, shown or sent anywhere, exactly as the
  SDK's `redactSecrets` does. An app's own `redact` function can call it and
  add patterns of its own.

  The text is matched as UTF-16 code units, as JavaScript holds it, and
  turned back into UTF-8 once at the end, so a match that cut a character
  outside the BMP in two leaves U+FFFD where JavaScript leaves the lone
  surrogate that becomes U+FFFD when it is written out.
  """
  @spec redact_secrets(String.t()) :: String.t()
  def redact_secrets(text) do
    compiled()
    |> Enum.reduce(JS.units(text), fn {re, replacement}, units ->
      JSRE.replace_units(re, units, &apply_replacement(replacement, &1))
    end)
    |> JS.from_units()
  end

  defp apply_replacement({:template, [first | rest]}, m) do
    group = Match.group(m, 1) || ""
    IO.iodata_to_binary([first | Enum.map(rest, &[group, &1])])
  end

  defp apply_replacement(:assignment, m) do
    quote = Match.group(m, 2) || Match.group(m, 3) || ""
    IO.iodata_to_binary([Match.group(m, 1) || "", quote, JS.units(@redacted), quote])
  end
end
