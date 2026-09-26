# frozen_string_literal: true

require_relative "test_helper"

# The SDK's store conformance test (stores.test.ts). A store added later
# (ActiveRecord) should pass the same module.
module StoreConformance
  def run_record(id, job, status, started_at)
    Cronwatch::Run.new(id: id, job: job, status: status, started_at: started_at,
                       finished_at: status == :running ? nil : started_at + 10, duration_ms: status == :running ? nil : 10,
                       error: nil, output: nil, metrics: { "n" => 1 }, trigger: "run")
  end

  def definition(hash)
    Cronwatch::JobDefinition.from_h(hash)
  end

  def test_store_conformance
    store = make_store
    store.init if store.respond_to?(:init)
    assert_nil store.get_job("a")
    store.upsert_job(definition("name" => "a", "schedule" => "every 5m"), 100)
    store.upsert_job(definition("name" => "a", "schedule" => "every 10m", "tags" => ["x"]), 200)
    store.upsert_job(definition("name" => "b"), 300)
    store.upsert_job(definition("name" => "B"), 300)
    store.upsert_job(definition("name" => "_c"), 300)
    a = store.get_job("a")
    assert_equal 100, a.created_at, "created_at survives upsert"
    assert_equal 200, a.updated_at
    assert_equal({ "name" => "a", "schedule" => "every 10m", "tags" => ["x"] }, a.definition.to_h)
    assert_equal %w[B _c a b], store.list_jobs.map(&:name), "code unit order, not locale"

    store.insert_run(run_record("r1", "a", :ok, 1000))
    store.insert_run(run_record("r2", "a", :failed, 2000))
    store.insert_run(run_record("r3", "a", :running, 3000))
    store.insert_run(run_record("r4", "b", :ok, 1500))
    store.insert_run(run_record("rb", "B", :running, 2000))
    store.insert_run(run_record("rc", "_c", :running, 2000))
    assert_equal %w[r3 r2 r1], store.list_runs("a", 10).map(&:id)
    assert_equal %w[r3 r2], store.list_runs("a", 2).map(&:id)
    assert_equal "r3", store.last_run("a").id
    assert_nil store.last_run("none")
    assert_equal %w[rb rc r3], store.running_runs.map(&:id), "oldest first, then insertion order"
    r1 = store.get_run("r1")
    assert_equal({ "n" => 1 }, r1.metrics)
    assert_equal 10, r1.duration_ms
    assert_equal :ok, r1.status

    updated = run_record("r3", "a", :ok, 3000).tap do |r|
      r.output = "line1\nline2"
      r.metrics = { "cost" => 0.25 }
    end
    store.update_run(updated)
    r3 = store.get_run("r3")
    assert_equal :ok, r3.status
    assert_equal "line1\nline2", r3.output
    assert_equal({ "cost" => 0.25 }, r3.metrics)
    assert_equal %w[rb rc], store.running_runs.map(&:id)

    # Forgetting a job while one of its runs is in flight: the run finishing later changes nothing.
    store.delete_job("B")
    store.update_run(run_record("rb", "B", :ok, 2000).tap { |r| r.output = "late" })
    assert_nil store.get_run("rb")
    assert_equal [], store.list_runs("B", 10)
    assert_equal %w[rc], store.running_runs.map(&:id)
    store.delete_job("_c")

    assert_nil store.get_state("a")
    state = ->(h) { Cronwatch::JobState.from_h(h) }
    store.set_state(state.call("job" => "a", "open" => { "failed" => 5 }, "consecutiveFailures" => 2, "silencedUntil" => nil, "lastAlertAt" => 6))
    store.set_state(state.call("job" => "a", "open" => {}, "consecutiveFailures" => 0, "silencedUntil" => 99, "lastAlertAt" => 6))
    assert_equal({ "job" => "a", "open" => {}, "consecutiveFailures" => 0, "silencedUntil" => 99, "lastAlertAt" => 6 }, store.get_state("a").to_h)
    undelivered = { "type" => "failed", "run" => nil, "details" => { "consecutiveFailures" => 1 }, "job" => "a",
                    "definition" => { "name" => "a" }, "title" => "a failed", "message" => "boom", "at" => 7 }
    full = { "job" => "a", "open" => { "stuck" => 7 }, "consecutiveFailures" => 1, "silencedUntil" => nil, "lastAlertAt" => 6,
             "pendingRecovery" => ["missed"], "undelivered" => [undelivered] }
    store.set_state(state.call(full))
    assert_equal Cronwatch::JS.json(full), store.get_state("a").to_json, "pendingRecovery and undelivered round-trip"
    assert_equal [:missed], store.get_state("a").pending_recovery
    assert_equal :failed, store.get_state("a").undelivered[0].type

    store.insert_run(run_record("r5", "a", :running, 500))
    assert_equal 2, store.prune(2500), "r1 and r2 pruned; running r5 kept, and b's r4 kept as b's newest run"
    assert_equal %w[r3 r5], store.list_runs("a", 10).map(&:id)
    assert_equal %w[r4], store.list_runs("b", 10).map(&:id)
    assert_equal 0, store.prune(1_000_000), "however old, each job keeps its newest run, and running runs stay"

    store.delete_job("a")
    assert_nil store.get_job("a")
    assert_equal [], store.list_runs("a", 10)
    assert_nil store.get_state("a")
    assert_equal "b", store.get_job("b").name
    store.close if store.respond_to?(:close)
  end

  # The SDK's store test for compareAndSetState: writes only over the version
  # it was told to expect.
  def test_compare_and_set_state
    store = make_store
    store.init if store.respond_to?(:init)
    v = ->(version, extra = {}) { Cronwatch::JobState.from_h({ "job" => "v", "open" => {}, "consecutiveFailures" => 0, "silencedUntil" => nil, "lastAlertAt" => nil, "version" => version }.merge(extra)) }
    cas = ->(state, expected) { store.compare_and_set_state(state, expected) }
    assert_equal false, cas.call(v.call(2), 1), "no row matches only version 0"
    assert_nil store.get_state("v")
    assert_equal true, cas.call(v.call(1), 0), "no row counts as version 0"
    assert_equal false, cas.call(v.call(1, "consecutiveFailures" => 9), 0), "a write from a stale read is refused"
    assert_equal true, cas.call(v.call(2, "consecutiveFailures" => 1), 1)
    assert_equal false, cas.call(v.call(3), 1)
    assert_equal v.call(2, "consecutiveFailures" => 1).to_json, store.get_state("v").to_json
    store.set_state(Cronwatch::JobState.from_h("job" => "w", "open" => {}, "consecutiveFailures" => 3, "silencedUntil" => nil, "lastAlertAt" => nil))
    assert_equal false, cas.call(v.call(1).tap { |s| s.job = "w" }, 1), "state written before versions counts as 0"
    assert_equal true, cas.call(v.call(1).tap { |s| s.job = "w" }, 0)
    assert_equal 1, store.get_state("w").version
    store.delete_job("v")
    assert_equal false, cas.call(v.call(3), 2), "a forgotten job's state is not written back"
    assert_nil store.get_state("v")
    store.delete_job("w")
  end

  CAS_SCRIPT = JSON.parse(File.read(File.expand_path("../../../conformance/store.json", __dir__)))["compareAndSetState"]

  # conformance/store.json's compareAndSetState script, recorded from the
  # SDK's memory store: which writes go through, and the states stored after
  # each step.
  def test_compare_and_set_state_replays_the_sdk_script
    store = make_store
    store.init if store.respond_to?(:init)
    failures = []
    CAS_SCRIPT.each_with_index do |step, i|
      written = nil
      if step["cas"]
        written = store.compare_and_set_state(Cronwatch::JobState.from_h(step["cas"]), step["expected"])
      elsif step["set"]
        store.set_state(Cronwatch::JobState.from_h(step["set"]))
      else
        store.delete_job(step["forget"])
      end
      expected = Cronwatch::JS.json([step["written"], step["states"]])
      states = { "a" => store.get_state("a")&.to_h, "b" => store.get_state("b")&.to_h }
      actual = Cronwatch::JS.json([written, states])
      failures << "step #{i} #{JSON.generate(step)}\n    expected #{expected}\n    got      #{actual}" unless expected == actual
    end
    assert failures.empty?, failures.join("\n")
  end

  def test_the_store_hands_out_copies
    store = make_store
    store.init if store.respond_to?(:init)
    run = run_record("r1", "a", :ok, 1)
    store.insert_run(run)
    run.metrics["n"] = 99
    fetched = store.get_run("r1")
    fetched.metrics["n"] = 42
    assert_equal({ "n" => 1 }, store.get_run("r1").metrics)
  end

  def test_runs_that_start_in_the_same_millisecond_keep_insertion_order
    store = make_store
    store.init if store.respond_to?(:init)
    %w[x y z].each { |id| store.insert_run(run_record(id, "a", :running, 5)) }
    assert_equal %w[z y x], store.list_runs("a", 10).map(&:id)
    assert_equal %w[x y z], store.running_runs.map(&:id)
  end
end

class MemoryStoreTest < Minitest::Test
  include StoreConformance

  def make_store
    Cronwatch::Stores::Memory.new
  end

  def test_names_sort_by_utf16_code_units
    store = make_store
    # U+FF5E sorts before U+1F600 in UTF-8 bytes, but after it in UTF-16 code
    # units (U+1F600 is the surrogate pair D83D DE00), which is JavaScript's order.
    ["\u{FF5E}", "\u{1F600}", "z"].each { |name| store.upsert_job(definition("name" => name), 1) }
    assert_equal ["z", "\u{1F600}", "\u{FF5E}"], store.list_jobs.map(&:name)
  end
end
