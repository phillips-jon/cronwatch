defmodule Cronwatch.Web.EnvTest do
  @moduledoc """
  What depends on the environment: the dashboard locked without a token
  outside development, the development token and its sign-in line (shown
  with the host only when `origin` is set or the host is loopback), and a
  job's handler with no secret. The environment is the node's, so these run
  alone, after the async tests, each with only the variables it names.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Cronwatch.Test.Client
  import Cronwatch.Test.Web, only: [header: 2]
  import ExUnit.CaptureIO

  alias Cronwatch.Web.Request
  alias Cronwatch.Web.Routes

  @vars ["CRONWATCH_ENV", "APP_ENV", "MIX_ENV", "CRONWATCH_TOKEN", "CRON_SECRET"]

  defp with_env(vars, fun) do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp send(opts, method, url, headers \\ []), do: Cronwatch.Test.Web.send(opts, method, url, headers)

  @intro "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: "
  @hostless " on this server (the first request's host is not local, so the link leaves it out)"

  defp announced(out), do: out |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "[cronwatch]"))

  test "the environment: CRONWATCH_ENV, then APP_ENV, then MIX_ENV, trimmed and lowercased" do
    # The SDK's env.test.ts table, MIX_ENV in NODE_ENV's place.
    cases = [
      {nil, nil, nil, nil},
      {nil, nil, "development", "development"},
      {nil, nil, "test", "development"},
      {nil, nil, "production", "production"},
      {nil, "local", "production", "development"},
      {"production", "dev", "development", "production"},
      {"staging", nil, "development", "staging"},
      {"  PROD ", nil, nil, "production"},
      {nil, "Testing", nil, "development"},
      {nil, "DEV", nil, "development"},
      {"", "   ", "production", "production"},
      {" \t", nil, nil, nil}
    ]

    for {cronwatch_env, app_env, mix_env, want} <- cases do
      vars =
        Enum.reject(
          [{"CRONWATCH_ENV", cronwatch_env}, {"APP_ENV", app_env}, {"MIX_ENV", mix_env}],
          &(elem(&1, 1) == nil)
        )

      with_env(vars, fn ->
        assert Cronwatch.Env.environment() == want, inspect(vars)
        assert Cronwatch.Env.development?() == (want == "development"), inspect(vars)
        assert Cronwatch.Env.production?() == (want == "production"), inspect(vars)
      end)
    end
  end

  test "the dashboard is locked without a token outside development" do
    %{cw: cw} = make()

    for env <- [nil, "production", "staging", "prod"] do
      with_env(if(env, do: [{"CRONWATCH_ENV", env}], else: []), fn ->
        opts = [instance: cw]
        assert Cronwatch.Web.token(opts) == nil
        api = send(opts, "GET", "http://localhost/cronwatch/api/jobs")
        assert api.status == 503
        assert api.body == ~s({"ok":false,"error":"CRONWATCH_TOKEN is not set"})
        page = send(opts, "GET", "http://localhost/cronwatch")
        assert page.status == 503
        assert page.body =~ "CronWatch routes are locked"
        assert page.body =~ "token: false"

        # The app shell is public even so.
        for path <- ["/manifest.webmanifest", "/sw.js", "/app.js", "/offline", "/icons/icon.svg"] do
          assert send(opts, "GET", "http://localhost/cronwatch" <> path).status == 200, path
        end
      end)
    end
  end

  test "a development token is printed once and required" do
    for var <- ["CRONWATCH_ENV", "APP_ENV", "MIX_ENV"] do
      %{cw: cw} = make()

      with_env([{var, "test"}], fn ->
        opts = [instance: cw, base_path: "/cronwatch/"]

        out =
          capture_io(fn ->
            for {url, headers} <- [
                  {"http://localhost:3000/cronwatch/api/jobs", []},
                  {"http://localhost:3000/cronwatch/api/jobs", [{"x-forwarded-for", "127.0.0.1"}]},
                  {"http://127.0.0.1:3000/cronwatch/", []},
                  {"http://192.168.1.20:3000/cronwatch/api/jobs", []},
                  {"http://[::1]:3000/cronwatch/api/jobs", [{"x-real-ip", "127.0.0.1"}]}
                ] do
              assert send(opts, "GET", url, headers).status == 401, url
            end

            send([instance: cw, base_path: "/"], "GET", "https://dev.example:8443/api/jobs")
          end)

        token = Cronwatch.Web.token(opts)
        assert byte_size(token) == 43, "base64url of 32 bytes"
        assert token =~ ~r/\A[A-Za-z0-9_-]+\z/
        [first, second] = announced(out)
        assert first == "#{@intro}http://localhost:3000/cronwatch/?token=#{token}", var
        assert String.starts_with?(second, @intro <> "/?token=")
        assert String.ends_with?(second, @hostless)
        refute second =~ token, "each mount makes its own token"

        page = send(opts, "GET", "http://localhost:3000/cronwatch/")
        assert page.body =~ "sign-in link is in the server log"
        assert send(opts, "GET", "http://localhost:3000/cronwatch/api/jobs").body =~ "in the server log"
        sign_in = send(opts, "GET", "http://localhost:3000/cronwatch/?token=#{token}")
        assert sign_in.status == 303
        assert header(sign_in, "location") == "/cronwatch/"
        cookie = sign_in |> header("set-cookie") |> String.split(";") |> hd()
        assert send(opts, "GET", "http://localhost:3000/cronwatch/", [{"cookie", cookie}]).status == 200
        bearer = {"authorization", "Bearer " <> token}
        assert send(opts, "GET", "http://localhost:3000/cronwatch/api/jobs", [bearer]).status == 200
      end)
    end
  end

  test "an empty token is unset, and token: false opens the dashboard" do
    %{cw: cw} = make()
    jobs = fn opts -> send([instance: cw] ++ opts, "GET", "http://app.test/cronwatch/api/jobs").status end

    with_env([{"CRONWATCH_ENV", "production"}], fn ->
      assert jobs.([]) == 503, "unset"
      assert jobs.(token: "") == 503, "empty"
      assert jobs.(token: false) == 200, "open"
    end)

    with_env([{"CRONWATCH_ENV", "development"}], fn ->
      assert capture_io(fn -> assert jobs.(token: false) == 200 end) == "", "no token made"
    end)

    with_env([{"CRONWATCH_ENV", "development"}, {"CRONWATCH_TOKEN", "envtok"}], fn ->
      out =
        capture_io(fn ->
          assert jobs.([]) == 401

          res =
            send([instance: cw, token: ""], "GET", "http://app.test/cronwatch/api/jobs", [
              {"authorization", "Bearer envtok"}
            ])

          assert res.status == 200, "the environment's token"
        end)

      assert out == "", "nothing printed"
    end)

    # A token from another variable, read on each request.
    with_env([{"CRONWATCH_ENV", "production"}, {"MY_TOKEN", "mine"}], fn ->
      opts = [instance: cw, token: {:system, "MY_TOKEN"}]
      assert Cronwatch.Web.token(opts) == "mine"
      res = send(opts, "GET", "http://app.test/cronwatch/api/jobs", [{"authorization", "Bearer mine"}])
      assert res.status == 200
    end)

    System.delete_env("MY_TOKEN")
    refute inspect(Cronwatch.Web.init(token: "secret-token")) =~ "secret-token", "the token is never inspected"
  end

  # Blank as JavaScript's trim sees it: U+FEFF and U+00A0 are spaces there,
  # U+0085 is not.
  @blanks ["", " ", "  ", "\t", " \n  ﻿ "]

  test "blank, as JavaScript's trim sees it" do
    for blank <- @blanks ++ [" ", " ", "﻿", "　"] do
      assert Cronwatch.Env.secret(blank) == nil, inspect(blank)
    end

    assert Cronwatch.Env.secret("\u0085") == "\u0085"
    assert Cronwatch.Env.secret(" padded ") == " padded ", "used untrimmed"
  end

  test "a CRONWATCH_TOKEN or token of only whitespace counts as unset, so the routes stay locked" do
    %{cw: cw} = make()

    locked = fn opts, what ->
      assert send(opts, "GET", "http://app.test/cronwatch/api/jobs").status == 503, what

      for blank <- @blanks do
        page = send(opts, "GET", "http://app.test/cronwatch/?token=" <> URI.encode_www_form(blank), [])
        assert page.status == 503, what
        assert header(page, "set-cookie") == nil, what
      end

      res = send(opts, "GET", "http://app.test/cronwatch/api/jobs", [{"authorization", "Bearer  "}])
      assert res.status == 503, what
    end

    for blank <- @blanks do
      with_env([{"CRONWATCH_ENV", "production"}, {"CRONWATCH_TOKEN", blank}], fn ->
        assert Cronwatch.Web.token(instance: cw) == nil
        locked.([instance: cw], "CRONWATCH_TOKEN=#{inspect(blank)}")
      end)

      with_env([{"CRONWATCH_ENV", "production"}, {"MY_TOKEN", blank}], fn ->
        locked.([instance: cw, token: {:system, "MY_TOKEN"}], "MY_TOKEN=#{inspect(blank)}")
      end)

      with_env([{"CRONWATCH_ENV", "production"}], fn ->
        locked.([instance: cw, token: blank], "token: #{inspect(blank)}")
      end)

      # A blank token in code falls back to the variable.
      with_env([{"CRONWATCH_ENV", "production"}, {"CRONWATCH_TOKEN", "from-env"}], fn ->
        res =
          send([instance: cw, token: blank], "GET", "http://app.test/cronwatch/api/jobs", [
            {"authorization", "Bearer from-env"}
          ])

        assert res.status == 200, inspect(blank)
      end)
    end

    System.delete_env("MY_TOKEN")

    # Any other value is used as it is, untrimmed.
    with_env([{"CRONWATCH_ENV", "production"}, {"CRONWATCH_TOKEN", " padded "}], fn ->
      assert send([instance: cw], "GET", "http://app.test/cronwatch/?token=%20padded%20").status == 303
      assert send([instance: cw], "GET", "http://app.test/cronwatch/?token=padded").status == 401
    end)
  end

  test "a CRON_SECRET or secret of only whitespace counts as unset" do
    bearer = fn h, value ->
      Plug.Test.conn("POST", "/")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> value)
      |> Cronwatch.Handler.call(h)
    end

    handler = fn cw, opts ->
      Cronwatch.Handler.init([instance: cw, job: "closed", run: {Cronwatch.Test.Handlers, :count, [self()]}] ++ opts)
    end

    for blank <- ["", " ", "\t\n", " ﻿"] do
      # From the variable, and given in code: no secret, so 503 and one report.
      for {env, opts} <- [{[{"CRON_SECRET", blank}], [cron_secret: nil]}, {[], [cron_secret: blank]}] do
        with_env([{"CRONWATCH_ENV", "production"} | env], fn ->
          %{cw: cw, errors: errors} = make(opts)
          assert Routes.cron_secret(Cronwatch.Config.get(cw)) == nil, inspect({env, opts})
          h = handler.(cw, [])
          assert call(h).status == 503
          assert bearer.(h, blank).status == 503
          refute_received :ran
          assert wheres(errors) == ["handler"], "reported once"

          # A blank secret of the handler's own falls back to the instance's.
          assert call(handler.(cw, secret: blank)).status == 503
        end)
      end

      # A blank cron_secret given in code does not fall back to the variable.
      with_env([{"CRONWATCH_ENV", "production"}, {"CRON_SECRET", "from-env"}], fn ->
        %{cw: cw} = make(cron_secret: blank)
        assert bearer.(handler.(cw, []), "from-env").status == 503
      end)

      # With cron_secret: false and a blank secret of its own, the job runs.
      with_env([{"CRONWATCH_ENV", "production"}], fn ->
        %{cw: cw} = make(cron_secret: false)
        assert call(handler.(cw, secret: blank)).status == 200
        assert_received :ran
      end)
    end

    # /api/check takes no blank cron secret, and the token is not it.
    with_env([{"CRONWATCH_ENV", "production"}, {"CRON_SECRET", "  "}], fn ->
      %{cw: cw} = make(cron_secret: nil)
      opts = [instance: cw, token: "tok"]
      res = send(opts, "POST", "http://app.test/cronwatch/api/check", [{"authorization", "Bearer   "}])
      assert res.status == 401
    end)
  end

  defp call(h), do: Cronwatch.Handler.call(Plug.Test.conn("GET", "/"), h)

  test "the sign-in line shows the host only when configured or loopback" do
    %{cw: cw} = make()
    internal = "http://10.0.0.5:8080"
    spoofed = [{"x-forwarded-proto", "https"}, {"x-forwarded-host", "attacker.example"}]

    cases = [
      {[origin: "https://app.example.com"], internal <> "/cronwatch/", [], "https://app.example.com/cronwatch", ""},
      {[origin: "https://app.example.com", trust_proxy: true], internal <> "/cronwatch/", spoofed,
       "https://app.example.com/cronwatch", ""},
      {[], "http://localhost:3000/cronwatch/", [], "http://localhost:3000/cronwatch", ""},
      {[], "http://app.localhost:3000/cronwatch/", [], "http://app.localhost:3000/cronwatch", ""},
      {[], "http://127.0.0.1:3000/cronwatch/", [], "http://127.0.0.1:3000/cronwatch", ""},
      {[], "http://127.8.9.10/cronwatch/", [], "http://127.8.9.10/cronwatch", ""},
      {[], "http://[::1]:3000/cronwatch/", [], "http://[::1]:3000/cronwatch", ""},
      {[trust_proxy: true], internal <> "/cronwatch/", [{"x-forwarded-host", "localhost:5173"}],
       "http://localhost:5173/cronwatch", ""},
      {[], internal <> "/cronwatch/", [], "/cronwatch", @hostless},
      {[], "https://app.example.com/cronwatch/", [], "/cronwatch", @hostless},
      {[trust_proxy: true], "http://localhost:3000/cronwatch/", spoofed, "/cronwatch", @hostless},
      {[], "http://localhost.example/cronwatch/", [], "/cronwatch", @hostless},
      {[], "http://128.0.0.1/cronwatch/", [], "/cronwatch", @hostless},
      {[base_path: "/"], "http://attacker.example/", [], "", @hostless},
      # A Host header that is not a host is not loopback, however it ends
      # (the Rust audit): the link leaves it out.
      {[], "http://evil.example/.localhost/cronwatch/", [], "/cronwatch", @hostless},
      {[], "http://localhost:1@evil.example/cronwatch/", [], "/cronwatch", @hostless}
    ]

    with_env([{"CRONWATCH_ENV", "development"}], fn ->
      cases
      |> Enum.with_index()
      |> Enum.each(fn {{options, url, headers, link, tail}, i} ->
        # Each case a mount of its own, as each routes value is in the SDK.
        # (a token read from a variable of its own, unset, makes the options
        # differ).
        opts = [instance: cw, base_path: "/cronwatch", token: {:system, "CRONWATCH_UNSET_#{i}"}]
        opts = Keyword.merge(opts, options)

        out =
          capture_io(fn ->
            request(opts, url, headers)
            # Printed once per mount, however many requests it answers.
            request(opts, url, headers)
          end)

        token = Cronwatch.Web.token(opts)
        assert announced(out) == ["#{@intro}#{link}/?token=#{token}#{tail}"], url
      end)
    end)
  end

  # A request with its Host header exactly as given, which may not be a host.
  defp request(opts, url, headers) do
    [_, scheme, authority, path] = Regex.run(~r{\A(https?)://(.*?)(/cronwatch/|/)\z}, url)

    request = %Request{
      method: "GET",
      path: path,
      headers: [{"host", authority} | headers],
      tls: scheme == "https"
    }

    Routes.handle(Cronwatch.Web.init(opts), request)
  end

  describe "a job's handler without a secret" do
    defp handler(cw, opts \\ []) do
      Cronwatch.Handler.init([instance: cw, job: "closed", run: {Cronwatch.Test.Handlers, :count, [self()]}] ++ opts)
    end

    test "fails closed outside development, and reports it once" do
      with_env([], fn ->
        %{cw: cw, errors: errors} = make(cron_secret: "")
        h = handler(cw)
        res = call(h)
        assert res.status == 503
        assert res.resp_body =~ "CRON_SECRET is not set"
        assert Plug.Conn.get_resp_header(res, "content-type") == ["application/json; charset=utf-8"]
        call(h)
        refute_received :ran
        assert wheres(errors) == ["handler"], "reported once"
        assert hd(messages(errors)) =~ "secret: false"

        # Opting out runs the job, and does not show the error to the caller.
        open =
          Cronwatch.Handler.init(
            instance: cw,
            job: "open",
            run: {Cronwatch.Test.Handlers, :fail, ["private detail"]},
            secret: false
          )

        failed = call(open)
        assert failed.status == 500
        refute failed.resp_body =~ "error", "the error went to a caller who sent no secret"
      end)
    end

    test "an instance with cron_secret: false lets anyone in" do
      with_env([], fn ->
        %{cw: cw} = make(cron_secret: false)
        assert call(handler(cw)).status == 200
        assert_received :ran
      end)
    end

    test "development lets it run" do
      with_env([{"APP_ENV", "local"}], fn ->
        %{cw: cw, errors: errors} = make(cron_secret: "")
        assert call(handler(cw)).status == 200
        assert wheres(errors) == []
      end)
    end

    test "CRON_SECRET is read on each request" do
      with_env([{"CRON_SECRET", "from-env"}], fn ->
        %{cw: cw} = make(cron_secret: nil)
        h = handler(cw)
        assert call(h).status == 401

        ok =
          Plug.Test.conn("GET", "/")
          |> Plug.Conn.put_req_header("authorization", "Bearer from-env")
          |> Cronwatch.Handler.call(h)

        assert ok.status == 200
      end)
    end
  end
end
