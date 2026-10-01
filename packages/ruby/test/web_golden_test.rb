# frozen_string_literal: true

require_relative "web/helpers"

# Replays test/web/golden.json, the SDK routes' answers to a fixed seed
# (written by test/web/golden.mjs), against Cronwatch::Web seeded the same
# way, and compares status, headers and body byte for byte. Run ids are
# random on both sides, so each becomes <id:N> in order of first appearance.
class WebGoldenTest < Minitest::Test
  include WebHelpers

  GOLDEN = File.expand_path("web/golden.json", __dir__)
  UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
  DAY = 24 * HOUR
  # The one header the SDK leaves to the server.
  IGNORED_HEADERS = %w[content-length].freeze

  # The seed in golden.mjs, step for step.
  def seed
    clock = Clock.new
    cw = Cronwatch.new(now: clock.to_proc, store: Cronwatch::Stores::Memory.new,
                       alerts: [Cronwatch::Alerts::Custom.new("capture") { nil }], cron_secret: nil)
    quietly = lambda do |&block|
      block.call
    rescue StandardError
      nil
    end

    nightly = cw.job("nightly-report",
                     schedule: "0 2 * * *", timezone: "UTC", grace: "15m", max_duration: "10m", budget: { cost: 2 },
                     expect: "Report written", failures_before_alert: 2, description: "Builds the <b>PDF</b>",
                     tags: ["reports", "<t>"])
    durations = [2000, 2500, 90_000, 3100, 1800]
    durations.each_with_index do |duration, i|
      clock.now = T0 - ((5 - i) * DAY) - (7 * HOUR) - (30 * MIN)
      quietly.call do
        nightly.run do |job|
          job.log(i == 3 ? "Wrote nothing" : "Report written:", "report-#{i}.pdf")
          job.metric("cost", i == 4 ? 2.5 : 1.2)
          job.metric("rows", 40 + i)
          job.metric("2", 0.123456)
          clock.advance(duration)
        end
      end
    end

    broken = cw.job("broken", expect: "done")
    clock.now = T0 - (2 * HOUR)
    quietly.call do
      broken.run do |job|
        job.log("half way <script>alert(1)</script>")
        clock.advance(450)
      end
    end

    sync = cw.job("sync-users", schedule: "*/15 * * * *", grace: 60_000, timeout: "5m")
    clock.now = T0 - (3 * HOUR)
    quietly.call { sync.run { clock.advance(12_345) } }

    cw.job("never-ran", schedule: "0 * * * *")

    # A run as a foreign or damaged row could hold it: started before the year 1.
    far_back = cw.job("far-back", timeout: "5m", expect: "far")
    clock.now = -62_135_596_800_001
    quietly.call { far_back.run { clock.advance(1000) } }

    # Cron jobs whose last run is as far off: counted from the first
    # millisecond of the year 1, the first is due then; after 9999 the other
    # is never due again.
    far_cron_back = cw.job("far-cron-back", schedule: "0 2 * * *", timezone: "UTC", grace: "10m")
    clock.now = -62_135_596_800_001
    far_cron_back.run { clock.advance(1000) }
    far_cron_ahead = cw.job("far-cron-ahead", schedule: "0 2 * * *", timezone: "UTC", grace: "10m")
    clock.now = 253_402_300_800_000
    far_cron_ahead.run { clock.advance(1000) }
    clock.now = T0
    cw
  end

  def test_the_json_api_and_pages_match_the_sdk_routes
    golden = JSON.parse(File.read(GOLDEN))
    assert_equal T0, golden["t0"]
    cw = seed
    web = Cronwatch::Web.new(cw, token: "tok", base_path: "/cronwatch")
    ids = {}
    golden["captures"].each do |capture|
      label = "#{capture["method"]} #{capture["path"]}"
      path = capture["path"].sub(/\{run:([^:}]+):(\d+)\}/) { cw.runs(Regexp.last_match(1), 50)[Regexp.last_match(2).to_i].id }
      res = send_request(web, capture["method"], path, capture["headers"], capture["body"])
      body =
        if res.headers["content-type"] == "image/png"
          # PNGs are kept as base64, so the fixture stays text.
          "base64:#{[res.body].pack("m0")}"
        else
          res.body.gsub(UUID) { |id| ids[id] ||= "<id:#{ids.size}>" }
        end

      assert_equal capture["status"], res.status, label
      headers = res.headers.reject { |k, _| IGNORED_HEADERS.include?(k) }
      assert_equal capture["responseHeaders"].sort.to_h, headers.sort.to_h, label
      # GET <base>/api names the library serving it; the fixture holds placeholders.
      expected = capture["responseBody"].sub('"<library>"', '"cronwatch"').sub('"<language>"', '"ruby"')
                                        .sub('"<version>"', JSON.generate(Cronwatch::VERSION))
      assert_equal expected, body, label
    end
  end
end
