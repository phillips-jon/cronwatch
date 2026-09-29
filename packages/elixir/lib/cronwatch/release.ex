defmodule Cronwatch.Release do
  @moduledoc """
  A check from a crontab line, for an app built as a release: the second of
  the two lines a plain crontab runs, beside the job itself.

      # m  h  dom mon dow  command
      0    2  *   *   *    /app/bin/my_app eval "MyApp.Nightly.main()"
      */5  *  *   *   *    /app/bin/my_app eval "Cronwatch.Release.check(MyApp.Cronwatch)"

  `check/2` starts what the check needs and nothing else (the store's Ecto
  repo, then an instance named `MyApp.Cronwatch` with the options the app
  keeps under `config :my_app, MyApp.Cronwatch` in `config/runtime.exs`),
  without starting the app's endpoint or queues, runs one check, prints what
  it did and stops what it started, as the Ecto migration helpers apps keep
  in `MyApp.Release` do. It exits non-zero when the check fails, so cron
  mails the failure. From source, `mix cronwatch.check` does the same.

  The instance's `check_every` and `integrations` are left out: the process
  checks once and ends.
  """

  @doc """
  Runs one check on the instance `name` with its configuration from the
  application environment, prints `cronwatch: checked 3 jobs, sent 1 alert`
  (or the failure, to standard error) and, on a failure, halts with status
  1. Options: `otp_app` (the application whose environment holds the
  configuration, found among the loaded applications when left out),
  `config` (the options themselves, in place of the environment's), and
  `halt: false` to answer the failure rather than halt.
  """
  @spec check(atom(), keyword()) :: {:ok, Cronwatch.CheckResult.t()} | {:error, Cronwatch.Error.t()}
  def check(name \\ Cronwatch, opts \\ []) do
    result = run(name, opts)

    case result do
      {:ok, r} ->
        jobs = length(r.jobs)
        alerts = length(r.alerts)
        IO.puts("cronwatch: checked #{jobs} job#{plural(jobs)}, sent #{alerts} alert#{plural(alerts)}")

      {:error, e} ->
        IO.puts(:stderr, "cronwatch: the check failed: #{Cronwatch.Config.describe(e)}")
        if Keyword.get(opts, :halt, true), do: System.halt(1)
    end

    result
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp run(name, opts) do
    with {:ok, config} <- config(name, opts),
         {:ok, _} <- Application.ensure_all_started(:cronwatch),
         {:ok, repos} <- start_repos(config) do
      try do
        config = config |> Keyword.drop([:check_every, :integrations]) |> Keyword.put(:name, name)

        case Cronwatch.Supervisor.start_link(config) do
          {:ok, sup} ->
            try do
              Cronwatch.check(instance: name)
            after
              stop(sup)
            end

          {:error, %Cronwatch.Error{} = e} ->
            {:error, e}

          {:error, reason} ->
            {:error, Cronwatch.Error.other("the instance did not start: #{inspect(reason)}")}
        end
      after
        Enum.each(repos, &stop/1)
      end
    end
  end

  defp config(name, opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} when is_list(config) ->
        {:ok, config}

      _ ->
        found =
          case Keyword.fetch(opts, :otp_app) do
            {:ok, app} ->
              Application.get_env(app, name)

            :error ->
              Enum.find_value(Application.loaded_applications(), fn {app, _, _} -> Application.get_env(app, name) end)
          end

        if is_list(found) do
          {:ok, found}
        else
          {:error,
           Cronwatch.Error.invalid(
             "no configuration for #{inspect(name)}: put `config :my_app, #{inspect(name)}, store: ...` " <>
               "in config/runtime.exs, or pass otp_app: or config:"
           )}
        end
    end
  end

  # The store's Ecto repo, started as the Ecto migrator starts one, unless
  # it is running already; answers the ones this started.
  defp start_repos(config) do
    case Keyword.get(config, :store) do
      {Cronwatch.Store.Ecto, store_opts} when is_list(store_opts) ->
        repo = Keyword.fetch!(store_opts, :repo)

        with {:ok, _} <- Application.ensure_all_started(:ecto_sql),
             {:ok, _} <- repo.__adapter__().ensure_all_started(repo.config(), :temporary) do
          # Two connections at most, as the Ecto migrator starts a repo.
          case repo.start_link(pool_size: min(Keyword.get(repo.config(), :pool_size, 2), 2)) do
            {:ok, pid} -> {:ok, [pid]}
            {:error, {:already_started, _}} -> {:ok, []}
            {:error, reason} -> {:error, Cronwatch.Error.store(reason)}
          end
        else
          {:error, reason} -> {:error, Cronwatch.Error.other("the repo could not start: #{inspect(reason)}")}
        end

      _ ->
        {:ok, []}
    end
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end
end
