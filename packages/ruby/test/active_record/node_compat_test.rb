# frozen_string_literal: true

require_relative "../support/active_record_helper"
require "open3"

# A Node process and a Ruby process sharing one database: the SDK's SQLite and
# Postgres stores (from the built packages/sdk/dist) and the ActiveRecord
# store replay the same store calls (fixtures/shared_store.json), and each
# must read what the other wrote exactly as it reads its own.
module NodeCompatTests
  REPO = File.expand_path("../../../..", __dir__)
  SCRIPT = File.expand_path("node_store.mjs", __dir__)
  FIXTURE_PATH = File.expand_path("fixtures/shared_store.json", __dir__)
  FIXTURE = Cronwatch::JS.parse(File.read(FIXTURE_PATH))

  def self.unavailable
    @unavailable ||=
      if !system("node", "--version", out: File::NULL, err: File::NULL)
        "node is not on the PATH"
      elsif !File.exist?(File.join(REPO, "packages/sdk/dist/sqlite.js"))
        "packages/sdk/dist is not built: run `npm ci && npm run build` at the repository root"
      elsif !%w[better-sqlite3 pg].all? { |m| Dir.exist?(File.join(REPO, "node_modules", m)) }
        "the SDK's drivers are not installed: run `npm ci` at the repository root"
      else
        false
      end
  end

  def setup
    super
    skip "Node compatibility: #{NodeCompatTests.unavailable}" if NodeCompatTests.unavailable
  end

  def target
    postgres? ? ARSupport::PG_URL : ARSupport::CONFIGS.fetch(:sqlite_file)[:database]
  end

  def node(action, prefix)
    out, err, status = Open3.capture3("node", SCRIPT, action, postgres? ? "postgres" : "sqlite", target, prefix, FIXTURE_PATH)
    assert status.success?, "node #{action} failed: #{err}"
    out
  end

  def node_write(prefix)
    @prefixes << prefix
    Cronwatch::JS.parse(node("write", prefix))
  end

  def ruby_write(store)
    with_conn { |conn| Cronwatch::Stores::ActiveRecord.create_tables!(conn, prefix: store.prefix) }
    pruned = []
    FIXTURE["ops"].each do |step|
      case step["op"]
      when "upsertJob" then store.upsert_job(Cronwatch::JobDefinition.from_h(step["definition"]), step["now"])
      when "insertRun" then store.insert_run(Cronwatch::Run.from_h(step["run"]))
      when "updateRun" then store.update_run(Cronwatch::Run.from_h(step["run"]))
      when "setState" then store.set_state(Cronwatch::JobState.from_h(step["state"]))
      when "deleteJob" then store.delete_job(step["name"])
      when "prune" then pruned << store.prune(step["before"])
      else raise "unknown op #{step["op"]}"
      end
    end
    { "pruned" => pruned }
  end

  # What node_store.mjs `read` prints, from the Ruby store, in the same key order.
  def ruby_read(store)
    out = { "jobs" => store.list_jobs.map(&:to_h) }
    %w[job runs limited last state].each { |key| out[key] = {} }
    FIXTURE["read"]["jobs"].each do |name|
      out["job"][name] = store.get_job(name)&.to_h
      out["runs"][name] = store.list_runs(name, 100).map(&:to_h)
      out["limited"][name] = store.list_runs(name, 1).map(&:to_h)
      out["last"][name] = store.last_run(name)&.to_h
      out["state"][name] = store.get_state(name)&.to_h
    end
    out["running"] = store.running_runs.map(&:to_h)
    out["run"] = FIXTURE["read"]["runs"].to_h { |id| [id, store.get_run(id)&.to_h] }
    Cronwatch::JS.json(out)
  end

  # Postgres hands JSONB back with its own key order, to Node as to Ruby, and
  # JobState#to_h puts the SDK's order back; compare those with keys sorted.
  def comparable(json)
    return json unless postgres?

    sort = ->(v) { v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v[k])] } : (v.is_a?(Array) ? v.map(&sort) : v) }
    Cronwatch::JS.json(sort.call(Cronwatch::JS.parse(json)))
  end

  # Every row of the three tables, JSON columns as the database holds their text.
  def raw_rows(prefix)
    with_conn do |conn|
      order = postgres? ? "seq" : "rowid"
      cast = postgres? ? "::text" : ""
      {
        "jobs" => conn.select_rows("SELECT name, definition#{cast}, created_at, updated_at FROM #{prefix}jobs ORDER BY created_at, name"),
        "runs" => conn.select_rows("SELECT #{order}, id, job, status, started_at, finished_at, duration_ms, error, output, " \
                                   "metrics#{cast}, trigger FROM #{prefix}runs ORDER BY #{order}"),
        "state" => conn.select_rows("SELECT job, state#{cast} FROM #{prefix}state ORDER BY job"),
      }
    end
  end

  def test_ruby_reads_what_node_wrote
    prefix = ARSupport.prefix
    written = node_write(prefix)
    store = Cronwatch::Stores::ActiveRecord.new(prefix: prefix, connection_class: connection_class)
    store.init
    assert_equal [1], written["pruned"]
    node_view = node("read", prefix)
    ruby_view = ruby_read(store)
    refute_includes node_view, "never stored"
    assert_equal comparable(node_view), comparable(ruby_view)
    assert_equal node_view, ruby_view unless postgres?
  end

  def test_node_reads_what_ruby_wrote_and_the_rows_are_the_same
    node_prefix = ARSupport.prefix
    written = node_write(node_prefix)
    store = make_store(create: false)
    assert_equal written, ruby_write(store)

    assert_equal node("read", node_prefix), node("read", store.prefix), "Node reads Ruby's rows as it reads its own"
    assert_equal raw_rows(node_prefix), raw_rows(store.prefix), "the same bytes in every column"
  end

  def test_node_carries_on_from_ruby_and_ruby_from_node
    prefix = ARSupport.prefix
    node_write(prefix)
    store = Cronwatch::Stores::ActiveRecord.new(prefix: prefix, connection_class: connection_class)
    # A Ruby client finishes the run Node left running and checks every job.
    clock = TestHelpers::Clock.new(1_767_606_100_000)
    capture = TestHelpers::Capture.new
    client = Cronwatch.new(store: store, now: clock.to_proc, alerts: [capture], cron_secret: nil)
    client.job("every-5", schedule: "every 5m", timeout: "2m", max_duration: "90s").run { |job| job.log("from ruby") }
    clock.advance(10 * TestHelpers::MIN)
    result = client.check
    assert_includes result.jobs.map(&:name), "nightly-report"
    assert_equal "from ruby", store.last_run("every-5").output
    node_view = Cronwatch::JS.parse(node("read", prefix))
    assert_equal "from ruby", node_view["last"]["every-5"]["output"]
    assert_equal store.get_state("every-5").to_h.keys.sort, node_view["state"]["every-5"].keys.sort
    assert_equal comparable(Cronwatch::JS.json(node_view)), comparable(ruby_read(store))
  end

  # One compareAndSetState from Node: whether it wrote, and the state it then reads.
  def node_cas(prefix, state, expected)
    out, err, status = Open3.capture3("node", SCRIPT, "cas", postgres? ? "postgres" : "sqlite", target, prefix,
                                      Cronwatch::JS.json(state.to_h), expected.to_s)
    assert status.success?, "node cas failed: #{err}"
    Cronwatch::JS.parse(out)
  end

  # Versions written by either side count for the other: a Node process and a
  # Ruby process sharing a job's state refuse each other's stale writes.
  def test_node_and_ruby_take_turns_on_one_jobs_state_version
    store = make_store
    v = ->(version, failures) { Cronwatch::JobState.from_h("job" => "v", "open" => {}, "consecutiveFailures" => failures, "silencedUntil" => nil, "lastAlertAt" => nil, "version" => version) }
    assert store.compare_and_set_state(v.call(1, 1), 0), "Ruby writes the first version"
    stale = node_cas(store.prefix, v.call(1, 9), 0)
    assert_equal false, stale["written"], "Node's write from before it is refused"
    fresh = node_cas(store.prefix, v.call(2, 2), 1)
    assert_equal true, fresh["written"]
    assert_equal 2, fresh["state"]["version"]
    refute store.compare_and_set_state(v.call(2, 7), 1), "Ruby's stale write is refused"
    assert store.compare_and_set_state(v.call(3, 3), 2)
    late = node_cas(store.prefix, v.call(3, 0), 2)
    assert_equal [false, 3, 3], [late["written"], late["state"]["version"], late["state"]["consecutiveFailures"]], "Node reads Ruby's version"
    assert_equal comparable(Cronwatch::JS.json(v.call(3, 3).to_h)), comparable(Cronwatch::JS.json(store.get_state("v").to_h))

    # State Node wrote before versions existed counts as 0 for Ruby too.
    store.set_state(Cronwatch::JobState.from_h("job" => "old", "open" => {}, "consecutiveFailures" => 4, "silencedUntil" => nil, "lastAlertAt" => nil))
    assert_equal true, node_cas(store.prefix, v.call(1, 5).tap { |s| s.job = "old" }, 0)["written"]
    assert_equal 1, store.get_state("old").version
  end

  def test_the_tables_are_the_same_whoever_creates_them
    node_prefix = ARSupport.prefix
    node_write(node_prefix)
    ruby_prefix = ARSupport.prefix
    @prefixes << ruby_prefix
    with_conn { |conn| Cronwatch::Stores::ActiveRecord.create_tables!(conn, prefix: ruby_prefix) }
    assert_equal schema_of(node_prefix).gsub(node_prefix, "PREFIX_"), schema_of(ruby_prefix).gsub(ruby_prefix, "PREFIX_")
  end

  def schema_of(prefix)
    with_conn do |conn|
      if postgres?
        columns = conn.select_rows(<<~SQL)
          SELECT table_name, column_name, data_type, is_nullable, column_default FROM information_schema.columns
          WHERE table_name IN ('#{prefix}jobs', '#{prefix}runs', '#{prefix}state') ORDER BY table_name, ordinal_position
        SQL
        indexes = conn.select_rows("SELECT indexname, indexdef FROM pg_indexes WHERE tablename LIKE '#{prefix}%' ORDER BY indexname")
        Cronwatch::JS.json([columns, indexes])
      else
        conn.select_rows("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name LIKE '#{prefix}%' ORDER BY name").to_s
      end
    end
  end
end

class NodeCompatSqliteTest < Minitest::Test
  include ActiveRecordStoreHarness
  include NodeCompatTests

  def database = :sqlite_file
end

class NodeCompatPostgresTest < Minitest::Test
  include ActiveRecordStoreHarness
  include NodeCompatTests

  def database = :postgres
end
