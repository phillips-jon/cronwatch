if Code.ensure_loaded?(Plug.Conn) do
  defmodule Cronwatch.Handler do
    @moduledoc """
    A job as a Plug, for a platform cron that calls a URL (Fly.io, Render,
    Gigalixir, a Kubernetes CronJob running `curl`): the SDK's
    `job.handler()`.

        # lib/my_app_web/router.ex
        forward "/cron/nightly", Cronwatch.Handler,
          job: "nightly-report", run: {MyApp.Reports, :nightly, []}

    Each request whose `Authorization` is `Bearer <secret>` (compared in
    constant time) runs the function as a recorded run with the trigger
    `"handler"`, and is answered with
    `{"ok","job","run","status","durationMs"}`, 200 when the run was ok and
    500 when it failed, with the error's first line as `error` for a caller
    who sent the secret. A wrong or missing bearer is 401. With no secret at
    all it answers 503, and reports it once to the error handler as
    `handler`, unless the environment is development or `secret: false` (or
    the instance's `cron_secret: false`) lets anyone in.

    Options:

      * `:job` - the job's name (required). A job the instance does not
        declare is declared with no options on the first request; declare it
        in the instance's `jobs:` to give it a schedule.
      * `:run` - `{module, function, args}` (required), called as
        `module.function(context, conn, ...args)`, since a router's options
        cannot hold an anonymous function. A raise, throw, exit,
        `{:error, reason}` or `:error` fails the run, as for any run. A
        `%Plug.Conn{}` it returns is the answer (sent as it is, or with the
        status it set), and a status of 400 or more fails the run with
        `HTTP <status> <reason>`.
      * `:secret` - the secret requests must carry, in place of the
        instance's cron secret; `""` counts as unset, `{:system, "VAR"}`
        reads a variable on each request, and `false` lets anyone run the
        job.
      * `:instance` - the Cronwatch instance (default `Cronwatch`).

    The function runs in the request's process, so a request whose client
    goes away and whose process the server ends records a failed run; an app
    that wants the job to outlive the request starts it under its own
    `Task.Supervisor`.
    """

    @behaviour Plug

    alias Cronwatch.Config
    alias Cronwatch.Env
    alias Cronwatch.JS
    alias Cronwatch.JS.Object
    alias Cronwatch.Run.Exec
    alias Cronwatch.Runs
    alias Cronwatch.Web.Request
    alias Cronwatch.Web.Routes
    alias Cronwatch.Web.Text

    @derive {Inspect, except: [:secret]}
    @enforce_keys [:job, :run]
    defstruct [:job, :run, secret: nil, instance: Cronwatch]

    @type t :: %__MODULE__{
            job: String.t(),
            run: {module(), atom(), list()},
            secret: String.t() | false | {:system, String.t()} | nil,
            instance: atom()
          }

    @known [:job, :run, :secret, :instance]

    @doc "Checks the options' shape and keeps them; nothing is read until a request comes."
    @impl Plug
    @spec init(keyword() | t()) :: t()
    def init(%__MODULE__{} = opts), do: opts

    def init(opts) when is_list(opts) do
      case Enum.find(opts, fn {k, _} -> k not in @known end) do
        nil -> :ok
        {k, _} -> raise ArgumentError, "Cronwatch.Handler: unknown option #{inspect(k)}"
      end

      job = Keyword.get(opts, :job)
      run = Keyword.get(opts, :run)
      secret = Keyword.get(opts, :secret)
      instance = Keyword.get(opts, :instance, Cronwatch)

      unless is_binary(job) and job != "",
        do: raise(ArgumentError, "Cronwatch.Handler needs :job, the job's name")

      unless match?({m, f, a} when is_atom(m) and is_atom(f) and is_list(a), run),
        do: raise(ArgumentError, "Cronwatch.Handler needs :run, as {module, function, args}")

      unless secret == nil or secret == false or is_binary(secret) or match?({:system, v} when is_binary(v), secret),
        do: raise(ArgumentError, "Cronwatch.Handler: secret must be a string, {:system, name} or false")

      unless is_atom(instance) and instance not in [nil, true, false],
        do: raise(ArgumentError, "Cronwatch.Handler: instance must be an atom, not #{inspect(instance)}")

      %__MODULE__{job: job, run: run, secret: secret, instance: instance}
    end

    @impl Plug
    def call(%Plug.Conn{} = conn, %__MODULE__{} = opts) do
      c = Config.get(opts.instance)
      {secret, opted_out} = secret(opts, c)

      cond do
        secret == nil and not opted_out and not Env.development?() ->
          if Runs.flag(opts.instance, {__MODULE__, :warned_no_secret}) do
            Config.report(
              c,
              Cronwatch.Error.other(
                "handler refused a request because no CRON_SECRET is set; pass secret: false to allow unauthenticated requests"
              ),
              "handler"
            )
          end

          json(
            conn,
            Object.new([
              {"ok", false},
              {"error",
               "CRON_SECRET is not set, so this job will not run for an unauthenticated request. Set it, or pass secret: false to Cronwatch.Handler to allow anyone."}
            ]),
            503
          )

        secret != nil and not authorized?(conn, secret) ->
          json(conn, Object.new([{"ok", false}, {"error", "Unauthorized"}]), 401)

        true ->
          run(conn, opts, secret)
      end
    end

    # The options' secret, else the instance's; and whether anyone may run
    # the job without one.
    defp secret(%{secret: false}, _c), do: {nil, true}
    defp secret(%{secret: s}, _c) when is_binary(s) and s != "", do: {s, false}

    defp secret(%{secret: {:system, var}} = opts, c) do
      case Env.read(var) do
        nil -> secret(%{opts | secret: nil}, c)
        s -> {s, false}
      end
    end

    defp secret(_opts, c), do: {Routes.cron_secret(c), c.cron_secret == false}

    defp authorized?(conn, secret) do
      sent = %Request{headers: conn.req_headers} |> Request.header("authorization") |> Kernel.||("") |> Text.latin1()
      Text.constant_time_eq(sent, "Bearer " <> secret)
    end

    defp run(conn, opts, secret) do
      {m, f, args} = opts.run
      job = Runs.job(opts.instance, opts.job) || Cronwatch.job!(opts.job, instance: opts.instance)
      key = {__MODULE__, make_ref()}

      result =
        try do
          {:returned,
           Exec.run(job, fn ctx -> apply(m, f, [ctx, conn | args]) end,
             trigger: "handler",
             recorded: &Process.put(key, &1)
           )}
        rescue
          _ -> :failed
        catch
          _, _ -> :failed
        end

      run = Process.delete(key)

      # A conn answered is halted, as every other answer here is, so a
      # pipeline the handler is plugged into does not go on to answer it
      # again.
      case result do
        {:returned, %Plug.Conn{state: state} = answered} when state in [:sent, :chunked, :file, :upgraded] ->
          Plug.Conn.halt(answered)

        {:returned, %Plug.Conn{state: :set} = answered} ->
          answered |> Plug.Conn.send_resp() |> Plug.Conn.halt()

        {:returned, %Plug.Conn{} = answered} ->
          answer(answered, opts, run, secret)

        _ ->
          answer(conn, opts, run, secret)
      end
    end

    defp answer(conn, _opts, nil, _secret),
      do: json(conn, Object.new([{"ok", false}, {"error", "Internal error"}]), 500)

    defp answer(conn, opts, run, secret) do
      body =
        Object.new([
          {"ok", run.status == "ok"},
          {"job", opts.job},
          {"run", run.id},
          {"status", run.status},
          {"durationMs", run.duration_ms}
        ])

      # Error text only goes to a caller who proved they hold the secret.
      body =
        if secret != nil and run.error not in [nil, ""],
          do: Object.put(body, "error", run.error |> :binary.split("\n") |> hd()),
          else: body

      json(conn, body, if(run.status == "ok", do: 200, else: 500))
    end

    # The SDK's json(): the body, with its type and no-store, in place of
    # Plug's own cache-control.
    defp json(conn, body, status) do
      conn
      |> Plug.Conn.delete_resp_header("cache-control")
      |> Plug.Conn.put_resp_header("content-type", "application/json; charset=utf-8")
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> Plug.Conn.send_resp(status, JS.stringify(body))
      |> Plug.Conn.halt()
    end
  end
end
