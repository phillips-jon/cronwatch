defmodule Cronwatch.Job do
  @moduledoc """
  A declared job's handle, as `Cronwatch.job/2` answers it: the instance it
  belongs to, its name, and its definition. `definition` is the stored JSON
  object (a `Cronwatch.JS.Object`, fields in the order given, `expect`
  described last); `expect` is the rule itself, as the options give it.
  """

  alias Cronwatch.JS.Object

  @enforce_keys [:instance, :name, :fields, :definition]
  defstruct [:instance, :name, :fields, :definition, expect: nil]

  @type t :: %__MODULE__{
          instance: atom(),
          name: String.t(),
          fields: Object.t(),
          definition: Object.t(),
          expect: rule() | nil
        }

  @typedoc "An `expect` rule, as `Cronwatch.job/2` reads it from the options."
  @type rule :: {:contains, String.t()} | {:matches, term()} | {:fun, (String.t() -> term())}

  @doc false
  def new(instance, name, options, defaults) do
    with {:ok, {fields, rule}} <- Cronwatch.Options.definition(name, options, defaults) do
      {:ok,
       %__MODULE__{
         instance: instance,
         name: name,
         fields: fields,
         expect: rule,
         definition: Cronwatch.Serialize.to_stored(fields, rule)
       }}
    end
  end

  defimpl Inspect do
    def inspect(job, _opts), do: "#Cronwatch.Job<#{job.name}>"
  end
end

defmodule Cronwatch.Context do
  @moduledoc """
  What a job's function is given: the run it is part of. Pass it to
  `Cronwatch.log/2`, `Cronwatch.metric/3`, and `Cronwatch.cancelled?/1`;
  `Cronwatch.current/0` finds it from the calling process, or from the
  process that started it (a `Task`).
  """

  @enforce_keys [:instance, :job, :run_id, :started_at, :key, :cancel]
  defstruct [:instance, :job, :run_id, :started_at, :key, :cancel, trigger: "run"]

  @type t :: %__MODULE__{
          instance: atom(),
          job: String.t(),
          run_id: String.t(),
          started_at: integer(),
          key: term(),
          cancel: :atomics.atomics_ref(),
          trigger: String.t()
        }

  @stack :"$cronwatch_runs"

  @doc false
  def push(ctx) do
    Process.put(@stack, [ctx | Process.get(@stack, [])])
  end

  @doc false
  def pop do
    case Process.get(@stack, []) do
      [_ | rest] when rest != [] -> Process.put(@stack, rest)
      _ -> Process.delete(@stack)
    end
  end

  @doc """
  The calling process's run, or the run of the process that started it
  (through `$callers`, which `Task` sets), or nil.
  """
  @spec current() :: t() | nil
  def current do
    case Process.get(@stack) do
      [ctx | _] ->
        ctx

      _ ->
        Enum.find_value(Process.get(:"$callers", []), fn pid ->
          case caller_stack(pid) do
            [ctx | _] -> ctx
            _ -> nil
          end
        end)
    end
  end

  # Only the one key is read, not the caller's whole dictionary; a caller on
  # another node (a Task started from there) cannot be asked, and has no run
  # here.
  defp caller_stack(pid) when is_pid(pid) and node(pid) == node() do
    case :erlang.process_info(pid, {:dictionary, @stack}) do
      {{:dictionary, @stack}, stack} when is_list(stack) -> stack
      _ -> nil
    end
  end

  defp caller_stack(_), do: nil

  defimpl Inspect do
    def inspect(ctx, _opts), do: "#Cronwatch.Context<#{ctx.job} #{ctx.run_id}>"
  end
end
