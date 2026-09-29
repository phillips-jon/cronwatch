defmodule Cronwatch.Store do
  @moduledoc """
  Where jobs, runs and state live: the SDK's `Store`, as a behaviour.

  A store is given to an instance as `{module, opts}`. The instance calls
  `c:new/2` once, when it starts, with the options and its own name; what
  that answers (the store's handle) is the first argument of every other
  callback. A store that needs a process of its own (`Cronwatch.Store.Memory`)
  defines `c:child_spec/1`, which is given the handle, and is started under
  the instance before anything else. `c:init/1` is called once before first
  use, to create tables.

  Every callback answers `{:ok, value}` or `{:error, reason}`; a raise, throw
  or exit in one is taken as its error. Names are the SDK's in snake_case.
  The three conditional writes are optional: without `c:update_run_if/3` or
  `c:compare_and_set_state/3` the client falls back to a read and a write,
  as the SDK does, and without `c:delete_run_if/4` a run given back is
  recorded as it ended.

  `Cronwatch.StoreCase` is the contract test every store passes, for a store
  of the app's own.
  """

  alias Cronwatch.JobState
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.StoredJob

  @type handle :: term()
  @type reason :: term()

  @doc "Checks the options and answers the handle every other callback is given."
  @callback new(opts :: keyword(), instance :: atom()) :: {:ok, handle()} | {:error, String.t()}

  @doc "The process the store needs, started under the instance."
  @callback child_spec(handle()) :: Supervisor.child_spec()

  @doc "Called once before first use. Create tables here."
  @callback init(handle()) :: :ok | {:error, reason()}

  @doc "Writes a job's stored definition; `created_at` is kept from the first write."
  @callback upsert_job(handle(), definition :: Object.t(), now :: integer()) :: :ok | {:error, reason()}

  @doc "The job, or nil when the store does not know it."
  @callback get_job(handle(), name :: String.t()) :: {:ok, StoredJob.t() | nil} | {:error, reason()}

  @doc "Every job, by name in byte order."
  @callback list_jobs(handle()) :: {:ok, [StoredJob.t()]} | {:error, reason()}

  @doc "Removes a job, its runs and its state."
  @callback delete_job(handle(), name :: String.t()) :: :ok | {:error, reason()}

  @doc "Inserts a run; refuses an id already stored."
  @callback insert_run(handle(), Run.t()) :: :ok | {:error, reason()}

  @doc "Writes a run's status, finish, duration, error, output and metrics. A run that is gone stays gone."
  @callback update_run(handle(), Run.t()) :: :ok | {:error, reason()}

  @doc """
  Writes the run as `c:update_run/2` does, only when its stored status is one
  of `from`, in one step, and says whether it wrote. This is what lets exactly
  one of several processes finishing the same run evaluate it.
  """
  @callback update_run_if(handle(), Run.t(), from :: [String.t()]) :: {:ok, boolean()} | {:error, reason()}

  @doc """
  Deletes the run `id` only when its stored job is `job` and its status is
  `status`, and says whether it deleted: how an attempt a queue gave back
  without failing leaves no run behind.
  """
  @callback delete_run_if(handle(), id :: String.t(), job :: String.t(), status :: String.t()) ::
              {:ok, boolean()} | {:error, reason()}

  @doc "The run, or nil."
  @callback get_run(handle(), id :: String.t()) :: {:ok, Run.t() | nil} | {:error, reason()}

  @doc "A job's newest runs first, at most `limit` of them."
  @callback list_runs(handle(), job :: String.t(), limit :: non_neg_integer()) :: {:ok, [Run.t()]} | {:error, reason()}

  @doc "A job's newest run, or nil."
  @callback last_run(handle(), job :: String.t()) :: {:ok, Run.t() | nil} | {:error, reason()}

  @doc "Every run still running, oldest first."
  @callback running_runs(handle()) :: {:ok, [Run.t()]} | {:error, reason()}

  @doc "The job's state, or nil when it has none yet."
  @callback get_state(handle(), job :: String.t()) :: {:ok, JobState.t() | nil} | {:error, reason()}

  @doc "Writes a job's state unconditionally. Used only when `c:compare_and_set_state/3` is missing."
  @callback set_state(handle(), JobState.t()) :: :ok | {:error, reason()}

  @doc """
  Writes `state` only when the stored state's version (absent, or no row at
  all, counts as 0) equals `expected_version`, and says whether it wrote.
  """
  @callback compare_and_set_state(handle(), JobState.t(), expected_version :: integer()) ::
              {:ok, boolean()} | {:error, reason()}

  @doc "Deletes finished runs that started before this time, keeping each job's newest run; answers how many."
  @callback prune(handle(), before :: integer()) :: {:ok, non_neg_integer()} | {:error, reason()}

  @doc "Lets go of anything the store holds."
  @callback close(handle()) :: :ok | {:error, reason()}

  @optional_callbacks new: 2,
                      child_spec: 1,
                      init: 1,
                      update_run_if: 3,
                      delete_run_if: 4,
                      compare_and_set_state: 3,
                      close: 1

  @typedoc "A store as the client holds it: the module and its handle."
  @type t :: {module(), handle()}

  @doc false
  # Calls a store callback, turning a raise, throw or exit into its error.
  def call({module, handle}, fun, args) do
    apply(module, fun, [handle | args])
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  @doc false
  def has?({module, _}, fun, arity) do
    Code.ensure_loaded(module)
    function_exported?(module, fun, arity + 1)
  end
end
