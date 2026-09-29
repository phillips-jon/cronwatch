defmodule Cronwatch.Transport.Httpc do
  @moduledoc """
  The default `Cronwatch.Transport`, on OTP's own `:httpc`, so the package
  needs no HTTP client of its own.

  Every request is made the one way, hardened:

    * A redirect is never followed (`autoredirect: false`): its 3xx is the
      answer, and the channel fails on it.
    * TLS is always verified: `verify: :verify_peer` against the system's
      roots (`:public_key.cacerts_get/0`), the host checked as HTTPS checks
      it and sent as SNI. `:httpc` without these options checks nothing on
      older OTP releases, which is why every request goes through here.
    * A 200 answer's body is streamed, a chunk at a time, so
      `Cronwatch.Alerts.Post` reads at most 1 MiB of it and the request is
      cancelled there. `:httpc` streams only 200 and 206 answers; any other
      is read by `:httpc` whole, so it is held to `max_body_size` (8 MiB):
      one that says it is longer, or whose chunks run longer, fails as
      `<origin>: body_too_big`. One that is neither, ending when the
      connection closes, is held by the deadline alone.
    * No `accept-encoding` is sent and `:httpc` decompresses nothing, so a
      compressed answer cannot grow in memory.
    * The requests run in `:httpc`'s profile `:cronwatch`, started on first
      use under the `:inets` application, with no connections kept between
      requests, and `:httpc`'s own timeout set to the request's deadline,
      so a request whose caller was stopped ends on its own.
    * `:httpc` reads no proxy from the environment, as Node's fetch reads
      none.

  Options: `cacerts:` (DER certificates to trust in place of the system's,
  for a private certificate authority) and `ssl:` (further `:ssl` client
  options, added after these).

  `:httpc` sends its own `host`, `content-length`, `te` and `connection`
  headers, places the headers it knows in an order of its own, and sends no
  `user-agent` unless given one.
  """

  @behaviour Cronwatch.Transport

  alias Cronwatch.Transport.Request
  alias Cronwatch.Transport.Response

  @profile :cronwatch
  # The most of an answer :httpc holds when it does not stream it.
  @max_body_size 8 * 1024 * 1024
  # :httpc's own timeout, a backstop for a request whose caller is gone;
  # Cronwatch.Alerts.Post holds the real deadline.
  @backstop 30_000

  @impl true
  def post(opts, %Request{} = r) do
    with :ok <- profile() do
      opts = if is_list(opts), do: opts, else: []
      url = String.to_charlist(r.url)
      {content_type, headers} = split_headers(r.headers)

      http = [
        autoredirect: false,
        timeout: Keyword.get(opts, :timeout, @backstop),
        ssl: ssl(r.url, opts)
      ]

      options = [sync: false, stream: {:self, :once}, body_format: :binary, max_body_size: @max_body_size]

      case :httpc.request(:post, {url, headers, content_type, r.body}, http, options, @profile) do
        {:ok, ref} -> answer(ref)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # content-type is given to :httpc on its own; the rest as charlists.
  defp split_headers(headers) do
    content_type =
      Enum.find_value(headers, ~c"", fn {n, v} -> if String.downcase(n) == "content-type", do: bytes(v) end)

    rest = for {n, v} <- headers, String.downcase(n) != "content-type", do: {bytes(n), bytes(v)}
    {content_type, rest}
  end

  defp bytes(s), do: :binary.bin_to_list(s)

  defp answer(ref) do
    receive do
      {:http, {^ref, :stream_start, headers, pid}} ->
        status = if List.keymember?(headers, ~c"content-range", 0), do: 206, else: 200

        {:ok,
         %Response{
           status: status,
           body: fn -> next(ref, pid) end,
           close: fn -> :httpc.cancel_request(ref, @profile) end
         }}

      {:http, {^ref, {{_version, status, _reason}, _headers, body}}} ->
        {:ok, %Response{status: status, body: IO.iodata_to_binary(body)}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    end
  end

  defp next(ref, pid) do
    :ok = :httpc.stream_next(pid)

    receive do
      {:http, {^ref, :stream, chunk}} -> {:ok, chunk}
      {:http, {^ref, :stream_end, _headers}} -> :done
      {:http, {^ref, {:error, reason}}} -> {:error, reason}
    end
  end

  # The profile, started once under :inets and set to keep no connections.
  defp profile do
    case :inets.start(:httpc, profile: @profile) do
      {:ok, _} -> configure()
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp configure do
    :httpc.set_options([max_sessions: 0, max_keep_alive_length: 0, keep_alive_timeout: 0], @profile)
  end

  @doc false
  # The TLS options: always verified, against the system's roots (or the
  # ones given), the host checked as HTTPS checks it and sent as SNI.
  def ssl(url, opts) do
    host = url |> URI.parse() |> Map.get(:host) |> to_string() |> String.trim_leading("[") |> String.trim_trailing("]")
    ip? = match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))

    cacerts =
      case Keyword.get(opts, :cacerts) do
        nil -> :public_key.cacerts_get()
        certs -> certs
      end

    [
      verify: :verify_peer,
      cacerts: cacerts,
      depth: 10,
      server_name_indication: if(ip? or host == "", do: :disable, else: String.to_charlist(host)),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ Keyword.get(opts, :ssl, [])
  end
end
