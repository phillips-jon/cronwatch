if Code.ensure_loaded?(Plug.Conn) do
  defmodule Cronwatch.Web do
    @moduledoc """
    The dashboard and its JSON API as a Plug: the SDK's `cw.routes()`, the
    same pages byte for byte and the same API, so `@cronwatch/mcp` works
    against an Elixir app as it does against a Node one.

    In Phoenix, forward to it outside the `:browser` pipeline (the dashboard
    has its own cross-site check and cookie, and Phoenix's CSRF plug would
    refuse its forms):

        # lib/my_app_web/router.ex
        scope "/" do
          forward "/cronwatch", Cronwatch.Web
        end

    and in a `Plug.Router` the same way. The base path is where the router
    mounted it; the pages link under it.

    Options:

      * `:instance` - the Cronwatch instance to show (default `Cronwatch`).
      * `:token` - the token the dashboard asks for, sent as
        `Authorization: Bearer <token>`, or once as `?token=<token>`, which
        moves it into a cookie. Left out (or `""`), it is `CRONWATCH_TOKEN`,
        read on each request; `{:system, "VAR"}` reads another variable, also
        on each request, so a release does not bake in its build machine's
        value. `false` serves the dashboard open to anyone, for one behind the
        app's own auth. With no token in development (`CRONWATCH_ENV`,
        `APP_ENV` or `MIX_ENV` naming it), the dashboard makes one and prints
        a sign-in link on its first request; with none otherwise it answers
        503. `/api/check` also takes the instance's cron secret as a bearer.
      * `:base_path` - where the dashboard is mounted, when a router's mount
        does not say (default `/cronwatch`).
      * `:origin` - the public origin the dashboard is served from, such as
        `"https://app.example.com"`, for an app behind a proxy whose requests
        carry an internal host or scheme. Anything that is not an http or
        https URL is refused when the options are read.
      * `:trust_proxy` - take the public origin from `X-Forwarded-Proto` and
        `X-Forwarded-Host`. Only for an app whose proxy sets or overwrites
        both.

    A request body is read only when a route wants it, and at most 1 MiB of
    it; behind a Phoenix endpoint, the fields its `Plug.Parsers` already read
    are used.
    """

    @behaviour Plug

    alias Cronwatch.Web.Origin
    alias Cronwatch.Web.Request
    alias Cronwatch.Web.Routes

    @derive {Inspect, except: [:token]}
    defstruct instance: Cronwatch, token: nil, base_path: nil, origin: nil, trust_proxy: false

    @type t :: %__MODULE__{
            instance: atom(),
            token: String.t() | false | {:system, String.t()} | nil,
            base_path: String.t() | nil,
            origin: String.t() | nil,
            trust_proxy: boolean()
          }

    @known [:instance, :token, :base_path, :origin, :trust_proxy]

    @doc """
    Checks the options' shape and keeps them. Phoenix calls this when the
    router compiles, so nothing here reads the environment or the instance:
    both are read on each request.
    """
    @impl Plug
    @spec init(keyword() | t()) :: t()
    def init(%__MODULE__{} = opts), do: opts

    def init(opts) when is_list(opts) do
      case Enum.find(opts, fn {k, _} -> k not in @known end) do
        nil -> :ok
        {k, _} -> raise ArgumentError, "Cronwatch.Web: unknown option #{inspect(k)}"
      end

      instance = Keyword.get(opts, :instance, Cronwatch)
      token = Keyword.get(opts, :token)
      base_path = Keyword.get(opts, :base_path)
      trust_proxy = Keyword.get(opts, :trust_proxy, false)

      unless is_atom(instance) and instance not in [nil, true, false],
        do: raise(ArgumentError, "Cronwatch.Web: instance must be an atom, not #{inspect(instance)}")

      unless token == nil or token == false or is_binary(token) or match?({:system, v} when is_binary(v), token),
        do: raise(ArgumentError, "Cronwatch.Web: token must be a string, {:system, name} or false")

      unless base_path == nil or is_binary(base_path),
        do: raise(ArgumentError, "Cronwatch.Web: base_path must be a string, not #{inspect(base_path)}")

      unless is_boolean(trust_proxy),
        do: raise(ArgumentError, "Cronwatch.Web: trust_proxy must be true or false, not #{inspect(trust_proxy)}")

      origin =
        case Keyword.get(opts, :origin) do
          o when is_binary(o) or o == nil ->
            case Origin.configured(o) do
              {:ok, origin} -> origin
              {:error, message} -> raise ArgumentError, message
            end

          other ->
            raise ArgumentError, "Cronwatch.Web: origin must be a string, not #{inspect(other)}"
        end

      %__MODULE__{
        instance: instance,
        token: token,
        base_path: base_path && String.trim_trailing(base_path, "/"),
        origin: origin,
        trust_proxy: trust_proxy
      }
    end

    @doc """
    The token the dashboard asks for with these options, the one it made in
    development included, or nil when it is open or locked for want of one.
    """
    @spec token(keyword() | t()) :: String.t() | nil
    def token(opts) do
      case Routes.token_state(init(opts)) do
        {kind, token} when kind in [:configured, :generated] -> token
        _ -> nil
      end
    end

    @impl Plug
    def call(%Plug.Conn{} = conn, %__MODULE__{} = opts) do
      key = {__MODULE__, make_ref()}
      Process.put(key, conn)

      try do
        {status, headers, body} = Routes.handle(opts, request(conn, key))
        conn = Process.get(key)

        # Plug starts every answer with a cache-control of its own; the SDK's
        # is set in its place, or none where the SDK sends none.
        conn = Plug.Conn.delete_resp_header(conn, "cache-control")

        headers
        |> Enum.reduce(conn, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value) end)
        |> Plug.Conn.send_resp(status, body)
        |> Plug.Conn.halt()
      after
        Process.delete(key)
      end
    end

    # The request as the routes read it: the path as sent (Plug does not
    # decode it), the query as sent, the headers, whether it came over TLS,
    # where a router mounted the plug, and a body read only when a route
    # wants it.
    defp request(conn, key) do
      headers =
        if List.keymember?(conn.req_headers, "host", 0),
          do: conn.req_headers,
          else: conn.req_headers ++ [{"host", authority(conn)}]

      %Request{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        headers: headers,
        tls: conn.scheme == :https,
        mount: if(conn.script_name != [], do: "/" <> Enum.join(conn.script_name, "/")),
        body: fn limit -> read_body(key, limit) end
      }
    end

    # HTTP/2 sends the host as :authority, which the adapter puts in
    # conn.host and conn.port.
    defp authority(%{scheme: :http, port: 80} = conn), do: conn.host
    defp authority(%{scheme: :https, port: 443} = conn), do: conn.host
    defp authority(conn), do: "#{conn.host}:#{conn.port}"

    # Reads the body, refusing one longer than `limit` by its length or once
    # more than that has arrived. A body a Phoenix endpoint's Plug.Parsers
    # already read is its parsed fields. The conn the read leaves is kept for
    # the answer.
    defp read_body(key, limit) do
      conn = Process.get(key)

      length =
        case Plug.Conn.get_req_header(conn, "content-length") do
          [value | _] ->
            case Integer.parse(String.trim(value)) do
              {n, ""} -> n
              _ -> nil
            end

          [] ->
            nil
        end

      if length != nil and length > limit do
        :too_large
      else
        case Plug.Conn.read_body(conn, length: limit + 1) do
          {:ok, data, conn} ->
            Process.put(key, conn)

            cond do
              byte_size(data) > limit -> :too_large
              data == "" and parsed?(conn) -> {:parsed, conn.body_params}
              true -> {:ok, data}
            end

          {:more, _, conn} ->
            Process.put(key, conn)
            :too_large

          {:error, reason} ->
            {:error, reason}
        end
      end
    rescue
      # A body that cannot be read at all (an adapter that refuses a second
      # read) is none, as a body cut short is.
      e -> {:error, e}
    end

    defp parsed?(%{body_params: %Plug.Conn.Unfetched{}}), do: false
    defp parsed?(%{body_params: params}), do: is_map(params) and map_size(params) > 0
  end
end
