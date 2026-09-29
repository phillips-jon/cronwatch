defmodule Cronwatch.Web.Request do
  @moduledoc false
  # A request as the dashboard reads it, whatever served it, and how it is
  # read the way the SDK's routes read a fetch Request, carried over from the
  # Go port's routes_request.go through the Rust port's web/request.rs: the
  # path as the URL parser leaves it, the query as URLSearchParams parses it,
  # headers as Headers.get joins them, and the body as request.json() and
  # request.formData() read it.
  #
  # `body` is a function of the most bytes wanted, answering {:ok, bytes},
  # :too_large (past that many) or {:error, reason} (a body that could not be
  # read to its end), so a request refused for want of the token is never
  # read; or {:parsed, params}, the fields a Phoenix endpoint's Plug.Parsers
  # already read.

  import Bitwise

  alias Cronwatch.Format
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Web.Text

  defstruct method: "GET", path: "/", query: "", headers: [], tls: false, mount: nil, body: nil

  @type body :: nil | (non_neg_integer() -> {:ok, binary()} | :too_large | {:error, term()}) | {:parsed, map()}
  @type t :: %__MODULE__{
          method: String.t(),
          path: String.t(),
          query: String.t(),
          headers: [{String.t(), binary()}],
          tls: boolean(),
          mount: String.t() | nil,
          body: body()
        }

  @doc """
  A request header as fetch's `Headers.get` gives it: every value joined
  with `, ` (a cookie's with `; `, as HTTP/2 sends each cookie apart), or
  nil when there is none.
  """
  @spec header(t(), String.t()) :: binary() | nil
  def header(%__MODULE__{headers: headers}, name) do
    case for({n, v} <- headers, String.downcase(n) == name, do: v) do
      [] -> nil
      [one] -> one
      many -> Enum.join(many, if(name == "cookie", do: "; ", else: ", "))
    end
  end

  @doc "The path the client sent: the empty path and `*` are `/`, a fragment is dropped."
  @spec target_path(String.t()) :: String.t()
  def target_path(path) do
    path = path |> String.split("#", parts: 2) |> hd()
    if path in ["", "*"], do: "/", else: path
  end

  # The path percent-encode set is C0 controls, space, " # < > ? ` { } and
  # everything past ~.
  defp path_safe?(c), do: c > 0x20 and c < 0x7F and c not in ~c"\"#<>?`{}"

  @doc """
  A path as `new URL()` leaves it for an http URL: backslashes read as
  slashes, characters outside the path set escaped, and `.` and `..`
  segments (written plainly or as `%2e`) resolved.
  """
  @spec normalize_path(String.t()) :: String.t()
  def normalize_path(raw) do
    b =
      for <<c <- raw>>, into: "" do
        cond do
          c == ?\\ -> "/"
          path_safe?(c) or c == ?% -> <<c>>
          true -> "%" <> Text.hex(c)
        end
      end

    trimmed = with "/" <> rest <- b, do: rest
    segments = String.split(trimmed, "/")
    last = length(segments) - 1

    out =
      segments
      |> Enum.with_index()
      |> Enum.reduce([], fn {s, i}, out ->
        case String.downcase(s) do
          d when d in [".", "%2e"] ->
            if i == last, do: ["" | out], else: out

          d when d in ["..", ".%2e", "%2e.", "%2e%2e"] ->
            out = Enum.drop(out, 1)
            if i == last, do: ["" | out], else: out

          _ ->
            [s | out]
        end
      end)

    "/" <> (out |> Enum.reverse() |> Enum.join("/"))
  end

  @doc "The path under the base, without a trailing slash."
  @spec strip_base(String.t(), String.t()) :: String.t()
  def strip_base(pathname, base) do
    path =
      if String.starts_with?(pathname, base),
        do: binary_part(pathname, byte_size(base), byte_size(pathname) - byte_size(base)),
        else: pathname

    path = if path == "", do: "/", else: path

    if byte_size(path) > 1 and String.ends_with?(path, "/"),
      do: binary_part(path, 0, byte_size(path) - 1),
      else: path
  end

  @doc """
  `decodeURIComponent`, or nil where it would throw: an escape that is not
  one, or bytes that are not UTF-8.
  """
  @spec safe_decode(String.t()) :: String.t() | nil
  def safe_decode(s) do
    if bad_escape?(s) do
      nil
    else
      decoded = percent_decode(s)
      if String.valid?(decoded), do: decoded
    end
  end

  defp bad_escape?(<<?%, a, b, rest::binary>>), do: not (hex?(a) and hex?(b)) or bad_escape?(rest)
  defp bad_escape?(<<?%, _::binary>>), do: true
  defp bad_escape?(<<_, rest::binary>>), do: bad_escape?(rest)
  defp bad_escape?(<<>>), do: false

  defp hex?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  defp hex_value(c) when c in ?0..?9, do: c - ?0
  defp hex_value(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_value(c), do: c - ?A + 10

  @doc "Decodes every `%XX`, leaving anything else as it is."
  @spec percent_decode(binary()) :: binary()
  def percent_decode(s), do: s |> pdecode([]) |> IO.iodata_to_binary()

  defp pdecode(<<?%, a, b, rest::binary>>, acc) do
    if hex?(a) and hex?(b),
      do: pdecode(rest, [hex_value(a) <<< 4 ||| hex_value(b) | acc]),
      else: pdecode(<<a, b, rest::binary>>, [?% | acc])
  end

  defp pdecode(<<c, rest::binary>>, acc), do: pdecode(rest, [c | acc])
  defp pdecode(<<>>, acc), do: Enum.reverse(acc)

  @doc """
  `application/x-www-form-urlencoded` parsing as `URLSearchParams` does it:
  `+` is a space, an escape that is not one is kept as written, and bytes
  that are not UTF-8 become U+FFFD.
  """
  @spec parse_form(binary()) :: [{String.t(), String.t()}]
  def parse_form(text) do
    text
    |> :binary.split("&", [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      case :binary.split(part, "=") do
        [name, value] -> {form_decode(name), form_decode(value)}
        [name] -> {form_decode(name), ""}
      end
    end)
  end

  defp form_decode(s), do: s |> String.replace("+", " ") |> percent_decode() |> JS.scrub()

  @doc "The `application/x-www-form-urlencoded` serializer `URLSearchParams` writes with."
  @spec form_encode(String.t()) :: String.t()
  def form_encode(s) do
    for <<c <- s>>, into: "" do
      cond do
        c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"*-._" -> <<c>>
        c == ?\s -> "+"
        true -> "%" <> Text.hex(c)
      end
    end
  end

  @doc "`URLSearchParams#get`: the first value, or nil."
  @spec param([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def param(pairs, name) do
    case List.keyfind(pairs, name, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  @doc """
  A field of a request's form or JSON object, as `String(value)` gives it in
  JavaScript; nil for anything else, or a body that cannot be read as its
  type says. The last of several fields of one name wins, as
  `Object.fromEntries` has it.
  """
  @spec body_field(String.t(), binary(), String.t()) :: String.t() | nil
  def body_field(content_type, data, name) do
    cond do
      String.contains?(content_type, "application/json") ->
        text = JS.scrub(data)
        text = with "﻿" <> rest <- text, do: rest

        case JS.parse(text) do
          {:ok, %Object{} = o} ->
            case Object.fetch(o, name) do
              {:ok, v} -> Format.js_text(v)
              :error -> nil
            end

          {:ok, list} when is_list(list) ->
            case Object.array_index(name) do
              nil -> nil
              i -> if i < length(list), do: Format.js_text(Enum.at(list, i))
            end

          _ ->
            nil
        end

      String.contains?(content_type, "multipart/form-data") ->
        case multipart_fields(content_type, data) do
          nil -> nil
          fields -> last(fields, name)
        end

      String.contains?(content_type, "application/x-www-form-urlencoded") ->
        data |> parse_form() |> last(name)

      true ->
        nil
    end
  end

  defp last(fields, name) do
    Enum.reduce(fields, nil, fn
      {^name, v}, _ -> v
      _, acc -> acc
    end)
  end

  @doc """
  A field of what a Phoenix endpoint's `Plug.Parsers` read, as `String(value)`
  gives it: a form's fields are strings already, JSON's values are what the
  endpoint's JSON library made of them, and a file is `[object File]`, as
  `formData()` has it.
  """
  @spec parsed_field(map(), String.t()) :: String.t() | nil
  def parsed_field(params, name) do
    case Map.fetch(params, name) do
      {:ok, v} -> parsed_text(v, 1)
      :error -> nil
    end
  catch
    # Nested past what JS.parse reads, as the plug's own read of the same
    # body would find it: none.
    :too_deep -> nil
  end

  defp parsed_text(v, depth) do
    # The body's object is the first level, as JS.parse counts.
    if depth >= JS.max_depth(), do: throw(:too_deep), else: text_at(v, depth)
  end

  defp text_at(nil, _), do: "null"
  defp text_at(%{__struct__: Plug.Upload}, _), do: "[object File]"
  defp text_at(v, _) when is_binary(v) or is_number(v) or is_boolean(v), do: Format.js_text(v)
  defp text_at(%{} = map, _) when not is_struct(map), do: "[object Object]"

  defp text_at(list, depth) when is_list(list),
    do: Enum.map_join(list, ",", fn e -> if e == nil, do: "", else: parsed_text(e, depth + 1) end)

  defp text_at(other, _), do: Format.js_text(other)

  # A media type's parameter, unquoted, its name matched without regard to
  # case.
  defp media_param(content_type, name) do
    content_type
    |> String.split(";")
    |> tl()
    |> Enum.find_value(fn part ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> if String.downcase(String.trim(k)) == name, do: unquote_value(String.trim(v))
        _ -> nil
      end
    end)
  end

  defp unquote_value(<<?", _::binary>> = v) when byte_size(v) >= 2 do
    if String.ends_with?(v, "\"") do
      v |> binary_part(1, byte_size(v) - 2) |> unescape([])
    else
      v
    end
  end

  defp unquote_value(v), do: v

  defp unescape(<<?\\, c::utf8, rest::binary>>, acc), do: unescape(rest, [<<c::utf8>> | acc])
  defp unescape(<<?\\>>, acc), do: unescape(<<>>, acc)
  defp unescape(<<c::utf8, rest::binary>>, acc), do: unescape(rest, [<<c::utf8>> | acc])
  defp unescape(<<c, rest::binary>>, acc), do: unescape(rest, [c | acc])
  defp unescape(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp find(haystack, needle, from) when from <= byte_size(haystack) do
    case :binary.match(haystack, needle, scope: {from, byte_size(haystack) - from}) do
      {at, _} -> at
      :nomatch -> nil
    end
  end

  defp find(_, _, _), do: nil

  # The fields of a multipart/form-data body, as formData() reads them: a
  # file part's value is [object File]. nil for a body that does not parse,
  # as formData() throws on one.
  defp multipart_fields(content_type, data) do
    case media_param(content_type, "boundary") do
      b when is_binary(b) and b != "" ->
        delimiter = "--" <> b

        start =
          if String.starts_with?(data, delimiter) do
            0
          else
            crlf = find(data, "\r\n" <> delimiter, 0)
            lf = find(data, "\n" <> delimiter, 0)

            cond do
              crlf -> crlf + 2
              lf -> lf + 1
              true -> nil
            end
          end

        if start, do: parts(data, delimiter, start, [])

      _ ->
        nil
    end
  end

  defp parts(data, delimiter, at, fields) do
    at = at + byte_size(delimiter)

    cond do
      at > byte_size(data) ->
        nil

      binary_part(data, at, min(2, byte_size(data) - at)) == "--" ->
        Enum.reverse(fields)

      true ->
        with eol when is_integer(eol) <- find(data, "\n", at),
             {:ok, disposition, at} <- part_headers(data, eol + 1, ""),
             next when is_integer(next) <- find(data, "\n" <> delimiter, at) do
          stop = if next > at and :binary.at(data, next - 1) == ?\r, do: next - 1, else: next
          value = binary_part(data, at, max(stop, at) - at)
          kind = disposition |> String.split(";") |> hd() |> String.trim() |> String.downcase()
          name = if kind == "form-data", do: media_param(disposition, "name")

          fields =
            cond do
              name in [nil, ""] -> fields
              media_param(disposition, "filename") not in [nil, ""] -> [{name, "[object File]"} | fields]
              true -> [{name, JS.scrub(value)} | fields]
            end

          parts(data, delimiter, next + 1, fields)
        else
          _ -> nil
        end
    end
  end

  # The part's headers, up to an empty line.
  defp part_headers(data, at, disposition) do
    case find(data, "\n", at) do
      nil ->
        nil

      eol ->
        line = binary_part(data, at, eol - at)
        line = if String.ends_with?(line, "\r"), do: binary_part(line, 0, byte_size(line) - 1), else: line

        if line == "" do
          {:ok, disposition, eol + 1}
        else
          disposition =
            case String.split(JS.scrub(line), ":", parts: 2) do
              [k, v] ->
                if String.downcase(String.trim(k)) == "content-disposition", do: String.trim(v), else: disposition

              _ ->
                disposition
            end

          part_headers(data, eol + 1, disposition)
        end
    end
  end
end

defimpl Inspect, for: Cronwatch.Web.Request do
  # A request carries the token as a bearer, a cookie or `?token=`, so its
  # inspect names the headers without their values and leaves out the query
  # and the body.
  import Inspect.Algebra

  def inspect(req, opts) do
    fields = [
      method: req.method,
      path: req.path,
      headers: Enum.map(req.headers, &elem(&1, 0)),
      tls: req.tls,
      mount: req.mount
    ]

    concat(["#Cronwatch.Web.Request<", to_doc(fields, opts), ">"])
  end
end
