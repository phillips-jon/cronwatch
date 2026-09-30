defmodule Cronwatch.Evaluate do
  @moduledoc false
  # Pure decisions about a job's health (evaluate.ts). Each function takes
  # the current state and returns the new state plus the alerts that should
  # go out, as drafts `{type, run, details}`. Nothing here touches a store or
  # a network, which is what makes it testable and what lets
  # conformance/evaluate.json replay a job's life through it event by event.
  #
  # A definition is the stored JSON object (a Cronwatch.JS.Object), which may
  # hold anything another writer put there, so a field is read as JavaScript
  # would read it and a bad one is an {:error, message}.

  alias Cronwatch.Duration
  alias Cronwatch.Format
  alias Cronwatch.JobState
  alias Cronwatch.JobSummary
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Schedule
  alias Cronwatch.Stats
  alias Cronwatch.StoredJob

  @default_grace_ms 10 * 60_000
  @default_timeout_ms 60 * 60_000
  # Runs faster than this are never called slow, whatever the baseline says.
  @slow_floor_ms 10_000
  # How many earlier runs a baseline needs before it is trusted.
  @baseline_min_runs 5
  # How many successful runs a baseline looks at, and how many runs a summary
  # covers.
  @baseline_window 20

  def default_grace_ms, do: @default_grace_ms
  def default_timeout_ms, do: @default_timeout_ms
  def baseline_window, do: @baseline_window

  def empty_state(job), do: %JobState{job: job, pending_recovery: [], undelivered: []}

  @doc "A stored state with every field present, or a fresh one."
  def normalize_state(nil, job), do: empty_state(job)

  def normalize_state(%JobState{} = s, job) do
    %{
      s
      | job: if(s.job == "", do: job, else: s.job),
        consecutive_failures: JobState.failure_count(s.consecutive_failures),
        pending_recovery: s.pending_recovery || [],
        undelivered: s.undelivered || []
    }
  end

  defp clone(%JobState{} = s), do: normalize_state(s, s.job)

  defp open_condition(s, c, now) do
    if List.keymember?(s.open, c, 0), do: {s, false}, else: {%{s | open: s.open ++ [{c, now}]}, true}
  end

  # Closes a condition. Every open condition has alerted, so closing one owes
  # a recovered message; it is remembered until a successful run leaves
  # nothing open and sends it.
  defp close_condition(s, c) do
    if List.keymember?(s.open, c, 0) do
      pending = s.pending_recovery || []
      pending = if c in pending, do: pending, else: pending ++ [c]
      %{s | open: List.keydelete(s.open, c, 0), pending_recovery: pending}
    else
      s
    end
  end

  def open_conditions(%JobState{open: open}), do: Enum.map(open, &elem(&1, 0))

  # A duration option of a definition, or the default when it is absent. A
  # present null is an error, as JavaScript's parseDuration(null) throws.
  defp duration_field(def, key, fallback) do
    case Object.fetch(def, key) do
      :error -> {:ok, fallback}
      {:ok, v} -> Duration.parse(v, key)
    end
  end

  def grace_ms(def), do: duration_field(def, "grace", @default_grace_ms)
  def timeout_ms(def), do: duration_field(def, "timeout", @default_timeout_ms)

  @doc "The slow threshold for a successful run and its basis, or nil when there is nothing to compare against yet."
  def slow_threshold(def, history) do
    case Object.fetch(def, "maxDuration") do
      {:ok, v} ->
        with {:ok, ms} <- Duration.parse(v, "maxDuration"), do: {:ok, {ms, "maxDuration"}}

      :error ->
        durations =
          history
          |> Enum.filter(&(&1.status == "ok" and &1.duration_ms != nil))
          |> Enum.take(@baseline_window)
          |> Enum.map(& &1.duration_ms)

        if length(durations) < @baseline_min_runs do
          {:ok, nil}
        else
          p95 = Stats.percentile(durations, 95)

          {:ok,
           {max(2 * p95, @slow_floor_ms),
            "twice the p95 of the last #{length(durations)} runs (#{Duration.format(p95)})"}}
        end
    end
  end

  # The run's metrics over their ceiling, or, without one, over three times
  # the job's usual value.
  defp budget_breaches(def, %Run{} = run, history) do
    budget =
      case Object.get(def, "budget") do
        %Object{} = b -> b
        _ -> nil
      end

    Enum.flat_map(run.metrics.pairs, fn {name, value} ->
      case budget && Object.fetch(budget, name) do
        {:ok, v} ->
          limit = js_number(v)
          if gt(value, limit), do: [%{metric: name, value: value, limit: limit, basis: "budget"}], else: []

        _ ->
          past =
            history
            |> Enum.filter(&(&1.status == "ok"))
            |> Enum.flat_map(fn r ->
              case Object.fetch(r.metrics, name) do
                {:ok, m} when is_number(m) -> [m]
                _ -> []
              end
            end)
            |> Enum.take(@baseline_window)

          with true <- length(past) >= @baseline_min_runs,
               usual = Stats.median(past),
               true <- usual > 0 and gt(value, 3 * usual) do
            [
              %{
                metric: name,
                value: value,
                limit: JS.normalize(3 * usual),
                basis: "three times the usual #{Format.format_number(usual)}"
              }
            ]
          else
            _ -> []
          end
      end
    end)
  end

  # `a > b` over JavaScript numbers, NaN comparing false.
  defp gt(a, b) when is_number(a) and is_number(b), do: a > b
  defp gt(:infinity, b), do: b not in [:infinity, :nan]
  defp gt(a, :neg_infinity), do: a not in [:neg_infinity, :nan]
  defp gt(_, _), do: false

  @doc "JavaScript's `Number(v)` for a JSON value, as a comparison with `>` coerces one."
  def js_number(n) when is_number(n), do: n
  def js_number(n) when n in [:infinity, :neg_infinity, :nan], do: n
  def js_number(nil), do: 0
  def js_number(true), do: 1
  def js_number(false), do: 0

  def js_number(s) when is_binary(s) do
    case JS.trim(s) do
      "" -> 0
      text -> string_to_number(text)
    end
  end

  def js_number(_), do: :nan

  # `Number(text)` for trimmed, non-empty text: decimal, Infinity, and the
  # 0x, 0o and 0b integer forms; anything else is NaN.
  defp string_to_number(text) do
    {sign, body} =
      case text do
        "-" <> rest -> {-1, rest}
        "+" <> rest -> {1, rest}
        _ -> {1, text}
      end

    radix =
      case body do
        <<?0, x, _::binary>> when x in [?x, ?X] -> 16
        <<?0, x, _::binary>> when x in [?o, ?O] -> 8
        <<?0, x, _::binary>> when x in [?b, ?B] -> 2
        _ -> 10
      end

    cond do
      body == "Infinity" ->
        if sign < 0, do: :neg_infinity, else: :infinity

      radix != 10 ->
        digits = binary_part(body, 2, byte_size(body) - 2)

        if sign < 0 or String.starts_with?(text, "+") or digits == "" do
          :nan
        else
          case Integer.parse(digits, radix) do
            {n, ""} -> JS.normalize(JS.to_float(n))
            _ -> :nan
          end
        end

      body != "" and not String.starts_with?(body, ["+", "-"]) and
        String.match?(body, ~r/\A[0-9.eE+-]+\z/) and String.match?(body, ~r/[0-9]/) ->
        case Float.parse(normalize_decimal(body)) do
          {f, ""} -> JS.normalize(sign * f)
          _ -> :nan
        end

      true ->
        :nan
    end
  end

  # Float.parse wants digits before and after a point; JavaScript takes
  # "5.", ".5" and "1e3".
  defp normalize_decimal(body) do
    body = if String.starts_with?(body, "."), do: "0" <> body, else: body
    String.replace(body, ~r/\.(?=[eE]|\z)/, ".0")
  end

  @doc """
  Called when a run starts. Missed and stuck are about the absence of a run,
  so a run starting closes them without an alert; the recovered message
  waits for a successful finish.
  """
  def on_run_start(state) do
    state |> clone() |> close_condition("missed") |> close_condition("stuck")
  end

  # Math.max(1, def.failuresBeforeAlert ?? 1)
  defp failures_before_alert(def) do
    case Object.get(def, "failuresBeforeAlert") do
      nil -> 1
      v -> v |> js_number() |> max_one()
    end
  end

  defp max_one(:nan), do: :nan
  defp max_one(:infinity), do: :infinity
  defp max_one(:neg_infinity), do: 1
  defp max_one(n), do: if(n < 1, do: 1, else: n)

  @doc """
  Called when a run finishes with status ok, failed or timeout. `history` is
  the job's earlier runs, newest first, not including this one. Answers
  `{:ok, {state, drafts}}`.
  """
  def on_run_finish(def, %Run{} = run, state, history, now) do
    next = clone(state)

    if run.status == "ok" do
      next = %{next | consecutive_failures: 0}
      next = next |> close_condition("missed") |> close_condition("stuck") |> close_condition("failed")

      with {:ok, slow} <- slow_threshold(def, history) do
        {next, alerts} =
          case slow do
            {threshold, basis} when run.duration_ms != nil ->
              if run.duration_ms > threshold do
                case open_condition(next, "slow", now) do
                  {next, true} ->
                    {next, [{"slow", run, %{duration_ms: run.duration_ms, threshold_ms: threshold, basis: basis}}]}

                  {next, false} ->
                    {next, []}
                end
              else
                {close_condition(next, "slow"), []}
              end

            _ ->
              {close_condition(next, "slow"), []}
          end

        {next, alerts} =
          case budget_breaches(def, run, history) do
            [] ->
              {close_condition(next, "over_budget"), alerts}

            breaches ->
              case open_condition(next, "over_budget", now) do
                {next, true} -> {next, alerts ++ [{"over_budget", run, %{breaches: breaches}}]}
                {next, false} -> {next, alerts}
              end
          end

        {next, alerts} =
          if next.pending_recovery != [] and next.open == [] do
            {%{next | pending_recovery: []},
             alerts ++ [{"recovered", run, %{after: next.pending_recovery, reason: nil, since: nil}}]}
          else
            {next, alerts}
          end

        {:ok, {next, alerts}}
      end
    else
      # failed or timeout
      # Held at 2^53 - 1: a count at the limit stays at the top.
      next = %{next | consecutive_failures: JobState.add_failure(next.consecutive_failures)}
      next = close_condition(next, "missed")
      threshold = failures_before_alert(def)
      condition = if run.status == "timeout", do: "stuck", else: "failed"

      if reached?(next.consecutive_failures, threshold) do
        case open_condition(next, condition, now) do
          {next, true} ->
            details = %{consecutive_failures: next.consecutive_failures, threshold: JS.to_int(threshold)}
            {:ok, {next, [{condition, run, details}]}}

          {next, false} ->
            {:ok, {next, []}}
        end
      else
        {:ok, {next, []}}
      end
    end
  end

  defp reached?(_n, :nan), do: false
  defp reached?(_n, :infinity), do: false
  defp reached?(n, threshold), do: n >= threshold

  @doc """
  `parseSchedule(def.schedule, def.timezone)` for a stored definition, which
  may hold anything another writer put there.
  """
  def parsed_schedule(def) do
    case Object.get(def, "schedule") do
      text when is_binary(text) ->
        case Object.get(def, "timezone") do
          nil -> Schedule.parse(text, nil)
          tz when is_binary(tz) -> Schedule.parse(text, if(tz == "", do: nil, else: tz))
          v -> {:error, "timezone #{JS.stringify(v)} is not an IANA timezone"}
        end

      _ ->
        {:error, "schedule.trim is not a function"}
    end
  end

  @doc """
  Called by a check. It decides whether the schedule has been missed: the run
  the schedule wants next has not started and its grace has run out.
  `last_run` is the most recent run of any status. A job with no schedule is
  never missed, and one whose schedule was removed while missed was open
  gets a recovered alert (reason `unscheduled`) for missed alone. Answers
  `{:ok, {{state, drafts}, next_expected_at, due_at}}`.
  """
  def on_check(def, %StoredJob{} = stored, last_run, state, now) do
    next = clone(state)

    if Format.truthy?(Object.get(def, "schedule")) do
      check_schedule(def, stored, last_run, next, now)
    else
      case JobState.open_at(next, "missed") do
        nil ->
          {:ok, {{next, []}, nil, nil}}

        since ->
          # The schedule went away while missed was open, so nothing is due
          # any more. Missed closes now with a recovery of its own; other
          # open conditions keep their own rules. Missed is taken out of the
          # pending recovery too, so the next successful run does not name it
          # again.
          next = %{
            next
            | open: List.keydelete(next.open, "missed", 0),
              pending_recovery: Enum.reject(next.pending_recovery, &(&1 == "missed"))
          }

          draft = {"recovered", last_run, %{after: ["missed"], reason: "unscheduled", since: since}}
          {:ok, {{next, [draft]}, nil, nil}}
      end
    end
  end

  defp check_schedule(def, stored, last_run, next, now) do
    with {:ok, parsed} <- parsed_schedule(def),
         {:ok, grace} <- grace_ms(def) do
      last_run_at = if last_run, do: last_run.started_at
      interval? = parsed.kind == "interval"

      next_expected_at =
        if interval?,
          do: Schedule.next_fire(parsed, stored.created_at, last_run_at),
          else: Schedule.next_fire(parsed, now, nil)

      case Schedule.expectation(parsed, last_run_at, stored.created_at, grace) do
        nil ->
          {:ok, {{next, []}, next_expected_at, nil}}

        %{due_at: due_at, deadline: deadline} ->
          cond do
            # An interval's next run is due a period after the last one
            # started. If that run is still going, the job is busy, not
            # late; stuck covers one that never ends.
            interval? and last_run != nil and last_run.status == "running" ->
              {:ok, {{next, []}, next_expected_at, due_at}}

            now > deadline ->
              case open_condition(next, "missed", now) do
                {next, true} ->
                  details = %{due_at: due_at, deadline: deadline, grace_ms: grace, last_run_at: last_run_at}
                  {:ok, {{next, [{"missed", last_run, details}]}, next_expected_at, due_at}}

                {next, false} ->
                  {:ok, {{next, []}, next_expected_at, due_at}}
              end

            true ->
              # A run has started since it opened, or the grace was widened.
              {:ok, {{close_condition(next, "missed"), []}, next_expected_at, due_at}}
          end
      end
    end
  end

  @max_duration_ms 9_007_199_254_740_991

  @doc "The longest duration written: 2^53 - 1, which every port and store reads back unchanged."
  def max_duration_ms, do: @max_duration_ms

  @doc """
  How long a run took, from `started_at` to `finished_at`: 0 when it started
  later, and never more than 2^53 - 1. A foreign row's start near a 64-bit
  limit must not make a duration no store can write.
  """
  @spec run_duration(integer(), integer()) :: non_neg_integer()
  def run_duration(started_at, finished_at) do
    ms = finished_at - started_at
    if ms > 0, do: min(ms, @max_duration_ms), else: 0
  end

  @doc "Whether a running run has gone on longer than the job's timeout."
  def stuck?(def, %Run{} = run, now) do
    if run.status != "running" do
      {:ok, false}
    else
      with {:ok, timeout} <- timeout_ms(def), do: {:ok, now - run.started_at > timeout}
    end
  end

  @doc """
  `next` with nothing opened that was not open in `previous`: while a job is
  silenced, conditions may close but none may open.
  """
  def mute_opens(%JobState{} = previous, %JobState{} = next) do
    muted = clone(next)
    %{muted | open: Enum.filter(muted.open, fn {c, _} -> List.keymember?(previous.open, c, 0) end)}
  end

  def silenced?(%JobState{silenced_until: until}, now), do: until != nil and until > now

  @doc "An evaluation as it is saved and sent: while the job was silenced when it began, nothing opens and nothing is sent."
  def apply_silence(previous, {state, alerts}, now) do
    if silenced?(previous, now), do: {mute_opens(previous, state), []}, else: {state, alerts}
  end

  @doc """
  Whether an alert waiting to be retried no longer describes the job, so it
  is dropped rather than sent late.
  """
  def stale_alert?(%{type: "recovered", details: details}, state) do
    Enum.any?(Map.get(details, :after, []), &(JobState.open_at(state, &1) != nil))
  end

  def stale_alert?(%{type: type, at: at}, state), do: JobState.open_at(state, type) != at

  @doc "How a job looks at a glance. Silence wins, then stuck, failing and late."
  def job_health(def, last_run, state, now) do
    open = open_conditions(state)

    cond do
      silenced?(state, now) ->
        {:ok, "silenced"}

      "stuck" in open ->
        {:ok, "stuck"}

      true ->
        stuck =
          case last_run do
            nil -> {:ok, false}
            run -> stuck?(def, run, now)
          end

        with {:ok, stuck} <- stuck do
          cond do
            stuck -> {:ok, "stuck"}
            "failed" in open or (last_run != nil and last_run.status in ["failed", "timeout"]) -> {:ok, "failing"}
            "missed" in open -> {:ok, "late"}
            last_run == nil -> {:ok, "never_ran"}
            true -> {:ok, "healthy"}
          end
        end
    end
  end

  @doc """
  A job's summary from its most recent runs (newest first; the first twenty
  are used) and its state.
  """
  def summarize(%StoredJob{} = stored, recent, state, next_expected_at, now) do
    window = Enum.take(recent, @baseline_window)

    with {:ok, health} <- job_health(stored.definition, List.first(window), state, now) do
      {:ok, summary(stored, recent, state, next_expected_at, health)}
    end
  end

  @doc """
  The summary of a job that could not be evaluated, say because its stored
  schedule no longer parses: failing (or silenced, while it is), and nothing
  known about when it is next due.
  """
  def unevaluable_summary(%StoredJob{} = stored, recent, state, now) do
    summary(stored, recent, state, nil, if(silenced?(state, now), do: "silenced", else: "failing"))
  end

  defp summary(stored, recent, state, next_expected_at, health) do
    window = Enum.take(recent, @baseline_window)
    finished = Enum.count(window, &(&1.status != "running"))
    ok = Enum.count(window, &(&1.status == "ok"))
    ok_durations = for r <- window, r.status == "ok", r.duration_ms != nil, do: r.duration_ms

    %JobSummary{
      name: stored.name,
      definition: stored.definition,
      health: health,
      open: open_conditions(state),
      last_run: List.first(window),
      next_expected_at: next_expected_at,
      consecutive_failures: state.consecutive_failures,
      silenced_until: state.silenced_until,
      stats: %{
        runs: finished,
        ok_rate: if(finished > 0, do: JS.normalize(ok / finished), else: 1),
        p50_ms: ok_durations |> Stats.percentile(50) |> maybe_int(),
        p95_ms: ok_durations |> Stats.percentile(95) |> maybe_int()
      }
    }
  end

  defp maybe_int(nil), do: nil
  defp maybe_int(n), do: JS.to_int(n)
end
