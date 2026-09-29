defmodule Cronwatch.Config do
  @moduledoc false
  # An instance's options, checked when it starts and kept in
  # :persistent_term under {Cronwatch, name}, so every call reads them
  # without a message. Written once per start.

  alias Cronwatch.Error
  alias Cronwatch.Options
  alias Cronwatch.Output
  alias Cronwatch.Types.Read

  require Logger

  defstruct name: Cronwatch,
            store: nil,
            default_store: false,
            alerts: [],
            triage: nil,
            transport: nil,
            sources: [],
            cron_secret: nil,
            retention_ms: 30 * 86_400_000,
            defaults: [],
            redact: :default,
            deliver: :now,
            on_error: nil,
            clock: nil,
            check_every: nil,
            jobs: []

  @known [
    :name,
    :store,
    :alerts,
    :triage,
    :transport,
    :sources,
    :cron_secret,
    :retention,
    :defaults,
    :redact,
    :deliver,
    :on_error,
    :clock,
    :check_every,
    :jobs
  ]

  @doc "The options, checked: {:ok, config} or {:error, %Cronwatch.Error{}}."
  def new(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, Cronwatch)

    with :ok <- known(opts),
         :ok <- check_name(name),
         {:ok, store, default?} <- store(Keyword.get(opts, :store), name),
         {:ok, alerts} <- alerts(Keyword.get(opts, :alerts)),
         {:ok, triage} <- triage(Keyword.get(opts, :triage)),
         :ok <- transport(Keyword.get(opts, :transport)),
         {:ok, retention} <- Options.duration_ms(Keyword.get(opts, :retention, "30d"), "retention"),
         defaults = Keyword.get(opts, :defaults, []),
         :ok <- Options.check_defaults(defaults),
         {:ok, redact} <- redact(Keyword.get(opts, :redact, :default)),
         {:ok, deliver} <- deliver(Keyword.get(opts, :deliver, :now)),
         {:ok, check_every} <- check_every(Keyword.get(opts, :check_every)),
         {:ok, cron_secret} <- cron_secret(opts) do
      {:ok,
       %__MODULE__{
         name: name,
         store: store,
         default_store: default?,
         alerts: alerts,
         triage: triage,
         transport: Keyword.get(opts, :transport),
         sources: Keyword.get(opts, :sources, []),
         cron_secret: cron_secret,
         retention_ms: retention,
         defaults: defaults,
         redact: redact,
         deliver: deliver,
         on_error: Keyword.get(opts, :on_error),
         clock: Keyword.get(opts, :clock),
         check_every: check_every,
         jobs: Keyword.get(opts, :jobs, [])
       }}
    end
  end

  defp known(opts) do
    case Enum.find(opts, fn {k, _} -> k not in @known end) do
      nil -> :ok
      {k, _} -> {:error, Error.invalid("Cronwatch: unknown option #{inspect(k)}")}
    end
  end

  defp check_name(name) when is_atom(name) and name not in [nil, true, false], do: :ok
  defp check_name(name), do: {:error, Error.invalid("Cronwatch: name must be an atom, not #{inspect(name)}")}

  defp store(nil, name), do: with({:ok, s, _} <- store(Cronwatch.Store.Memory, name), do: {:ok, s, true})
  defp store(module, name) when is_atom(module), do: store({module, []}, name)

  defp store({module, opts}, name) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      if function_exported?(module, :new, 2) do
        case module.new(opts, name) do
          {:ok, handle} -> {:ok, {module, handle}, false}
          {:error, message} -> {:error, Error.invalid(message)}
        end
      else
        {:ok, {module, opts}, false}
      end
    else
      {:error, Error.invalid("Cronwatch: store #{inspect(module)} is not a module")}
    end
  end

  defp store(other, _name),
    do: {:error, Error.invalid("Cronwatch: store must be {module, opts}, not #{inspect(other)}")}

  defp alerts(nil), do: alerts([Cronwatch.Alerts.Console])

  defp alerts(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn spec, {:ok, acc} ->
      case channel(spec) do
        {:ok, c} -> {:cont, {:ok, acc ++ [c]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp alerts(other), do: {:error, Error.invalid("Cronwatch: alerts must be a list of channels, not #{inspect(other)}")}

  defp channel(module) when is_atom(module), do: channel({module, []})

  defp channel({module, opts}) when is_atom(module) do
    Code.ensure_loaded(module)

    cond do
      not function_exported?(module, :send, 3) ->
        {:error, Error.invalid("Cronwatch: #{inspect(module)} is not an alert channel")}

      function_exported?(module, :init, 1) ->
        case module.init(opts) do
          {:ok, state} -> {:ok, {module, state}}
          {:error, message} -> {:error, Error.invalid(message)}
        end

      true ->
        {:ok, {module, opts}}
    end
  end

  defp channel(other), do: {:error, Error.invalid("Cronwatch: not an alert channel: #{inspect(other)}")}

  # Triage given as {module, opts} whose module has init/1 has its options
  # checked once, now, as a channel's are (Cronwatch.Triage.Anthropic
  # refuses to start without an API key, as the SDK's anthropic() throws).
  defp triage({module, opts}) when is_atom(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :init, 1) do
      case module.init(opts) do
        {:ok, state} -> {:ok, {module, state}}
        {:error, message} -> {:error, Error.invalid(message)}
      end
    else
      {:ok, {module, opts}}
    end
  end

  defp triage(module) when is_atom(module) and module not in [nil, true, false] do
    Code.ensure_loaded(module)
    if function_exported?(module, :init, 1), do: triage({module, []}), else: {:ok, module}
  end

  defp triage(other), do: {:ok, other}

  defp transport(spec) do
    case Cronwatch.Transport.check(spec, "Cronwatch") do
      :ok -> :ok
      {:error, message} -> {:error, Error.invalid(message)}
    end
  end

  defp redact(:default), do: {:ok, :default}
  defp redact(nil), do: {:ok, :default}
  defp redact(false), do: {:ok, false}
  defp redact(f) when is_function(f, 1), do: {:ok, f}

  defp redact(other),
    do: {:error, Error.invalid("Cronwatch: redact must be a function of one argument or false, not #{inspect(other)}")}

  defp deliver(d) when d in [:now, :check], do: {:ok, d}
  defp deliver(d) when d in ["now", "check"], do: {:ok, String.to_existing_atom(d)}

  defp deliver(other),
    do: {:error, Error.invalid(~s(deliver must be "now" or "check", not #{inspect(other)}))}

  # The SDK's start(every): at least five seconds, and at most setTimeout's
  # longest delay.
  @timer_max 2_147_483_647
  defp check_every(nil), do: {:ok, nil}

  defp check_every(every) do
    with {:ok, ms} <- Options.duration_ms(every, "check interval") do
      {:ok, ms |> max(5_000) |> min(@timer_max) |> Cronwatch.JS.to_int()}
    end
  end

  # A binary, false for none, or left out to read CRON_SECRET when a handler
  # needs it; "" counts as unset.
  defp cron_secret(opts) do
    case Keyword.fetch(opts, :cron_secret) do
      :error -> {:ok, :env}
      {:ok, nil} -> {:ok, :env}
      {:ok, false} -> {:ok, false}
      {:ok, s} when is_binary(s) -> {:ok, s}
      {:ok, other} -> {:error, Error.invalid("Cronwatch: cron_secret must be a string or false, not #{inspect(other)}")}
    end
  end

  ## At run time

  @doc "The config of a running instance."
  def get(name) do
    case :persistent_term.get({Cronwatch, name}, nil) do
      nil -> raise ArgumentError, "no Cronwatch instance named #{inspect(name)} is running"
      config -> config
    end
  end

  @doc false
  def put(%__MODULE__{name: name} = config), do: :persistent_term.put({Cronwatch, name}, config)

  @doc false
  def erase(name), do: :persistent_term.erase({Cronwatch, name})

  @doc "The instance's clock, in epoch milliseconds."
  def now(%__MODULE__{clock: nil}), do: System.system_time(:millisecond)
  def now(%__MODULE__{clock: f}) when is_function(f, 0), do: f.()
  def now(%__MODULE__{clock: m}) when is_atom(m), do: m.now()

  @doc "The error handler: the app's on_error, or Logger's error line."
  def report(%__MODULE__{} = c, error, where) do
    Cronwatch.Telemetry.error(c.name, where, error)

    try do
      case c.on_error do
        nil -> Logger.error("[cronwatch] #{where}: #{describe(error)}")
        f when is_function(f, 2) -> f.(error, where)
        f when is_function(f, 1) -> f.(error)
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  @doc false
  def describe(%Error{message: m}), do: m
  def describe(%{__exception__: true} = e), do: Exception.message(e)
  def describe(s) when is_binary(s), do: s
  def describe(other), do: inspect(other)

  @doc "The redaction applied to every stored output and error."
  def redact(%__MODULE__{redact: :default}, text), do: Output.redact_secrets(text)
  def redact(%__MODULE__{redact: false}, text), do: text

  def redact(%__MODULE__{redact: f} = c, text) do
    case f.(text) do
      out when is_binary(out) -> out
      other -> raise ArgumentError, "redact must return a string, not #{Read.kind(other)}"
    end
  rescue
    e ->
      # A broken redact must not stop the run finishing, nor leak what it
      # was given.
      report(c, e, "redact")
      Output.redact_secrets(text)
  catch
    kind, reason ->
      report(c, {kind, reason}, "redact")
      Output.redact_secrets(text)
  end
end
