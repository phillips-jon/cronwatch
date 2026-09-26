# frozen_string_literal: true

require_relative "test_helper"

begin
  require "sidekiq"
rescue LoadError
  # Sidekiq is optional; these tests need it.
end

if defined?(::Sidekiq::Job)
  require "cronwatch/sidekiq"
  # Sidekiq 8.1 has Sidekiq.testing!; 7 has sidekiq/testing.
  if ::Sidekiq.respond_to?(:testing!)
    ::Sidekiq.testing!(:fake)
  else
    require "sidekiq/testing"
    ::Sidekiq::Testing.fake!
  end
  ::Sidekiq.default_configuration.logger.level = ::Logger::WARN

  module SidekiqJobs
    class NightlyReportJob
      include ::Sidekiq::Job
      include Cronwatch::Sidekiq
      cronwatch schedule: "0 2 * * *", grace: "15m", expect: "Report written"

      def perform(rows)
        cronwatch.log("Report written:", rows)
        cronwatch.metric(:rows, rows)
        :finished
      end
    end

    class HardWorker
      include ::Sidekiq::Worker
      include Cronwatch::Sidekiq
      cronwatch name: "hard", schedule: "every 1h"

      class Boom < StandardError; end

      def perform(mode)
        cronwatch.log("working")
        raise Boom, "it broke" if mode == "raise"
      end
    end

    # A Sidekiq job CronWatch does not watch.
    class PlainWorker
      include ::Sidekiq::Job

      def perform = :plain
    end
  end

  class SidekiqTest < Minitest::Test
    include TestHelpers

    M = Cronwatch::Sidekiq::ServerMiddleware

    def setup
      @client, @clock, @capture = make
      Cronwatch.client = @client
      ::Sidekiq::Testing.server_middleware(&:clear)
    end

    def teardown
      Cronwatch.client = nil
    end

    def runs(name)
      @client.runs(name)
    end

    # The chain Sidekiq's processor calls for each job, built as Sidekiq builds it.
    def chain
      ::Sidekiq::Middleware::Chain.new(::Sidekiq.default_configuration) { |c| c.add(M) }
    end

    # Sidekiq.configure_server yields only in a server process.
    def as_server
      server = ::Sidekiq.method(:server?).unbind
      ::Sidekiq.singleton_class.send(:remove_method, :server?)
      ::Sidekiq.singleton_class.send(:define_method, :server?) { true }
      yield
    ensure
      ::Sidekiq.singleton_class.send(:remove_method, :server?)
      ::Sidekiq.singleton_class.send(:define_method, :server?, server)
    end

    def payload(klass, *args, **extra)
      { "class" => klass.name, "args" => args, "jid" => "abc123", "queue" => "default", **extra.transform_keys(&:to_s) }
    end

    # ActiveSupport's underscore when it is loaded, the same rules without it otherwise.
    def test_the_name_is_the_class_name_without_job_dasherized
      assert_equal "sidekiq-jobs:nightly-report", SidekiqJobs::NightlyReportJob.cronwatch_name
      assert_equal "hard", SidekiqJobs::HardWorker.cronwatch_name
      assert_equal "html-parser-worker", Cronwatch::Monitored.default_name(Class.new { def self.name = "HTMLParserWorker" })
    end

    def test_a_run_through_the_server_chain_is_recorded
      job = SidekiqJobs::NightlyReportJob.new
      result = chain.invoke(job, payload(SidekiqJobs::NightlyReportJob, 42), "default") { job.perform(42) }
      assert_equal :finished, result
      run = runs("sidekiq-jobs:nightly-report").first
      assert_equal :ok, run.status
      assert_equal "sidekiq", run.trigger
      assert_equal "Report written: 42", run.output
      assert_equal({ "rows" => 42 }, run.metrics)
      assert_same Cronwatch::Monitored::NULL_CONTEXT, job.cronwatch, "the context is the run's only while it runs"
    end

    def test_a_job_that_raises_is_recorded_as_failed_and_raises_to_sidekiq
      job = SidekiqJobs::HardWorker.new
      error = assert_raises(SidekiqJobs::HardWorker::Boom) do
        chain.invoke(job, payload(SidekiqJobs::HardWorker, "raise"), "default") { job.perform("raise") }
      end
      assert_equal "it broke", error.message
      run = runs("hard").first
      assert_equal :failed, run.status
      assert_match(/\ASidekiqJobs::HardWorker::Boom: it broke\n/, run.error)
      assert_equal "working", run.output
      assert_equal [:failed], @capture.types
    end

    # What Sidekiq raises into a busy job when a deploy outlasts its
    # timeout: the job goes back on the queue, and its run is not left running.
    def test_a_job_stopped_by_sidekiq_shutdown_is_recorded_and_the_shutdown_raised
      job = SidekiqJobs::HardWorker.new
      assert_raises(::Sidekiq::Shutdown) do
        chain.invoke(job, payload(SidekiqJobs::HardWorker, "ok"), "default") { raise ::Sidekiq::Shutdown }
      end
      run = runs("hard").first
      assert_equal :failed, run.status
      assert_equal "Interrupted: Sidekiq::Shutdown", run.error.split("\n").first
      refute_nil run.finished_at
    end

    def test_sidekiq_testing_inline_runs_the_middleware
      ::Sidekiq::Testing.server_middleware { |c| c.add(M) }
      ::Sidekiq::Testing.inline! do
        SidekiqJobs::NightlyReportJob.perform_async(7)
        assert_raises(SidekiqJobs::HardWorker::Boom) { SidekiqJobs::HardWorker.perform_async("raise") }
        SidekiqJobs::HardWorker.perform_async("ok")
      end
      assert_equal [:ok], runs("sidekiq-jobs:nightly-report").map(&:status)
      assert_equal [:ok, :failed], runs("hard").map(&:status)
    end

    def test_fake_mode_drain_runs_the_middleware
      ::Sidekiq::Testing.server_middleware { |c| c.add(M) }
      SidekiqJobs::NightlyReportJob.perform_async(3)
      assert_empty runs("sidekiq-jobs:nightly-report"), "queued, not run"
      SidekiqJobs::NightlyReportJob.drain
      assert_equal "Report written: 3", runs("sidekiq-jobs:nightly-report").first.output
    end

    def test_anything_else_passes_through
      job = SidekiqJobs::PlainWorker.new
      assert_equal :plain, chain.invoke(job, payload(SidekiqJobs::PlainWorker), "default") { job.perform }
      wrapped = payload(SidekiqJobs::NightlyReportJob, 1, wrapped: "SomeActiveJob")
      assert_equal :done, chain.invoke(SidekiqJobs::NightlyReportJob.new, wrapped, "default") { :done }
      assert_empty @client.jobs_with_runs.flat_map(&:runs)
    end

    def test_install_adds_the_middleware_to_a_server_once
      config = ::Sidekiq.default_configuration
      config.server_middleware.remove(M)
      Cronwatch::Sidekiq.install
      refute config.server_middleware.exists?(M), "not a server: nothing to add"

      as_server do
        Cronwatch::Sidekiq.install
        Cronwatch::Sidekiq.install
      end
      assert_equal 1, config.server_middleware.count { |entry| entry.klass == M }
    ensure
      config&.server_middleware&.remove(M)
    end

    def test_ready_declares_every_job_and_the_check_worker_checks
      Cronwatch::Sidekiq.ready!
      names = @client.defined_jobs.map(&:name)
      assert_includes names, "sidekiq-jobs:nightly-report"
      assert_includes names, "hard"

      assert_nil Cronwatch::Sidekiq::CheckWorker.new.perform
      assert_empty @capture.types, "known before they ever ran"
      @clock.now = Time.utc(2026, 1, 6, 2, 20).to_i * 1000
      Cronwatch::Sidekiq::CheckWorker.new.perform
      assert_equal [:missed, :missed], @capture.types.sort
      assert_equal false, Cronwatch::Sidekiq::CheckWorker.get_sidekiq_options["retry"]
    end
  end
end
