defmodule Cronwatch.Telemetry do
  @moduledoc """
  The `:telemetry` events CronWatch emits, named in one place.

    * `[:cronwatch, :run, :start | :stop | :exception]`: a span around a
      job's function, with `:instance`, `:job`, `:run` (the run's id) and
      `:trigger` in the metadata and, on `:stop`, the run's `:status`.
    * `[:cronwatch, :check, :start | :stop | :exception]`: a span around a
      check, with the counts of its result (`:jobs`, `:alerts`, `:pruned`)
      in the `:stop` metadata.
    * `[:cronwatch, :alert, :sent | :failed | :queued | :dropped]`: one per
      channel and alert (`:sent` and `:failed`) or per alert (`:queued` for
      one kept for the next check, `:dropped` for one no longer worth
      sending), with `:instance`, `:job`, `:type`, `:condition` (nil for a
      recovery) and `:channel` in the metadata.
    * `[:cronwatch, :error]`: whatever the error handler hears, with
      `:instance`, `:where` (`recording nightly-report`, the SDK's text) and
      `:error` in the metadata.
  """

  @doc false
  def run_span(meta, fun), do: :telemetry.span([:cronwatch, :run], meta, fun)

  @doc false
  def check_span(meta, fun), do: :telemetry.span([:cronwatch, :check], meta, fun)

  @doc false
  def alert(event, meta), do: :telemetry.execute([:cronwatch, :alert, event], %{count: 1}, meta)

  @doc false
  def error(instance, where, error) do
    :telemetry.execute([:cronwatch, :error], %{count: 1}, %{instance: instance, where: where, error: error})
  end
end
