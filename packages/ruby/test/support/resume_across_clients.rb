# frozen_string_literal: true

# The body of the SDK's "resume in a second client on the same store" test
# (start-finish.test.ts), run against the memory store by
# test/start_finish_test.rb and against the SQL stores by
# test/active_record/start_finish_test.rb.
module ResumeAcrossClients
  include TestHelpers

  def check_resume_across_clients(store_a, store_b)
    clock = Clock.new
    capture = Capture.new
    errors = []
    on_error = ->(error, _where) { errors << error }
    first = Cronwatch.new(store: store_a, now: clock.to_proc, alerts: [capture], cron_secret: nil, on_error: on_error)
    second = Cronwatch.new(store: store_b, now: clock.to_proc, alerts: [capture], cron_secret: nil, on_error: on_error)
    options = { expect: "sent", budget: { emails: 100 } }
    started = first.job("digest", **options).start(id: "evt-1")
    started.log("loaded 40 recipients")
    started.log("token=abc123")
    started.metric(:recipients, 40)
    started.flush
    midway = first.get_run("evt-1")
    assert_equal :running, midway.status
    assert_equal "loaded 40 recipients\ntoken=[redacted]", midway.output

    clock.advance(5 * MIN)
    second.job("digest", **options)
    resumed = second.resume_run("digest", "evt-1")
    assert resumed.active?
    assert_equal midway.started_at, resumed.started_at
    resumed.log("sent 40 emails")
    resumed.metric(:emails, 40)
    run = resumed.finish
    assert_equal :ok, run.status
    assert_equal 5 * MIN, run.duration_ms
    stored = first.get_run("evt-1")
    assert_equal :ok, stored.status
    assert_equal "loaded 40 recipients\ntoken=[redacted]\nsent 40 emails", stored.output
    assert_equal({ "recipients" => 40, "emails" => 40 }, stored.metrics)
    assert_equal [], capture.types
    assert_equal [], errors
    first.close
    second.close
  end
end
