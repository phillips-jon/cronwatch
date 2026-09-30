defmodule Cronwatch.Alerts.URL do
  @moduledoc false
  # A URL read as the WHATWG URL parser (and so fetch) reads an http or
  # https URL, the Go and Rust ports' rules: characters up to U+0020 around
  # it dropped and every tab, CR and LF inside it removed; the slashes after
  # the scheme, and backslashes, read as fetch reads them; the host
  # lowercased, IPv4 in its dotted form (hex, octal and short forms read)
  # and IPv6 compressed; the scheme's own port left out; dot segments
  # resolved; and a space or other character a URL cannot hold
  # percent-encoded in the path, query and fragment. URI.parse/1 is RFC
  # 3986, which reads several of these differently. A host outside ASCII is
  # refused rather than converted to punycode.

  import Bitwise

  defstruct [:scheme, :host, :port, :path, :query, :fragment, user?: false]

  @type t :: %__MODULE__{
          scheme: String.t(),
          host: String.t(),
          port: non_neg_integer() | nil,
          path: String.t(),
          query: String.t() | nil,
          fragment: String.t() | nil,
          user?: boolean()
        }

  @default_ports %{"http" => 80, "https" => 443, "ws" => 80, "wss" => 443, "ftp" => 21}

  @doc "The text as the parser first cleans it."
  @spec clean(String.t()) :: String.t()
  def clean(raw) do
    raw
    |> trim_c0()
    |> String.replace(["\t", "\r", "\n"], "")
  end

  defp trim_c0(s), do: s |> trim_lead() |> String.reverse() |> trim_lead() |> String.reverse()
  defp trim_lead(<<c, rest::binary>>) when c <= 0x20, do: trim_lead(rest)
  defp trim_lead(s), do: s

  @doc """
  Reads a URL: `{:ok, url}` for one of a special scheme (http, https, ws,
  wss, ftp) with a host, `{:other, scheme}` for a URL of any other scheme,
  `:error` for anything else.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:other, String.t()} | :error
  def parse(raw) when is_binary(raw) do
    s = clean(raw)

    with {:ok, scheme, rest} <- scheme(s) do
      if Map.has_key?(@default_ports, scheme), do: special(scheme, rest), else: {:other, scheme}
    end
  end

  def parse(_), do: :error

  defp scheme(<<c, _::binary>> = s) when c in ?a..?z or c in ?A..?Z do
    case :binary.match(s, ":") do
      {at, 1} ->
        name = binary_part(s, 0, at)

        if name =~ ~r/\A[A-Za-z][A-Za-z0-9+.\-]*\z/,
          do: {:ok, String.downcase(name), binary_part(s, at + 1, byte_size(s) - at - 1)},
          else: :error

      :nomatch ->
        :error
    end
  end

  defp scheme(_), do: :error

  defp special(scheme, rest) do
    rest = skip_slashes(rest)
    {authority, rest} = split_at(rest, [?/, ?\\, ??, ?#])

    {rest, fragment} = split_once(rest, ?#)
    {path, query} = split_once(rest, ??)

    with {:ok, user?, hostport} <- userinfo(authority),
         {:ok, host, port} <- host_port(hostport),
         {:ok, host} <- host(host),
         {:ok, port} <- port(port, scheme) do
      {:ok,
       %__MODULE__{
         scheme: scheme,
         host: host,
         port: port,
         path: path(path),
         query: query && encode(query, &query_char?/1),
         fragment: fragment && encode(fragment, &fragment_char?/1),
         user?: user?
       }}
    end
  end

  defp skip_slashes(<<c, rest::binary>>) when c in [?/, ?\\], do: skip_slashes(rest)
  defp skip_slashes(s), do: s

  # The text up to the first of `stops`, and the rest from it.
  defp split_at(s, stops) do
    case :binary.match(s, Enum.map(stops, &<<&1>>)) do
      {at, _} -> {binary_part(s, 0, at), binary_part(s, at, byte_size(s) - at)}
      :nomatch -> {s, ""}
    end
  end

  defp split_once(s, c) do
    case :binary.split(s, <<c>>) do
      [a, b] -> {a, b}
      [a] -> {a, nil}
    end
  end

  # The part before the last "@" is the user name and password.
  defp userinfo(authority) do
    case :binary.matches(authority, "@") do
      [] ->
        {:ok, false, authority}

      matches ->
        {at, _} = List.last(matches)
        info = binary_part(authority, 0, at)
        host = binary_part(authority, at + 1, byte_size(authority) - at - 1)
        {:ok, info not in ["", ":"], host}
    end
  end

  defp host_port("[" <> _ = s) do
    case :binary.split(s, "]") do
      [v6, ""] -> {:ok, v6 <> "]", ""}
      [v6, ":" <> port] -> {:ok, v6 <> "]", port}
      _ -> :error
    end
  end

  defp host_port(s) do
    case :binary.split(s, ":") do
      [host, port] -> {:ok, host, port}
      [host] -> {:ok, host, ""}
    end
  end

  defp port("", _scheme), do: {:ok, nil}

  defp port(text, scheme) do
    if text =~ ~r/\A[0-9]+\z/ do
      n = String.to_integer(text)

      cond do
        n > 65_535 -> :error
        n == @default_ports[scheme] -> {:ok, nil}
        true -> {:ok, n}
      end
    else
      :error
    end
  end

  defp host(""), do: :error

  defp host("[" <> rest) do
    v6 = String.trim_trailing(rest, "]")

    # WHATWG's IPv6 parser has no zone (`%eth0`), which OTP's reads and drops.
    case not String.contains?(v6, "%") and :inet.parse_ipv6strict_address(String.to_charlist(v6)) do
      {:ok, addr} -> {:ok, "[" <> ipv6(addr) <> "]"}
      _ -> :error
    end
  end

  defp host(text) do
    decoded = percent_decode_bytes(text)

    cond do
      not String.valid?(decoded) -> :error
      not ascii?(decoded) -> :error
      Enum.any?(:binary.bin_to_list(decoded), &forbidden_host?/1) -> :error
      true -> decoded |> String.downcase() |> ipv4_or_domain()
    end
  end

  defp ascii?(s), do: Enum.all?(:binary.bin_to_list(s), &(&1 < 0x80))

  defp forbidden_host?(c),
    do: c < 0x21 or c == 0x7F or c in ~c"#%/:<>?@[\\]^|"

  # A host whose last label is a number is an IPv4 address.
  defp ipv4_or_domain(host) do
    labels = String.split(host, ".")
    labels = if length(labels) > 1 and List.last(labels) == "", do: Enum.drop(labels, -1), else: labels

    if number?(List.last(labels)), do: ipv4(labels), else: {:ok, host}
  end

  defp number?(label), do: label =~ ~r/\A[0-9]+\z/ or label =~ ~r/\A0[xX][0-9A-Fa-f]*\z/

  defp ipv4(labels) when length(labels) > 4, do: :error

  defp ipv4(labels) do
    parts = Enum.map(labels, &ipv4_number/1)
    n = length(parts)
    {init, [last]} = Enum.split(parts, n - 1)

    cond do
      Enum.any?(parts, &(&1 == :error)) -> :error
      Enum.any?(init, &(&1 > 255)) -> :error
      last >= Integer.pow(256, 5 - n) -> :error
      true -> {:ok, dotted(Enum.reduce(Enum.with_index(init), last, fn {p, i}, acc -> acc + (p <<< (8 * (3 - i))) end))}
    end
  end

  defp ipv4_number(""), do: :error

  defp ipv4_number(<<?0, x, hex::binary>>) when x in [?x, ?X] do
    if hex == "", do: 0, else: parse_int(hex, 16)
  end

  defp ipv4_number(<<?0, octal::binary>>) when octal != "", do: parse_int(octal, 8)
  defp ipv4_number(dec), do: parse_int(dec, 10)

  defp parse_int(text, base) do
    case Integer.parse(text, base) do
      {n, ""} -> n
      _ -> :error
    end
  end

  defp dotted(n), do: Enum.map_join([24, 16, 8, 0], ".", &Integer.to_string(n >>> &1 &&& 255))

  # WHATWG's IPv6 serializer: lowercase hex, the first longest run of two
  # or more zero pieces compressed.
  defp ipv6(addr) do
    pieces = Tuple.to_list(addr)
    {start, len} = longest_zeros(pieces)

    if len < 2 do
      Enum.map_join(pieces, ":", &hex/1)
    else
      {a, rest} = Enum.split(pieces, start)
      b = Enum.drop(rest, len)
      Enum.map_join(a, ":", &hex/1) <> "::" <> Enum.map_join(b, ":", &hex/1)
    end
  end

  defp hex(n), do: n |> Integer.to_string(16) |> String.downcase()

  defp longest_zeros(pieces) do
    pieces
    |> Enum.with_index()
    |> Enum.reduce({{0, 0}, nil}, fn
      {0, i}, {best, nil} -> {best, {i, 1}}
      {0, _}, {best, {s, l}} -> {best, {s, l + 1}}
      {_, _}, {best, run} -> {better(best, run), nil}
    end)
    |> then(fn {best, run} -> better(best, run) end)
  end

  defp better(best, nil), do: best
  defp better({_, bl} = best, {_, l} = run), do: if(l > bl, do: run, else: best)

  # The path, its dot segments resolved and characters a path cannot hold
  # encoded.
  defp path(text) do
    segments =
      text
      |> String.replace("\\", "/")
      |> String.split("/")
      |> Enum.drop(1)

    out =
      segments
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {seg, i}, acc ->
        last? = i == length(segments)

        cond do
          double_dot?(seg) ->
            acc = Enum.drop(acc, 1)
            if last?, do: ["" | acc], else: acc

          single_dot?(seg) ->
            if last?, do: ["" | acc], else: acc

          true ->
            [encode(seg, &path_char?/1) | acc]
        end
      end)
      |> Enum.reverse()

    "/" <> Enum.join(out, "/")
  end

  defp single_dot?(seg), do: String.downcase(seg) in [".", "%2e"]
  defp double_dot?(seg), do: String.downcase(seg) in ["..", ".%2e", "%2e.", "%2e%2e"]

  defp c0_or_high?(c), do: c < 0x20 or c > 0x7E
  defp path_char?(c), do: not (c0_or_high?(c) or c in ~c" \"#<>?^`{}")
  defp query_char?(c), do: not (c0_or_high?(c) or c in ~c" \"#<>'")
  defp fragment_char?(c), do: not (c0_or_high?(c) or c in ~c" \"<>`")

  defp encode(text, keep?) do
    for <<c <- text>>, into: "" do
      if keep?.(c), do: <<c>>, else: "%" <> String.upcase(Base.encode16(<<c>>))
    end
  end

  @doc "`%XX` decoded, bytes as they are."
  @spec percent_decode_bytes(String.t()) :: binary()
  def percent_decode_bytes(text), do: decode(text, [])

  defp decode(<<?%, h, l, rest::binary>>, acc)
       when h in ~c"0123456789abcdefABCDEF" and l in ~c"0123456789abcdefABCDEF" do
    decode(rest, [String.to_integer(<<h, l>>, 16) | acc])
  end

  defp decode(<<c, rest::binary>>, acc), do: decode(rest, [c | acc])
  defp decode(<<>>, acc), do: acc |> Enum.reverse() |> :binary.list_to_bin()

  @doc "The URL as the parser writes it."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = u) do
    origin(u) <>
      u.path <>
      if(u.query, do: "?" <> u.query, else: "") <>
      if(u.fragment, do: "#" <> u.fragment, else: "")
  end

  @doc "`url.origin`: the scheme, host and port."
  @spec origin(t()) :: String.t()
  def origin(%__MODULE__{} = u) do
    u.scheme <> "://" <> u.host <> if(u.port, do: ":#{u.port}", else: "")
  end
end
