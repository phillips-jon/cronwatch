# frozen_string_literal: true

module Cronwatch
  # Pure decisions about a job's health. Each function takes the current state
  # and returns the new state plus the alerts that should go out. Nothing here
  # touches a store or a network, which is what makes it testable.
  #
  # @api private
  module Evaluate
    DEFAULT_GRACE_MS = 10 * 60_000
    DEFAULT_TIMEOUT_MS = 60 * 60_000
    # Runs faster than this are never called slow, whatever the baseline says.
    SLOW_FLOOR_MS = 10_000
    # How many earlier runs a baseline needs before it is trusted.
    BASELINE_MIN_RUNS = 5
    # How many successful runs a baseline looks at, and how many runs a summary covers.
    BASELINE_WINDOW = 20

    Evaluation = Struct.new(:state, :alerts, keyword_init: true)
    CheckEvaluation = Struct.new(:state, :alerts, :next_expected_at, :due_at, keyword_init: true)
    SlowThreshold = Struct.new(:threshold_ms, :basis, keyword_init: true)

    # The longest duration written: the largest integer JavaScript holds
    # exactly, which every port and store reads back unchanged.
    MAX_DURATION_MS = 9_007_199_254_740_991

    module_function

    # How long a run took, from `started_at` to `finished_at`: 0 when it
    # started later, and never more than MAX_DURATION_MS. A foreign row's
    # start near a 64-bit limit must not make a duration no store can write.
    def run_duration(started_at, finished_at)
      ms = finished_at - started_at
      return 0 unless ms.is_a?(Numeric) && ms.positive?

      ms = ms.to_i if ms.is_a?(Float) && ms.finite? && ms == ms.floor
      [ms, MAX_DURATION_MS].min
    end

    # When a silence of `ms` from `now` ends: a whole millisecond, never past
    # MAX_DURATION_MS (2**53 - 1), however long the silence asked for. Every
    # port sharing the store reads it back unchanged, where a larger number
    # could wrap to a time long past and send alerts during the silence.
    def silence_end(now, ms)
      [now + (ms >= MAX_DURATION_MS ? MAX_DURATION_MS : ms.floor), MAX_DURATION_MS].min
    end

    # The version a stored state counts as for compare_and_set_state: its
    # `version` when that is a whole number from 0 to MAX_DURATION_MS
    # (2**53 - 1), else 0, as when it is absent. The SQL stores read it the
    # same way, so a foreign row's 1.5, "x" or -1 is written over by the next
    # update instead of refusing every compare-and-set of its job for good.
    def state_version(state)
      version = state&.version
      return 0 unless version.is_a?(Integer) || (version.is_a?(Float) && version.finite? && version == version.floor)
      return 0 unless version >= 0 && version <= MAX_DURATION_MS

      version.to_i
    end

    # The failures in a row a stored state counts as: its `consecutive_failures`
    # when that is a whole number, held at MAX_DURATION_MS (2**53 - 1), and 0
    # when it is negative or not a whole number. A foreign row's count past
    # 2**53 stays at the top, as the SDK holds it, and a 1.5, "3" or -1
    # counts as none.
    def failure_count(state)
      count = state&.consecutive_failures
      return 0 unless count.is_a?(Integer) || (count.is_a?(Float) && count.finite? && count == count.floor)
      return 0 unless count.positive?

      [count, MAX_DURATION_MS].min.to_i
    end

    # A JSON number, as JavaScript's typeof value === "number" sees one
    # read from JSON: an Integer or a Float (never true or false).
    def json_number?(value)
      value.is_a?(Integer) || value.is_a?(Float)
    end

    def empty_state(job)
      JobState.new(job: job, open: {}, consecutive_failures: 0, silenced_until: nil, last_alert_at: nil,
                   pending_recovery: [], undelivered: [])
    end

    # A stored state with every field present, or a fresh one. State written
    # by an older version lacks the newer fields. `sending` is the exception:
    # it is there only while it holds an alert (see hold_alerts).
    #
    # Read leniently, since a foreign, hand-edited or damaged row must affect
    # only its own job, and the next write puts it right: a state that is not
    # an object reads as none; `open` keeps only its entries whose value is a
    # number (anything but an object reads as {}); `silenced_until` and
    # `last_alert_at` that are not numbers read as nil; `pending_recovery`
    # keeps only its conditions (strings as stored), and `undelivered` only
    # its entries that are objects (a list of neither shape reads as []).
    # Unknown fields are kept as written.
    def normalize_state(state, job)
      state = JobState.from_h(state)
      return empty_state(job) if state.nil?

      sending = state.sending
      open = state.open.is_a?(Hash) ? state.open.select { |_, at| json_number?(at) } : {}
      pending = state.pending_recovery.is_a?(Array) ? state.pending_recovery.grep(Symbol) : []
      undelivered = state.undelivered.is_a?(Array) ? state.undelivered.grep(Alert) : []
      JobState.new(
        job: state.job.nil? ? job : state.job,
        open: open,
        consecutive_failures: failure_count(state),
        silenced_until: json_number?(state.silenced_until) ? state.silenced_until : nil,
        last_alert_at: json_number?(state.last_alert_at) ? state.last_alert_at : nil,
        pending_recovery: pending,
        undelivered: undelivered,
        version: state.version,
        sending: sending.is_a?(Array) && !sending.empty? ? sending.dup : nil,
        # Fields a newer release wrote, carried through every write.
        extra: state.extra,
      )
    end

    # ---------------------------------------------------------------- delivery

    # Alerts kept per job for retry, and per job being sent; past it the oldest go.
    MAX_UNDELIVERED = 20

    # How long an alert in `sending` is left to the process sending it.
    # Longer than any send takes: at most three alerts go out together, each
    # with 25 seconds of triage and 15 of channels.
    SEND_LEASE_MS = 5 * 60_000

    # A state and how many alerts the queue let go to make it.
    Held = Struct.new(:state, :dropped, keyword_init: true) do
      def to_h = { "state" => state.to_h, "dropped" => dropped }
    end

    # Identifies an alert across retries, and in `sending`. `at` is printed
    # as JavaScript prints a number.
    def alert_key(alert)
      at = alert.at
      run = alert.run
      "#{alert.type}|#{at.is_a?(Numeric) ? JS.number(at) : at}|#{run.id if run.is_a?(Run)}"
    end

    # `alerts` added to the undelivered queue: one with the same key as a
    # queued alert replaces it where it stands, the rest go at the end, and
    # only the newest MAX_UNDELIVERED stay. `dropped` counts those let go.
    def queue_undelivered(state, alerts)
      following = clone_state(state)
      by_key = alerts.to_h { |alert| [alert_key(alert), alert] }
      queue = following.undelivered.map { |alert| by_key.fetch(alert_key(alert), alert) }
      known = queue.to_set { |alert| alert_key(alert) }
      queue.concat(alerts.reject { |alert| known.include?(alert_key(alert)) })
      following.undelivered = queue.last(MAX_UNDELIVERED)
      Held.new(state: following, dropped: [0, queue.length - MAX_UNDELIVERED].max)
    end

    # The outbox. Alerts just composed are written with the state that opens
    # their condition, before any is sent, so a process that stops part way
    # does not lose them: into `sending`, each with its lease ending at
    # `until_at`, when this process sends them, or (deliver: :check) straight
    # into the undelivered queue for a check elsewhere. `dropped` counts
    # alerts let go past MAX_UNDELIVERED.
    def hold_alerts(state, alerts, until_at, deferred)
      return Held.new(state: state, dropped: 0) if alerts.empty?
      return queue_undelivered(state, alerts) if deferred

      following = clone_state(state)
      entries = (following.sending || []) + alerts.map { |alert| { "until" => until_at, "alert" => alert } }
      following.sending = entries.last(MAX_UNDELIVERED)
      Held.new(state: following, dropped: [0, entries.length - MAX_UNDELIVERED].max)
    end

    # Alerts in `sending` whose lease ran out by `now`: the process sending
    # them stopped before it recorded how the send went. They go to the
    # undelivered queue, where the retry sends them (with triage, which is
    # never stored with them here) or drops them as stale. An entry that is
    # not a Hash with an alert is dropped; one without a numeric `until`
    # counts as run out.
    def release_sending(state, now)
      sending = state.sending.is_a?(Array) ? state.sending : []
      lapsed, held = sending.partition { |entry| !(entry.is_a?(Hash) && entry["until"].is_a?(Numeric) && entry["until"] > now) }
      return Held.new(state: state, dropped: 0) if lapsed.empty?

      kept = state.dup
      kept.sending = held
      queue_undelivered(kept, lapsed.filter_map { |entry| sending_alert(entry) })
    end

    # How a send went. Delivered and stale alerts leave the queue; failed
    # ones replace their queued copy, so a triage made on this attempt is
    # kept, or join the queue. Every one of them leaves `sending`.
    # last_alert_at moves only on a delivery. `dropped` counts alerts let go
    # past MAX_UNDELIVERED.
    def record_sent(state, delivered, failed, stale, now)
      following = clone_state(state)
      done = (delivered + stale).to_set { |alert| alert_key(alert) }
      following.undelivered = following.undelivered.reject { |alert| done.include?(alert_key(alert)) }
      sent = (delivered + failed + stale).to_set { |alert| alert_key(alert) }
      held = (following.sending || []).reject do |entry|
        alert = sending_alert(entry)
        alert && sent.include?(alert_key(alert))
      end
      following.sending = held.empty? ? nil : held
      following.last_alert_at = now if delivered.any?
      queue_undelivered(following, failed)
    end

    # The alert of an entry of `sending`, or nil when it has none, or one
    # that did not parse as an alert (which could not be sent either).
    def sending_alert(entry)
      entry.is_a?(Hash) && entry["alert"].is_a?(Alert) ? entry["alert"] : nil
    end

    def clone_state(state)
      normalize_state(state, state.job)
    end

    def open_condition(state, condition, now)
      return false if state.open.key?(condition)

      state.open[condition] = now
      true
    end

    # Every open condition has alerted, so closing one owes a recovered message.
    # It is remembered until a successful run leaves nothing open and sends it.
    def close_condition(state, condition)
      return false unless state.open.key?(condition)

      state.open.delete(condition)
      state.pending_recovery ||= []
      state.pending_recovery << condition unless state.pending_recovery.include?(condition)
      true
    end

    def open_conditions(state)
      state.open.keys
    end

    def grace_ms(definition)
      definition.grace.nil? ? DEFAULT_GRACE_MS : Duration.parse(definition.grace, "grace")
    end

    def timeout_ms(definition)
      definition.timeout.nil? ? DEFAULT_TIMEOUT_MS : Duration.parse(definition.timeout, "timeout")
    end

    # Slow threshold for a successful run, or nil when there is nothing to compare against yet.
    def slow_threshold(definition, history)
      unless definition.max_duration.nil?
        return SlowThreshold.new(threshold_ms: Duration.parse(definition.max_duration, "maxDuration"), basis: "maxDuration")
      end

      durations = history.select { |r| r.status == :ok && !r.duration_ms.nil? }.first(BASELINE_WINDOW).map(&:duration_ms)
      return nil if durations.length < BASELINE_MIN_RUNS

      p95 = Stats.percentile(durations, 95)
      SlowThreshold.new(
        threshold_ms: [2 * p95, SLOW_FLOOR_MS].max,
        basis: "twice the p95 of the last #{durations.length} runs (#{Duration.format(p95)})",
      )
    end

    def budget_breaches(definition, run, history)
      breaches = []
      budget = definition.budget
      metrics = run.metrics || {}
      JS.object_keys(metrics).each do |metric|
        value = metrics[metric]
        ceiling = budget&.[](metric.to_s)
        unless ceiling.nil?
          breaches << { metric: metric.to_s, value: value, limit: ceiling, basis: "budget" } if value > ceiling
          next
        end
        past = history.select { |r| r.status == :ok && (r.metrics || {})[metric].is_a?(Numeric) }
                      .first(BASELINE_WINDOW).map { |r| r.metrics[metric] }
        next if past.length < BASELINE_MIN_RUNS

        usual = Stats.median(past)
        if usual.positive? && value > 3 * usual
          breaches << { metric: metric.to_s, value: value, limit: 3 * usual, basis: "three times the usual #{format_number(usual)}" }
        end
      end
      breaches
    end

    # Whether `history` (newest first) holds a full baseline window of successful runs.
    def full_baseline?(history)
      history.count { |r| r.status == :ok } >= BASELINE_WINDOW
    end

    # toLocaleString("en-US"): digit groups, and a fraction rounded half up to
    # at most four places. Worked on the shortest decimal digits, as ICU does.
    def format_number(n)
      return (n.negative? ? "-" : "") + (n.nan? ? "NaN" : "\u221e") if n.is_a?(Float) && !n.finite?

      negative = n.negative? || (n.is_a?(Float) && n.zero? && (1.0 / n).negative?)
      if n.is_a?(Integer)
        whole = n.abs.to_s
        fraction = ""
      else
        digits, point = JS.decimal(n.abs.to_f)
        if point >= digits.length
          whole = digits + ("0" * (point - digits.length))
          fraction = ""
        elsif point.positive?
          whole = digits[0, point]
          fraction = digits[point..]
        else
          whole = "0"
          fraction = ("0" * -point) + digits
        end
        if fraction.length > 4
          up = fraction[4].to_i >= 5
          fraction = fraction[0, 4]
          if up
            rounded = ((whole + fraction).to_i + 1).to_s.rjust(whole.length + 4, "0")
            whole = rounded[0...-4]
            fraction = rounded[-4..]
          end
        end
        fraction = fraction.sub(/0+\z/, "")
      end
      whole = whole.reverse.scan(/\d{1,3}/).join(",").reverse
      text = fraction.empty? ? whole : "#{whole}.#{fraction}"
      negative ? "-#{text}" : text
    end

    # Called when a run starts. Missed and stuck are about the absence of a run,
    # so a run starting closes them without an alert; the recovered message
    # waits for a successful finish.
    def on_run_start(state)
      next_state = clone_state(state)
      close_condition(next_state, :missed)
      close_condition(next_state, :stuck)
      next_state
    end

    # Called when a run finishes with status ok, failed or timeout. `history` is
    # the job's earlier runs, newest first, not including this one.
    def on_run_finish(definition, run, state, history, now)
      next_state = clone_state(state)
      alerts = []

      if run.status == :ok
        next_state.consecutive_failures = 0
        close_condition(next_state, :missed)
        close_condition(next_state, :stuck)
        close_condition(next_state, :failed)

        slow = slow_threshold(definition, history)
        if slow && !run.duration_ms.nil? && run.duration_ms > slow.threshold_ms
          if open_condition(next_state, :slow, now)
            alerts << AlertDraft.new(type: :slow, run: run,
                                     details: { duration_ms: run.duration_ms, threshold_ms: slow.threshold_ms, basis: slow.basis })
          end
        else
          close_condition(next_state, :slow)
        end

        breaches = budget_breaches(definition, run, history)
        if breaches.any?
          alerts << AlertDraft.new(type: :over_budget, run: run, details: { breaches: breaches }) if open_condition(next_state, :over_budget, now)
        else
          close_condition(next_state, :over_budget)
        end

        pending = next_state.pending_recovery || []
        if pending.any? && open_conditions(next_state).empty?
          alerts << AlertDraft.new(type: :recovered, run: run, details: { after: pending.dup })
          next_state.pending_recovery = []
        end
        return Evaluation.new(state: next_state, alerts: alerts)
      end

      # failed or timeout
      # Held at the top, as the SDK holds it: a count at the limit stays there.
      next_state.consecutive_failures = [next_state.consecutive_failures + 1, MAX_DURATION_MS].min
      close_condition(next_state, :missed)
      threshold = [1, definition.failures_before_alert || 1].max
      condition = run.status == :timeout ? :stuck : :failed
      if next_state.consecutive_failures >= threshold && open_condition(next_state, condition, now)
        alerts << AlertDraft.new(type: condition, run: run,
                                 details: { consecutive_failures: next_state.consecutive_failures, threshold: threshold })
      end
      Evaluation.new(state: next_state, alerts: alerts)
    end

    # Called by check. Decides whether the schedule has been missed: the run
    # the schedule wants next (see Schedule.expectation) has not started and its
    # grace has run out. `last_run` is the most recent run of any status. A job
    # with no schedule is never missed, and one whose schedule was removed while
    # missed was open gets a recovered alert (reason :unscheduled) for missed alone.
    def on_check(definition, stored, last_run, state, now)
      next_state = clone_state(state)
      alerts = []
      schedule = definition.schedule
      if schedule.nil? || schedule == ""
        since = next_state.open[:missed]
        unless since.nil?
          # The schedule went away while missed was open (the job was declared
          # again without one, or a source retired it), so nothing is due any
          # more. Missed closes now with a recovery of its own; other open
          # conditions keep their own rules. Missed is taken out of the pending
          # recovery too, so the next successful run does not name it again.
          next_state.open.delete(:missed)
          next_state.pending_recovery = (next_state.pending_recovery || []).reject { |c| c == :missed }
          alerts << AlertDraft.new(type: :recovered, run: last_run, details: { after: [:missed], reason: :unscheduled, since: since })
        end
        return CheckEvaluation.new(state: next_state, alerts: alerts, next_expected_at: nil, due_at: nil)
      end

      parsed = Schedule.parse(schedule, definition.timezone)
      grace = grace_ms(definition)
      last_run_at = last_run&.started_at
      exp = Schedule.expectation(parsed, last_run_at, stored.created_at, grace)
      next_expected_at =
        if parsed.interval? then Schedule.next_fire(parsed, stored.created_at, last_run_at)
        else Schedule.next_fire(parsed, now, nil)
        end
      return CheckEvaluation.new(state: next_state, alerts: alerts, next_expected_at: next_expected_at, due_at: nil) unless exp

      # An interval's next run is due a period after the last one started. If that
      # run is still going, the job is busy, not late; stuck covers one that never ends.
      if parsed.interval? && last_run&.status == :running
        return CheckEvaluation.new(state: next_state, alerts: alerts, next_expected_at: next_expected_at, due_at: exp.due_at)
      end

      if now > exp.deadline
        if open_condition(next_state, :missed, now)
          alerts << AlertDraft.new(type: :missed, run: last_run,
                                   details: { due_at: exp.due_at, deadline: exp.deadline, grace_ms: grace, last_run_at: last_run_at })
        end
      else
        # A run has started since it opened, or the grace was widened.
        close_condition(next_state, :missed)
      end
      CheckEvaluation.new(state: next_state, alerts: alerts, next_expected_at: next_expected_at, due_at: exp.due_at)
    end

    # Whether a running run has gone on longer than the job's timeout.
    def stuck?(definition, run, now)
      run.status == :running && now - run.started_at > timeout_ms(definition)
    end

    # While a job is silenced nothing new is recorded as an incident: conditions
    # may close (so a job that recovered during the silence shows as healthy) but
    # none may open, so the first problem after the silence ends alerts normally.
    def mute_opens(previous, next_state)
      muted = clone_state(next_state)
      open_conditions(muted).each { |condition| muted.open.delete(condition) unless previous.open.key?(condition) }
      muted
    end

    def silenced?(state, now)
      !state.silenced_until.nil? && state.silenced_until > now
    end

    # An evaluation as it is saved and sent: while the job was silenced when it
    # began, nothing opens and nothing is sent.
    def apply_silence(previous, evaluation, now)
      return evaluation unless silenced?(previous, now)

      Evaluation.new(state: mute_opens(previous, evaluation.state), alerts: [])
    end

    # Whether an alert waiting to be retried no longer describes the job, so it
    # is dropped rather than sent late. An alert for a condition is stale once
    # that condition has closed, or has closed and opened again (it opened at a
    # time other than the alert's). A recovery is stale when any condition it
    # names is open again; while they all stay closed it is kept. From a
    # foreign or damaged row: an alert whose `at` is not a number, and a
    # recovery whose `details.after` is not a list of conditions, are stale.
    def stale_alert?(alert, state)
      if alert.type == :recovered
        # One whose details say nothing of what it recovers from cannot be judged, and goes.
        after = alert.details.is_a?(Hash) ? alert.details[:after] : nil
        return true unless after.is_a?(Array)

        return after.any? { |condition| !condition.is_a?(Symbol) || state.open.key?(condition) }
      end
      # One with no time cannot match an open condition.
      !json_number?(alert.at) || state.open[alert.type] != alert.at
    end

    # How a job looks at a glance. Silence wins, then stuck, failing and late.
    def job_health(definition, last_run, state, now)
      open = open_conditions(state)
      return :silenced if silenced?(state, now)
      return :stuck if open.include?(:stuck) || (last_run && stuck?(definition, last_run, now))
      return :failing if open.include?(:failed) || %i[failed timeout].include?(last_run&.status)
      return :late if open.include?(:missed)
      return :never_ran if last_run.nil?

      :healthy
    end

    # A job's summary from its most recent runs (newest first; the first
    # BASELINE_WINDOW are used) and its state. Stats cover runs of any status;
    # the percentiles are over the successful ones among them.
    def summarize(stored, recent, state, next_expected_at, now)
      summary(stored, recent, state, next_expected_at) { |last_run| job_health(stored.definition, last_run, state, now) }
    end

    # The summary of a job that could not be evaluated, say because its stored
    # schedule no longer parses. It reads nothing from the definition. The job
    # shows as failing (or silenced, while it is), since it needs a look, and
    # nothing is known about when it is next due.
    def unevaluable_summary(stored, recent, state, now)
      summary(stored, recent, state, nil) { silenced?(state, now) ? :silenced : :failing }
    end

    def summary(stored, recent, state, next_expected_at)
      window = recent.first(BASELINE_WINDOW)
      last_run = window.first
      finished = window.reject { |r| r.status == :running }
      ok_durations = window.select { |r| r.status == :ok && !r.duration_ms.nil? }.map(&:duration_ms)
      JobSummary.new(
        name: stored.name,
        definition: stored.definition,
        health: yield(last_run),
        open: open_conditions(state),
        last_run: last_run,
        next_expected_at: next_expected_at,
        consecutive_failures: state.consecutive_failures,
        silenced_until: state.silenced_until,
        stats: JobStats.new(
          runs: finished.length,
          ok_rate: finished.empty? ? 1 : finished.count { |r| r.status == :ok }.fdiv(finished.length),
          p50_ms: Stats.percentile(ok_durations, 50),
          p95_ms: Stats.percentile(ok_durations, 95),
        ),
      )
    end
  end
end
