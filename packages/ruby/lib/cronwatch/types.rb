# frozen_string_literal: true

module Cronwatch
  CONDITIONS = %i[missed failed stuck slow over_budget under_floor].freeze
  RUN_STATUSES = %i[running ok failed timeout].freeze

  # Ruby names are snake_case symbols; everything that leaves the process
  # (store rows, JSON, webhook bodies) uses the SDK's camelCase names and
  # string values. Each type's to_h is that JSON shape, and from_h reads it.
  #
  # @api private
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
  #
  # @api private
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
      max_duration: "maxDuration", budget: "budget", floor: "floor", expect: "expect",
      failures_before_alert: "failuresBeforeAlert", description: "description", tags: "tags",
    }.freeze
    OPTIONS = (FIELDS.keys - [:name]).freeze
    BY_JSON = FIELDS.invert.freeze

    FIELDS.each_key { |field| define_method(field) { @fields[field] } }

    private_constant :BY_JSON, :FIELDS

    def initialize(fields = {})
      @fields = {}
      fields.each { |k, v| @fields[k.is_a?(Symbol) ? k : k.to_s] = v }
      @fields.freeze
      @unreadable = false
      freeze
    end

    # A stored definition that is not a JSON object (null, a string, a
    # number, an array, or text that does not parse, written by hand or by
    # something else) reads as `{ name }` (`name` being the job's, when
    # given) marked unreadable, so the one row does not stop every other job
    # being listed; a check or a dashboard read reports that job and shows it
    # as failing (see Client#evaluable). `tags` is kept only when it is a
    # list of strings. Every other field is kept as stored.
    def self.from_h(hash, name = nil)
      return hash if hash.is_a?(JobDefinition)
      return unreadable(name) unless hash.is_a?(Hash)

      fields = hash.each_with_object({}) { |(k, v), out| out[BY_JSON[k.to_s] || k.to_s] = v }
      tags = fields[:tags]
      fields.delete(:tags) if fields.key?(:tags) && !(tags.is_a?(Array) && tags.all?(String))
      new(fields)
    end

    # `{ name }`, marked unreadable. See from_h.
    def self.unreadable(name)
      definition = allocate
      definition.instance_variable_set(:@fields, (name.nil? ? {} : { name: name }).freeze)
      definition.instance_variable_set(:@unreadable, true)
      definition.freeze
    end
    private_class_method :unreadable

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
        status: Run.status_from(Naming.fetch(hash, "status")),
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
        "id" => id, "job" => job, "status" => status.is_a?(Symbol) ? status.to_s : status,
        "startedAt" => started_at, "finishedAt" => finished_at,
        "durationMs" => duration_ms, "error" => error, "output" => output,
        "metrics" => Run.metrics_from(metrics), "trigger" => trigger,
      }
    end

    # A status as read: text as a Symbol, anything else (a foreign or
    # damaged row's) kept as it came, which matches no known status.
    def self.status_from(value)
      value.is_a?(String) ? value.to_sym : value
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

      name = Naming.fetch(hash, "name")
      new(
        name: name,
        definition: JobDefinition.from_h(Naming.fetch(hash, "definition"), name),
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
  #
  # @api private
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
  # or tried and nothing came of it (it raised, timed out, or answered empty;
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

    # Read leniently, since a queued alert a foreign writer left malformed
    # must affect only its own job: a field of the wrong type is kept as it
    # came (a `type` or `run` that is not what it should be, `details` that
    # are not an object, an `at` that is not a number), and the retry drops
    # such an alert as stale (Evaluate.stale_alert?).
    def self.from_h(hash)
      return hash if hash.is_a?(Alert)

      run = Naming.fetch(hash, "run")
      written = Naming.fetch(hash, "details") || {}
      details = Naming.from_json_value(written)
      if details.is_a?(Hash)
        details[:after] = details[:after].map { |c| c.is_a?(String) ? c.to_sym : c } if details[:after].is_a?(Array)
        details[:reason] = details[:reason].to_sym if details[:reason].is_a?(String)
      end
      type = Naming.fetch(hash, "type")
      definition = Naming.fetch(hash, "definition")
      alert = new(
        type: type.is_a?(String) ? type.to_sym : type,
        run: run.is_a?(Hash) ? Run.from_h(run) : run,
        details: details,
        job: Naming.fetch(hash, "job"),
        definition: definition.nil? || definition.is_a?(Hash) ? JobDefinition.from_h(definition || {}) : definition,
        title: Naming.fetch(hash, "title"),
        message: Naming.fetch(hash, "message"),
        at: Naming.fetch(hash, "at"),
      )
      alert.triage_result = Naming.fetch(hash, "triage") if Naming.present?(hash, "triage")
      alert.keep_as_written(hash, written, details)
      alert
    end

    # What a stored alert held that its members do not say again: the
    # fields this version does not know (a newer release may add one), its
    # details as written, since snake_case and back would turn a key spelled
    # `a_b` into `aB`, and which known fields it left out. to_h writes the
    # first two back, the details only while they are unchanged, and leaves
    # out a field that was absent while it still holds what its absence
    # read as, so a partial alert (a foreign row's) is written as it came,
    # in the order it came. An alert with every field the SDK writes has
    # them written back in the SDK's order, then the fields it does not
    # know, since a store on Postgres jsonb gives an object's keys back in
    # an order of its own (as JobState.sending_entry does for an entry).
    #
    # @api private
    def keep_as_written(hash, written, details)
      extra = hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v unless Alert::KNOWN.include?(k.to_s) }
      @extra = extra.empty? ? nil : extra
      @written_details = [Marshal.load(Marshal.dump(details)), Alert.string_keys(written)] if written.is_a?(Hash)
      absent = (Alert::KNOWN - ["triage"]).reject { |key| Naming.present?(hash, key) }
      @absent = absent.empty? ? nil : to_h.slice(*absent)
      order = hash.keys.map(&:to_s)
      @order = @absent && order.uniq == order ? order : nil
    end

    # @api private
    def self.string_keys(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s, string_keys(v)] }
      when Array then value.map { |v| string_keys(v) }
      else value
      end
    end

    def to_h
      out = {
        "type" => type.is_a?(Symbol) ? type.to_s : type, "run" => run.is_a?(Run) ? run.to_h : run,
        "details" => details_json, "job" => job,
        "definition" => definition.is_a?(JobDefinition) ? definition.to_h : definition,
        "title" => title, "message" => message, "at" => at,
      }
      @absent&.each { |key, value| out.delete(key) if out[key] == value }
      out["triage"] = triage if triage_tried?
      @extra&.each { |key, value| out[key] = value unless out.key?(key) || Alert::KNOWN.include?(key) }
      return out if @order.nil? || @order == out.keys

      # The keys in the order they were read, as the object a store held
      # keeps them; any added since go after.
      written = @order.select { |key| out.key?(key) }
      (written + (out.keys - written)).to_h { |key| [key, out[key]] }
    end

    private

    def details_json
      return @written_details[1] if @written_details && @written_details[0] == details

      Naming.to_json_value(details)
    end
  end

  # The fields this version reads from a stored alert; the rest are kept as they came.
  # @api private
  Alert::KNOWN = %w[type run details job definition title message at triage].freeze

  # `version` goes up by one on every write, so a store can refuse a write
  # made from a stale read (see Stores::Memory#compare_and_set_state). Absent
  # (nil) counts as 0.
  #
  # from_h reads a state as stored, keeping each field as it came where it
  # has the wrong type (Evaluate.normalize_state then reads it leniently),
  # so a foreign, hand-edited, or damaged row is written back unchanged by a
  # read that changes nothing, and affects only its own job. A stored state
  # that is not a JSON object reads as none (nil).
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
                        :undelivered, :version, :sending, :under_floor, :extra, keyword_init: true) do
    include Serializable

    def self.from_h(hash)
      return hash if hash.is_a?(JobState)
      return nil unless hash.is_a?(Hash)

      open = Naming.fetch(hash, "open") || {}
      pending = Naming.fetch(hash, "pendingRecovery")
      undelivered = Naming.fetch(hash, "undelivered")
      sending = Naming.fetch(hash, "sending")
      under_floor = Naming.fetch(hash, "underFloor")
      extra = hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v unless JobState::KNOWN.include?(k.to_s) }
      new(
        extra: extra.empty? ? nil : extra,
        job: Naming.fetch(hash, "job"),
        open: open.is_a?(Hash) ? open.to_h { |k, v| [k.to_sym, v] } : open,
        consecutive_failures: Naming.fetch(hash, "consecutiveFailures", 0),
        silenced_until: Naming.fetch(hash, "silencedUntil"),
        last_alert_at: Naming.fetch(hash, "lastAlertAt"),
        pending_recovery: pending.is_a?(Array) ? pending.map { |c| c.is_a?(String) ? c.to_sym : c } : pending,
        undelivered: undelivered.is_a?(Array) ? undelivered.map { |a| a.is_a?(Hash) ? Alert.from_h(a) : a } : undelivered,
        version: Naming.fetch(hash, "version"),
        sending: sending.is_a?(Array) ? sending.map { |entry| JobState.sending_entry(entry) } : sending,
        under_floor: under_floor,
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

    # pendingRecovery, undelivered, and version are left out when unset, as in
    # state written before they existed. The version comes after them, where
    # the SDK's spread of a normalized state puts it, then `sending` and
    # `underFloor`, each only while it holds an entry.
    def to_h
      out = {
        "job" => job, "open" => open.is_a?(Hash) ? open.transform_keys(&:to_s) : (open || {}),
        "consecutiveFailures" => consecutive_failures, "silencedUntil" => silenced_until, "lastAlertAt" => last_alert_at,
      }
      unless pending_recovery.nil?
        out["pendingRecovery"] =
          pending_recovery.is_a?(Array) ? pending_recovery.map { |c| c.is_a?(Symbol) ? c.to_s : c } : pending_recovery
      end
      unless undelivered.nil?
        out["undelivered"] = undelivered.is_a?(Array) ? undelivered.map { |a| a.is_a?(Alert) ? a.to_h : a } : undelivered
      end
      out["version"] = version unless version.nil?
      if sending.is_a?(Array) && !sending.empty?
        out["sending"] = sending.map do |entry|
          entry.is_a?(Hash) ? entry.transform_values { |v| v.is_a?(Alert) ? v.to_h : v } : entry
        end
      end
      out["underFloor"] = under_floor.dup if under_floor.is_a?(Array) && !under_floor.empty?
      extra&.each { |key, value| out[key] = value unless out.key?(key) || JobState::KNOWN.include?(key) }
      out
    end
  end

  # The fields this version reads from a stored state; the rest are kept in `extra`.
  # @api private
  JobState::KNOWN = %w[job open consecutiveFailures silencedUntil lastAlertAt pendingRecovery undelivered version sending underFloor].freeze

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
