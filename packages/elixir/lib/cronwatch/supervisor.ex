defmodule Cronwatch.Supervisor do
  @moduledoc false
  # An instance's processes, :rest_for_one: the store's process (when it has
  # one), Cronwatch.Runs (the tables and the monitor on runs in flight),
  # Cronwatch.Locks, a Task.Supervisor for the work done off the caller's
  # path, and Cronwatch.Checker. The options are checked, and the jobs
  # given in `jobs:` declared, before any of them starts, so a bad option
  # fails the app's boot with the SDK's message.

  use Supervisor

  alias Cronwatch.Config
  alias Cronwatch.Job

  def start_link(opts) do
    with {:ok, config} <- Config.new(opts),
         {:ok, jobs} <- declare(config) do
      config = %{config | jobs: jobs}
      Supervisor.start_link(__MODULE__, config, name: Module.concat(config.name, Supervisor))
    else
      {:error, %Cronwatch.Error{} = e} -> {:error, e}
    end
  end

  defp declare(config) do
    Enum.reduce_while(config.jobs, {:ok, []}, fn
      {name, options}, {:ok, acc} ->
        case Job.new(config.name, name, options, config.defaults) do
          {:ok, job} -> {:cont, {:ok, [job | Enum.reject(acc, &(&1.name == name))]}}
          {:error, _} = e -> {:halt, e}
        end

      name, {:ok, acc} when is_binary(name) ->
        case Job.new(config.name, name, [], config.defaults) do
          {:ok, job} -> {:cont, {:ok, [job | Enum.reject(acc, &(&1.name == name))]}}
          {:error, _} = e -> {:halt, e}
        end

      other, _ ->
        {:halt, {:error, Cronwatch.Error.invalid("Cronwatch: jobs must be {name, options}, not #{inspect(other)}")}}
    end)
  end

  @doc false
  def tasks(instance), do: Module.concat(instance, Tasks)

  @impl true
  def init(config) do
    Config.put(config)
    {module, handle} = config.store
    Code.ensure_loaded(module)

    store =
      if function_exported?(module, :child_spec, 1) and not match?(%{owned: false}, handle) and
           owns_process?(module, handle),
         do: [module.child_spec(handle)],
         else: []

    children =
      store ++
        [
          {Cronwatch.Runs, config.name},
          {Cronwatch.Locks, config.name},
          {Task.Supervisor, name: tasks(config.name)},
          {Cronwatch.Checker, config.name}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # A store module may define child_spec/1 for its own use in an app's tree
  # (the memory store started on its own); the instance starts it only for a
  # handle that asks for a process.
  defp owns_process?(Cronwatch.Store.Memory, handle), do: Cronwatch.Store.Memory.owned?(handle)
  defp owns_process?(_module, _handle), do: true
end
