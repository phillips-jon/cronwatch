defmodule Cronwatch.RunStatus do
  @moduledoc """
  Where a run stands, as the SDK writes it: `"running"`, `"ok"`, `"failed"`
  or `"timeout"`. Statuses are strings, never atoms, since stored values come
  from other writers and a newer SDK may add one.
  """

  @doc false
  def all, do: ["running", "ok", "failed", "timeout"]

  @doc ~s("running")
  @spec running() :: String.t()
  def running, do: "running"
  @doc ~s("ok")
  @spec ok() :: String.t()
  def ok, do: "ok"
  @doc ~s("failed")
  @spec failed() :: String.t()
  def failed, do: "failed"
  @doc ~s("timeout")
  @spec timeout() :: String.t()
  def timeout, do: "timeout"
end

defmodule Cronwatch.Condition do
  @moduledoc """
  Something wrong with a job that opens once, alerts, and closes with a
  recovery, as the SDK writes it, in the SDK's order: `"missed"`, `"failed"`,
  `"stuck"`, `"slow"`, `"over_budget"` and `"under_floor"`.
  """

  @doc "Every condition, in the SDK's order."
  @spec all() :: [String.t()]
  def all, do: ["missed", "failed", "stuck", "slow", "over_budget", "under_floor"]

  @doc ~s("missed")
  @spec missed() :: String.t()
  def missed, do: "missed"
  @doc ~s("failed")
  @spec failed() :: String.t()
  def failed, do: "failed"
  @doc ~s("stuck")
  @spec stuck() :: String.t()
  def stuck, do: "stuck"
  @doc ~s("slow")
  @spec slow() :: String.t()
  def slow, do: "slow"
  @doc ~s("over_budget")
  @spec over_budget() :: String.t()
  def over_budget, do: "over_budget"
  @doc ~s("under_floor")
  @spec under_floor() :: String.t()
  def under_floor, do: "under_floor"
end

defmodule Cronwatch.AlertType do
  @moduledoc "A condition opening, or `\"recovered\"`, as the SDK writes it."

  @doc ~s("recovered")
  @spec recovered() :: String.t()
  def recovered, do: "recovered"
end

defmodule Cronwatch.Health do
  @moduledoc """
  How a job looks at a glance, as the SDK writes it: `"healthy"`, `"late"`,
  `"failing"`, `"stuck"`, `"silenced"` or `"never_ran"`.
  """

  @doc false
  def all, do: ["healthy", "late", "failing", "stuck", "silenced", "never_ran"]
end
