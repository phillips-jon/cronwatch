# frozen_string_literal: true

# The conformance fixtures are generated in UTC, and a schedule without a
# timezone is read in the process's zone, so the tests run in UTC too.
ENV["TZ"] = "UTC"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cronwatch"
require "minitest/autorun"

module TestHelpers
  T0 = Time.utc(2026, 1, 5, 9, 30).to_i * 1000 # Monday 2026-01-05 09:30:00Z
  SEC = 1000
  MIN = 60_000
  HOUR = 3_600_000

  # A clock the test moves by hand.
  class Clock
    attr_accessor :now

    def initialize(start = T0)
      @now = start
    end

    def advance(ms)
      @now += ms
    end

    def to_proc
      -> { @now }
    end
  end

  # A channel that keeps what it is sent.
  class Capture
    attr_reader :name, :alerts

    def initialize(name = "capture")
      @name = name
      @alerts = []
      @lock = Mutex.new
    end

    def call(alert)
      @lock.synchronize { @alerts << alert }
    end

    def types
      @lock.synchronize { @alerts.map(&:type) }
    end
  end

  # Wraps a store so the named methods raise while they are in `broken`.
  class Flaky
    def initialize(store, broken)
      @store = store
      @broken = broken
    end

    def respond_to_missing?(name, include_private = false)
      @store.respond_to?(name, include_private)
    end

    def method_missing(name, *args, &block)
      return super unless @store.respond_to?(name)
      raise "store down: #{name}" if @broken.include?(name)

      @store.public_send(name, *args, &block)
    end
  end

  def make(**options)
    clock = Clock.new
    capture = Capture.new
    client = Cronwatch.new(now: clock.to_proc, alerts: [capture], cron_secret: nil, **options)
    [client, clock, capture]
  end

  def json(value)
    Cronwatch::JS.json(value)
  end

  def assert_json(expected, actual, message = nil)
    assert_equal json(expected), json(actual), message
  end
end
