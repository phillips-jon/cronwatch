defmodule Cronwatch.Audit.WebTest do
  @moduledoc """
  The dashboard's and the handler's cases found by the phase 5 audit.
  """
  use ExUnit.Case, async: true

  import Cronwatch.Test.Client
  import Plug.Conn, only: [put_req_header: 3]

  alias Cronwatch.Test.Clock
  alias Cronwatch.Web.Request

  test "a request's inspect shows no header values, query or body" do
    req = %Request{
      method: "POST",
      path: "/cronwatch/api/check",
      query: "token=query-secret",
      headers: [{"authorization", "Bearer header-secret"}, {"cookie", "cronwatch_token=cookie-secret"}],
      body: {:parsed, %{"for" => "body-secret"}}
    }

    text = inspect(req)
    refute text =~ "secret"
    assert text =~ "authorization"
    assert text =~ "/cronwatch/api/check"
  end

  test "a body Phoenix parsed that is nested deeply reads as none" do
    deep = Enum.reduce(1..10_000, "2h", fn _, acc -> [acc] end)
    assert Request.parsed_field(%{"for" => deep}, "for") == nil

    # The same depth as the plug's own read of the body: 254 arrays inside
    # the body's object read, 255 do not.
    for {k, want} <- [{254, "2h"}, {255, nil}] do
      json = ~s({"for":) <> String.duplicate("[", k) <> ~s("2h") <> String.duplicate("]", k) <> "}"
      parsed = Enum.reduce(1..k, "2h", fn _, acc -> [acc] end)
      assert Request.body_field("application/json", json, "for") == want
      assert Request.parsed_field(%{"for" => parsed}, "for") == want
    end
  end

  test "a silence through parsed params nested deeply is the default hour" do
    k = make()
    opts = [instance: k.cw, token: "tok", base_path: "/cronwatch"]
    Cronwatch.run("nightly", fn _ -> :ok end, instance: k.cw)
    deep = Enum.reduce(1..10_000, "2h", fn _, acc -> [acc] end)

    conn =
      Plug.Test.conn("POST", "/cronwatch/api/jobs/nightly/silence", "")
      |> Map.put(:body_params, %{"for" => deep})
      |> put_req_header("authorization", "Bearer tok")

    conn = Cronwatch.Web.call(conn, Cronwatch.Web.init(opts))
    assert conn.status == 200
    job = Cronwatch.job_summary!("nightly", instance: k.cw)
    assert job.silenced_until == Clock.now(k.clock) + 3_600_000
  end

  test "a handler request whose process is killed records a failed run" do
    %{cw: cw} = make(cron_secret: false)
    Cronwatch.job!("killed", instance: cw)
    parent = self()
    h = Cronwatch.Handler.init(instance: cw, job: "killed", run: {__MODULE__, :block, [parent]})

    pid = spawn(fn -> Cronwatch.Handler.call(Plug.Test.conn("GET", "/cron"), h) end)
    assert_receive {:blocking, ^pid}, 2000
    Process.exit(pid, :kill)

    assert eventually(fn ->
             case Cronwatch.runs!("killed", 5, instance: cw) do
               [%{status: "failed"} = run] -> run.error =~ "killed"
               _ -> false
             end
           end)
  end

  test "a conn the handler's function answers is halted, as its own answers are" do
    %{cw: cw} = make()

    for run <- [
          {Cronwatch.Test.Handlers, :sent, [202, "queued"]},
          {Cronwatch.Test.Handlers, :answer, [503, "bad"]},
          {Cronwatch.Test.Handlers, :text, ["done"]}
        ] do
      h = Cronwatch.Handler.init(instance: cw, job: "h", run: run, secret: false)
      conn = Cronwatch.Handler.call(Plug.Test.conn("GET", "/cron"), h)
      assert conn.halted, inspect(run)
    end
  end

  def block(_job, _conn, parent) do
    send(parent, {:blocking, self()})
    Process.sleep(:infinity)
  end
end

defmodule Cronwatch.Audit.WebServerTest do
  @moduledoc "The body cap over the wire, under Bandit."
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Cronwatch.Test.Clock
  alias Cronwatch.Test.HTTP

  @inst Cronwatch.Test.GoldenWeb
  @t0 Clock.t0()
  @max 1_048_576

  setup do
    start_supervised!({Cronwatch, name: @inst, clock: Clock.fun(Clock.new(@t0)), alerts: [], cron_secret: false})
    Cronwatch.run("x", fn _ -> :ok end, instance: @inst)
    %{port: HTTP.serve(Cronwatch.Test.WebRouter)}
  end

  defp body(size) do
    head = "for=2h&pad="
    head <> String.duplicate("x", size - byte_size(head))
  end

  defp post(port, body, chunked) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)

    framing =
      if chunked,
        do: "transfer-encoding: chunked\r\n",
        else: "content-length: #{byte_size(body)}\r\n"

    wire =
      if chunked do
        # Chunks of 64 KiB, as a client streaming the body would send them.
        chunks =
          for <<chunk::binary-size(65_536) <- body>>, do: [Integer.to_string(65_536, 16), "\r\n", chunk, "\r\n"]

        rest_size = rem(byte_size(body), 65_536)
        rest = binary_part(body, byte_size(body) - rest_size, rest_size)
        tail = if rest_size > 0, do: [Integer.to_string(rest_size, 16), "\r\n", rest, "\r\n"], else: []
        [chunks, tail, "0\r\n\r\n"]
      else
        body
      end

    :ok =
      :gen_tcp.send(socket, [
        "POST /cronwatch/api/jobs/x/silence HTTP/1.1\r\nhost: app.test\r\nconnection: close\r\n",
        "authorization: Bearer tok\r\ncontent-type: application/x-www-form-urlencoded\r\n",
        framing,
        "\r\n",
        wire
      ])

    answer = recv_all(socket, "")
    :gen_tcp.close(socket)
    answer |> String.split("\r\n", parts: 2) |> hd()
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, _} -> acc
    end
  end

  test "a body of exactly the cap is read, with a length or chunked, and one byte more is refused", %{port: port} do
    for chunked <- [false, true] do
      Cronwatch.unsilence!("x", instance: @inst)
      # A server that answers before reading the rest of a body may reset
      # the connection before the answer is read, so the refusal is seen in
      # the job's state rather than the status line.
      post(port, body(@max + 1), chunked)
      assert Cronwatch.job_summary!("x", instance: @inst).silenced_until == nil, "chunked: #{chunked}"
      assert post(port, body(@max), chunked) =~ " 200 ", "chunked: #{chunked}"
      assert Cronwatch.job_summary!("x", instance: @inst).silenced_until == @t0 + 2 * 3_600_000
    end
  end
end
