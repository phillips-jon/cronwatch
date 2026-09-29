defmodule Cronwatch.Alerts.SigV4 do
  @moduledoc false
  # AWS Signature Version 4, for the SES channel (alerts/sigv4.ts), so no AWS
  # SDK is needed. Spec:
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
  # Checked against the AWS SigV4 test suite (test/alerts/sigv4_test.exs).

  alias Cronwatch.Alerts.Shared
  alias Cronwatch.JS

  @doc """
  The headers to send: the given ones (names lowercased) plus `x-amz-date`,
  the session token when there is one, and `authorization`. Host is signed
  but not returned, because the HTTP client sets it.

  `request` has `:method`, `:url`, `:headers` (a list of pairs), `:body`,
  `:region`, `:service` and `:now` (epoch milliseconds); `credentials` has
  `:access_key_id`, `:secret_access_key` and `:session_token` (`""` for
  none).
  """
  @spec sign(map(), map()) :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def sign(request, credentials) do
    case URI.new(request.url) do
      {:ok, %URI{host: host} = url} when is_binary(host) and host != "" ->
        {:ok, signed(request, credentials, url)}

      _ ->
        {:error, "cannot sign a request to an invalid URL"}
    end
  end

  defp signed(r, c, url) do
    iso = JS.iso_string(r.now)
    amz_date = (iso |> binary_part(0, 19) |> String.replace(["-", ":"], "")) <> "Z"
    day = binary_part(amz_date, 0, 8)

    headers =
      Enum.reduce(r.headers, [], fn {name, value}, acc -> assign(acc, String.downcase(name), value) end)
      |> assign("x-amz-date", amz_date)

    headers = if c.session_token != "", do: assign(headers, "x-amz-security-token", c.session_token), else: headers

    signing =
      headers
      |> Enum.reject(fn {n, _} -> n == "host" end)
      |> Kernel.++([{"host", host(url)}])
      |> Enum.sort_by(&elem(&1, 0))

    canonical_headers = Enum.map_join(signing, fn {n, v} -> "#{n}:#{collapse(JS.trim(v))}\n" end)
    signed_headers = Enum.map_join(signing, ";", &elem(&1, 0))

    canonical_request =
      Enum.join(
        [
          String.upcase(r.method),
          canonical_uri(url.path || ""),
          canonical_query(url.query || ""),
          canonical_headers,
          signed_headers,
          Shared.sha256_hex(r.body)
        ],
        "\n"
      )

    scope = "#{day}/#{r.region}/#{r.service}/aws4_request"
    string_to_sign = Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, Shared.sha256_hex(canonical_request)], "\n")

    key =
      Enum.reduce([day, r.region, r.service, "aws4_request"], "AWS4" <> c.secret_access_key, fn part, key ->
        Shared.hmac_sha256(key, part)
      end)

    signature = Shared.hex(Shared.hmac_sha256(key, string_to_sign))

    assign(
      headers,
      "authorization",
      "AWS4-HMAC-SHA256 Credential=#{c.access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
    )
  end

  # Sets a header, in its place when it is there already.
  defp assign(headers, name, value) do
    if List.keymember?(headers, name, 0),
      do: List.keyreplace(headers, name, 0, {name, value}),
      else: headers ++ [{name, value}]
  end

  @doc false
  # `URL#host`: the host, and the port when it is not the scheme's own.
  def host(%URI{host: h, port: port, scheme: scheme}) do
    if port == nil or port == URI.default_port(scheme || ""), do: h, else: "#{h}:#{port}"
  end

  # `.replace(/\s+/g, " ")` with JavaScript's `\s`.
  defp collapse(text) do
    {out, space} =
      for <<c::utf8 <- text>>, reduce: {[], false} do
        {out, space} ->
          cond do
            JS.space?(c) -> {out, true}
            space -> {[<<c::utf8>>, " " | out], false}
            true -> {[<<c::utf8>> | out], false}
          end
      end

    out = if space, do: [" " | out], else: out
    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # RFC 3986 encoding of every byte but the unreserved characters.
  defp uri_encode(text), do: Shared.percent(text, ~c"-_.~", false)

  # Each segment of the path, which is already encoded once, encoded again:
  # every AWS service but S3 expects that.
  defp canonical_uri(""), do: "/"
  defp canonical_uri(path), do: path |> String.split("/") |> Enum.map_join("/", &uri_encode/1)

  # The query as URLSearchParams reads it, each name and value encoded,
  # sorted by name and then value.
  defp canonical_query(""), do: ""

  defp canonical_query(query) do
    query
    |> String.split("&")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn pair ->
      {n, v} =
        case String.split(pair, "=", parts: 2) do
          [n, v] -> {n, v}
          [n] -> {n, ""}
        end

      {uri_encode(form_decode(n)), uri_encode(form_decode(v))}
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {n, v} -> "#{n}=#{v}" end)
  end

  # application/x-www-form-urlencoded decoding: `+` a space, `%XX` a byte,
  # anything else as it is.
  defp form_decode(text), do: text |> String.replace("+", " ") |> Cronwatch.Alerts.Post.percent_decode()
end
