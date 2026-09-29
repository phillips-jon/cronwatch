defmodule Cronwatch.Test.HTTPServer do
  @moduledoc """
  A small HTTP/1.1 server on a local port, over plain TCP or TLS, for the
  hardening tests: it keeps every request (the head as sent, so header
  order can be pinned, and the body), and answers each as its handler says.

      server = HTTPServer.start(fn request -> {200, [], "ok"} end)
      server.url   #=> "http://127.0.0.1:54321"
      HTTPServer.requests(server)

  The handler is given `%{method:, target:, headers: [{name, value}], head:,
  body:}` (names lowercased) and answers one of:

    * `{status, headers, body}`: sent at once, with a `content-length`;
    * `{:raw, iodata}`: written as it is, then the connection closed;
    * `{:drip, status, headers, chunks, pause_ms}`: the head, then each
      chunk after a pause, closing at the end (no length);
    * `:hang`: nothing, the connection held open until the test ends.

  With `tls: true` it serves TLS with a certificate for `localhost` made
  at run time by `:public_key`'s test helpers, from a root no system
  trusts; `ca(server)` is that root, DER encoded, for a test that trusts it.
  """

  @doc "Starts a server under the running test."
  def start(handler, opts \\ []) do
    tls? = Keyword.get(opts, :tls, false)
    {:ok, requests} = ExUnit.Callbacks.start_supervised({Agent, fn -> [] end}, id: {__MODULE__, make_ref()})
    certs = if tls?, do: certificates()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    parent = self()

    ExUnit.Callbacks.start_supervised!(
      %{
        id: {__MODULE__, :acceptor, make_ref()},
        start: {Task, :start_link, [fn -> accept(listen, handler, requests, certs, parent) end]}
      },
      restart: :temporary
    )

    scheme = if tls?, do: "https", else: "http"

    %{
      url: "#{scheme}://#{if tls?, do: "localhost", else: "127.0.0.1"}:#{port}",
      port: port,
      requests: requests,
      ca: certs && certs.ca
    }
  end

  @doc "The requests the server took, oldest first."
  def requests(%{requests: agent}), do: Agent.get(agent, &Enum.reverse/1)

  @doc "The root the TLS server's certificate chains to, DER encoded."
  def ca(%{ca: ca}), do: ca

  defp accept(listen, handler, requests, certs, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> serve(socket, handler, requests, certs) end)
        :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listen, handler, requests, certs, parent)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, handler, requests, certs) do
    receive do
      :go -> :ok
    end

    socket =
      if certs do
        case :ssl.handshake(socket, [cert: certs.cert, key: certs.key, cacerts: [certs.ca]], 5000) do
          {:ok, s} -> {:ssl, s}
          {:error, _} -> nil
        end
      else
        {:tcp, socket}
      end

    if socket do
      case read_request(socket, "") do
        {:ok, request} ->
          Agent.update(requests, &[request | &1])
          respond(socket, handler.(request))

        :error ->
          :ok
      end

      close(socket)
    end
  end

  defp read_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        [line | lines] = String.split(head, "\r\n")
        [method, target | _] = String.split(line, " ")

        headers =
          Enum.map(lines, fn l ->
            [n, v] = String.split(l, ":", parts: 2)
            {String.downcase(n), String.trim(v)}
          end)

        length = headers |> List.keyfind("content-length", 0, {nil, "0"}) |> elem(1) |> String.to_integer()

        with {:ok, body} <- read_body(socket, rest, length) do
          {:ok, %{method: method, target: target, headers: headers, head: head, body: body}}
        end

      [_] ->
        case recv(socket) do
          {:ok, data} -> read_request(socket, acc <> data)
          _ -> :error
        end
    end
  end

  defp read_body(_socket, have, length) when byte_size(have) >= length, do: {:ok, binary_part(have, 0, length)}

  defp read_body(socket, have, length) do
    case recv(socket) do
      {:ok, data} -> read_body(socket, have <> data, length)
      _ -> :error
    end
  end

  defp respond(socket, {status, headers, body}) do
    body = IO.iodata_to_binary(body)

    head = [
      "HTTP/1.1 #{status} X\r\n",
      header_lines(headers),
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n"
    ]

    write(socket, [head, body])
  end

  defp respond(socket, {:raw, data}), do: write(socket, data)

  defp respond(socket, {:drip, status, headers, chunks, pause}) do
    write(socket, ["HTTP/1.1 #{status} X\r\n", header_lines(headers), "connection: close\r\n\r\n"])

    Enum.each(chunks, fn c ->
      Process.sleep(pause)
      write(socket, c)
    end)
  end

  defp respond(_socket, :hang), do: Process.sleep(:infinity)

  defp header_lines(headers), do: Enum.map(headers, fn {n, v} -> "#{n}: #{v}\r\n" end)

  defp recv({:tcp, s}), do: :gen_tcp.recv(s, 0, 5000)
  defp recv({:ssl, s}), do: :ssl.recv(s, 0, 5000)
  defp write({:tcp, s}, data), do: :gen_tcp.send(s, data)
  defp write({:ssl, s}, data), do: :ssl.send(s, data)
  defp close({:tcp, s}), do: :gen_tcp.close(s)
  defp close({:ssl, s}), do: :ssl.close(s)

  # P-256 keys signed with SHA-256, which every TLS version takes.
  defp ec, do: [key: {:namedCurve, :secp256r1}, digest: :sha256]

  # A root, and a certificate for localhost signed by it, made now.
  defp certificates do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: ec(), intermediates: [], peer: ec() ++ [extensions: [san]]},
        client_chain: %{root: ec(), intermediates: [], peer: ec()}
      })

    server = data.server_config
    [ca | _] = Enum.reverse(Keyword.fetch!(server, :cacerts))
    %{cert: Keyword.fetch!(server, :cert), key: Keyword.fetch!(server, :key), ca: ca}
  end
end
