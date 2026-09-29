defmodule Cronwatch.Alerts.PostTest do
  use ExUnit.Case, async: true

  alias Cronwatch.Alerts.Post
  alias Cronwatch.Alerts.Shared
  alias Cronwatch.Test.HTTPServer
  alias Cronwatch.Transport.Httpc

  test "URLs are read as fetch reads them" do
    ok = fn raw -> Post.postable(raw) |> elem(1) end
    assert ok.("https://Hooks.Example.COM/a b?x=1 2#f g") == "https://hooks.example.com/a%20b?x=1%202#f%20g"
    assert ok.("  https://h.example:443/p\n") == "https://h.example/p"
    assert ok.("http://h.example:0080") == "http://h.example/"
    assert ok.("https:\\\\h.example\\a\\..\\b/./c/%2e%2E/d") == "https://h.example/b/d"
    assert ok.("http://0x7f.1:8080/x") == "http://127.0.0.1:8080/x"
    assert ok.("http://[0:0:0:0:0:0:0:1]/") == "http://[::1]/"
    assert ok.("https://h.example/é?é") == "https://h.example/%C3%A9?%C3%A9"
    assert ok.("https://@h.example/") == "https://h.example/"

    refused = fn raw -> raw |> Post.postable() |> elem(1) |> Exception.message() end
    assert refused.("javascript:alert(1)") == "only http and https URLs can be posted to, not javascript:"
    assert refused.("FTP://h.example/") == "only http and https URLs can be posted to, not ftp:"
    assert refused.("h.example/x") == "only http and https URLs can be posted to, not this URL"
    assert refused.("https://user:pw@h.example/") == "only http and https URLs can be posted to, not this URL"
    assert refused.("https://h.example:99999/") == "only http and https URLs can be posted to, not this URL"
    assert refused.("https:///") == "only http and https URLs can be posted to, not this URL"
    assert refused.("https://a b/") == "only http and https URLs can be posted to, not this URL"
    assert refused.(nil) == "only http and https URLs can be posted to, not this URL"

    assert Post.origin("https://h.example:8443/secret?k=1") == "https://h.example:8443"
    assert Post.origin("mailto:x@y") == "null"
    assert Post.origin("no") == "(invalid URL)"
  end

  test "headers are checked as fetch checks them, naming the header and never its value" do
    assert Post.headers([{"a", " v \n"}, {"x-b", "c"}]) == {:ok, [{"a", "v"}, {"x-b", "c"}]}
    {:error, e} = Post.headers([{"authorization", "Bearer x\r\ninjected: 1"}])
    assert Exception.message(e) == "the authorization header's value may not contain a line break"
    {:error, e} = Post.headers([{"bad name", "v"}])
    assert Exception.message(e) =~ "a header name must be a token"
  end

  test "error bodies have secrets cut before the cut" do
    secret = "abcdefgh"
    body = String.duplicate("x", 196) <> secret <> "tail"
    assert Post.error_body(body, [secret]) == String.duplicate("x", 196) <> "[red"
    assert Post.error_body("key abc", ["abc"]) == "key abc"
    assert Post.cut("a😀b", 2) == "a"
  end

  test "encodings are the SDK's" do
    assert Shared.base64("api:é") == "YXBpOsOp"
    assert Shared.encode_uri_component("a b/c?d=é!'()*~") == "a%20b%2Fc%3Fd%3D%C3%A9!'()*~"
    assert Shared.form([{"To", "+1 555"}, {"Body", "a&b=c*~"}]) == "To=%2B1+555&Body=a%26b%3Dc*%7E"
    assert Shared.as_uuid("0123456789abcdef0123456789abcdef") == "01234567-89ab-cdef-0123-456789abcdef"

    assert Shared.hex(Shared.hmac_sha256("key", "The quick brown fox jumps over the lazy dog")) ==
             "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
  end

  test "a request through :httpc reaches a real server with the body and headers given" do
    server = HTTPServer.start(fn _ -> {200, [], "fine"} end)
    headers = [{"content-type", "application/json"}, {"authorization", "Bearer t"}]
    assert {:ok, %{status: 200, body: "fine"}} = Post.fetch(nil, 5000, server.url <> "/in", headers, ~s({"a":1}))
    [req] = HTTPServer.requests(server)
    assert req.method == "POST"
    assert req.target == "/in"
    assert req.body == ~s({"a":1})
    assert {"authorization", "Bearer t"} in req.headers
    assert {"content-type", "application/json"} in req.headers
    refute List.keymember?(req.headers, "accept-encoding", 0)
  end

  test "the TLS options verify the peer against the system's roots" do
    opts = Httpc.ssl("https://h.example/x", [])
    assert opts[:verify] == :verify_peer
    assert opts[:server_name_indication] == ~c"h.example"
    assert Httpc.ssl("https://127.0.0.1/", [])[:server_name_indication] == :disable
  end
end
