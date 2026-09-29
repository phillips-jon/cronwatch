defmodule Cronwatch.Web.Origin do
  @moduledoc false
  # Origins read as the SDK's `new URL(value).origin` reads them, carried
  # over from the Go port's routes_origin.go through the Rust port's
  # web/origin.rs: spaces and control characters around the value and tabs
  # or line breaks in it are dropped, slashes after the scheme may be missing
  # or backslashes, credentials are ignored, the host is lowercased (percent
  # escapes decoded, IPv4 numbers written out, IPv6 compressed, a host
  # outside ASCII written in punycode) and a default port is left out.
  # URI.parse/1 is RFC 3986, which reads all of these differently.

  import Bitwise

  alias Cronwatch.JS
  alias Cronwatch.Web.Request

  # The longest host outside ASCII read, in bytes. Punycode takes time in the
  # label's length times its distinct characters, and a Host header is
  # anyone's to send: a name no DNS could hold (253 bytes) is refused well
  # past that bound.
  @max_idn_host 1024

  @doc """
  The origin option as `scheme://host[:port]`, nil for `""` or nil, or the
  SDK's error for anything that is not an http or https URL.
  """
  @spec configured(String.t() | nil) :: {:ok, String.t() | nil} | {:error, String.t()}
  def configured(nil), do: {:ok, nil}
  def configured(""), do: {:ok, nil}

  def configured(value) when is_binary(value) do
    case read(value) do
      {:ok, origin, _} ->
        {:ok, origin}

      {:error, :not_http} ->
        {:error, "routes: origin must be http or https, got #{JS.quote(value)}"}

      {:error, :not_url} ->
        {:error, ~s(routes: origin must be an absolute URL such as "https://app.example.com", got #{JS.quote(value)})}
    end
  end

  @doc """
  `scheme://host[:port]` for text that is a scheme and a bare host, or nil
  when it carries a path, credentials, a query or a fragment, or is not an
  http or https URL.
  """
  @spec bare(String.t()) :: String.t() | nil
  def bare(value) do
    case read(value) do
      {:ok, origin, false} -> origin
      _ -> nil
    end
  end

  @doc """
  The origin of `value`, and whether anything past the host would show in the
  URL (a path other than `/`, credentials, a query or a fragment).
  """
  @spec read(String.t()) :: {:ok, String.t(), boolean()} | {:error, :not_url | :not_http}
  def read(value) do
    text =
      value
      |> trim_controls()
      |> String.replace(["\t", "\n", "\r"], "")

    with [scheme, rest] <- :binary.split(text, ":"),
         true <- scheme_ok?(scheme) || {:error, :not_url},
         scheme = String.downcase(scheme),
         {:ok, default_port} <- default_port(scheme) do
      rest = trim_leading_slashes(rest)
      {authority, after_host} = split_authority(rest)

      {userinfo, hostport, has_at} =
        case :binary.matches(authority, "@") do
          [] ->
            {"", authority, false}

          matches ->
            {at, _} = List.last(matches)
            {binary_part(authority, 0, at), binary_part(authority, at + 1, byte_size(authority) - at - 1), true}
        end

      with {:ok, host, port} <- split_port(hostport),
           {:ok, host} <- read_host(host) do
        shown = if port != nil and port != default_port, do: ":#{port}", else: ""
        extra = (has_at and userinfo != "" and userinfo != ":") or past_host?(after_host)
        {:ok, "#{scheme}://#{host}#{shown}", extra}
      end
    else
      {:error, _} = e -> e
      _ -> {:error, :not_url}
    end
  end

  defp trim_controls(s) do
    s = trim_leading_controls(s)
    trim_trailing_controls(s, byte_size(s))
  end

  defp trim_leading_controls(<<c, rest::binary>>) when c <= 0x20, do: trim_leading_controls(rest)
  defp trim_leading_controls(s), do: s

  defp trim_trailing_controls(_s, 0), do: ""

  defp trim_trailing_controls(s, n) do
    if :binary.at(s, n - 1) <= 0x20, do: trim_trailing_controls(s, n - 1), else: binary_part(s, 0, n)
  end

  defp scheme_ok?(<<c, rest::binary>>) when c in ?a..?z or c in ?A..?Z,
    do: for(<<d <- rest>>, reduce: true, do: (ok -> ok and (d in ?a..?z or d in ?A..?Z or d in ?0..?9 or d in ~c"+.-")))

  defp scheme_ok?(_), do: false

  defp default_port("http"), do: {:ok, 80}
  defp default_port("https"), do: {:ok, 443}
  defp default_port(_), do: {:error, :not_http}

  defp trim_leading_slashes(<<c, rest::binary>>) when c in [?/, ?\\], do: trim_leading_slashes(rest)
  defp trim_leading_slashes(s), do: s

  defp split_authority(rest) do
    case :binary.match(rest, ["/", "\\", "?", "#"]) do
      {i, _} -> {binary_part(rest, 0, i), binary_part(rest, i, byte_size(rest) - i)}
      :nomatch -> {rest, ""}
    end
  end

  defp past_host?(after_host) do
    {path, fragment} =
      case :binary.split(after_host, "#") do
        [p, f] -> {p, f}
        [p] -> {p, nil}
      end

    {path, query} =
      case :binary.split(path, "?") do
        [p, q] -> {p, q}
        [p] -> {p, ""}
      end

    (path != "" and path != "/" and path != "\\") or query != "" or (fragment != nil and fragment != "")
  end

  # The host and the port (nil for none) of host[:port].
  defp split_port(authority) do
    split =
      if String.starts_with?(authority, "[") do
        case :binary.match(authority, "]") do
          {end_at, _} ->
            {binary_part(authority, 0, end_at + 1),
             binary_part(authority, end_at + 1, byte_size(authority) - end_at - 1)}

          :nomatch ->
            :error
        end
      else
        case :binary.matches(authority, ":") do
          [] ->
            {authority, ""}

          matches ->
            {i, _} = List.last(matches)
            {binary_part(authority, 0, i), binary_part(authority, i, byte_size(authority) - i)}
        end
      end

    case split do
      :error -> {:error, :not_url}
      {host, rest} when rest in ["", ":"] -> {:ok, host, nil}
      {host, ":" <> digits} -> port(host, digits)
      _ -> {:error, :not_url}
    end
  end

  defp port(host, digits) do
    if digits != "" and digits?(digits) do
      digits = String.trim_leading(digits, "0")

      cond do
        byte_size(digits) > 5 -> {:error, :not_url}
        digits == "" -> {:ok, host, 0}
        String.to_integer(digits) > 65_535 -> {:error, :not_url}
        true -> {:ok, host, String.to_integer(digits)}
      end
    else
      {:error, :not_url}
    end
  end

  defp digits?(s), do: s != "" and for(<<c <- s>>, reduce: true, do: (ok -> ok and c in ?0..?9))

  defp forbidden_host_char?(c), do: c <= 0x20 or c == 0x7F or c in ~c"#%/:<>?@[\\]^|"

  defp read_host(""), do: {:error, :not_url}

  defp read_host("[" <> inner) do
    with true <- String.ends_with?(inner, "]"),
         inner = binary_part(inner, 0, byte_size(inner) - 1),
         false <- String.contains?(inner, "%"),
         {:ok, addr} <- :inet.parse_ipv6strict_address(String.to_charlist(inner)) do
      {:ok, "[#{ipv6_text(addr)}]"}
    else
      _ -> {:error, :not_url}
    end
  end

  defp read_host(host) do
    decoded = Request.percent_decode(host)

    with true <- String.valid?(decoded) || {:error, :not_url},
         decoded = String.downcase(decoded),
         {:ok, decoded} <- punycode_host(decoded),
         true <-
           (decoded != "" and not Enum.any?(String.to_charlist(decoded), &forbidden_host_char?/1)) || {:error, :not_url} do
      case ipv4(decoded) do
        {:ok, nil} -> {:ok, decoded}
        {:ok, v4} -> {:ok, v4}
        e -> e
      end
    end
  end

  defp punycode_host(host) do
    cond do
      ascii?(host) ->
        {:ok, host}

      byte_size(host) > @max_idn_host ->
        {:error, :not_url}

      true ->
        labels =
          host
          |> String.split(".")
          |> Enum.map(fn label ->
            if ascii?(label) do
              label
            else
              case punycode(label) do
                nil -> throw(:not_url)
                p -> "xn--" <> p
              end
            end
          end)

        {:ok, Enum.join(labels, ".")}
    end
  catch
    :not_url -> {:error, :not_url}
  end

  defp ascii?(s), do: for(<<c <- s>>, reduce: true, do: (ok -> ok and c < 0x80))

  # An IPv6 address as the URL serializer writes it: groups in lowercase
  # hex, the first longest run of two or more zero groups as ::, and never
  # the dotted form.
  defp ipv6_text(addr) do
    groups = Tuple.to_list(addr)
    {start, length} = longest_zero_run(groups)

    groups
    |> Enum.with_index()
    |> Enum.reduce({[], false}, fn {g, i}, {out, in_run} ->
      cond do
        i == start -> {[if(i == 0, do: "::", else: ":") | out], true}
        in_run and i < start + length -> {out, true}
        true -> {[if(i < 7, do: ":", else: ""), Integer.to_string(g, 16) |> String.downcase() | out], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp longest_zero_run(groups) do
    {best, _} =
      groups
      |> Enum.with_index()
      |> Enum.reduce({{-1, 0}, nil}, fn
        {0, i}, {best, nil} -> {update(best, i, 1), {i, 1}}
        {0, _}, {best, {s, n}} -> {update(best, s, n + 1), {s, n + 1}}
        {_, _}, {best, _} -> {best, nil}
      end)

    best
  end

  defp update({_bs, bn} = best, s, n), do: if(n > bn and n > 1, do: {s, n}, else: best)

  defp hex_label?(<<?0, x, rest::binary>>) when x in [?x, ?X],
    do: for(<<c <- rest>>, reduce: true, do: (ok -> ok and (c in ?0..?9 or c in ?a..?f or c in ?A..?F)))

  defp hex_label?(_), do: false

  defp octal_label?(<<?0, rest::binary>>) when rest != "",
    do: for(<<c <- rest>>, reduce: true, do: (ok -> ok and c in ?0..?7))

  defp octal_label?(_), do: false

  # WHATWG's IPv4 parser, for a host whose last label is a number: 127.1 and
  # 0x7f.1 are 127.0.0.1. {:ok, nil} for a host that is a name.
  defp ipv4(host) do
    parts = String.split(host, ".")
    parts = if length(parts) > 1 and List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    last = List.last(parts)

    cond do
      not digits?(last) and not hex_label?(last) ->
        {:ok, nil}

      length(parts) > 4 ->
        {:error, :not_url}

      true ->
        numbers = Enum.map(parts, &ipv4_number/1)

        if Enum.any?(numbers, &(&1 == :error)) do
          {:error, :not_url}
        else
          {init, [last_n]} = Enum.split(numbers, -1)

          cond do
            Enum.any?(init, &(&1 > 255)) ->
              {:error, :not_url}

            last_n >= Integer.pow(256, 5 - length(numbers)) ->
              {:error, :not_url}

            true ->
              a =
                init
                |> Enum.with_index()
                |> Enum.reduce(last_n, fn {n, i}, acc -> acc + n * Integer.pow(256, 3 - i) end)

              {:ok, "#{a >>> 24}.#{a >>> 16 &&& 255}.#{a >>> 8 &&& 255}.#{a &&& 255}"}
          end
        end
    end
  end

  defp ipv4_number(""), do: :error

  defp ipv4_number(part) do
    cond do
      hex_label?(part) ->
        if part in ["0x", "0X"], do: 0, else: String.to_integer(binary_part(part, 2, byte_size(part) - 2), 16)

      octal_label?(part) ->
        String.to_integer(binary_part(part, 1, byte_size(part) - 1), 8)

      digits?(part) and (part == "0" or not String.starts_with?(part, "0")) ->
        String.to_integer(part)

      true ->
        :error
    end
  end

  # RFC 3492's encoding of one label, without the xn--.
  @base 36
  @t_min 1
  @t_max 26
  @skew 38
  @damp 700
  @max_int 2_147_483_647

  defp punycode(label) do
    runes = String.to_charlist(label)
    basic = for r <- runes, r < 0x80, do: r
    out = if basic == [], do: [], else: Enum.reverse([?- | Enum.reverse(basic)])
    encode(runes, length(basic), length(basic), 128, 0, 72, Enum.reverse(out))
  end

  defp encode(runes, basic, handled, n, delta, bias, out) do
    if handled >= length(runes) do
      out |> Enum.reverse() |> List.to_string()
    else
      m = runes |> Enum.filter(&(&1 >= n)) |> Enum.min(fn -> @max_int end)

      if (m - n) * (handled + 1) > @max_int - delta do
        nil
      else
        delta = delta + (m - n) * (handled + 1)
        n = m

        {delta, bias, handled, out} =
          Enum.reduce(runes, {delta, bias, handled, out}, fn r, {delta, bias, handled, out} ->
            delta = if r < n, do: delta + 1, else: delta

            if r == n do
              {q, out} = digits(delta, @base, bias, out)
              out = [digit(q) | out]
              bias = adapt(delta, handled + 1, handled == basic)
              {0, bias, handled + 1, out}
            else
              {delta, bias, handled, out}
            end
          end)

        encode(runes, basic, handled, n + 1, delta + 1, bias, out)
      end
    end
  end

  defp digits(q, k, bias, out) do
    t = (k - bias) |> max(@t_min) |> min(@t_max)

    if q < t do
      {q, out}
    else
      digits(div(q - t, @base - t), k + @base, bias, [digit(t + rem(q - t, @base - t)) | out])
    end
  end

  defp digit(d) when d < 26, do: ?a + d
  defp digit(d), do: ?0 + d - 26

  defp adapt(delta, points, first) do
    delta = if first, do: div(delta, @damp), else: div(delta, 2)
    delta = delta + div(delta, points)
    {delta, k} = shrink(delta, 0)
    k + div((@base - @t_min + 1) * delta, delta + @skew)
  end

  defp shrink(delta, k) when delta > div((@base - @t_min) * @t_max, 2),
    do: shrink(div(delta, @base - @t_min), k + @base)

  defp shrink(delta, k), do: {delta, k}

  @doc """
  The origin of a request's own URL: its scheme (https when it came over
  TLS) and `Host`, lowercased and without a default port.
  """
  @spec request_origin(boolean(), binary()) :: String.t()
  def request_origin(tls, host) do
    scheme = if tls, do: "https", else: "http"
    host = JS.scrub(host)
    bare("#{scheme}://#{host}") || "#{scheme}://#{String.downcase(host)}"
  end

  @doc """
  Whether an origin's host is loopback: `localhost`, a name ending in
  `.localhost`, an IPv4 address in 127.0.0.0/8, or the IPv6 address ::1.
  Only an origin that reads as one counts: a `Host` header is anyone's to
  send, and one such as `evil.example/.localhost` or
  `localhost:1@evil.example` must not put the development token in a link to
  another host.
  """
  @spec loopback?(String.t()) :: boolean()
  def loopback?(origin) do
    case bare(origin) do
      nil ->
        false

      origin ->
        authority = origin |> :binary.split("://") |> List.last()

        host =
          if String.starts_with?(authority, "[") do
            case :binary.match(authority, "]") do
              {e, _} -> binary_part(authority, 0, e + 1)
              :nomatch -> authority
            end
          else
            authority |> :binary.split(":") |> hd()
          end

        host = String.downcase(host)

        cond do
          host in ["localhost", "[::1]"] or String.ends_with?(host, ".localhost") ->
            true

          String.starts_with?(host, "127.") ->
            octets = host |> binary_part(4, byte_size(host) - 4) |> String.split(".")

            length(octets) == 3 and
              Enum.all?(octets, fn o -> byte_size(o) in 1..3 and digits?(o) and String.to_integer(o) <= 255 end)

          true ->
            false
        end
    end
  end
end
