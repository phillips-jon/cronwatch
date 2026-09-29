defmodule Cronwatch.Web.RequestPropertyTest do
  # The Rust port's `routes` fuzz target as a property: any request, in five
  # configurations of the dashboard, is answered without a raise (the plug
  # catches one and answers 500, which counts as a failure here) and without
  # an error reported. `CRONWATCH_PROPERTY_RUNS` asks for more.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Cronwatch.Test.Client

  alias Cronwatch.Web.Request
  alias Cronwatch.Web.Routes

  @moduletag :property

  @runs String.to_integer(System.get_env("CRONWATCH_PROPERTY_RUNS", "200"))

  defp piece do
    one_of([
      member_of(
        ~w(cronwatch api jobs runs check silence unsilence forget offline icons sw.js app.js nightly .. . %2e %zz %E9 %2F)
      ),
      string(:printable, max_length: 8),
      binary(max_length: 6)
    ])
  end

  defp request do
    gen all(
          method <- member_of(~w(GET HEAD POST DELETE PUT get)),
          segments <- list_of(piece(), max_length: 5),
          query <- one_of([constant(""), string(:printable, max_length: 20), constant("token=tok&runs=1e9&for=7d")]),
          headers <-
            list_of(
              tuple(
                {member_of(
                   ~w(authorization cookie origin sec-fetch-site content-type host referer x-forwarded-host x-forwarded-proto content-length)
                 ),
                 one_of([
                   member_of([
                     "Bearer tok",
                     "application/json",
                     "multipart/form-data; boundary=b",
                     "application/x-www-form-urlencoded",
                     "http://app.test",
                     "cronwatch_token=%",
                     "[::1]:3000",
                     "https"
                   ]),
                   binary(max_length: 16)
                 ])}
              ),
              max_length: 6
            ),
          body <- one_of([constant(nil), binary(max_length: 40), constant(~s({"for":"2h"})), constant("--b\r\n")])
        ) do
      %Request{
        method: method,
        path: "/" <> Enum.join(segments, "/"),
        query: query,
        headers: headers,
        body: fn _ -> {:ok, body || ""} end
      }
    end
  end

  property "any request is answered, never with a raise" do
    %{cw: cw, errors: errors} = make()
    Cronwatch.run("nightly", fn _ -> :ok end, instance: cw)

    configs =
      Enum.map(
        [
          [token: "tok", base_path: "/cronwatch"],
          [token: false],
          [token: "tok", origin: "https://app.example.com"],
          [token: "tok", trust_proxy: true, base_path: ""],
          [token: "tok", base_path: "/a/b/"]
        ],
        &Cronwatch.Web.init([instance: cw] ++ &1)
      )

    check all(req <- request(), opts <- member_of(configs), max_runs: @runs) do
      {status, headers, body} = Routes.handle(opts, req)
      assert status in [200, 303, 400, 401, 403, 404, 405, 413], "#{req.method} #{req.path}: #{status}"
      assert is_binary(body)
      assert Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end)
      assert wheres(errors) == [], inspect(messages(errors))
    end
  end
end
