defmodule Cronwatch.Transport do
  @moduledoc """
  Sends the one POST the alert channels and Claude triage make: a behaviour,
  so an app can send it its own way (its Finch pool, a proxy, Req's
  retries). The default is `Cronwatch.Transport.Httpc`, on OTP's own
  `:httpc`.

  A transport is given as `{module, opts}` (or the module alone for `[]`),
  on a channel or triage (`transport: {MyApp.ReqTransport, []}`) or on the
  instance, which hands it to every channel and triage that has none of
  its own.

  `c:post/2` is given the options and a `Cronwatch.Transport.Request` (the
  URL, already read and checked; the headers in the order they are sent;
  the body) and answers `{:ok, %Cronwatch.Transport.Response{}}` whatever
  the status, or `{:error, reason}` when there was no answer. It must not
  follow a redirect: a 3xx is an answer like any other, and the channel
  fails on it, so credential headers never go where it points.

  The deadline and the answer's cap are not the transport's to enforce:
  `Cronwatch.Alerts.Post` runs `c:post/2` and reads the body in a process
  of its own, which it kills past the deadline, and reads at most 1 MiB of
  the body. A body can be a binary, or a function of no arguments called
  in that same process for each chunk in turn (`{:ok, chunk}`, `:done` or
  `{:error, reason}`), so a transport that streams is held to the cap as
  the body arrives. Its errors are rewritten so they name only the URL's
  origin.

  A transport over Req is a dozen lines:

      defmodule MyApp.ReqTransport do
        @behaviour Cronwatch.Transport

        @impl true
        def post(_opts, request) do
          case Req.post(request.url, headers: request.headers, body: request.body, redirect: false, retry: false) do
            {:ok, response} -> {:ok, %Cronwatch.Transport.Response{status: response.status, body: response.body}}
            {:error, e} -> {:error, e}
          end
        end
      end
  """

  alias Cronwatch.Transport.Request
  alias Cronwatch.Transport.Response

  @typedoc "A transport as given: a module, `{module, opts}`, or nil for the default."
  @type spec :: module() | {module(), term()} | nil

  @callback post(opts :: term(), Request.t()) :: {:ok, Response.t()} | {:error, term()}

  @doc """
  The transport to use: the one given, else the instance's (`fallback`),
  else `Cronwatch.Transport.Httpc`.
  """
  @spec resolve(spec(), spec()) :: {module(), term()}
  def resolve(given, fallback \\ nil)
  def resolve(nil, nil), do: {Cronwatch.Transport.Httpc, []}
  def resolve(nil, fallback), do: resolve(fallback, nil)
  def resolve({module, opts}, _) when is_atom(module), do: {module, opts}
  def resolve(module, _) when is_atom(module), do: {module, []}

  @doc "Checks a transport given as an option: nil, a module or `{module, opts}` whose module has `post/2`."
  @spec check(term(), String.t()) :: :ok | {:error, String.t()}
  def check(nil, _who), do: :ok
  def check({module, _opts}, who) when is_atom(module), do: check(module, who)

  def check(module, who) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :post, 2),
      do: :ok,
      else: {:error, "#{who}: #{inspect(module)} is not a Cronwatch.Transport"}
  end

  def check(other, who), do: {:error, "#{who}: transport must be a module or {module, opts}, not #{inspect(other)}"}
end

defmodule Cronwatch.Transport.Request do
  @moduledoc """
  One POST, as a `Cronwatch.Transport` is asked to send it. `url` is http
  or https, as the WHATWG URL parser (and so fetch) writes it; its path or
  query may be a credential, so it is never quoted. `headers` are in the
  order they are sent, names as the SDK writes them (lowercase), values
  without the spaces and line breaks around them. `body` is UTF-8.

  Its `Inspect` shows the URL's origin and the header names only, since the
  rest carries the channel's credentials.
  """

  @enforce_keys [:url]
  defstruct [:url, headers: [], body: ""]

  @type t :: %__MODULE__{url: String.t(), headers: [{String.t(), String.t()}], body: binary()}

  defimpl Inspect do
    import Inspect.Algebra

    alias Cronwatch.Alerts.Post

    def inspect(r, opts) do
      concat([
        "#Cronwatch.Transport.Request<origin: ",
        to_doc(Post.origin(r.url), opts),
        ", headers: ",
        to_doc(Enum.map(r.headers, &elem(&1, 0)), opts),
        ", body: #{byte_size(r.body)} bytes>"
      ])
    end
  end
end

defmodule Cronwatch.Transport.Response do
  @moduledoc """
  An answer: its status, and its body, a binary or a function of no
  arguments answering the next chunk (`{:ok, chunk}`), `:done` at the end,
  or `{:error, reason}`, called in the process that called
  `c:Cronwatch.Transport.post/2`. `close`, when set, is called in that
  process if the body is not read to its end (the cap was reached), so the
  transport can let the connection go.
  """

  @enforce_keys [:status]
  defstruct [:status, body: "", close: nil]

  @type chunk :: {:ok, binary()} | :done | {:error, term()}
  @type t :: %__MODULE__{
          status: non_neg_integer(),
          body: binary() | (-> chunk()),
          close: (-> any()) | nil
        }
end
