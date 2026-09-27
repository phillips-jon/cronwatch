# frozen_string_literal: true

module Cronwatch
  class Web
    # The dashboard's timelines, markup for markup the SDK's
    # routes/timeline.ts: one lane per job (or per day, on a job's page),
    # drawn on the server as inline SVG so the page needs no script.
    #
    # Every time a job was due is a faint tick, worked out from its schedule
    # with the same functions the checks use (Schedule.fires_between and
    # Schedule.expectation), so the lane shows the cadence the job is meant to
    # keep. Every run it recorded is a solid mark on top, as wide as it took
    # and coloured by how it ended. A slot the check has reported missed is a
    # dashed box. The empty part of a lane carries a short note about anything
    # open, and a visually hidden list says the same things in words.
    #
    # Every time is UTC: without script the page cannot know the viewer's zone.
    module Timeline
      HOUR = 3_600_000
      DAY = 24 * HOUR

      # The board's span: the last day, plus a few hours ahead so what is due soon shows.
      BOARD_BEHIND_MS = DAY
      BOARD_AHEAD_MS = 3 * HOUR
      # How many jobs the board's timeline draws. The table below it lists every job.
      BOARD_LANES = 30
      # Runs read for a lane when the twenty the table reads start inside the
      # span, so a frequent job's lane is not cut short. Older runs than this
      # are shown as not loaded rather than as absent.
      BOARD_RUNS = 200
      # How many days a job's page draws.
      WEEK_DAYS = 7

      # Width of a lane in SVG units. Lanes stretch to fit, so strokes do not scale.
      W = 1000
      # A lane with more due times than this shows its cadence as a dotted line instead.
      MAX_TICKS = 330
      # More missed slots than this are drawn as one dashed band.
      MAX_BOXES = 8
      # The narrowest a missed box is drawn, in SVG units.
      MIN_BOX = 10

      MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze
      WEEKDAYS = %w[Sun Mon Tue Wed Thu Fri Sat].freeze
      STATE_CLASS = { healthy: "ok", late: "warn", failing: "bad", stuck: "bad", silenced: "muted", never_ran: "muted" }.freeze

      # What one lane is drawn from: the job, its runs (any order; only those
      # overlapping the span are drawn), and whether older runs exist that were
      # not read (the lane then says so before its oldest run).
      LaneInput = Struct.new(:job, :runs, :complete, keyword_init: true)
      # Every time the job was or will be due within a span, ascending, and
      # whether there are too many to draw one by one (`times` is then empty).
      DueTimes = Struct.new(:times, :dense, keyword_init: true)
      # The stretch of time a timeline draws, and the moment it was drawn.
      Span = Struct.new(:from, :to, :now, keyword_init: true)
      LaneParts = Struct.new(:svg, :note, :words, keyword_init: true)

      module_function

      def h(value)
        HTML.h(value)
      end

      # toFixed(1).
      def f(value)
        HTML.to_fixed(value, 1)
      end

      # Animation delay for a mark at x, so marks arrive in time order, left to right.
      def delay(x, base = 80, per_unit = 0.75)
        "--d:#{JS.round(base + ([0, x].max * per_unit))}ms"
      end

      def utc(t)
        Time.at(t.div(1000), t % 1000, :millisecond).utc
      end

      # "22:42", in UTC.
      def clock(t)
        JS.iso(t)[11, 5]
      end

      # "Sat 26 Sep", in UTC.
      def day_label(t)
        d = utc(t)
        "#{WEEKDAYS[d.wday]} #{d.day} #{MONTHS[d.month - 1]}"
      end

      # "22:42" on the same UTC day as `now`, otherwise "25 Sep 22:42".
      def when_at(t, now)
        return clock(t) if t.div(DAY) == now.div(DAY)

        d = utc(t)
        "#{d.day} #{MONTHS[d.month - 1]} #{clock(t)}"
      end

      # The job's schedule, parsed, or nil when it has none or it no longer parses.
      def parsed_schedule(job)
        schedule = job.definition.schedule
        return nil unless HTML.truthy?(schedule)

        Schedule.parse(schedule, job.definition.timezone)
      rescue StandardError
        nil
      end

      def safely(fallback)
        yield
      rescue StandardError
        fallback
      end

      # When the job was due within `from` to `to`. A cron's fires come from
      # Schedule.fires_between. An interval is due one period after each run
      # started, and after the last run once a period for as long as nothing
      # runs (the times a missed interval job keeps being asked for); with no
      # run yet, from its next expected time.
      def due_times(job, parsed, runs, from, to)
        return DueTimes.new(times: [], dense: false) if parsed.nil?

        if parsed.interval?
          every = parsed.every_ms
          return DueTimes.new(times: [], dense: true) if (to - from).fdiv(every) > MAX_TICKS

          starts = runs.map(&:started_at).sort
          times = []
          starts.each do |start|
            t = start + every
            times << t if t >= from && t <= to
          end
          t = starts.empty? ? job.next_expected_at : starts.last + every
          unless t.nil?
            t += (from - t).fdiv(every).ceil * every if t < from
            while t <= to
              times << t
              t += every
            end
          end
          return DueTimes.new(times: times.uniq.sort, dense: false)
        end
        times = safely([]) { Schedule.fires_between(parsed, from - 1, to, MAX_TICKS) }
        times.nil? ? DueTimes.new(times: [], dense: true) : DueTimes.new(times: times, dense: false)
      end

      # The slot a missed job was due at, the one the check reported: the first
      # fire its last run does not cover (Schedule.expectation, as on_check
      # works it out). A job that never ran has no run to count from, so the
      # latest due time whose grace has passed stands in. Nil when missed is
      # not open.
      def missed_at(job, parsed, times, now)
        return nil if parsed.nil? || !open?(job, :missed)

        grace = safely(0) { Evaluate.grace_ms(job.definition) }
        last = job.last_run&.started_at
        return safely(nil) { Schedule.expectation(parsed, last, last, grace)&.due_at } unless last.nil?

        past = times.select { |t| t + grace < now }
        past.last
      end

      def open?(job, condition)
        job.open.any? { |c| c.to_s == condition.to_s }
      end

      def tone_of(run, job, now)
        status = run.status.to_s
        return safely(false) { Evaluate.stuck?(job.definition, run, now) } ? "stuck" : "running" if status == "running"
        return "bad" if status == "failed"
        return "timeout" if status == "timeout"

        latest = !job.last_run.nil? && job.last_run.id == run.id
        latest && (open?(job, :over_budget) || open?(job, :slow)) ? "warn" : "ok"
      end

      def timeout_text(job)
        safely("configured") { Duration.format(Evaluate.timeout_ms(job.definition)) }
      end

      # One run, as its tooltip says it.
      def describe_run(run, tone, job, now)
        at = "#{when_at(run.started_at, now)} UTC"
        return "running since #{at}, #{Duration.format(now - run.started_at)} so far" if tone == "running"
        return "running since #{at}, past its #{timeout_text(job)} timeout" if tone == "stuck"

        took = run.duration_ms.nil? ? "" : ", took #{Duration.format(run.duration_ms)}"
        extra = tone == "warn" ? (open?(job, :over_budget) ? ", over budget" : ", slow") : ""
        "#{run.status} at #{at}#{took}#{extra}"
      end

      # The metrics of the job's last run that went over their ceilings.
      def over_ceilings(job)
        metrics = job.last_run&.metrics || {}
        HTML.entries(job.definition.budget).select do |k, limit|
          value = metrics.key?(k) ? metrics[k] : metrics[k.to_sym]
          (value.nil? ? -Float::INFINITY : value) > limit
        end.map(&:first)
      end

      # What is worth saying about the job in a few words, or nil when all is well.
      def lane_note(job, missed, now)
        last = job.last_run
        status = last&.status&.to_s
        return "silenced until #{when_at(job.silenced_until, now)}" if !job.silenced_until.nil? && job.silenced_until > now
        return missed.nil? ? "overdue, nothing ran" : "due #{when_at(missed, now)}, nothing ran" if open?(job, :missed)

        if status == "running"
          stuck = safely(false) { Evaluate.stuck?(job.definition, last, now) }
          return stuck ? "running since #{when_at(last.started_at, now)}, past its #{timeout_text(job)} timeout" : "running since #{when_at(last.started_at, now)}"
        end
        if status == "failed"
          return "failed at #{when_at(last.started_at, now)}#{job.consecutive_failures > 1 ? ", #{job.consecutive_failures} in a row" : ""}"
        end
        return "timed out at #{when_at(last.started_at, now)}" if status == "timeout"
        return "stuck" if open?(job, :stuck)

        if open?(job, :over_budget) && last
          over = over_ceilings(job)
          return "went over budget#{over.empty? ? "" : " on #{over.join(" and ")}"} at #{when_at(last.started_at, now)}"
        end
        return "slow: took #{Duration.format(last.duration_ms)}" if open?(job, :slow) && !last&.duration_ms.nil?
        return "failing" if open?(job, :failed)
        return "no runs yet, first due #{when_at(job.next_expected_at, now)}" if last.nil? && !job.next_expected_at.nil?

        nil
      end

      # Sorted by start, keeping the given order for equal starts, as Array#sort does in JavaScript.
      def by_start(runs)
        runs.each_with_index.sort_by { |r, i| [r.started_at, i] }.map(&:first)
      end

      def lane(input, span, now_in_lane:, label:)
        job = input.job
        from = span.from
        to = span.to
        now = span.now
        x = ->(t) { [W.to_f, [0.0, (t - from).fdiv(to - from) * W].max].min }
        parsed = parsed_schedule(job)
        due = due_times(job, parsed, input.runs, from, to)
        missed = missed_at(job, parsed, due.times, now)
        grace = safely(0) { Evaluate.grace_ms(job.definition) }
        name = label
        busy = []
        inside = now_in_lane && now > from && now < to

        s = +%(<svg class="marks" viewBox="0 0 #{W} 24" preserveAspectRatio="none" aria-hidden="true" focusable="false">)
        s << %(<rect class="ahead" x="#{f(x.call(now))}" y="0" width="#{f(W - x.call(now))}" height="24"/>) if inside
        s << %(<line class="base" x1="0" y1="12" x2="#{W}" y2="12"/>)

        in_span = by_start(input.runs.select { |r| r.started_at <= to && (r.finished_at || now) >= from })
        unless input.complete
          oldest = input.runs.map(&:started_at).min
          if !oldest.nil? && oldest > from
            s << %(<rect class="unloaded" x="0" y="4" width="#{f(x.call(oldest))}" height="16"><title>#{h("#{name}: runs before #{when_at(oldest, now)} UTC are not loaded here")}</title></rect>)
          end
        end

        if due.dense
          s << %(<line class="cadence" x1="0" y1="12" x2="#{W}" y2="12"><title>#{h("#{name}: due #{job.definition.schedule}, too often to mark each time")}</title></line>)
        end
        due.times.each do |t|
          tx = x.call(t)
          s << %(<line class="tick#{t > now ? " ahead" : ""}" x1="#{f(tx)}" y1="6" x2="#{f(tx)}" y2="18" style="#{delay(tx, 0, 0.45)}"/>)
        end

        # Missed slots: the reported one and every later one whose grace has run out.
        if !missed.nil? && missed <= to
          slots = due.dense ? [] : due.times.select { |t| t >= missed && t + grace < now }
          slots.unshift(missed) if !slots.include?(missed) && missed >= from
          title = h("#{name}: due #{when_at(missed, now)} UTC, nothing started#{slots.length > 1 ? " (#{slots.length} slots in this span)" : ""}")
          if due.dense || slots.length > MAX_BOXES
            x1 = x.call([missed, from].max)
            x2 = [x.call(now), x1 + MIN_BOX].max
            s << %(<rect class="missed" x="#{f(x1)}" y="5" width="#{f(x2 - x1)}" height="14" style="#{delay(x1)}"><title>#{title}</title></rect>)
            busy << [x1, x2]
          else
            slots.each do |t|
              next if t < from

              x1 = x.call(t)
              width = [x.call(t + grace) - x1, MIN_BOX].max
              s << %(<rect class="missed" x="#{f(x1)}" y="5" width="#{f(width)}" height="14" style="#{delay(x1)}"><title>#{title}</title></rect>)
              busy << [x1, x1 + width]
            end
          end
        end

        in_span.each do |run|
          tone = tone_of(run, job, now)
          # A zero-width rect is not drawn at all; its stroke gives short runs their width.
          x1 = x.call(run.started_at)
          x2 = [x.call(run.finished_at || now), x1 + 0.5].max
          s << %(<rect class="run #{tone}" x="#{f(x1)}" y="5" width="#{f(x2 - x1)}" height="14" style="#{delay(x1)}"><title>#{h("#{name}: #{describe_run(run, tone, job, now)}")}</title></rect>)
          busy << [x1, x2]
        end

        s << %(<line class="nowline" x1="#{f(x.call(now))}" y1="0" x2="#{f(x.call(now))}" y2="24"/>) if inside
        s << "</svg>"

        # The note goes wherever the lane is actually empty, so it never sits on
        # the marks it describes; it is cut short with an ellipsis when narrow.
        text = lane_note(job, missed, now)
        note = ""
        if text
          now_x = x.call(now)
          lo = busy.empty? ? now_x : busy.map(&:first).min
          hi = busy.empty? ? now_x : busy.map(&:last).max
          right = W - hi >= lo
          room = right ? W - hi : lo
          if room > 90
            edge = right ? hi + 14 : lo - 14
            place = right ? "left:#{f(edge / 10.0)}%" : "right:#{f(100 - (edge / 10.0))}%"
            note = %(<span class="note#{right ? "" : " before"}" style="#{place};max-width:#{f((room - 18) / 10.0)}%">#{h(text)}</span>)
          end
        end

        LaneParts.new(svg: s, note: note, words: words(job, in_span, due, missed, span, text))
      end

      # The lane in words, for anyone who cannot see it.
      def words(job, runs, due, missed, span, note)
        parts = []
        if due.dense
          parts << "due #{job.definition.schedule}"
        elsif HTML.truthy?(job.definition.schedule)
          n = due.times.count { |t| t <= span.now }
          parts << "due #{n.zero? ? "no times" : n == 1 ? "once" : "#{n} times"} so far"
        end
        ok = runs.count { |r| r.status.to_s == "ok" }
        summary =
          if runs.empty? then ""
          elsif ok == runs.length then ok == 1 ? ", ok" : ", all ok"
          elsif ok.positive? then ", #{ok} ok"
          else ""
          end
        parts << "#{runs.length} #{runs.length == 1 ? "run" : "runs"} recorded#{summary}"
        runs.select { |r| %w[failed timeout].include?(r.status.to_s) }.last(5).each do |r|
          parts << "#{r.status} at #{when_at(r.started_at, span.now)} UTC after #{Duration.format(r.duration_ms || 0)}"
        end
        parts << "due at #{when_at(missed, span.now)} UTC and nothing started" unless missed.nil?
        parts << note if note && !note.match?(/\A(due |failed at|timed out)/)
        parts.join("; ")
      end

      # Grid lines and hour labels every `step`, on UTC boundaries.
      def hours(span, step, now_label)
        x = ->(t) { (t - span.from).fdiv(span.to - span.from) * W }
        now_x = x.call(span.now)
        lines = +""
        labels = +""
        t = span.from.fdiv(step).ceil * step
        while t <= span.to
          gx = x.call(t)
          lines << %(<i class="gl" style="left:#{f(gx / 10)}%"></i>)
          near_now = now_label && (gx - now_x).abs < 70
          unless gx < 25 || gx > W - 25 || near_now
            minor = (JS.round(t.fdiv(HOUR)) % 6) != 0
            # On a phone the track is too narrow for a label this close to "now"; CSS hides it there.
            near = now_label && (gx - now_x).abs < 170
            cls = [("minor" if minor), ("near" if near)].compact.join(" ")
            labels << %(<span class="#{cls}" style="left:#{f(gx / 10)}%">#{clock(t)}</span>)
          end
          t += step
        end
        if now_label && span.now >= span.from && span.now <= span.to
          labels << %(<span class="nowlabel" style="left:#{f(now_x / 10)}%">now #{clock(span.now)}</span>)
        end
        [lines, labels]
      end

      # The key under a timeline: a small sample of each mark and what it means.
      def legend
        key = ->(inner) { %(<svg class="key" viewBox="0 0 16 12" aria-hidden="true" focusable="false">#{inner}</svg>) }
        box = ->(cls) { key.call(%(<rect class="#{cls}" x="2" y="1" width="12" height="10"/>)) }
        items = [
          [key.call(%(<line class="tick" x1="8" y1="1" x2="8" y2="11"/>)), "due"],
          [box.call("run ok"), "ran"],
          [box.call("run bad"), "failed"],
          [box.call("run timeout"), "timed out"],
          [box.call("run warn"), "over budget or slow"],
          [box.call("run running"), "running"],
          [box.call("missed"), "missed"],
        ]
        %(<p class="legend" aria-hidden="true">#{items.map { |k, label| "<span>#{k}#{label}</span>" }.join}</p>)
      end

      def state_class(job)
        STATE_CLASS.fetch(job.health.to_sym)
      end

      # The board's timeline: one lane per job across `span`, with a shared now
      # line and the first BOARD_LANES jobs only. `total` is how many jobs there
      # are in all, for the note when some are left out.
      def day_timeline(lanes, span, base, total)
        lines, labels = hours(span, 3 * HOUR, true)
        now_x = (span.now - span.from).fdiv(span.to - span.from) * 100
        rows = lanes.map do |input|
          job = input.job
          parts = lane(input, span, now_in_lane: false, label: job.name)
          schedule = job.definition.schedule.nil? ? "no schedule" : job.definition.schedule
          [
            %(<li class="lane"><div class="who"><i class="sq #{state_class(job)}" aria-hidden="true"></i><a class="name" href="#{h(base)}/jobs/#{HTML.encode_uri_component(job.name)}">#{h(job.name)}</a><span class="sched">#{h(schedule)}</span></div><div class="track">#{parts.svg}#{parts.note}</div></li>),
            "<li>#{h("#{job.name} (#{schedule}): #{parts.words}.")}</li>",
          ]
        end
        more = total > lanes.length ? %(<p class="more">Showing the first #{lanes.length} of #{total} jobs here; the table below lists them all.</p>) : ""
        <<~HTML.chomp
          <figure class="timeline day">
          <div class="axis" aria-hidden="true"><span></span><div class="hours">#{labels}</div></div>
          <div class="field">
          <div class="under" aria-hidden="true"><span></span><div>#{lines}<i class="future" style="left:#{f(now_x)}%"></i></div></div>
          <ol class="lanes">#{rows.map(&:first).join}</ol>
          <div class="over" aria-hidden="true"><span></span><div><i class="now" style="left:#{f(now_x)}%"></i></div></div>
          </div>
          #{legend}#{more}
          <ul class="vh">#{rows.map(&:last).join}</ul>
          </figure>
        HTML
      end

      # A job's page: its last WEEK_DAYS UTC days, today first, one lane each.
      # `complete` is false when the runs read do not reach back over the week.
      def week_timeline(job, runs, complete, now)
        today = now.div(DAY) * DAY
        oldest = runs.map(&:started_at).min
        lines, labels = hours(Span.new(from: today, to: today + DAY, now: now), 3 * HOUR, false)
        rows = (0...WEEK_DAYS).map do |i|
          from = today - (i * DAY)
          span = Span.new(from: from, to: from + DAY, now: now)
          day_runs = runs.select { |r| r.started_at < span.to && (r.finished_at || now) >= from }
          known = complete || (!oldest.nil? && oldest <= from)
          label = i.zero? ? "today" : day_label(from)
          parts = lane(LaneInput.new(job: job, runs: runs, complete: known), span, now_in_lane: i.zero?, label: "#{job.name}, #{label}")
          count = "#{day_runs.length} #{day_runs.length == 1 ? "run" : "runs"}"
          [
            %(<li class="lane#{i.zero? ? " today" : ""}"><div class="who"><span class="name">#{h(i.zero? ? "Today, #{day_label(from)[4..]}" : day_label(from))}</span><span class="sched">#{h(count)}</span></div><div class="track">#{parts.svg}#{i.zero? ? parts.note : ""}</div></li>),
            "<li>#{h("#{i.zero? ? "Today" : day_label(from)}: #{parts.words}.")}</li>",
          ]
        end
        <<~HTML.chomp
          <figure class="timeline week">
          <div class="axis" aria-hidden="true"><span></span><div class="hours">#{labels}</div></div>
          <div class="field">
          <div class="under" aria-hidden="true"><span></span><div>#{lines}</div></div>
          <ol class="lanes">#{rows.map(&:first).join}</ol>
          </div>
          #{legend}
          <ul class="vh">#{rows.map(&:last).join}</ul>
          </figure>
        HTML
      end

      # How many runs a job's page reads so its week is drawn in full: roughly
      # how often the schedule was due over the week, with room to spare, from
      # 50 (what the run list shows) to 500 (the most runs returns).
      def week_runs_limit(job, now)
        parsed = parsed_schedule(job)
        return 50 if parsed.nil?

        from = (now.div(DAY) * DAY) - ((WEEK_DAYS - 1) * DAY)
        span = now + DAY - from
        # A cron's fires over one day, times the week: close enough, and cheap.
        expected =
          if parsed.interval? then span.fdiv(parsed.every_ms)
          else
            due = due_times(job, parsed, [], now - DAY, now)
            due.dense ? Float::INFINITY : (due.times.length * span).fdiv(DAY)
          end
        wanted = expected * 1.2
        return 500 unless wanted.finite?

        (wanted.ceil + 10).clamp(50, 500)
      end
    end
  end
end
