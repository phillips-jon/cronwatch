defmodule Cronwatch.HandlerTest do
  @moduledoc """
  `Cronwatch.Handler`: the SDK's handler tests (client.test.ts and
  client-hardening.test.ts), as the Go and Rust ports have them, and the
  Elixir answers: a `%Plug.Conn{}` the function returns, set or sent, and
  `current/0` inside the function. Without a secret, and in development, it
  is tested in env_test.exs, and behind a real server in server_test.exs.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Test.Capture
  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.Handlers

  @secret "s3" <> "cret"

  defp handler(cw, job, run, opts \\ []),
    do: Cronwatch.Handler.init([instance: cw, job: job, run: run] ++ opts)

  defp call(h, headers \\ [], path \\ "/api/cron/hourly") do
    headers
    |> Enum.reduce(Plug.Test.conn("GET", path), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> Cronwatch.Handler.call(h)
  end

  defp runs(cw, name), do: Cronwatch.runs!(name, 50, instance: cw)
  defp json(conn), do: JS.parse!(conn.resp_body)

  test "the handler checks the bearer and reports the run" do
    %{cw: cw, clock: clock} = make(cron_secret: @secret)
    Cronwatch.job!("hourly", schedule: "@hourly", instance: cw)
    h = handler(cw, "hourly", {Handlers, :log_path, []})
    assert call(h).status == 401, "no auth"
    wrong = call(h, [{"authorization", "Bearer wrong"}])
    assert wrong.resp_body == ~s({"ok":false,"error":"Unauthorized"})
    assert call(h, [{"authorization", "bearer " <> @secret}]).status == 401, "a lowercase bearer"
    res = call(h, [{"authorization", "Bearer " <> @secret}])
    assert res.status == 200
    assert get_resp_header(res, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(res, "cache-control") == ["no-store"], "Plug's own cache-control is replaced"
    [run] = runs(cw, "hourly")
    assert res.resp_body == ~s({"ok":true,"job":"hourly","run":"#{run.id}","status":"ok","durationMs":0})
    Clock.advance(clock, 1000)
    failed = call(h, [{"authorization", "Bearer " <> @secret}, {"x-fail", "1"}])
    assert failed.status == 500
    assert Object.get(json(failed), "error") == "nope", "the error's first line"
    [newest, oldest] = runs(cw, "hourly")
    assert oldest.output == "/api/cron/hourly"
    assert newest.trigger == "handler"
    assert newest.error == "nope\nsecond line"
    refute inspect(h) =~ @secret
  end

  test "a secret of its own replaces the instance's" do
    instance_secret = "instance-" <> "secret"
    own = "own-" <> "secret"
    %{cw: cw} = make(cron_secret: instance_secret)
    ok = {Handlers, :count, [self()]}
    h = handler(cw, "own", ok, secret: own)
    bearer = fn s -> [{"authorization", "Bearer " <> s}] end
    assert call(h, bearer.(instance_secret)).status == 401, "the instance's"
    assert call(h, bearer.(own)).status == 200, "its own"

    assert call(handler(cw, "own", ok, secret: ""), bearer.(instance_secret)).status == 200,
           "an empty one is the instance's"

    assert call(handler(cw, "own", ok, secret: false)).status == 200, "secret: false lets anyone in"
  end

  test "a conn the function returns is the answer, and fails the run at 400" do
    %{cw: cw, clock: clock, alerts: alerts} = make()
    set = call(handler(cw, "h", {Handlers, :answer, [503, "bad"]}, secret: false))
    assert set.status == 503, "passed through"
    assert set.resp_body == "bad"
    assert get_resp_header(set, "x-upstream") == ["1"]
    assert hd(runs(cw, "h")).error == "HTTP 503 Service Unavailable"
    assert Capture.types(alerts) == ["failed"]

    Clock.advance(clock, 1000)
    sent = call(handler(cw, "h", {Handlers, :sent, [404, "not here"]}, secret: false))
    assert sent.status == 404
    assert sent.resp_body == "not here"
    assert hd(runs(cw, "h")).error == "HTTP 404 Not Found"

    Clock.advance(clock, 1000)
    fine = call(handler(cw, "h", {Handlers, :sent, [202, "queued"]}, secret: false))
    assert fine.status == 202
    assert fine.resp_body == "queued"
    assert hd(runs(cw, "h")).status == "ok"

    Clock.advance(clock, 1000)
    text = call(handler(cw, "h", {Handlers, :text, ["Report written"]}, secret: false))
    assert text.status == 200, "a binary"
    assert hd(runs(cw, "h")).output == "Report written", "its output"
  end

  test "an error is answered with the run" do
    %{cw: cw} = make()
    res = call(handler(cw, "h", {Handlers, :fail, ["the report was empty"]}, secret: false))
    assert res.status == 500
    assert Object.get(json(res), "ok") == false
    assert hd(runs(cw, "h")).error == "the report was empty"
  end

  test "a raise is a failed run answered 500" do
    %{cw: cw, alerts: alerts} = make(cron_secret: @secret)
    res = call(handler(cw, "p", {Handlers, :raise_it, ["boom"]}), [{"authorization", "Bearer " <> @secret}])
    assert res.status == 500, "answered"
    assert get_resp_header(res, "content-type") == ["application/json; charset=utf-8"]
    [run] = runs(cw, "p")
    assert run.status == "failed"
    assert run.error =~ ~r/\ARuntimeError: boom\n    at /

    assert res.resp_body ==
             ~s({"ok":false,"job":"p","run":"#{run.id}","status":"failed","durationMs":0,"error":"RuntimeError: boom"})

    assert Capture.types(alerts) == ["failed"]

    # A caller without the secret gets no error text, as for any failure.
    open = call(handler(cw, "q", {Handlers, :raise_it, ["private detail"]}, secret: false))
    assert open.status == 500
    assert Object.get(json(open), "error") == nil
  end

  test "the function runs as the run, current/0 included, and a declared job keeps its options" do
    %{cw: cw} = make()
    Cronwatch.job!("declared", schedule: "0 2 * * *", instance: cw)
    call(handler(cw, "declared", {Handlers, :current, [self()]}, secret: false))
    assert_received {:current, current, job}
    assert current.run_id == job.run_id
    assert hd(runs(cw, "declared")).trigger == "handler"
    assert Object.get(Cronwatch.job_summary!("declared", instance: cw).definition, "schedule") == "0 2 * * *"
  end

  test "options are checked when they are read" do
    assert_raise ArgumentError, ~r/needs :job/, fn -> Cronwatch.Handler.init(run: {Handlers, :count, []}) end
    assert_raise ArgumentError, ~r/needs :run/, fn -> Cronwatch.Handler.init(job: "x", run: fn -> :ok end) end

    assert_raise ArgumentError, ~r/unknown option :nope/, fn ->
      Cronwatch.Handler.init(job: "x", run: {M, :f, []}, nope: 1)
    end

    assert_raise ArgumentError, ~r/secret must be/, fn ->
      Cronwatch.Handler.init(job: "x", run: {M, :f, []}, secret: 1)
    end
  end
end
