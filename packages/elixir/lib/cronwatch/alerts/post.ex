defmodule Cronwatch.Alerts.Post do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # The one POST the alert channels and Claude triage make, as the SDK makes
  # it with fetch (`alerts/shared.ts`), the Go port's `internal/post`, and the
  # Rust port's `alerts::post`: the URL read as fetch reads it, only http and
  # https, headers checked as fetch checks them, one ten second deadline for
  # the whole request, a redirect refused rather than followed, at most 1 MiB
  # of an answer read, and an error that names only the URL's origin, with
  # every secret the caller holds cut out of a quoted answer before it is cut
  # to 200 characters.
  #
  # The request goes out through a `Cronwatch.Transport`, in a process of its
  # own that is killed past the deadline, so the deadline holds whatever the
  # transport does, while connecting, sending, or reading the answer.
  #
  # Errors are `Cronwatch.Error`s of kind `:other`; one past the deadline has
  # the reason `:timeout` and fetch's message, `The operation was aborted due
  # to timeout`.

  alias Cronwatch.Alerts.URL
  alias Cronwatch.JS
  alias Cronwatch.Transport
  alias Cronwatch.Transport.Request
  alias Cronwatch.Transport.Response

  @timeout 10_000
  @max_body 1_048_576
  @error_body_max 200

  @typedoc "An answer: its status, and as much of its body as was read, as `response.text()` reads it."
  @type answer :: %{status: non_neg_integer(), body: String.t()}

  @doc """
  How long one request may take, connecting, sending, and reading the
  answer, as the SDK's `AbortSignal.timeout(10_000)`: 10 seconds. The tests
  shorten it through the application environment (`:post_timeout`).
  """
  @spec timeout() :: non_neg_integer()
  def timeout, do: Application.get_env(:cronwatch, :post_timeout, @timeout)

  @doc "How much of an answer is read: 1 MiB."
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  @doc "How much of an answer's body goes into an error: 200 UTF-16 code units."
  @spec error_body_max() :: pos_integer()
  def error_body_max, do: @error_body_max

  @doc "An error of this module's, with its message."
  @spec fail(String.t(), term()) :: Cronwatch.Error.t()
  def fail(message, reason \\ nil), do: Cronwatch.Error.other(message, reason)

  @doc "Fetch's error for a request past its deadline."
  @spec timed_out() :: Cronwatch.Error.t()
  def timed_out, do: fail("The operation was aborted due to timeout", :timeout)

  @doc "`response.ok`: a 2xx status."
  @spec ok?(answer()) :: boolean()
  def ok?(%{status: s}), do: s in 200..299

  @doc """
  The URL, cleaned and written as fetch writes it, once it is one a channel
  can post to: http or https with a host. Refused without quoting it, since
  a webhook URL's path is its credential: "not ftp:" for another scheme,
  "not this URL" for anything else (no URL at all, or one with a user name
  or password, which fetch refuses to send).
  """
  @spec postable(term()) :: {:ok, String.t()} | {:error, Cronwatch.Error.t()}
  def postable(raw) do
    refused = fail("only http and https URLs can be posted to, not this URL")

    case URL.parse(raw) do
      {:ok, %URL{user?: true}} -> {:error, refused}
      {:ok, %URL{scheme: s} = u} when s in ["http", "https"] -> {:ok, URL.to_string(u)}
      {:ok, %URL{scheme: s}} -> {:error, fail("only http and https URLs can be posted to, not #{s}:")}
      {:other, s} -> {:error, fail("only http and https URLs can be posted to, not #{s}:")}
      :error -> {:error, refused}
    end
  end

  @doc """
  `new URL(url).origin`: the scheme, host, and port only, a port that is the
  scheme's own left out; `"null"` for a URL of a scheme that has no origin
  and `"(invalid URL)"` for text that is no URL. A URL's path or query can
  hold a credential, so an error names only this.
  """
  @spec origin(term()) :: String.t()
  def origin(raw) do
    case URL.parse(raw) do
      {:ok, u} -> URL.origin(u)
      {:other, _} -> "null"
      :error -> "(invalid URL)"
    end
  end

  # An HTTP token (RFC 9110).
  defp token?(""), do: false

  defp token?(name) when is_binary(name) do
    name
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 in ~c"!#$%&'*+.^_`|~-"))
  end

  defp token?(_), do: false

  @doc """
  The headers as a request sends them: each name a token, each value
  without the spaces, tabs, and line breaks around it, as fetch sends it. A
  name that is not a token, or a value with a line break or NUL inside, is
  refused, as fetch refuses them, so no header can add another; the error
  names the header, never its value, which may be a credential.
  """
  @spec headers([{String.t(), term()}]) :: {:ok, [{String.t(), String.t()}]} | {:error, Cronwatch.Error.t()}
  def headers(list) do
    Enum.reduce_while(list, {:ok, []}, fn {name, value}, {:ok, acc} ->
      value = if is_binary(value), do: value, else: to_string(value)
      value = trim_http(value)

      cond do
        not token?(name) ->
          {:halt, {:error, fail("a header name must be a token (letters, digits, and !#$%&'*+.^_`|~-)")}}

        String.contains?(value, ["\r", "\n", <<0>>]) ->
          {:halt, {:error, fail("the #{name} header's value may not contain a line break")}}

        true ->
          {:cont, {:ok, acc ++ [{name, value}]}}
      end
    end)
  end

  defp trim_http(s), do: s |> trim_lead() |> String.reverse() |> trim_lead() |> String.reverse()
  defp trim_lead(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: trim_lead(rest)
  defp trim_lead(s), do: s

  @doc "Bytes as `response.text()` reads them: UTF-8, U+FFFD for bytes that are not, no byte order mark."
  @spec text(binary()) :: String.t()
  def text(data) do
    case JS.scrub(data) do
      <<0xFEFF::utf8, rest::binary>> -> rest
      s -> s
    end
  end

  @doc """
  Posts `body` to `url` through `transport` within `within` milliseconds,
  and answers whatever the status. An error is a request that could not be
  made or had no answer: the URL or a header refused, `timed_out/0` past
  the deadline, or the transport's own error, naming no more of the URL
  than its origin. A body the deadline cut short, or one that could not be
  read, is `""`.
  """
  @spec fetch(Transport.spec(), non_neg_integer(), String.t(), [{String.t(), term()}], iodata()) ::
          {:ok, answer()} | {:error, Cronwatch.Error.t()}
  def fetch(transport, within, url, headers, body) do
    with {:ok, target} <- postable(url),
         {:ok, headers} <- headers(headers) do
      {module, opts} = Transport.resolve(transport)
      # UTF-8 as fetch sends a string, U+FFFD for bytes that are not.
      request = %Request{url: target, headers: headers, body: JS.scrub(IO.iodata_to_binary(body))}
      run(module, opts, request, url, within)
    end
  end

  # Runs the request in a process of its own and waits for it, killing it
  # at the deadline.
  defp run(module, opts, request, raw_url, within) do
    parent = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + within

    {pid, monitor} =
      spawn_monitor(fn ->
        case safely(fn -> module.post(opts, request) end) do
          {:ok, %Response{status: status} = response} when is_integer(status) ->
            send(parent, {ref, :status, status})
            send(parent, {ref, :body, read(response)})

          {:ok, other} ->
            send(parent, {ref, :error, {:bad_answer, other}})

          {:error, reason} ->
            send(parent, {ref, :error, reason})
        end
      end)

    result =
      receive do
        {^ref, :status, status} ->
          receive do
            {^ref, :body, data} -> {:ok, %{status: status, body: text(data)}}
            {:DOWN, ^monitor, :process, _, _} -> {:ok, %{status: status, body: ""}}
          after
            left(deadline) -> {:ok, %{status: status, body: ""}}
          end

        {^ref, :error, reason} ->
          {:error, without_url(describe(reason), raw_url, request.url)}

        {:DOWN, ^monitor, :process, _, reason} ->
          {:error, without_url(describe(reason), raw_url, request.url)}
      after
        left(deadline) -> {:error, timed_out()}
      end

    Process.exit(pid, :kill)
    Process.demonitor(monitor, [:flush])
    flush(ref)
    result
  end

  defp left(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp flush(ref) do
    receive do
      {^ref, _, _} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  # At most max_body bytes of the body, read a chunk at a time; a body that
  # could not be read is none.
  defp read(%Response{body: body}) when is_binary(body), do: binary_part(body, 0, min(byte_size(body), @max_body))

  defp read(%Response{body: next, close: close}) when is_function(next, 0) do
    case read_chunks(next, [], 0) do
      {:full, data} ->
        if close, do: safely(close)
        data

      {:done, data} ->
        data

      :error ->
        if close, do: safely(close)
        ""
    end
  end

  defp read(_), do: ""

  defp read_chunks(next, acc, n) do
    case safely(next) do
      {:ok, chunk} when is_binary(chunk) ->
        room = @max_body - n
        taken = binary_part(chunk, 0, min(byte_size(chunk), room))
        acc = [acc, taken]
        n = n + byte_size(taken)
        if n >= @max_body, do: {:full, IO.iodata_to_binary(acc)}, else: read_chunks(next, acc, n)

      :done ->
        {:done, IO.iodata_to_binary(acc)}

      _ ->
        :error
    end
  end

  # A transport's error as one line: a socket's reason as itself
  # (econnrefused), a TLS alert as its text, an :httpc failure (an app's
  # transport on it) as the reason it holds, an exception as its message.
  defp describe({:failed_connect, list}) when is_list(list) do
    case List.last(list) do
      {_, _, reason} -> describe(reason)
      other -> describe(other)
    end
  end

  defp describe({:tls_alert, {_, text}}), do: to_text(text)
  defp describe({:tls_alert, text}), do: to_text(text)
  defp describe({:exit, reason}), do: "exit: " <> describe(reason)
  defp describe({:throw, value}), do: "throw: " <> describe(value)
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(a) when is_atom(a), do: Atom.to_string(a)
  defp describe(s) when is_binary(s), do: s
  defp describe(other), do: to_text(other)

  defp to_text(text) when is_list(text) do
    case :unicode.characters_to_binary(text) do
      s when is_binary(s) -> s
      _ -> inspect(text)
    end
  end

  defp to_text(text) when is_binary(text), do: text
  defp to_text(other), do: inspect(other)

  # `<origin>: <text>`, with every spelling of the URL in the text written as
  # its origin and its path and query cut out.
  defp without_url(text, raw, target) do
    {:ok, u} = URL.parse(target)
    origin = URL.origin(u)

    out =
      Enum.reduce([JS.trim(to_string(raw)), target], text, fn s, out ->
        if s != "" and s != origin and s != origin <> "/", do: String.replace(out, s, origin), else: out
      end)

    query = u.query || ""
    request_uri = if query == "", do: u.path, else: u.path <> "?" <> query
    decoded = JS.scrub(URL.percent_decode_bytes(u.path))

    out =
      Enum.reduce([request_uri, u.path, decoded, query], out, fn s, out ->
        if byte_size(s) > 1, do: String.replace(out, s, ""), else: out
      end)

    fail("#{origin}: #{out}")
  end

  @doc "`%XX` decoded, with U+FFFD for bytes that are not UTF-8."
  @spec percent_decode(String.t()) :: String.t()
  def percent_decode(text), do: text |> URL.percent_decode_bytes() |> JS.scrub()

  @doc "At most `max` UTF-16 code units of text, never half a surrogate pair (shared.ts's cut)."
  @spec cut(String.t(), non_neg_integer()) :: String.t()
  def cut(text, max) do
    if JS.len16(text) <= max, do: text, else: cut(text, max, 0, [])
  end

  defp cut(<<c::utf8, rest::binary>>, max, n, acc) do
    w = if c > 0xFFFF, do: 2, else: 1
    if n + w > max, do: IO.iodata_to_binary(Enum.reverse(acc)), else: cut(rest, max, n + w, [<<c::utf8>> | acc])
  end

  defp cut(_, _max, _n, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  @doc """
  The start of an error body: every secret of four or more characters cut
  out of a prefix long enough to hold one that starts inside the first 200
  characters, and only then cut to that length, so no part of a secret
  survives at the edge.
  """
  @spec error_body(String.t(), [String.t()]) :: String.t()
  def error_body(text, secrets) do
    kept = Enum.filter(secrets, &(is_binary(&1) and JS.len16(&1) >= 4))
    longest = kept |> Enum.map(&JS.len16/1) |> Enum.max(fn -> 0 end)
    head = Enum.reduce(kept, cut(text, @error_body_max + longest), &String.replace(&2, &1, "[redacted]"))
    cut(head, @error_body_max)
  end

  @doc "The error for an answer outside 2xx: `<provider> <origin> answered <status>: <body>`, the body's secrets cut out."
  @spec refused(String.t(), String.t(), answer(), [String.t()]) :: Cronwatch.Error.t()
  def refused(provider, url, %{status: status, body: body}, secrets) do
    tail = if body == "", do: "", else: ": " <> error_body(body, secrets)
    fail("#{provider} #{origin(url)} answered #{status}#{tail}")
  end

  @doc """
  `fetch/5` within `timeout/0` that fails on an answer outside 2xx with
  `refused/4`.
  """
  @spec post(Transport.spec(), String.t(), String.t(), [{String.t(), term()}], iodata(), [String.t()]) ::
          {:ok, answer()} | {:error, Cronwatch.Error.t()}
  def post(transport, provider, url, headers, body, secrets) do
    with {:ok, answer} <- fetch(transport, timeout(), url, headers, body) do
      if ok?(answer), do: {:ok, answer}, else: {:error, refused(provider, url, answer, secrets)}
    end
  end
end
