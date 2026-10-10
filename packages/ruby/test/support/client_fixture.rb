# frozen_string_literal: true

require "json"

# conformance/client.json, the first fixture driven through the client's
# public API: the run ids start, resume, and record_run take, and stored data
# a newer release wrote surviving a check, a silence, an unsilence, a
# summary, and a run. Shared by the memory store's replay and the
# ActiveRecord store's.
module ClientFixture
  FIXTURE = JSON.parse(File.read(File.expand_path("../../../../conformance/client.json", __dir__)))
  T0 = 1_767_605_400_000

  # The SDK's method names, as the gem spells them in its messages.
  METHODS = { "start" => "start", "resume" => "resume", "recordRun" => "record_run" }.freeze

  module_function

  # Each case's error text as the gem writes it, or nil when it is accepted.
  def run_id_outcome(method, id)
    client = Cronwatch.new(now: -> { T0 }, cron_secret: nil, alerts: [])
    job = client.job("j")
    case method
    when "start" then job.start(id: id).finish
    when "resume" then job.resume(id)
    when "recordRun"
      client.record_run({ id: id, job: "j", status: "ok", startedAt: T0 - 1000, finishedAt: T0, durationMs: 1000,
                          error: nil, output: nil, metrics: {}, trigger: "run" })
    end
    nil
  rescue ArgumentError => e
    e.message
  ensure
    client&.close
  end

  def expected_error(c)
    c["error"]&.sub(/\ArecordRun:/, "record_run:")
  end

  # Replays unknownFields over `store`, yielding each step's name, what was
  # expected and what the store and the channel hold after it, as JSON
  # values; the summary step also yields its summary.
  def replay_unknown_fields(store)
    fixture = FIXTURE["unknownFields"]
    seed = fixture["seed"]
    now = 0
    sent = []
    errors = []
    store.upsert_job(Cronwatch::JobDefinition.from_h(seed["definition"]), seed["createdAt"])
    seed["runs"].each { |run| store.insert_run(Cronwatch::Run.from_h(run)) }
    store.set_state(Cronwatch::JobState.from_h(seed["state"]))
    capture = Cronwatch::Alerts::Custom.new("capture") { |alert| sent << JSON.parse(Cronwatch::JS.json(alert.to_h)) }
    client = Cronwatch.new(store: store, now: -> { now }, cron_secret: nil, alerts: [capture],
                           on_error: ->(error, where) { errors << "#{where}: #{error.message}" })
    fixture["steps"].each do |step|
      now = step["at"]
      case step["op"]
      when "check" then client.check
      when "silence" then client.silence("keep", for: step["for"])
      when "unsilence" then client.unsilence("keep")
      when "summary"
        yield "summary", sorted(step["summary"]), sorted(as_json(client.job_summary("keep").to_h))
      when "declareAndRun"
        now = step["startedAt"]
        handle = client.job("keep", **step["declared"].to_h { |k, v| [Cronwatch::Naming.snake(k), v] }).start(id: step["id"])
        now = step["finishedAt"]
        handle.finish(step["output"])
      else raise "unknown step #{step["op"]}"
      end
      got = {
        "job" => as_json(store.get_job("keep").to_h), "state" => as_json(store.get_state("keep").to_h),
        "runs" => store.list_runs("keep", 10).map { |run| as_json(run.to_h) },
        "alerts" => sent.slice!(0..), "errors" => errors.slice!(0..)
      }
      yield step["op"], step["expect"], got
    end
  ensure
    client&.close
  end

  # A value as the JSON it writes, read back, so hashes compare by content.
  def as_json(value)
    JSON.parse(Cronwatch::JS.json(value))
  end

  # A summary's open conditions follow the stored state's key order, which
  # Postgres's jsonb does not keep: compared as a set.
  def sorted(summary)
    summary.merge("open" => summary["open"].sort)
  end
end
