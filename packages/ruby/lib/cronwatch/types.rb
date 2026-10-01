# frozen_string_literal: true

module Cronwatch
  CONDITIONS = %i[missed failed stuck slow over_budget].freeze
  RUN_STATUSES = %i[running ok failed timeout].freeze

  # Ruby names are snake_case symbols; everything that leaves the process
  # (store rows, JSON, webhook bodies) uses the SDK's camelCase names and
  # string values. Each type's to_h is that JSON shape, and from_h reads it.
  module Naming
    module_function

    def camel(name)
      name.to_s.gsub(/_([a-z0-9])/) { Regexp.last_match(1).upcase }
    end

    def snake(name)
      name.to_s.gsub(/([A-Z])/) { "_#{Regexp.last_match(1).downcase}" }.to_sym
    end

    # Reads a camelCase field from a hash with string or symbol keys.
    def fetch(hash, key, default = nil)
      return hash[key] if hash.key?(key)
      return hash[key.to_sym] if hash.key?(key.to_sym)

      default
    end

    def present?(hash, key)
      hash.key?(key) || hash.key?(key.to_sym)
    end

    # Ruby hash with symbol keys and symbol values -> JSON-ready camelCase.
    def to_json_value(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), out| out[k.is_a?(Symbol) ? camel(k) : k.to_s] = to_json_value(v) }
      when Array then value.map { |v| to_json_value(v) }
      when Symbol then value.to_s
      when Struct then value.to_h
      else value
      end
    end

    def from_json_value(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), out| out[snake(k)] = from_json_value(v) }
      when Array then value.map { |v| from_json_value(v) }
      else value
      end
    end
  end

  # Shared by the structs below.
  module Serializable
    def as_json(*)
      to_h
    end

    def to_json(*)
      JS.json(to_h)
    end
  end

  # A job's options. Kept as an ordered set of fields rather than a Struct so
  # its JSON has the same keys in the same order as the SDK writes: defaults,
  # then options as given, then name, and a stored `expect` last. Fields this
  # version does not know (written by a newer one) are kept as they came.
  class JobDefinition
    include Serializable

    FIELDS = {
      name: "name", schedule: "schedule", timezone: "timezone", grace: "grace", timeout: "timeout",
      max_duration: "maxDuration", budget: "budget", expect: "expect",
      failures_before_alert: "failuresBeforeAlert", description: "description", tags: "tags",
    }.freeze
    OPTIONS = (FIELDS.keys - [:name]).freeze
    BY_JSON = FIELDS.invert.freeze

    FIELDS.each_key { |field| define_method(field) { @fields[field] } }

    # What from_h makes a stored definition that is not a JSON object from.
    UNREADABLE = {}.freeze

    def initialize(fields = {})
      @fields = {}
      fields.each { |k, v| @fields[k.is_a?(Symbol) ? k : k.to_s] = v }
      @fields.freeze
      @unreadable = fields.equal?(UNREADABLE)
      freeze
    end

    # A stored definition that is not a JSON object (null, a string, a
    # number, written by hand or by something else) reads as an empty one
    # marked unreadable, so the one row does not stop every other job being
    # listed; a check or a dashboard read reports that job and shows it as
    # failing (see Client#evaluable).
    def self.from_h(hash)
      return hash if hash.is_a?(JobDefinition)
      return new(UNREADABLE) unless hash.is_a?(Hash)

      new(hash.each_with_object({}) { |(k, v), out| out[BY_JSON[k.to_s] || k.to_s] = v })
    end

    def [](field)
      @fields[field]
    end

    # True for a stored definition that was not a JSON object. See from_h.
    def unreadable?
      @unreadable
    end

    def key?(field)
      @fields.key?(field)
    end

    # The fields as given, symbols for known ones.
    def fields
      @fields.dup
    end

    # A copy with some fields changed or added (at the end, as in JavaScript).
    def merge(changes)
      JobDefinition.new(@fields.merge(changes))
    end

    def to_h
      @fields.each_with_object({}) do |(k, v), out|
        next if v.nil?

        out[k.is_a?(Symbol) ? FIELDS.fetch(k) { Naming.camel(k) } : k] =
          case v
          when Hash then v.transform_keys(&:to_s)
          when Symbol then v.to_s
          else v
          end
      end
    end

    def ==(other)
      other.is_a?(JobDefinition) && JS.json(to_h) == JS.json(other.to_h)
    end
    alias eql? ==

    def hash
      JS.json(to_h).hash
    end

    def inspect
      "#<Cronwatch::JobDefinition #{JS.json(to_h)}>"
    end
  end

  Run = Struct.new(:id, :job, :status, :started_at, :finished_at, :duration_ms, :error, :output, :metrics, :trigger,
                   keyword_init: true) do
    include Serializable

    def self.from_h(hash)
      return hash if hash.is_a?(Run)

      new(
        id: Naming.fetch(hash, "id"),
        job: Naming.fetch(hash, "job"),
        status: Naming.fetch(hash, "status")&.to_sym,
        started_at: Naming.fetch(hash, "startedAt"),
        finished_at: Naming.fetch(hash, "finishedAt"),
        duration_ms: Naming.fetch(hash, "durationMs"),
        error: Naming.fetch(hash, "error"),
        output: Naming.fetch(hash, "output"),
        metrics: Run.metrics_from(Naming.fetch(hash, "metrics")),
        trigger: Naming.fetch(hash, "trigger", "run"),
      )
    end

    def to_h
      {
        "id" => id, "job" => job, "status" => status.to_s, "startedAt" => started_at, "finishedAt" => finished_at,
        "durationMs" => duration_ms, "error" => error, "output" => output,
        "metrics" => Run.metrics_from(metrics), "trigger" => trigger,
      }
    end

    # Stored metrics as a Hash with string keys. Anything else (a string or
    # an array a foreign or corrupted row holds) reads as none.
    def self.metrics_from(value)
      value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    end

    def running? = status == :running
    def ok? = status == :ok
  end

  StoredJob = Struct.new(:name, :definition, :created_at, :updated_at, keyword_init: true) do
    include Serializable

    def self.from_h(hash)
      return hash if hash.is_a?(StoredJob)

      new(
        name: Naming.fetch(hash, "name"),
        definition: JobDefinition.from_h(Naming.fetch(hash, "definition") || {}),
        created_at: Naming.fetch(hash, "createdAt"),
        updated_at: Naming.fetch(hash, "updatedAt"),
      )
    end

    def to_h
      { "name" => name, "definition" => definition.to_h, "createdAt" => created_at, "updatedAt" => updated_at }
    end
  end

  # An alert before it has a title and message. See Format.compose_alert.
  # `details` is a hash with snake_case symbol keys; its JSON is camelCase.
  AlertDraft = Struct.new(:type, :run, :details, keyword_init: true) do
    include Serializable

    def to_h
      { "type" => type.to_s, "run" => run&.to_h, "details" => Naming.to_json_value(details) }
    end
  end

  # Members in the order the SDK's alert object has its keys, which is the
  # order its JSON (a webhook body, an undelivered alert in state) has them.
  #
  # `triage` is the triage callable's diagnosis, or nil. A nil triage is one
  # of two things, as in the SDK: never tried (no "triage" key in the JSON),
  # or tried and nothing came of it (it raised, timed out or answered empty;
  # `"triage": null`, and `triage_tried?` is true). A tried alert is not
  # triaged again.
  Alert = Struct.new(:type, :run, :details, :job, :definition, :title, :message, :at, :triage, keyword_init: true) do
    include Serializable

    # Whether triage was tried for this alert, whatever it gave.
    def triage_tried?
      !triage.nil? || @triage_tried == true
    end

    # Records a triage attempt: the diagnosis, or nil when there was none.
    def triage_result=(diagnosis)
      self.triage = diagnosis
      @triage_tried = true
    end

    def self.from_h(hash)
      return hash if hash.is_a?(Alert)

      run = Naming.fetch(hash, "run")
      details = Naming.from_json_value(Naming.fetch(hash, "details") || {})
      details[:after] = details[:after].map(&:to_sym) if details[:after].is_a?(Array)
      details[:reason] = details[:reason].to_sym if details[:reason].is_a?(String)
      alert = new(
        type: Naming.fetch(hash, "type")&.to_sym,
        run: run && Run.from_h(run),
        details: details,
        job: Naming.fetch(hash, "job"),
        definition: JobDefinition.from_h(Naming.fetch(hash, "definition") || {}),
        title: Naming.fetch(hash, "title"),
        message: Naming.fetch(hash, "message"),
        at: Naming.fetch(hash, "at"),
      )
      alert.triage_result = Naming.fetch(hash, "triage") if Naming.present?(hash, "triage")
      alert
    end

    def to_h
      out = {
        "type" => type.to_s, "run" => run&.to_h, "details" => Naming.to_json_value(details), "job" => job,
        "definition" => definition.respond_to?(:to_h) ? definition.to_h : definition,
        "title" => title, "message" => message, "at" => at,
      }
      out["triage"] = triage if triage_tried?
      out
    end
  end

  # `version` goes up by one on every write, so a store can refuse a write
  # made from a stale read (see Stores::Memory#compare_and_set_state). Absent
  # (nil) counts as 0.
  #
  # `sending` is the outbox (see Evaluate.hold_alerts): entries of
  # { "until" => epoch ms, "alert" => Alert }, read leniently, since an entry
  # a foreign writer left malformed must not make the whole state unreadable:
  # an entry that is not a Hash, or whose alert is not one, is kept as it
  # came. nil when there is none; it is never written empty.
  #
  # `extra` holds the fields this version does not know, written by a newer
  # one, as the JSON they came as (string keys): every write carries them
  # back unchanged, after the known fields, so a process sharing the store
  # with a newer release never erases what that release keeps there. nil
  # when there are none. An open condition this version does not know stays
  # in `open` the same way, under its own name.
  JobState = Struct.new(:job, :open, :consecutive_failures, :silenced_until, :last_alert_at, :pending_recovery,
                        :undelivered, :version, :sending, :extra, keyword_init: true) do
    include Serializable

    # The fields this version reads, as stored.
    KNOWN = %w[job open consecutiveFailures silencedUntil lastAlertAt pendingRecovery undelivered version sending].freeze

    def self.from_h(hash)
      return hash if hash.is_a?(JobState)

      pending = Naming.fetch(hash, "pendingRecovery")
      undelivered = Naming.fetch(hash, "undelivered")
      sending = Naming.fetch(hash, "sending")
      extra = hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v unless KNOWN.include?(k.to_s) }
      new(
        extra: extra.empty? ? nil : extra,
        job: Naming.fetch(hash, "job"),
        open: (Naming.fetch(hash, "open") || {}).each_with_object({}) { |(k, v), out| out[k.to_sym] = v },
        consecutive_failures: Naming.fetch(hash, "consecutiveFailures", 0),
        silenced_until: Naming.fetch(hash, "silencedUntil"),
        last_alert_at: Naming.fetch(hash, "lastAlertAt"),
        pending_recovery: pending&.map(&:to_sym),
        undelivered: undelivered&.map { |a| Alert.from_h(a) },
        version: Naming.fetch(hash, "version"),
        sending: sending.is_a?(Array) ? sending.map { |entry| JobState.sending_entry(entry) } : sending,
      )
    end

    # One entry of `sending` as read: its alert parsed when it is a Hash
    # that parses, anything else kept as it came. `until` and `alert` come
    # first, in the order the SDK writes them, since a store on Postgres
    # jsonb gives an object's keys back in an order of its own.
    def self.sending_entry(entry)
      return entry unless entry.is_a?(Hash)

      read = entry.to_h do |key, value|
        next [key.to_s, value] unless key.to_s == "alert" && value.is_a?(Hash)

        parsed = begin
          Alert.from_h(value)
        rescue StandardError
          value
        end
        ["alert", parsed]
      end
      %w[until alert].select { |key| read.key?(key) }.to_h { |key| [key, read[key]] }.merge(read)
    end

    # pendingRecovery, undelivered and version are left out when unset, as in
    # state written before they existed. The version comes after them, where
    # the SDK's spread of a normalized state puts it, and `sending` last, and
    # only while it holds an entry.
    def to_h
      out = {
        "job" => job, "open" => (open || {}).transform_keys(&:to_s), "consecutiveFailures" => consecutive_failures,
        "silencedUntil" => silenced_until, "lastAlertAt" => last_alert_at,
      }
      out["pendingRecovery"] = pending_recovery.map(&:to_s) unless pending_recovery.nil?
      out["undelivered"] = undelivered.map(&:to_h) unless undelivered.nil?
      out["version"] = version unless version.nil?
      if sending.is_a?(Array) && !sending.empty?
        out["sending"] = sending.map do |entry|
          entry.is_a?(Hash) ? entry.transform_values { |v| v.is_a?(Alert) ? v.to_h : v } : entry
        end
      end
      extra&.each { |key, value| out[key] = value unless out.key?(key) || KNOWN.include?(key) }
      out
    end
  end

  JobStats = Struct.new(:runs, :ok_rate, :p50_ms, :p95_ms, keyword_init: true) do
    include Serializable

    def self.from_h(hash)
      new(runs: Naming.fetch(hash, "runs"), ok_rate: Naming.fetch(hash, "okRate"),
          p50_ms: Naming.fetch(hash, "p50Ms"), p95_ms: Naming.fetch(hash, "p95Ms"))
    end

    def to_h
      { "runs" => runs, "okRate" => ok_rate, "p50Ms" => p50_ms, "p95Ms" => p95_ms }
    end
  end

  JobSummary = Struct.new(:name, :definition, :health, :open, :last_run, :next_expected_at, :consecutive_failures,
                          :silenced_until, :stats, keyword_init: true) do
    include Serializable

    def self.from_h(hash)
      last = Naming.fetch(hash, "lastRun")
      new(
        name: Naming.fetch(hash, "name"),
        definition: JobDefinition.from_h(Naming.fetch(hash, "definition") || {}),
        health: Naming.fetch(hash, "health")&.to_sym,
        open: (Naming.fetch(hash, "open") || []).map(&:to_sym),
        last_run: last && Run.from_h(last),
        next_expected_at: Naming.fetch(hash, "nextExpectedAt"),
        consecutive_failures: Naming.fetch(hash, "consecutiveFailures"),
        silenced_until: Naming.fetch(hash, "silencedUntil"),
        stats: JobStats.from_h(Naming.fetch(hash, "stats") || {}),
      )
    end

    def to_h
      {
        "name" => name, "definition" => definition.to_h, "health" => health.to_s, "open" => open.map(&:to_s),
        "lastRun" => last_run&.to_h, "nextExpectedAt" => next_expected_at,
        "consecutiveFailures" => consecutive_failures, "silencedUntil" => silenced_until, "stats" => stats.to_h,
      }
    end
  end

  CheckResult = Struct.new(:checked_at, :jobs, :alerts, :pruned, keyword_init: true) do
    include Serializable

    def to_h
      { "checkedAt" => checked_at, "jobs" => jobs.map(&:to_h), "alerts" => alerts.map(&:to_h), "pruned" => pruned }
    end
  end
end
