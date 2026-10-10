defmodule Cronwatch.Web.RoutesTest do
  @moduledoc """
  The SDK's routes tests (routes.test.ts, routes-security.test.ts,
  routes-origin.test.ts, routes-pwa.test.ts in part), as the Go and Rust
  ports have them, with their audits' cases. The tests that need an
  environment of their own (development, a missing token) are in
  env_test.exs, and those that go through a real server in server_test.exs.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Cronwatch.Test.More
  import Cronwatch.Test.Web, only: [header: 2, json: 1, field: 2, token_cookie: 0]

  alias Cronwatch.JS
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Flaky
  alias Cronwatch.Test.Stores
  alias Cronwatch.Test.Wrap
  alias Cronwatch.Web.Origin
  alias Cronwatch.Web.Request
  alias Cronwatch.Web.Routes

  @t0 Clock.t0()
  @min 60_000
  @hour 3_600_000

  @auth {"authorization", "Bearer tok"}
  @form {"content-type", "application/x-www-form-urlencoded"}
  @json {"content-type", "application/json"}

  defp web(opts \\ [], make_opts \\ []) do
    k = make(make_opts)
    Map.put(k, :opts, Keyword.merge([instance: k.cw, token: "tok", base_path: "/cronwatch"], opts))
  end

  defp req(w, method, path, headers \\ [], body \\ nil),
    do: Cronwatch.Test.Web.send(w.opts, method, "http://app.test" <> path, headers, body)

  defp get(w, path, headers \\ []), do: req(w, "GET", path, headers)

  defp ok(w, name), do: Cronwatch.run(name, fn _ -> :ok end, instance: w.cw)
  defp summary(w, name), do: Cronwatch.job_summary!(name, instance: w.cw)

  test "everything needs the token" do
    w = web()
    assert get(w, "/cronwatch").status == 401
    assert get(w, "/cronwatch/api/jobs").status == 401
    assert get(w, "/cronwatch/api/jobs", [{"authorization", "Bearer wrong"}]).status == 401
    assert get(w, "/cronwatch/api/jobs", [@auth]).status == 200
    assert get(w, "/cronwatch/api/jobs", [{"authorization", "bEaReR \t tok"}]).status == 200, "any case and spaces"
    assert Cronwatch.Web.token(w.opts) == "tok"
  end

  test "a token or secret given in code that is not a string, nil, or false is refused" do
    %{cw: cw} = make()

    for bad <- [true, 5, 1.5, :sym, ~c"tok", %{}, {:system, :not_a_name}] do
      e = assert_raise ArgumentError, fn -> Cronwatch.Web.init(instance: cw, token: bad) end
      assert e.message =~ "token must be a string", inspect(bad)
      assert e.message =~ "false to", inspect(bad)
      refute e.message =~ "tok\"", "the value is not printed"

      e =
        assert_raise ArgumentError, fn ->
          Cronwatch.Handler.init(instance: cw, job: "j", run: {Cronwatch.Test.Handlers, :count, [self()]}, secret: bad)
        end

      assert e.message =~ "secret must be a string", inspect(bad)
      assert e.message =~ "false to opt out", inspect(bad)

      assert {:error, %Cronwatch.Error{message: message}} = Cronwatch.Config.new(cron_secret: bad)
      assert message =~ "cron_secret must be a string, or false to opt out", inspect(bad)
    end

    # nil (left out), false (the opt-out), and a string are taken.
    for good <- [nil, false, "s", {:system, "VAR"}] do
      assert %Cronwatch.Web{} = Cronwatch.Web.init(instance: cw, token: good)
    end

    for good <- [nil, false, "s"], do: assert({:ok, _} = Cronwatch.Config.new(cron_secret: good))
  end

  test "an Authorization header that is not a bearer leaves the cookie and ?token= to sign in" do
    w = web()
    cookie = {"cookie", token_cookie()}
    basic = {"authorization", "Basic dXNlcjpwYXNz"}
    assert get(w, "/cronwatch/api/jobs", [basic, cookie]).status == 200
    assert get(w, "/cronwatch/api/jobs", [basic]).status == 401
    assert get(w, "/cronwatch/api/check", [basic, cookie]).status == 405, "a GET check still needs a bearer"
    assert get(w, "/cronwatch/?token=tok", [basic]).status == 303

    for header <- ["Token tok", "Bearertok", "Bearer", "tok"] do
      assert get(w, "/cronwatch/api/jobs", [{"authorization", header}, cookie]).status == 200, header
      assert get(w, "/cronwatch/api/jobs", [{"authorization", header}]).status == 401, header
    end

    assert get(w, "/cronwatch/api/jobs", [{"authorization", "bearer tok"}]).status == 200
    assert get(w, "/cronwatch/api/jobs", [{"authorization", "Bearer wrong"}, cookie]).status == 401, "a bearer wins"
  end

  test "the sign-in form posts the token to <base>/signin" do
    w = web()
    res = get(w, "/cronwatch/")
    assert res.status == 401
    assert res.body =~ ~s(<form class="signin" method="post" action="/cronwatch/signin">)
    assert res.body =~ "Enter your CRONWATCH_TOKEN and this browser stays signed in."

    signed =
      req(w, "POST", "/cronwatch/signin", [@form, {"referer", "http://app.test/cronwatch/jobs/x?a=1"}], "token=tok")

    assert signed.status == 303
    assert header(signed, "location") == "http://app.test/cronwatch/jobs/x?a=1"
    assert hd(String.split(header(signed, "set-cookie"), ";")) == token_cookie()

    for referer <- [
          "http://app.test/cronwatch/?token=",
          "http://app.test/cronwatch/?a=1&%74oken=x",
          "http://app.test.evil/cronwatch/",
          "http://app.test"
        ] do
      res = req(w, "POST", "/cronwatch/signin", [@form, {"referer", referer}], "token=tok")
      assert header(res, "location") == "/cronwatch/", referer
    end

    assert req(w, "POST", "/cronwatch/signin/", [@form], "token=tok").status == 303, "a trailing slash"
    wrong = req(w, "POST", "/cronwatch/signin", [@form], "token=tok2")
    assert {wrong.status, header(wrong, "set-cookie")} == {401, nil}
    assert req(w, "POST", "/cronwatch/signin", [@json], ~s({"token":"tok"})).status == 303

    # Over https the cookie is Secure.
    secure = Cronwatch.Test.Web.send(w.opts, "POST", "https://app.test/cronwatch/signin", [@form], "token=tok")
    assert header(secure, "set-cookie") =~ "; Secure"

    # With the routes open, /signin is any other path.
    open = %{w | opts: Keyword.put(w.opts, :token, false)}
    assert req(open, "POST", "/cronwatch/signin", [@form], "token=tok").status == 404
  end

  test "check accepts the cron secret and nothing else does" do
    secret = "cron-" <> "s3cret"
    w = web([], cron_secret: secret)
    bearer = {"authorization", "Bearer " <> secret}
    assert get(w, "/cronwatch/api/check", [bearer]).status == 200
    assert get(w, "/cronwatch/api/jobs", [bearer]).status == 401
    assert get(w, "/cronwatch/api/check?token=#{secret}").status == 401, "only as a bearer"
  end

  test "GET /api names the library, the language, and the versions" do
    secret = "cron-" <> "s3cret"
    w = web([], cron_secret: secret)
    want = ~s({"ok":true,"library":"cronwatch","language":"elixir","version":"#{Cronwatch.version()}","api":1})

    for path <- ["/cronwatch/api", "/cronwatch/api/"] do
      res = get(w, path, [@auth])
      assert res.status == 200, path
      assert res.body == want, path
      assert header(res, "content-type") =~ "application/json", path
    end

    assert get(w, "/cronwatch/api").status == 401
    assert get(w, "/cronwatch/api", [{"authorization", "Bearer " <> secret}]).status == 401, "the cron secret"
    res = req(w, "POST", "/cronwatch/api", [@auth])
    assert {res.status, res.body} == {404, ~s({"ok":false,"error":"Not found"})}
  end

  test "sign-in sets a cookie and redirects to a clean URL" do
    w = web()
    cookie = token_cookie()
    res = get(w, "/cronwatch/?token=tok")
    assert res.status == 303
    assert header(res, "location") == "/cronwatch/"
    set = header(res, "set-cookie")
    assert hd(String.split(set, ";")) == cookie, "a digest, not the token"
    assert set =~ "; Path=/cronwatch; HttpOnly; SameSite=Lax; Max-Age=2592000"
    page = get(w, "/cronwatch/", [{"cookie", "other=1; " <> cookie}])
    assert page.status == 200
    assert header(page, "content-type") =~ "text/html"
    assert get(w, "/cronwatch/", [{"cookie", "cronwatch_token=tok"}]).status == 401, "the raw token is not a cookie"
    # HTTP/2 may send each cookie as a header of its own.
    assert get(w, "/cronwatch/", [{"cookie", "other=1"}, {"cookie", cookie}]).status == 200, "split cookies"
    other = get(w, "/cronwatch/jobs/x?view=all&token=tok&a=b+c")
    assert header(other, "location") == "/cronwatch/jobs/x?view=all&a=b+c", "the rest of the query is kept"
  end

  test "pages render and the API answers" do
    w = web()
    job = Cronwatch.job!("nightly-report", schedule: "0 2 * * *", description: "Builds the PDF", instance: w.cw)

    Cronwatch.run(job, fn j ->
      Cronwatch.log(j, "built")
      Clock.advance(w.clock, 2000)
      :ok
    end)

    Cronwatch.run("broken", fn _ -> {:error, "kaboom <script>"} end, instance: w.cw)

    dash = get(w, "/cronwatch", [@auth]).body

    for want <- [
          "nightly-report",
          "Builds the PDF",
          "healthy",
          "failing",
          ~s(<p class="headline">2 jobs, <b>1 needing attention</b>.</p>),
          ~s(<div class="bad"><dt><i class="sq bad" aria-hidden="true"></i>failing</dt><dd>1</dd></div>),
          ~s(<figure class="timeline day">),
          ~s(<table class="board">),
          ~s(<form class="inline" method="post" action="/cronwatch/check"><button class="primary" type="submit">Run check now</button></form>)
        ] do
      assert dash =~ want
    end

    page = get(w, "/cronwatch/jobs/broken", [@auth])
    assert page.status == 200
    assert page.body =~ "kaboom &lt;script&gt;"
    refute page.body =~ "<script>", "an unescaped <script>"
    assert page.body =~ ~s(<h1 class="jobname">broken</h1>)
    assert page.body =~ ~s(<figure class="timeline week">)
    assert page.body =~ ~s(<details class="out error" open><summary>error</summary><pre>kaboom &lt;script&gt;)

    list = json(get(w, "/cronwatch/api/jobs", [@auth]))
    assert length(field(list, ["jobs"])) == 2
    one = json(get(w, "/cronwatch/api/jobs/nightly-report?runs=5", [@auth]))
    assert field(one, ["job", "health"]) == "healthy"
    [run] = field(one, ["runs"])
    assert field(run, ["output"]) == "built"
    assert get(w, "/cronwatch/api/jobs/missing", [@auth]).status == 404
    assert get(w, "/cronwatch/jobs/missing", [@auth]).status == 404
    assert get(w, "/cronwatch/nope", [@auth]).status == 404
    got = json(get(w, "/cronwatch/api/runs/#{field(run, ["id"])}", [@auth]))
    assert field(got, ["run", "job"]) == "nightly-report"
  end

  test "names break after their separators, only as text" do
    w = web()
    name = "wp:store_sync.inventory--eu"
    ok(w, name)
    shown = "wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu"
    href = "/cronwatch/jobs/wp%3Astore_sync.inventory--eu"
    dash = get(w, "/cronwatch", [@auth]).body
    assert dash =~ ~s(<a class="name" href="#{href}">#{shown}</a><span class="sched">), "the lane"
    assert dash =~ ~s(<td class="job"><a class="name" href="#{href}">#{shown}</a></td>), "the board"
    assert dash =~ "<li>wp:store_sync.inventory--eu (", "the words"
    page = get(w, href, [@auth]).body
    assert page =~ ~s(<span class="crumb">#{shown}</span>)
    assert page =~ ~s(<h1 class="jobname">#{shown}</h1>)
    assert page =~ "<title>wp:store_sync.inventory--eu: CronWatch</title>"
    assert page =~ "<title>wp:store_sync.inventory--eu, "
    assert length(String.split(page, "<wbr>")) - 1 == 8, "only in the crumb and the heading"
  end

  test "API writes" do
    w = web()
    ok(w, "s")
    post = fn path, body -> req(w, "POST", path, [@auth, @json], body) end
    result = json(post.("/cronwatch/api/check", ""))
    assert field(result, ["ok"]) == true
    assert length(field(result, ["jobs"])) == 1
    silenced = json(post.("/cronwatch/api/jobs/s/silence", ~s({"for":"2h"})))
    assert field(silenced, ["job", "silencedUntil"]) == @t0 + 2 * @hour
    assert field(silenced, ["job", "health"]) == "silenced", "the summary after the silence"
    assert Enum.map(silenced.pairs, &elem(&1, 0)) == ["ok", "job"]
    assert summary(w, "s").health == "silenced"
    un = json(post.("/cronwatch/api/jobs/s/unsilence", ""))
    assert field(un, ["job", "silencedUntil"]) == nil
    assert post.("/cronwatch/api/jobs/nope/silence", ~s({"for":"1h"})).status == 404
    assert req(w, "DELETE", "/cronwatch/api/jobs/s", [@auth]).status == 200
    assert summary(w, "s") == nil, "the job was not forgotten"
    assert req(w, "DELETE", "/cronwatch/api/jobs/s", [@auth]).status == 404
  end

  test "forms post and redirect back" do
    w = web()
    ok(w, "f")

    res =
      req(
        w,
        "POST",
        "/cronwatch/jobs/f/silence",
        [@auth, @form, {"referer", "http://app.test/cronwatch/jobs/f"}],
        "for=4h"
      )

    assert res.status == 303
    assert header(res, "location") == "http://app.test/cronwatch/jobs/f"
    assert summary(w, "f").health == "silenced"
    elsewhere = req(w, "POST", "/cronwatch/jobs/f/unsilence", [@auth, {"referer", "https://evil.example/phish"}])
    assert header(elsewhere, "location") == "/cronwatch/", "a foreign referer is not followed"
    multipart = "--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n--b--\r\n"

    res =
      req(
        w,
        "POST",
        "/cronwatch/jobs/f/silence",
        [@auth, {"content-type", "multipart/form-data; boundary=b"}],
        multipart
      )

    assert res.status == 303
    assert summary(w, "f").silenced_until == @t0 + 2 * @hour, "silenced for two hours"
    assert req(w, "POST", "/cronwatch/jobs/f/forget", [@auth]).status == 303
    assert summary(w, "f") == nil, "the job was not forgotten"
  end

  test "cross-site writes are refused" do
    w = web()
    ok(w, "x")
    cookie = {"cookie", token_cookie()}

    for headers <- [
          [{"origin", "https://evil.example"}],
          [{"origin", "null"}],
          [{"sec-fetch-site", "cross-site"}],
          [{"sec-fetch-site", "same-site"}],
          [{"origin", "http://app.test"}, {"sec-fetch-site", "cross-site"}]
        ] do
      assert req(w, "POST", "/cronwatch/jobs/x/silence", [cookie, @form | headers], "for=1h").status == 403
      assert req(w, "POST", "/cronwatch/api/check", [@auth | headers]).status == 403
      assert req(w, "DELETE", "/cronwatch/api/jobs/x", [cookie | headers]).status == 403
    end

    assert summary(w, "x").silenced_until == nil, "a cross-site write went through"

    same = [
      {"origin", "http://app.test"},
      {"sec-fetch-site", "same-origin"},
      {"referer", "http://app.test/cronwatch/jobs/x"}
    ]

    assert req(w, "POST", "/cronwatch/check", [cookie | same]).status == 303, "run check now"
    assert req(w, "POST", "/cronwatch/api/jobs/x/unsilence", [@auth]).status == 200, "an API client"
    assert req(w, "POST", "/cronwatch/api/check", [@auth, {"sec-fetch-site", "none"}]).status == 200
    refused = req(w, "POST", "/cronwatch/api/check", [@auth, {"origin", "https://evil.example"}])
    assert refused.body == ~s({"ok":false,"error":"Cross-site request refused"})
  end

  test "a GET of the check needs a bearer, and query tokens only sign in" do
    w = web()
    ok(w, "x")
    cookie = {"cookie", token_cookie()}
    via_cookie = get(w, "/cronwatch/api/check", [cookie])
    assert via_cookie.status == 405
    assert header(via_cookie, "allow") == "POST"
    assert req(w, "POST", "/cronwatch/api/check", [cookie]).status == 200
    assert get(w, "/cronwatch/api/check", [@auth]).status == 200
    assert get(w, "/cronwatch/api/jobs?token=tok").status == 401
    assert get(w, "/cronwatch/api/jobs/x?token=tok").status == 401
    assert req(w, "POST", "/cronwatch/api/check?token=tok").status == 401
    assert req(w, "POST", "/cronwatch/check?token=tok").status == 401
    assert req(w, "POST", "/cronwatch/jobs/x/forget?token=tok").status == 401
    assert summary(w, "x") != nil, "forgotten by a query token"
    assert get(w, "/cronwatch/jobs/x?token=tok").status == 303
  end

  test "malformed cookies and paths are answered" do
    w = web()
    assert get(w, "/cronwatch/", [{"cookie", "cronwatch_token=%E0%A4%A"}]).status == 401
    assert get(w, "/cronwatch/api/jobs", [{"cookie", "cronwatch_token=%"}]).status == 401
    assert get(w, "/cronwatch/jobs/%E0%A4%A", [@auth]).status == 400
    api = get(w, "/cronwatch/api/jobs/%zz", [@auth])
    assert api.status == 400
    assert field(json(api), ["ok"]) == false
    assert req(w, "POST", "/cronwatch/api/jobs/%zz/silence", [@auth]).status == 400
    assert get(w, "/cronwatch/jobs/%E9", [@auth]).status == 400, "not UTF-8"
  end

  test "runs is clamped" do
    w = web()
    for _ <- 1..3, do: ok(w, "r")

    for {value, want} <- [
          {"0", 1},
          {"-5", 1},
          {"2.7", 2},
          {"abc", 3},
          {"", 3},
          {"1e9", 3},
          {"Infinity", 3},
          {"0x2", 2},
          {"%202%20", 2}
        ] do
      res = json(get(w, "/cronwatch/api/jobs/r?runs=#{value}", [@auth]))
      assert length(field(res, ["runs"])) == want, "runs=#{value}"
    end
  end

  test "an unexpected error is a generic 500, reported as routes" do
    {store, broken} = Flaky.new(Wrap.memory(shared_memory()))
    w = web([], store: store)
    Flaky.break(broken, :list_jobs)
    api = get(w, "/cronwatch/api/jobs", [@auth])
    assert api.status == 500
    assert api.body == ~s({"ok":false,"error":"Internal error"})
    page = get(w, "/cronwatch/", [@auth])
    assert page.status == 500
    assert header(page, "content-type") =~ "text/html"
    refute page.body =~ "store down", "the error reached the page"
    assert wheres(w.errors) == ["routes", "routes"]
    assert Enum.all?(messages(w.errors), &(&1 =~ "store down: list_jobs"))

    throwing = web([], store: store, on_error: fn _, _ -> raise "logger down" end)
    assert get(throwing, "/cronwatch/api/jobs", [@auth]).status == 500, "an error handler that raises"
  end

  test "a store that raises is a generic 500, reported as routes" do
    {store, hooks} = Stores.hooked(Wrap.memory(shared_memory()))
    Stores.hook(hooks, :list_jobs, fn _args, _call -> raise "the store fell over" end)
    w = web([], store: store)
    assert get(w, "/cronwatch/api/jobs", [@auth]).status == 500
    assert wheres(w.errors) == ["routes"]
    assert messages(w.errors) |> hd() =~ "the store fell over"
  end

  test "a body nested deeply is read as none, not a crash" do
    w = web()
    ok(w, "s")
    body = String.duplicate("[", 100_000) <> String.duplicate("]", 100_000)
    assert req(w, "POST", "/cronwatch/api/jobs/s/silence", [@auth, @json], body).status == 200
  end

  test "silence durations" do
    w = web()
    ok(w, "s")
    silence = fn body -> req(w, "POST", "/cronwatch/api/jobs/s/silence", [@auth, @json], body) end

    for bad <- [~s("forever"), ~s("2 hours"), ~s(""), ~s("-5"), ~s("1h then some"), "true"] do
      res = silence.(~s({"for":#{bad}}))
      assert res.status == 400, bad
      assert field(json(res), ["error"]) =~ "silence duration"
    end

    assert summary(w, "s").silenced_until == nil, "a bad duration silenced the job"
    until = fn body -> field(json(silence.(body)), ["job", "silencedUntil"]) - @t0 end
    assert until.(~s({"for":7200000})) == 7_200_000, "a number"
    assert until.(~s({"for":"60000"})) == 60_000, "a numeric string"
    assert until.(~s({"for":"90m"})) == 90 * @min, "text"
    assert until.("{}") == @hour, "absent"
    assert until.(~s(\uFEFF{"for":"2h"})) == 2 * @hour, "a byte order mark"
    assert req(w, "POST", "/cronwatch/api/jobs/s/silence?for=forever", [@auth]).status == 400
    query = json(req(w, "POST", "/cronwatch/api/jobs/s/silence?for=3h", [@auth]))
    assert field(query, ["job", "silencedUntil"]) == @t0 + 3 * @hour, "the query when the body has none"
    # The SDK's 64 character cap, quoting the first 32.
    long = json(silence.(~s({"for":"#{String.duplicate("1", 65)}m"})))
    assert field(long, ["error"]) =~ "silence duration"
    assert field(long, ["error"]) =~ String.duplicate("1", 32)
    refute field(long, ["error"]) =~ String.duplicate("1", 33)
  end

  test "a request that ended before its answer is not reported" do
    {store, hooks} = Stores.hooked(Wrap.memory(shared_memory()))
    test = self()

    Stores.hook(hooks, :list_jobs, fn _args, _call ->
      send(test, :waiting)
      Process.sleep(:infinity)
    end)

    w = web([], store: store)
    request = spawn(fn -> get(w, "/cronwatch/api/jobs", [@auth]) end)
    assert_receive :waiting
    ref = Process.monitor(request)
    Process.exit(request, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    Stores.unhook(hooks, :list_jobs)
    assert get(w, "/cronwatch/api/jobs", [@auth]).status == 200, "a request still open"
    assert wheres(w.errors) == []
  end

  test "a body cut short is read as none, not as the part that arrived" do
    w = web()
    ok(w, "s")
    opts = Cronwatch.Web.init(w.opts)

    request = %Request{
      method: "POST",
      path: "/cronwatch/api/jobs/s/silence",
      headers: [{"host", "app.test"}, @auth, @form],
      body: fn _limit -> {:error, "the client went away after for=7"} end
    }

    {200, _, _} = Routes.handle(opts, request)
    assert summary(w, "s").silenced_until == @t0 + @hour, "the default hour"
  end

  test "the silence form shows an error" do
    w = web()
    ok(w, "s")
    f = [{"cookie", token_cookie()}, @form]
    bad = req(w, "POST", "/cronwatch/jobs/s/silence", f, "for=forever")
    assert bad.status == 400
    assert header(bad, "content-type") =~ "text/html"
    assert bad.body =~ "silence duration &quot;forever&quot;"
    assert req(w, "POST", "/cronwatch/jobs/ghost/silence", f, "for=1h").status == 404
    assert req(w, "POST", "/cronwatch/jobs/ghost/unsilence", f).status == 404
    assert req(w, "POST", "/cronwatch/jobs/s/explode", f).status == 404
  end

  test "a body past the cap is 413, and a body is not read without the token" do
    w = web()
    ok(w, "s")
    big = ~s({"for":"2h","pad":"#{String.duplicate("x", Routes.max_body())}"})
    api = req(w, "POST", "/cronwatch/api/jobs/s/silence", [@auth, @json], big)
    assert api.status == 413
    assert api.body == ~s({"ok":false,"error":"Request body too large"})

    page =
      req(
        w,
        "POST",
        "/cronwatch/jobs/s/silence",
        [@auth, @form],
        "for=2h&pad=" <> String.duplicate("x", Routes.max_body())
      )

    assert page.status == 413
    assert page.body =~ "The request was too large."
    # By its Content-Length alone.
    long =
      req(w, "POST", "/cronwatch/api/jobs/s/silence", [@auth, @json, {"content-length", "2000000"}], ~s({"for":"2h"}))

    assert long.status == 413
    assert summary(w, "s").silenced_until == nil, "a body past the cap silenced the job"

    test = self()
    opts = Cronwatch.Web.init(w.opts)

    request = %Request{
      method: "POST",
      path: "/cronwatch/api/jobs/s/silence",
      headers: [{"host", "app.test"}, @json],
      body: fn _ ->
        send(test, :read)
        {:ok, ""}
      end
    }

    assert {401, _, _} = Routes.handle(opts, request)
    refute_received :read, "a body was read without the token"
  end

  test "a body a Phoenix endpoint's parsers already read is taken from its fields" do
    w = web()
    ok(w, "s")

    conn =
      Plug.Test.conn("POST", "/cronwatch/api/jobs/s/silence", "")
      |> Map.put(:host, "app.test")
      |> Map.put(:req_headers, [@auth, @json])
      |> Map.put(:body_params, %{"for" => "2h"})

    conn = Cronwatch.Web.call(conn, Cronwatch.Web.init(w.opts))
    assert conn.status == 200
    assert summary(w, "s").silenced_until == @t0 + 2 * @hour

    for {params, want} <- [
          {%{"for" => 7_200_000}, 7_200_000},
          {%{"for" => "90m"}, 90 * @min},
          {%{"other" => "x"}, @hour}
        ] do
      conn =
        Plug.Test.conn("POST", "/cronwatch/api/jobs/s/silence", "")
        |> Map.merge(%{host: "app.test", req_headers: [@auth, @json], body_params: params})
        |> Cronwatch.Web.call(Cronwatch.Web.init(w.opts))

      assert field(JS.parse!(conn.resp_body), ["job", "silencedUntil"]) == @t0 + want, inspect(params)
    end
  end

  test "security headers, and Plug's own cache-control replaced" do
    w = web()
    ok(w, "h")

    for path <- ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope"] do
      res = get(w, path, [@auth])

      assert header(res, "content-security-policy") ==
               "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"

      assert header(res, "x-frame-options") == "DENY"
      assert header(res, "x-content-type-options") == "nosniff"
      assert header(res, "referrer-policy") == "same-origin"
      assert for({"cache-control", v} <- res.headers, do: v) == ["no-store"]

      assert Regex.scan(~r/<script[^>]*>[^<]*<\/script>/, res.body) == [
               [~s(<script src="/cronwatch/app.js" defer></script>)]
             ]
    end

    api = get(w, "/cronwatch/api/jobs", [@auth])
    assert header(api, "x-content-type-options") == "nosniff"
    assert header(api, "cache-control") == "no-store"
    # A redirect without the SDK's cache-control has none of Plug's either.
    signed = get(w, "/cronwatch/?token=tok")
    assert for({"cache-control", v} <- signed.headers, do: v) == ["no-store"]
  end

  test "markup stays escaped" do
    w = web()

    job =
      Cronwatch.job!("m",
        schedule: "0 2 * * *",
        description: "<img src=x>",
        tags: ["<t>"],
        expect: "<e>",
        instance: w.cw
      )

    Cronwatch.run(job, fn j ->
      Cronwatch.log(j, "<o>")
      Cronwatch.metric(j, "<k>", 1)
      :ok
    end)

    for path <- ["/cronwatch/", "/cronwatch/jobs/m", "/cronwatch/jobs/%3Cx%3E"] do
      text = get(w, path, [@auth]).body

      for bad <- ["<img", "<t>", "<e>", "<o>", "<k>", "<x>"] do
        refute text =~ bad, "#{path}: #{bad} unescaped"
      end
    end
  end

  test "origins" do
    internal = "http://10.0.0.5:8080"
    cookie = {"cookie", token_cookie()}

    app = fn opts ->
      w = web(opts)
      ok(w, "x")
      w
    end

    send = fn w, method, path, headers, body ->
      Cronwatch.Test.Web.send(w.opts, method, internal <> path, headers ++ [cookie], body)
    end

    # The request's own origin by default.
    w = app.([])

    assert send.(w, "POST", "/cronwatch/jobs/x/silence", [@form, {"origin", "https://app.example.com"}], "for=1h").status ==
             403

    assert summary(w, "x").silenced_until == nil
    assert send.(w, "POST", "/cronwatch/jobs/x/silence", [@form, {"origin", internal}], "for=1h").status == 303
    refute header(send.(w, "GET", "/cronwatch/?token=tok", [], nil), "set-cookie") =~ "Secure", "Secure over http"

    # The origin option replaces it.
    w = app.(origin: "https://app.example.com/ignored/path")
    assert send.(w, "POST", "/cronwatch/jobs/x/silence", [@form, {"origin", internal}], "for=1h").status == 403
    assert summary(w, "x").silenced_until == nil
    referer = "https://app.example.com/cronwatch/jobs/x"

    res =
      send.(
        w,
        "POST",
        "/cronwatch/jobs/x/silence",
        [@form, {"origin", "https://app.example.com"}, {"referer", referer}],
        "for=2h"
      )

    assert res.status == 303
    assert header(res, "location") == referer
    assert summary(w, "x").silenced_until == @t0 + 2 * @hour
    sign_in = send.(w, "GET", "/cronwatch/jobs/x?token=tok", [], nil)
    assert header(sign_in, "location") == "/cronwatch/jobs/x"
    assert String.ends_with?(header(sign_in, "set-cookie"), "; Secure"), "not Secure over https"

    # The origin option wins over trust_proxy.
    w = app.(origin: "https://app.example.com", trust_proxy: true)
    fwd = [{"x-forwarded-proto", "https"}, {"x-forwarded-host", "other.example"}]
    assert send.(w, "POST", "/cronwatch/check", fwd ++ [{"origin", "https://other.example"}], nil).status == 403
    assert send.(w, "POST", "/cronwatch/check", fwd ++ [{"origin", "https://app.example.com"}], nil).status == 303

    # trust_proxy takes the first forwarded values.
    w = app.(trust_proxy: true)
    fwd = [{"x-forwarded-proto", "https, http"}, {"x-forwarded-host", "app.example.com, 10.0.0.5:8080"}]
    assert send.(w, "POST", "/cronwatch/jobs/x/silence", fwd ++ [@form, {"origin", internal}], "for=1h").status == 403

    assert send.(
             w,
             "POST",
             "/cronwatch/jobs/x/silence",
             fwd ++ [@form, {"origin", "https://app.example.com"}],
             "for=1h"
           ).status ==
             303

    assert String.ends_with?(header(send.(w, "GET", "/cronwatch/?token=tok", fwd, nil), "set-cookie"), "; Secure")

    assert send.(
             w,
             "POST",
             "/cronwatch/check",
             [{"x-forwarded-proto", "https"}, {"origin", "https://10.0.0.5:8080"}],
             nil
           ).status ==
             303,
           "proto only"

    assert send.(w, "POST", "/cronwatch/check", [{"origin", internal}], nil).status == 303, "neither"

    for {headers, origin} <- [
          {[{"x-forwarded-proto", "javascript"}, {"x-forwarded-host", "evil.example"}], "javascript://evil.example"},
          {[{"x-forwarded-proto", "https"}, {"x-forwarded-host", "evil.example/path"}], "https://evil.example"},
          {[{"x-forwarded-proto", "https"}, {"x-forwarded-host", "user@evil.example"}], "https://evil.example"}
        ] do
      assert send.(w, "POST", "/cronwatch/check", headers ++ [{"origin", origin}], nil).status == 403, origin
      assert send.(w, "POST", "/cronwatch/check", headers ++ [{"origin", internal}], nil).status == 303, origin
    end

    # Without trust_proxy forwarded headers change nothing.
    w = web()
    ok(w, "x")
    spoofed = [{"x-forwarded-host", "evil.example"}, {"x-forwarded-proto", "https"}]

    assert req(
             w,
             "POST",
             "/cronwatch/jobs/x/silence",
             [cookie, @form | spoofed] ++ [{"origin", "https://evil.example"}],
             "for=1h"
           ).status ==
             403

    back =
      req(
        w,
        "POST",
        "/cronwatch/check",
        [cookie | spoofed] ++ [{"origin", "http://app.test"}, {"referer", "https://evil.example/cronwatch/jobs/x"}]
      )

    assert header(back, "location") == "/cronwatch/"
    refute header(get(w, "/cronwatch/?token=tok", spoofed), "set-cookie") =~ "Secure", "Secure from a spoofed header"
    # TLS makes the request's own origin https.
    tls = Cronwatch.Test.Web.send(w.opts, "GET", "https://app.test/cronwatch/?token=tok")
    assert String.ends_with?(header(tls, "set-cookie"), "; Secure"), "not Secure over TLS"

    # A bad origin is refused when the options are read.
    assert_raise ArgumentError,
                 ~s(routes: origin must be an absolute URL such as "https://app.example.com", got "app.example.com"),
                 fn -> Cronwatch.Web.init(token: "tok", origin: "app.example.com") end

    assert_raise ArgumentError, ~s(routes: origin must be http or https, got "ftp://app.example.com"), fn ->
      Cronwatch.Web.init(token: "tok", origin: "ftp://app.example.com")
    end

    assert Cronwatch.Web.init(token: "tok", origin: "").origin == nil

    # Origins are read as URL#origin reads them.
    for {given, want} <- [
          {" HTTPS://App.Example.COM:443/x ", "https://app.example.com"},
          {"http:\\\\example.com:8080", "http://example.com:8080"},
          {"http://0x7f.1", "http://127.0.0.1"},
          {"http://[0:0::1]:80", "http://[::1]"},
          {"https://bücher.example", "https://xn--bcher-kva.example"},
          {"http://user:pw@example.com", "http://example.com"},
          {"http://[::ffff:1.2.3.4]", "http://[::ffff:102:304]"},
          {"http://1.2.3.4.", "http://1.2.3.4"}
        ] do
      assert Cronwatch.Web.init(origin: given).origin == want, given

      res =
        Cronwatch.Test.Web.send(
          [instance: w.cw, token: "tok", origin: given],
          "POST",
          "http://10.0.0.5/cronwatch/api/check",
          [
            @auth,
            {"origin", want}
          ]
        )

      assert res.status == 200, given
    end

    for bad <- ["http://256.1.1.1.1", "http://a b", "javascript://x"] do
      assert_raise ArgumentError, fn -> Cronwatch.Web.init(origin: bad) end
    end
  end

  # The Go port's second audit: a Host header outside ASCII over 1024 bytes
  # is not punycoded (which takes time in its length times its distinct
  # characters) or read as a URL; the request is answered all the same.
  test "a long host outside ASCII is not read as a URL" do
    w = web()
    ok(w, "x")
    host = for i <- 0..1999, into: "", do: <<0x4E00 + i::utf8>>
    started = System.monotonic_time(:millisecond)
    opts = Cronwatch.Web.init(w.opts)
    request = %Request{method: "POST", path: "/cronwatch/api/check", headers: [{"host", host}, @auth]}
    assert {200, _, _} = Routes.handle(opts, request)
    request = %{request | headers: request.headers ++ [{"origin", "http://" <> host}]}
    assert {200, _, _} = Routes.handle(opts, request), "its own origin"
    assert System.monotonic_time(:millisecond) - started < 10_000
    assert Origin.bare("http://" <> String.duplicate("é", 600)) == nil
    assert Origin.bare("http://" <> String.duplicate("é", 10)) =~ "http://xn--"
  end

  test "the app shell is public and only for reads" do
    for token <- ["tok", false] do
      w = web(token: token)

      for path <- ["/manifest.webmanifest", "/sw.js", "/app.js", "/offline", "/icons/icon.svg", "/icons/icon-192.png"] do
        assert get(w, "/cronwatch" <> path).status == 200, path
        assert req(w, "HEAD", "/cronwatch" <> path).status == 200, path
      end

      assert header(get(w, "/cronwatch/sw.js"), "service-worker-allowed") == "/cronwatch/"
      svg = get(w, "/cronwatch/icons/icon.svg")

      assert header(svg, "content-security-policy") ==
               "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"

      assert header(svg, "cache-control") == "public, max-age=31536000, immutable"
    end

    w = web()
    assert req(w, "POST", "/cronwatch/sw.js").status == 401, "a write to the shell"
    assert req(w, "HEAD", "/cronwatch/", [@auth]).status == 404, "HEAD elsewhere"
    open = web(token: false)
    assert Cronwatch.Web.token(open.opts) == nil
    assert get(open, "/cronwatch/api/jobs").status == 200
  end

  test "the base path" do
    w = web(token: false, base_path: nil)
    ok(w, "x")
    id = fn opts, url -> field(json(Cronwatch.Test.Web.send(opts, "GET", url)), ["id"]) end
    assert id.(w.opts, "http://app.test/cronwatch/manifest.webmanifest") == "/cronwatch/", "the default"
    assert id.(Keyword.put(w.opts, :base_path, ""), "http://app.test/manifest.webmanifest") == "/", "at the root"
    assert id.(Keyword.put(w.opts, :base_path, "/a/b/"), "http://app.test/a/b/manifest.webmanifest") == "/a/b/"

    mounted = fn opts, path, script ->
      Plug.Test.conn("GET", path)
      |> Map.merge(%{host: "app.test", script_name: script})
      |> Cronwatch.Web.call(Cronwatch.Web.init(opts))
      |> Map.get(:resp_body)
      |> JS.parse!()
      |> field(["id"])
    end

    assert mounted.(w.opts, "/x/y/manifest.webmanifest", ["x", "y"]) == "/x/y/", "a router's mount"

    assert mounted.(Keyword.put(w.opts, :base_path, "/a/b"), "/a/b/manifest.webmanifest", ["x"]) == "/a/b/",
           "the option wins"
  end

  test "paths are read as the URL parser leaves them" do
    w = web()
    ok(w, "x")

    for path <- [
          "/cronwatch/./jobs/x",
          "/cronwatch/nope/../jobs/x",
          "/cronwatch\\jobs\\x",
          "/cronwatch/%2e/jobs/x",
          "/cronwatch/jobs/%78"
        ] do
      res = get(w, path, [@auth])
      assert res.status == 200, path
      assert res.body =~ ~s(<h1 class="jobname">x</h1>)
    end

    assert get(w, "/cronwatch/api/jobs/a%2Fb", [@auth]).status == 404, "a slash inside a name"

    for {raw, want} <- [
          {"/a/..", "/"},
          {"/a/b/.", "/a/b/"},
          {"/a b/{c}", "/a%20b/%7Bc%7D"},
          {"/é", "/%C3%A9"}
        ] do
      assert Request.normalize_path(raw) == want, raw
    end
  end

  # The Go port's audit: an interval past what an int64 of milliseconds
  # holds wrapped round, and drawing the board's timeline never ended; a
  # silence for longer than that ended at once.
  test "huge durations neither hang nor wrap" do
    w = web()
    job = Cronwatch.job!("rare", schedule: "every 20000000000w", instance: w.cw)
    Cronwatch.run(job, fn _ -> :ok end)
    Clock.advance(w.clock, 10 * 24 * @hour)
    Cronwatch.check!(instance: w.cw)

    for path <- ["/cronwatch/", "/cronwatch/jobs/rare", "/cronwatch/api/jobs/rare"] do
      assert get(w, path, [@auth]).status == 200, path
    end

    silenced =
      json(req(w, "POST", "/cronwatch/api/jobs/rare/silence", [@auth, @json], ~s({"for":"99999999999999999999999"})))

    assert field(silenced, ["job", "silencedUntil"]) > Clock.now(w.clock), "a long silence ended at once"
  end

  test "a foreign row's far times do not fail the pages" do
    w = web(token: false)
    Cronwatch.run(Cronwatch.job!("far", schedule: "every 5m", instance: w.cw), fn _ -> :ok end)
    Cronwatch.run("old", fn _ -> :ok end, instance: w.cw)
    {m, h} = Cronwatch.Config.get(w.cw).store
    [far] = Cronwatch.runs!("far", 1, instance: w.cw)

    :ok =
      m.insert_run(h, %{
        far
        | id: "far-future",
          started_at: 9_223_372_036_854_775_806,
          finished_at: nil,
          status: "running"
      })

    :ok =
      m.insert_run(h, %Cronwatch.Run{
        id: "long-ago",
        job: "old",
        status: "running",
        started_at: -9_223_372_036_854_775_807
      })

    assert {:ok, _} = Cronwatch.check(instance: w.cw)

    for path <- ["/cronwatch", "/cronwatch/jobs/far", "/cronwatch/jobs/old", "/cronwatch/api/jobs"] do
      assert get(w, path).status == 200, path
    end
  end

  test "a run whose metrics hold something other than a finite number still shows its job's page" do
    w = web(token: false)
    Cronwatch.job!("imported", instance: w.cw)
    now = Clock.now(w.clock)

    run = %Cronwatch.Run{
      id: "nan",
      job: "imported",
      status: "ok",
      started_at: now,
      finished_at: now,
      duration_ms: 0,
      metrics: JS.Object.new([{"rows", :nan}]),
      trigger: "source"
    }

    assert {:error, e} = Cronwatch.record_run(run, instance: w.cw)
    assert Exception.message(e) =~ ~s(record_run: metric "rows" must be a finite number)
    assert Cronwatch.get_run!("nan", instance: w.cw) == nil, "nothing is written"

    # As a foreign row, or a store that kept NaN as null, may hold them.
    {m, h} = Cronwatch.Config.get(w.cw).store
    odd = JS.Object.new([{"rows", nil}, {"label", "abc"}, {"cost", 1.25}, {"n", 3}])
    :ok = m.insert_run(h, %{run | id: "odd", metrics: odd})

    res = get(w, "/cronwatch/jobs/imported")
    assert res.status == 200
    assert res.body =~ ~s(<span class="k">cost</span> 1.2500</span><span><span class="k">n</span> 3<)
    refute res.body =~ ~r/class="k">(rows|label)</
  end

  test "text helpers keep JavaScript's answers" do
    alias Cronwatch.Web.Text

    for {x, d, want} <- [
          {0.25, 1, "0.3"},
          {0.35, 1, "0.3"},
          {1.005, 2, "1.00"},
          {2.5, 0, "3"},
          {-2.5, 0, "-3"},
          {-0.04, 1, "-0.0"},
          {0.0, 1, "0.0"},
          {123.456, 1, "123.5"},
          {0.123456, 4, "0.1235"},
          {1.0e20, 1, "100000000000000000000.0"},
          {5.0e-324, 4, "0.0000"},
          {1000.0, 1, "1000.0"},
          {1.0e21, 1, "1e+21"}
        ] do
      assert Text.to_fixed(x, d) == want, "#{x}.toFixed(#{d})"
    end

    assert Text.escape_name("wp:store_sync.inventory--eu") == "wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu"
    assert Text.escape_name("a-") == "a-"
    assert Text.escape_name("<a>_b") == "&lt;a&gt;_<wbr>b"
    assert Text.constant_time_eq("tok", "tok")
    refute Text.constant_time_eq("tok", "toK")
    refute Text.constant_time_eq("é", Text.latin1("é"))
    assert Text.constant_time_eq("é", Text.latin1(<<0xE9>>))
    assert Request.form_encode("b c/é") == "b+c%2F%C3%A9"

    assert Request.body_field(
             "multipart/form-data; boundary=\"b\"",
             "--b\r\nContent-Disposition: form-data; name=\"for\"; filename=\"x.txt\"\r\n\r\n2h\r\n--b--\r\n",
             "for"
           ) == "[object File]"

    assert Request.body_field(
             "multipart/form-data; boundary=b",
             "--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h",
             "for"
           ) == nil

    assert Request.body_field("application/x-www-form-urlencoded", "for=1h&for=2h", "for") == "2h"
    assert Request.body_field("text/plain", "for=1h", "for") == nil
  end
end
