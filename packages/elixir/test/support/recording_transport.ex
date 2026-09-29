defmodule Cronwatch.Test.RecordingTransport do
  @moduledoc """
  A `Cronwatch.Transport` for the replays: it keeps every request it is
  asked to send and answers each with the status and body its answer
  function gives for the request's body.

      rec = RecordingTransport.start()
      channel_opts = [transport: RecordingTransport.spec(rec)]
      RecordingTransport.answer_with(rec, 500, "no")
      RecordingTransport.answer_by(rec, fn body -> {201, "{}"} end)
      [%Cronwatch.Transport.Request{url: _, headers: _, body: _}] = RecordingTransport.taken(rec)
  """

  @behaviour Cronwatch.Transport

  alias Cronwatch.Transport.Response

  @doc "Starts a recorder under the running test (answering 200 with no body) and answers it."
  def start do
    ExUnit.Callbacks.start_supervised!(
      {Agent, fn -> %{requests: [], answer: fn _ -> {200, ""} end} end},
      id: {__MODULE__, System.unique_integer()}
    )
  end

  @doc "The transport, as a channel's `transport:` option takes it."
  def spec(rec), do: {__MODULE__, rec}

  @doc "Forgets the requests, and answers every request with `status` and `body` from now on."
  def answer_with(rec, status, body), do: answer_by(rec, fn _ -> {status, body} end)

  @doc "Forgets the requests, and answers each with what `fun` gives for its body."
  def answer_by(rec, fun) when is_function(fun, 1) do
    Agent.update(rec, fn _ -> %{requests: [], answer: fun} end)
  end

  @doc "The requests sent since the last reset, oldest first."
  def taken(rec), do: Agent.get(rec, &Enum.reverse(&1.requests))

  @impl true
  def post(rec, request) do
    fun =
      Agent.get_and_update(rec, fn s -> {s.answer, %{s | requests: [request | s.requests]}} end)

    {status, body} = fun.(request.body)
    {:ok, %Response{status: status, body: body}}
  end
end
