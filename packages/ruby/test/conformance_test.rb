# frozen_string_literal: true

require_relative "test_helper"
require "digest"

# Replays every case in conformance/ (written by scripts/conformance.mjs from
# the TypeScript SDK) against the gem. Values are compared as the JSON the SDK
# would write, so key order and number formatting count too.
class ConformanceTest < Minitest::Test
  include TestHelpers

  DIR = File.expand_path("../../../conformance", __dir__)

  # Schedules croner reads and Fugit does not. The gem refuses them rather
  # than guess; each must raise, with the usual prefix.
  RUBY_REFUSES = {
    "0 0 15W * *" => "W (nearest weekday)",
    "0 0 5L * *" => "a day-of-month L after a number",
  }.freeze

  def self.fixture(name)
    JSON.parse(File.read(File.join(DIR, name)))
  end

  # JSON has no NaN or Infinity; the fixtures write them as { "special": "NaN" }.
  def self.decode(value)
    return value unless value.is_a?(Hash) && value.key?("special")

    { "NaN" => Float::NAN, "Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY }.fetch(value["special"])
  end

  def decode(value) = self.class.decode(value)

  # Runs each case, collecting mismatches, so one failure lists them all.
  def each_case(cases)
    failures = []
    cases.each_with_index do |c, i|
      message = yield(c)
      failures << "##{i} #{JSON.generate(c)[0, 300]}\n    #{message}" if message
    rescue StandardError => e
      failures << "##{i} #{JSON.generate(c)[0, 300]}\n    raised #{e.class}: #{e.message}\n    #{e.backtrace.first(3).join("\n    ")}"
    end
    assert failures.empty?, "#{failures.length} of #{cases.length} cases differ:\n#{failures.first(15).join("\n")}"
  end

  def differs(expected, actual)
    e = expected.is_a?(String) ? expected : json(expected)
    a = actual.is_a?(String) ? actual : json(actual)
    e == a ? nil : "expected #{e[0, 1500]}\n    got      #{a[0, 1500]}"
  end

  def raises(expected_message)
    yield
    "expected an error: #{expected_message}"
  rescue ArgumentError => e
    e.message == expected_message ? nil : "expected error #{expected_message.inspect}\n    got   error #{e.message.inspect}"
  end

  # ---------------------------------------------------------------- duration

  DURATION = fixture("duration.json")

  def test_duration_parse
    each_case(DURATION["parse"]) do |c|
      args = [decode(c["input"])]
      args << c["label"] if c["label"]
      if c.key?("error")
        raises(c["error"]) { Cronwatch::Duration.parse(*args) }
      else
        differs(c["ms"], Cronwatch::Duration.parse(*args))
      end
    end
  end

  def test_duration_format
    each_case(DURATION["format"]) { |c| differs(c["text"], Cronwatch::Duration.format(decode(c["ms"]))) }
  end

  def test_duration_relative
    each_case(DURATION["relative"]) { |c| differs(c["text"], Cronwatch::Duration.relative(c["at"], c["now"])) }
  end

  # ---------------------------------------------------------------- schedule

  SCHEDULE = fixture("schedule.json")

  def test_schedule_parse
    each_case(SCHEDULE["parse"]) do |c|
      if RUBY_REFUSES.key?(c["schedule"])
        begin
          Cronwatch::Schedule.parse(c["schedule"], c["timezone"])
          next "the gem was expected to refuse #{RUBY_REFUSES[c["schedule"]]}"
        rescue ArgumentError => e
          prefix = "schedule \"#{c["schedule"]}\" is not a cron expression or \"every <duration>\": "
          next e.message.start_with?(prefix) ? nil : "unexpected message #{e.message}"
        end
      end
      if c.key?("error")
        raises(c["error"]) { Cronwatch::Schedule.parse(c["schedule"], c["timezone"]) }
      else
        differs(c["parsed"], Cronwatch::Schedule.parse(c["schedule"], c["timezone"]))
      end
    end
  end

  def test_schedule_fires
    each_case(SCHEDULE["fires"]) do |c|
      parsed = Cronwatch::Schedule.parse(c["schedule"], c["timezone"])
      t = c["from"]
      fires = []
      c["fires"].length.times do
        t = Cronwatch::Schedule.next_fire(parsed, t, nil)
        fires << t
        break if t.nil?
      end
      differs(c["fires"].map { |f| f && Cronwatch::JS.iso(f) }, fires.map { |f| f && Cronwatch::JS.iso(f) })
    end
  end

  def test_schedule_next_fire_across_the_autumn_clock_change
    each_case(SCHEDULE["autumn"]) do |c|
      parsed = Cronwatch::Schedule.parse(c["schedule"], c["timezone"])
      actual = c["next"].each_index.map { |i| Cronwatch::Schedule.next_fire(parsed, c["from"] + (i * c["stepMs"]), nil) }
      differs(c["next"].map { |f| f && Cronwatch::JS.iso(f) }, actual.map { |f| f && Cronwatch::JS.iso(f) })
    end
  end

  def test_schedule_next_fire_for_intervals
    each_case(SCHEDULE["nextFire"]) do |c|
      differs(c["expected"], Cronwatch::Schedule.next_fire(Cronwatch::Schedule.parse(c["schedule"]), c["from"], c["lastRunAt"]))
    end
  end

  def test_schedule_expectation
    each_case(SCHEDULE["expectation"]) do |c|
      parsed = Cronwatch::Schedule.parse(c["schedule"], c["timezone"])
      differs(c["expected"], Cronwatch::Schedule.expectation(parsed, c["lastRunAt"], c["registeredAt"], c["graceMs"]))
    end
  end

  def test_schedule_run_covers
    each_case(SCHEDULE["runCovers"]) do |c|
      differs(c["expected"], Cronwatch::Schedule.run_covers?(c["startedAt"], c["dueAt"], c["followingAt"]))
    end
  end

  # ---------------------------------------------------------------- evaluate

  # The generator's Sim, in Ruby: a job's life through the pure functions, the way the client plays it.
  class Sim
    attr_reader :state

    def initialize(definition, created_at)
      @def = definition
      @stored = Cronwatch::StoredJob.new(name: definition.name, definition: definition, created_at: created_at, updated_at: created_at)
      @state = Cronwatch::Evaluate.empty_state(definition.name)
      @runs = []
      @order = {}
      @seq = 0
    end

    def define(definition)
      @def = definition
      @stored = @stored.dup.tap { |s| s.definition = definition }
    end

    def silence(until_at)
      @state = @state.dup.tap { |s| s.silenced_until = until_at }
    end

    def start(id, now)
      @runs << Cronwatch::Run.new(id: id, job: @def.name, status: :running, started_at: now, finished_at: nil, duration_ms: nil,
                                  error: nil, output: nil, metrics: {}, trigger: "run")
      @order[id] = (@seq += 1)
      @state = Cronwatch::Evaluate.on_run_start(@state)
      { "state" => @state }
    end

    def finish(id, now, fields)
      run = @runs.find { |r| r.id == id }
      marked_timed_out = run.status == :timeout
      run.finished_at = now
      run.duration_ms = [0, now - run.started_at].max
      run.status = fields.fetch("status").to_sym
      run.metrics = fields.fetch("metrics", {})
      run.output = fields.fetch("output", nil)
      run.error = fields.fetch("error", nil)
      # As the client does: a check already counted this run as stuck, so a
      # late failure only updates the run; a late success is evaluated.
      return { "alerts" => [], "state" => @state } if marked_timed_out && run.status != :ok

      alerts = finish_run(run, now)
      { "alerts" => alerts, "state" => @state }
    end

    def check(now)
      alerts = []
      running = @runs.select { |r| r.status == :running }.sort { |a, b| (a.started_at <=> b.started_at).nonzero? || @order[a.id] <=> @order[b.id] }
      running.each do |run|
        next unless Cronwatch::Evaluate.stuck?(@def, run, now)

        run.status = :timeout
        run.finished_at = now
        run.duration_ms = now - run.started_at
        run.error = "Still running after #{Cronwatch::Duration.format(Cronwatch::Evaluate.timeout_ms(@def))}; marked as timed out"
        alerts.concat(finish_run(run, now))
      end
      recent = sorted.first(20).map { |r| copy(r) }
      previous = @state
      evaluation = Cronwatch::Evaluate.on_check(@def, @stored, recent.first, previous, now)
      alerts.concat(settle(previous, evaluation, now))
      {
        "alerts" => alerts, "state" => @state, "nextExpectedAt" => evaluation.next_expected_at, "dueAt" => evaluation.due_at,
        "summary" => Cronwatch::Evaluate.summarize(@stored, recent, @state, evaluation.next_expected_at, now),
      }
    end

    private

    def sorted
      @runs.sort { |a, b| (b.started_at <=> a.started_at).nonzero? || @order[b.id] <=> @order[a.id] }
    end

    def copy(run)
      Cronwatch::Run.from_h(run.to_h)
    end

    def finish_run(run, now)
      history = sorted.reject { |r| r.id == run.id }.map { |r| copy(r) }
      previous = @state
      settle(previous, Cronwatch::Evaluate.on_run_finish(@def, copy(run), previous, history, now), now)
    end

    def settle(previous, evaluation, now)
      state = evaluation.state
      alerts = evaluation.alerts
      if Cronwatch::Evaluate.silenced?(previous, now)
        state = Cronwatch::Evaluate.mute_opens(previous, state)
        alerts = []
      end
      @state = state
      alerts.map { |draft| Cronwatch::Format.compose_alert(draft, @def, now).to_h }
    end
  end

  EVALUATE = fixture("evaluate.json")

  EVALUATE["scenarios"].each_with_index do |scenario, index|
    define_method("test_scenario_#{index.to_s.rjust(2, "0")}_#{scenario["name"].gsub(/\W+/, "_")}") do
      sim = Sim.new(Cronwatch::JobDefinition.from_h(scenario["definition"]), scenario["createdAt"])
      scenario["events"].each_with_index do |event, i|
        actual =
          case event["op"]
          when "start" then sim.start(event["id"], event["at"])
          when "finish" then sim.finish(event["id"], event["at"], event)
          when "check" then sim.check(event["at"])
          when "silence" then { "state" => sim.silence(event["until"]) }
          when "unsilence" then { "state" => sim.silence(nil) }
          when "define" then sim.define(Cronwatch::JobDefinition.from_h(event["definition"])) && next
          else flunk "unknown event #{event["op"]}"
          end
        event["expect"].each do |key, expected|
          assert_equal json(expected), json(actual.fetch(key)), "#{scenario["name"]}: event #{i} (#{event["op"]} at #{event["at"]}), #{key}"
        end
      end
    end
  end

  # ---------------------------------------------------------------- format

  FORMAT = fixture("format.json")

  def draft_from(hash)
    details = Cronwatch::Naming.from_json_value(hash["details"])
    details[:after] = details[:after].map(&:to_sym) if details[:after]
    Cronwatch::AlertDraft.new(type: hash["type"].to_sym, run: hash["run"] && Cronwatch::Run.from_h(hash["run"]), details: details)
  end

  def test_compose_alert
    each_case(FORMAT["alerts"]) do |c|
      alert = Cronwatch::Format.compose_alert(draft_from(c["draft"]), Cronwatch::JobDefinition.from_h(c["definition"]), c["now"])
      differs(c["alert"], alert)
    end
  end

  def test_format_number
    each_case(FORMAT["numbers"]) { |c| differs(c["text"], Cronwatch::Evaluate.format_number(c["n"])) }
  end

  def test_cap_output
    each_case(FORMAT["capOutput"]) do |c|
      output = Cronwatch::Output.cap(c["prefix"] + (c["piece"] * c["times"]))
      differs([c["length"], c["sha256"]], [Cronwatch::JS.length16(output), Digest::SHA256.hexdigest(output)])
    end
  end

  def expect_from(value)
    return value unless value.is_a?(Hash)
    return ->(output) { output.length > 3 } if value["callable"]

    Regexp.new(value["regex"]["source"], value["regex"]["flags"].include?("i") ? Regexp::IGNORECASE : 0)
  end

  def test_to_stored
    each_case(FORMAT["toStored"]) do |c|
      fields = c["definition"].to_h { |k, v| [k, k == "expect" ? expect_from(v) : v] }
      differs(c["stored"], Cronwatch::Serialize.to_stored(Cronwatch::JobDefinition.from_h(fields)))
    end
  end

  def test_check_expectation
    each_case(FORMAT["checkExpectation"]) do |c|
      differs(c["result"], Cronwatch::Serialize.check_expectation(expect_from(c["expect"]), c["output"]))
    end
  end

  # ---------------------------------------------------------------- health

  HEALTH = fixture("health.json")

  def state_from(hash)
    hash && Cronwatch::JobState.from_h(hash)
  end

  def test_job_health
    each_case(HEALTH["jobHealth"]) do |c|
      last = c["lastRun"] && Cronwatch::Run.from_h(c["lastRun"])
      differs(c["health"], Cronwatch::Evaluate.job_health(Cronwatch::JobDefinition.from_h(c["definition"]), last, state_from(c["state"]), c["now"]).to_s)
    end
  end

  def test_summarize
    each_case(HEALTH["summarize"]) do |c|
      stored = Cronwatch::StoredJob.from_h(c["stored"])
      recent = c["recent"].map { |r| Cronwatch::Run.from_h(r) }
      differs(c["summary"], Cronwatch::Evaluate.summarize(stored, recent, state_from(c["state"]), c["nextExpectedAt"], c["now"]))
    end
  end

  def test_percentile_and_median
    each_case(HEALTH["percentile"]) { |c| differs(c["percentile"], Cronwatch::Stats.percentile(c["values"], c["p"])) }
    each_case(HEALTH["median"]) { |c| differs(c["median"], Cronwatch::Stats.median(c["values"])) }
  end

  def test_normalize_state
    each_case(HEALTH["normalizeState"]) { |c| differs(c["normalized"], Cronwatch::Evaluate.normalize_state(state_from(c["state"]), "j")) }
  end

  def test_mute_opens
    each_case(HEALTH["muteOpens"]) { |c| differs(c["muted"], Cronwatch::Evaluate.mute_opens(state_from(c["previous"]), state_from(c["next"]))) }
  end

  def test_is_stuck
    each_case(HEALTH["isStuck"]) do |c|
      differs(c["stuck"], Cronwatch::Evaluate.stuck?(Cronwatch::JobDefinition.from_h(c["definition"]), Cronwatch::Run.from_h(c["run"]), c["now"]))
    end
  end

  # ---------------------------------------------------------------- output

  OUTPUT = fixture("output.json")

  # Long text travels as { "parts" => [[piece, times], ...] }.
  def self.expand(spec)
    spec.is_a?(Hash) && spec.key?("parts") ? spec["parts"].map { |piece, times| piece * times }.join : spec
  end

  def expand(spec) = self.class.expand(spec)

  # A result as the fixtures hold it: the text, or when long its length in UTF-16 code units and SHA-256.
  def self.digest(text)
    return nil if text.nil?

    length = Cronwatch::JS.length16(text)
    length <= 400 ? { "text" => text } : { "length" => length, "sha256" => Digest::SHA256.hexdigest(text) }
  end

  def digest(text) = self.class.digest(text)

  def test_output_cap_is_the_sdks
    assert_equal OUTPUT["outputCap"], Cronwatch::Output::CAP
  end

  def test_redact_secrets
    each_case(OUTPUT["redact"]) { |c| differs(c["result"], digest(Cronwatch::Output.redact_secrets(expand(c["input"])))) }
  end

  def test_error_message
    each_case(OUTPUT["errorMessage"]) do |c|
      error =
        if c.key?("value")
          expand(c["value"])
        else
          Object.const_get(c["name"]).new(expand(c["message"])).tap { |e| e.set_backtrace(c["frames"]) }
        end
      differs(c["result"], digest(Cronwatch::Output.error_message(error)))
    end
  end

  def self.expand_lines(lines)
    lines.flat_map do |line|
      if line.is_a?(Hash) && line.key?("numbered")
        Array.new(line["count"]) do |i|
          head = "#{line["numbered"]}#{i} "
          head + ("x" * [0, line["width"] - Cronwatch::JS.length16(head)].max)
        end
      else
        [expand(line)]
      end
    end
  end

  def test_expect_text
    each_case(OUTPUT["expectText"]) do |c|
      run = Cronwatch::Run.new(id: "r", job: "j", status: :running, started_at: T0, finished_at: nil, duration_ms: nil,
                               error: nil, output: nil, metrics: {}, trigger: "run")
      recorder = Cronwatch::RunRecorder.new(run, 60_000)
      self.class.expand_lines(c["lines"]).each { |line| recorder.context.log(line) }
      text = recorder.expect_text
      checks = c["checks"].map { |check| { "expect" => check["expect"], "result" => Cronwatch::Serialize.check_expectation(check["expect"], text) } }
      differs([c["expectText"], c["output"], c["checks"]], [digest(text), digest(recorder.output), checks])
    end
  end

  # ---------------------------------------------------------------- store

  STORE = fixture("store.json")

  def test_memory_prune
    each_case(STORE["prune"]) do |c|
      store = Cronwatch::Stores::Memory.new
      mismatch = nil
      c["events"].each do |event|
        if event.key?("insert")
          event["insert"].each { |run| store.insert_run(Cronwatch::Run.from_h(run)) }
        else
          pruned = store.prune(event["prune"])
          remaining = event["remaining"].keys.to_h { |job| [job, store.list_runs(job, 100).map(&:id)] }
          mismatch ||= differs([event["pruned"], event["remaining"]], [pruned, remaining])
        end
      end
      mismatch
    end
  end

  # ---------------------------------------------------------------- channels

  CHANNELS = fixture("channels.json")
  CHANNEL_ALERTS = CHANNELS["alerts"].to_h { |a| [a["name"], a["alert"]] }

  # Stands in for Net::HTTP, keeping the last request.
  class FakeHTTP
    attr_accessor :status, :body
    attr_reader :last

    def initialize
      @status = 200
      @body = ""
    end

    def post(url, body, headers)
      @last = { "url" => url, "headers" => headers, "body" => body }
      Cronwatch::HTTP::Response.new(status: @status, body: @body)
    end
  end

  def channel_for(c, http)
    options = c["options"]
    link = options["link"] ? ->(alert) { "https://app.example/cronwatch/jobs/#{alert.job}" } : nil
    case c["channel"]
    when "slack" then Cronwatch::Alerts::Slack.new(webhook_url: options["webhookUrl"], link: link, http: http)
    when "discord" then Cronwatch::Alerts::Discord.new(webhook_url: options["webhookUrl"], link: link, http: http)
    when "webhook" then Cronwatch::Alerts::Webhook.new(url: options["url"], headers: options["headers"] || {}, secret: options["secret"], http: http)
    end
  end

  def test_channel_payloads
    each_case(CHANNELS["sends"]) do |c|
      http = FakeHTTP.new
      channel_for(c, http).call(Cronwatch::Alert.from_h(CHANNEL_ALERTS.fetch(c["alert"])))
      request = http.last
      differs([c["url"], c["headers"], c["body"]], [request["url"], request["headers"], digest(request["body"])])
    end
  end

  def test_channel_failures
    first = Cronwatch::Alert.from_h(CHANNELS["alerts"][0]["alert"])
    each_case(CHANNELS["failures"]) do |c|
      http = FakeHTTP.new
      http.status = c["status"]
      http.body = c["body"]
      begin
        channel_for(c, http).call(first)
        next "expected an error: #{c["error"]}"
      rescue RuntimeError => e
        differs(c["error"], e.message)
      end
    end
  end
end
