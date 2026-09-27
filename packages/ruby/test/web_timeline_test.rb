# frozen_string_literal: true

require_relative "web/helpers"

# The SDK's timeline tests (routes-timeline.test.ts) and firesBetween's
# (schedule.test.ts), against Cronwatch::Web and Cronwatch::Schedule.
class WebTimelineTest < Minitest::Test
  include WebHelpers

  DAY = 24 * HOUR

  # A board with a daily cron that failed today, an interval job that stopped, and a busy one.
  def seeded
    clock = Clock.new(T0 - (30 * HOUR))
    cw = Cronwatch.new(now: clock.to_proc, alerts: [Capture.new], cron_secret: nil)
    web = Cronwatch::Web.new(cw, token: "tok", base_path: "/cronwatch")
    day = Time.utc(2026, 1, 5).to_i * 1000

    hourly = cw.job("hourly", schedule: "0 * * * *", timezone: "UTC")
    t = day - (24 * HOUR)
    while t <= T0 - (30 * MIN)
      clock.now = t
      hourly.run { clock.advance(5 * MIN) }
      t += HOUR
    end
    nightly = cw.job("nightly", schedule: "0 3 * * *", timezone: "UTC")
    clock.now = day + (3 * HOUR)
    assert_raises(RuntimeError) do
      nightly.run do
        clock.advance(400)
        raise "boom"
      end
    end

    sync = cw.job("sync", schedule: "every 30m", grace: "5m")
    clock.now = T0 - (2 * HOUR)
    sync.run { clock.advance(8000) }

    busy = cw.job("busy", schedule: "every 5m", grace: "4m")
    t = T0 - (3 * HOUR)
    while t < T0
      clock.now = t
      busy.run { clock.advance(1000) }
      t += 5 * MIN
    end
    clock.now = T0
    cw.check
    [cw, web]
  end

  def get(web, path)
    send_request(web, "GET", path, BEARER).body
  end

  def count(text, pattern)
    text.scan(pattern).length
  end

  def test_the_board_draws_a_day_timeline
    _, web = seeded
    html = get(web, "/cronwatch/")
    lanes = html[%r{<ol class="lanes">(.*?)</ol>}m, 1]
    lane = ->(name) { lanes.split("<li ").find { |l| l.include?(">#{name}</a>") } }

    # Hourly: a tick for every hour in the last day and the next three, one ok run for each past hour.
    hourly = lane.call("hourly")
    assert_equal 24, count(hourly, /<line class="tick"/), "a tick each hour of the last day"
    assert_equal 3, count(hourly, /<line class="tick ahead"/), "and dashed ones ahead"
    assert_operator count(hourly, /class="run ok"/), :>=, 23
    assert_match %r{<title>hourly: ok at 09:00 UTC, took 5m</title>}, hourly

    # The failed nightly run is a red mark with a note beside it.
    nightly = lane.call("nightly")
    assert_match %r{class="run bad"[^>]*><title>nightly: failed at 03:00 UTC, took 400ms</title>}, nightly
    assert_match %r{<span class="note[^"]*"[^>]*>failed at 03:00</span>}, nightly

    # Sync stopped: due 08:00, nothing started, so a dashed box and a note.
    sync = lane.call("sync")
    assert_match %r{<rect class="missed"[^>]*><title>sync: due 08:00 UTC, nothing started}, sync
    assert_match %r{>due 08:00, nothing ran</span>}, sync

    # Busy runs every 5m, more than the table's twenty runs: the lane reads deeper and draws them all.
    assert_equal 36, count(lane.call("busy"), /class="run ok"/)

    assert_match %r{<i class="now" style="left:[\d.]+%"></i>}, html
    assert_match %r{<span class="nowlabel"[^>]*>now 09:30</span>}, html
    assert_match(/<ul class="vh"><li>busy \(every 5m\): /, html, "the same in words for screen readers")
    assert_match(/@media\(prefers-reduced-motion:reduce\)\{[^}]*animation:none!important/, html)
    refute_match(/<script/i, html.sub('<script src="/cronwatch/app.js" defer></script>', ""), "drawn without script")
    assert_equal "4 jobs, <b>2 needing attention</b>.", html[%r{<p class="headline">(.*?)</p>}, 1]
  end

  def test_a_job_page_draws_its_last_seven_days_today_first
    _, web = seeded
    html = get(web, "/cronwatch/jobs/hourly")
    week = html[%r{<figure class="timeline week">(.*?)</figure>}m, 1]
    assert_equal 7, count(week, /<li class="lane/)
    assert_match(/Today, 5 Jan/, week)
    assert_match(%r{Sun 4 Jan</span><span class="sched">24 runs}, week)
    assert_match(/<line class="nowline"/, week, "a now line on today's lane only")
    assert_equal 1, count(week, /class="nowline"/)
  end

  def test_job_names_are_escaped_inside_the_svg_and_notes
    # Names made through cw.job are plain, but a store can hold anything another writer put there.
    clock = Clock.new
    store = Cronwatch::Stores::Memory.new
    cw = Cronwatch.new(now: clock.to_proc, store: store, alerts: [Capture.new], cron_secret: nil)
    name = %(<svg onload=alert(1)>"&')
    store.upsert_job(Cronwatch::JobDefinition.from_h("name" => name, "schedule" => "0 * * * *", "timezone" => "UTC"), T0 - HOUR)
    store.insert_run(Cronwatch::Run.from_h(
                       "id" => "r1", "job" => name, "status" => "failed", "startedAt" => T0 - (10 * MIN),
                       "finishedAt" => T0 - (9 * MIN), "durationMs" => MIN, "error" => "x", "output" => nil,
                       "metrics" => {}, "trigger" => "run",
                     ))
    web = Cronwatch::Web.new(cw, token: nil, base_path: "/cronwatch")
    ["/cronwatch/", "/cronwatch/jobs/#{Cronwatch::Web::HTML.encode_uri_component(name)}"].each do |path|
      html = send_request(web, "GET", path).body
      refute_match(/<svg onload/, html, path)
      refute_match(/<[a-z]+ onload/i, html, path)
      assert_match(/<title>&lt;svg onload=alert\(1\)&gt;&quot;&amp;&#39;[^<]*: failed at 09:20 UTC/, html, path)
    end
  end

  def test_the_board_draws_at_most_thirty_lanes_and_says_so
    cw, = make
    33.times { |i| cw.run(format("job-%02d", i)) { nil } }
    web = Cronwatch::Web.new(cw, token: nil, base_path: "/cronwatch")
    html = send_request(web, "GET", "/cronwatch/").body
    assert_equal 30, count(html, /<li class="lane">/)
    assert_match(/Showing the first 30 of 33 jobs here/, html)
    assert_equal 33, count(html, /<td class="job">/), "the table lists every job"
  end

  def test_an_empty_store_shows_no_timeline
    cw = Cronwatch.new(alerts: [Capture.new], cron_secret: nil)
    web = Cronwatch::Web.new(cw, token: nil, base_path: "/cronwatch")
    html = send_request(web, "GET", "/cronwatch/").body
    assert_match(/No jobs yet\./, html)
    refute_match(/class="timeline/, html)
  end

  def test_a_job_due_too_often_to_draw_shows_its_cadence_as_a_line
    cw, = make
    cw.job("minutely", schedule: "* * * * *").run { nil }
    web = Cronwatch::Web.new(cw, token: nil, base_path: "/cronwatch")
    html = send_request(web, "GET", "/cronwatch/").body
    assert_match %r{<line class="cadence"[^>]*><title>minutely: due \* \* \* \* \*, too often to mark each time</title>}, html
    refute_match(/class="tick[^"]*" x1="[\d.]+" y1="6"/, html, "no ticks in the lane")
  end

  def test_fires_between_lists_a_crons_fires_the_same_ones_next_fire_gives
    schedule = Cronwatch::Schedule
    hourly = schedule.parse("0 * * * *", "UTC")
    from = Time.utc(2026, 1, 5, 9, 30).to_i * 1000
    fires = schedule.fires_between(hourly, from, from + (24 * HOUR), 100)
    assert_equal 24, fires.length
    t = from
    fires.each { |fire| assert_equal (t = schedule.next_fire(hourly, t, nil)), fire }
    assert_nil schedule.fires_between(hourly, from, from + (24 * HOUR), 23)
    assert_equal [], schedule.fires_between(schedule.parse("0 3 * * *", "UTC"), from, from + HOUR, 5)
    # The night clocks go back in New York: fires only ever move forward.
    ny = schedule.parse("30 * * * *", "America/New_York")
    night = schedule.fires_between(ny, Time.utc(2026, 11, 1, 4).to_i * 1000, Time.utc(2026, 11, 1, 9).to_i * 1000, 20)
    assert night.each_cons(2).all? { |a, b| b > a }, night.inspect
    assert_includes 4..5, night.length, night.length.to_s
  end

  def test_week_runs_limit_follows_the_schedule
    cw, = make
    timeline = Cronwatch::Web::Timeline
    summary = ->(name, **options) { cw.job(name, **options) && cw.job_summary(name) }
    cw.run("plain") { nil }
    assert_equal 50, timeline.week_runs_limit(cw.job_summary("plain"), T0), "no schedule"
    # 24 fires a day over the six days, today and tomorrow (177.5 hours): 177.5 * 1.2 + 10.
    assert_equal 223, timeline.week_runs_limit(summary.call("hourly", schedule: "0 * * * *", timezone: "UTC"), T0)
    assert_equal 500, timeline.week_runs_limit(summary.call("minutely", schedule: "* * * * *"), T0), "too dense to count"
    assert_equal 50, timeline.week_runs_limit(summary.call("daily", schedule: "0 3 * * *", timezone: "UTC"), T0)
    assert_equal 500, timeline.week_runs_limit(summary.call("often", schedule: "every 5m"), T0)
  end
end
