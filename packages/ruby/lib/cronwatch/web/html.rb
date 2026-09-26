# frozen_string_literal: true

module Cronwatch
  class Web
    # The dashboard's pages, markup for markup the SDK's routes/html.ts. No
    # script anywhere: the pages refresh themselves and the forget button
    # confirms with a <details>.
    module HTML
      CSS = "\n" + <<~'CSS'
        :root{--bg:#fbfbf9;--fg:#1b1b18;--muted:#6b6b64;--line:#e6e5df;--card:#fff;--ok:#1f8a4c;--warn:#b7791f;--bad:#c62828;--info:#2b5fb3;--pill:#f1f0ea;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif}
        @media(prefers-color-scheme:dark){:root{--bg:#121311;--fg:#ecece6;--muted:#9a9a91;--line:#2a2b27;--card:#1a1b18;--pill:#24251f}}
        *{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
        body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 var(--sans)}
        a{color:inherit}main{max-width:1080px;margin:0 auto;padding:24px 16px 64px}
        header{display:flex;align-items:baseline;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:20px}
        header h1{font-size:18px;margin:0;letter-spacing:-.01em}header h1 a{text-decoration:none}
        header .meta{color:var(--muted);font-size:13px}
        .card{background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
        table{width:100%;border-collapse:collapse;font-size:14px}
        th{text-align:left;font-weight:600;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em;padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap}
        td{padding:10px 12px;border-bottom:1px solid var(--line);vertical-align:top}
        tr:last-child td{border-bottom:0}
        .name{font-weight:600;white-space:nowrap}.name a{text-decoration:none}.name a:hover{text-decoration:underline}
        .mono{font-family:var(--mono);font-size:13px}.muted{color:var(--muted)}.nowrap{white-space:nowrap}
        .pill{display:inline-flex;align-items:center;gap:6px;padding:2px 9px;border-radius:999px;background:var(--pill);font-size:12px;font-weight:600;white-space:nowrap}
        .pill::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
        .ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.info{color:var(--info)}.mutedpill{color:var(--muted)}
        .spark{display:block}
        form.inline{display:inline}
        button,select{font:inherit;font-size:13px;padding:5px 10px;border:1px solid var(--line);border-radius:7px;background:var(--card);color:var(--fg);cursor:pointer}
        button:hover{border-color:var(--muted)}
        .actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
        .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:0 0 20px}
        .stat{padding:12px 14px}.stat .k{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}.stat .v{font-size:20px;font-weight:600;margin-top:2px}
        pre{margin:0;padding:10px 12px;background:var(--pill);border-radius:8px;font:12.5px/1.45 var(--mono);white-space:pre-wrap;word-break:break-word;max-height:320px;overflow:auto}
        details summary{cursor:pointer;color:var(--muted);font-size:13px}details{margin-top:6px}
        details.confirm{margin:0}details.confirm summary{list-style:none;display:inline-block;font-size:13px;padding:5px 10px;border:1px solid var(--line);border-radius:7px;background:var(--card);color:var(--fg)}
        details.confirm summary::-webkit-details-marker{display:none}details.confirm[open] summary{border-color:var(--muted)}details.confirm form{margin-left:8px;font-size:13px}
        .empty{padding:40px 16px;text-align:center;color:var(--muted)}
        dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:0;padding:14px 16px;font-size:14px}dt{color:var(--muted)}dd{margin:0}
        footer{margin-top:28px;color:var(--muted);font-size:12px}
        @media(max-width:720px){.hide-sm{display:none}main{padding:16px 16px 48px}}
      CSS

      HEALTH = {
        healthy: %w[ok healthy], late: %w[warn late], failing: %w[bad failing], stuck: %w[bad stuck],
        silenced: %w[mutedpill silenced], never_ran: ["info", "never ran"],
      }.freeze
      # Conditions the health pill already says; the others get a pill of their own.
      SHOWN_BY_HEALTH = %i[missed failed stuck].freeze
      # What encodeURIComponent leaves alone.
      URI_UNRESERVED = /[A-Za-z0-9\-_.!~*'()]/

      module_function

      # escapeHtml: String(value ?? "") with & < > " ' escaped.
      def h(value)
        text(value).gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&#39;")
      end

      # String(value), the way a template literal writes it.
      def text(value)
        case value
        when nil then ""
        when String then value
        when Symbol then value.to_s
        when Numeric then JS.number(value)
        when Array then value.map { |v| v.nil? ? "" : text(v) }.join(",")
        when Hash then "[object Object]"
        else value.to_s
        end
      end

      # JavaScript truthiness, for the template's `x ? a : b`.
      def truthy?(value)
        return false if value.nil? || value == false || value == ""
        return false if value.is_a?(Numeric) && (value.zero? || (value.is_a?(Float) && value.nan?))

        true
      end

      # encodeURIComponent.
      def encode_uri_component(value)
        text(value).each_char.map do |c|
          URI_UNRESERVED.match?(c) ? c : c.bytes.map { |b| format("%%%02X", b) }.join
        end.join
      end

      # Number.prototype.toFixed: the nearest `digits`-place decimal to the
      # exact value of the double, halves away from zero.
      def to_fixed(value, digits)
        return JS.number(value) if !JS.finite?(value) || value.abs >= 1e21

        scaled = (Rational(value.abs) * (10**digits)).round(half: :up).to_s
        scaled = scaled.rjust(digits + 1, "0") if digits.positive?
        out = digits.positive? ? "#{scaled[0...-digits]}.#{scaled[-digits..]}" : scaled
        value.negative? ? "-#{out}" : out
      end

      # Object.entries: integer-like keys first, ascending, then the rest in insertion order.
      def entries(hash)
        return [] if hash.nil?

        JS.object_keys(hash).map { |k| [k.to_s, hash[k]] }
      end

      def layout(title, body, refresh: nil)
        <<~HTML.chomp
          <!doctype html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <meta name="robots" content="noindex,nofollow">
          #{truthy?(refresh) ? "<meta http-equiv=\"refresh\" content=\"#{text(refresh)}\">" : ""}
          <title>#{h(title)}</title>
          <style>#{CSS}</style>
          </head>
          <body><main>#{body}</main></body>
          </html>
        HTML
      end

      def health_pill(job)
        cls, label = HEALTH.fetch(job.health.to_sym)
        extras = job.open.map(&:to_sym).reject { |c| SHOWN_BY_HEALTH.include?(c) }.map { |c| c.to_s.sub("_", " ") }
        extra = extras.empty? ? "" : %( <span class="pill warn">#{h(extras.join(", "))}</span>)
        %(<span class="pill #{cls}">#{label}</span>#{extra})
      end

      def run_pill(run)
        status = run.status.to_s
        cls = if status == "ok" then "ok"
              elsif status == "running" then "info"
              else "bad"
              end
        %(<span class="pill #{cls}">#{h(status)}</span>)
      end

      def sparkline(runs)
        points = runs.reverse.reject { |r| r.duration_ms.nil? }.last(20)
        return "" if points.length < 2

        w = 96
        hgt = 22
        max = [*points.map(&:duration_ms), 1].max
        step = w.fdiv(points.length - 1)
        y = ->(r) { to_fixed(hgt - 2 - (r.duration_ms.fdiv(max) * (hgt - 4)), 1) }
        path = points.each_with_index.map { |r, i| "#{i.zero? ? "M" : "L"}#{to_fixed(i * step, 1)},#{y.call(r)}" }.join(" ")
        dots = points.each_with_index.map do |r, i|
          r.status.to_s == "ok" ? "" : %(<circle cx="#{to_fixed(i * step, 1)}" cy="#{y.call(r)}" r="2.2" fill="var(--bad)"/>)
        end.join
        %(<svg class="spark" width="#{w}" height="#{hgt}" viewBox="0 0 #{w} #{hgt}" aria-hidden="true"><path d="#{path}" fill="none" stroke="var(--muted)" stroke-width="1.5"/>#{dots}</svg>)
      end

      def stamp(at, now)
        return %(<span class="muted">never</span>) if at.nil?

        iso = JS.iso(at.to_i).sub("T", " ")[0, 19]
        %(<span class="nowrap" title="#{iso} UTC">#{h(Duration.relative(at, now))}</span>)
      end

      def dashboard_page(jobs, runs_by_job, now, base, checked_at)
        rows = jobs.map do |job|
          last = job.last_run
          d = job.definition
          description = truthy?(d.description) ? %(<div class="muted" style="font-weight:400;font-size:13px;white-space:normal">#{h(d.description)}</div>) : ""
          last_cell =
            if last
              took = last.duration_ms.nil? ? "" : %( <span class="muted">#{h(Duration.format(last.duration_ms))}</span>)
              "#{run_pill(last)} #{stamp(last.started_at, now)}#{took}"
            else
              %(<span class="muted">never</span>)
            end
          <<~ROW.chomp
            <tr>
            <td class="name"><a href="#{h(base)}/jobs/#{encode_uri_component(job.name)}">#{h(job.name)}</a>#{description}</td>
            <td>#{health_pill(job)}</td>
            <td class="mono nowrap">#{h(d.schedule.nil? ? "" : d.schedule)}<span class="muted">#{truthy?(d.schedule) ? "" : "no schedule"}</span></td>
            <td class="nowrap">#{last_cell}</td>
            <td class="nowrap hide-sm">#{stamp(job.next_expected_at, now)}</td>
            <td class="hide-sm">#{sparkline(runs_by_job[job.name] || [])}</td>
            </tr>
          ROW
        end.join("\n")

        checked = truthy?(checked_at) ? ", checked #{h(Duration.relative(checked_at, now))}" : ""
        table =
          if jobs.empty?
            %(<div class="empty">No jobs yet. Declare one with <code class="mono">CW.job("name", schedule: "0 2 * * *")</code> and run it once.</div>)
          else
            <<~TABLE.chomp
              <table>
              <thead><tr><th>Job</th><th>Health</th><th>Schedule</th><th>Last run</th><th class="hide-sm">Next due</th><th class="hide-sm">Durations</th></tr></thead>
              <tbody>#{rows}</tbody></table>
            TABLE
          end
        body = <<~BODY.chomp

          <header>
            <h1><a href="#{h(base)}/">CronWatch</a></h1>
            <div class="actions">
              <span class="meta">#{jobs.length} job#{jobs.length == 1 ? "" : "s"}#{checked}</span>
              <form class="inline" method="post" action="#{h(base)}/check"><button type="submit">Run check now</button></form>
            </div>
          </header>
          <div class="card">
          #{table}
          </div>
          <footer>Refreshes every minute. <a href="#{h(base)}/api/jobs">JSON</a></footer>
        BODY
        layout("CronWatch", body, refresh: 60)
      end

      def job_page(job, runs, now, base)
        d = job.definition
        ok_rate = "#{JS.number(JS.round(job.stats.ok_rate * 100))}%"
        run_rows = runs.map do |run|
          detail = [
            truthy?(run.error) ? %(<details open><summary>error</summary><pre>#{h(run.error)}</pre></details>) : "",
            truthy?(run.output) ? %(<details#{run.status.to_s == "ok" ? "" : " open"}><summary>output</summary><pre>#{h(run.output)}</pre></details>) : "",
          ].join
          metrics = entries(run.metrics).map do |k, v|
            %(<span class="pill mutedpill">#{h(k)} #{h(JS.integer?(v) ? v : to_fixed(v, 4))}</span>)
          end.join(" ")
          took = run.duration_ms.nil? ? %(<span class="muted">running</span>) : h(Duration.format(run.duration_ms))
          detail_row = detail.empty? ? "" : %(<tr><td colspan="5" style="padding-top:0">#{detail}</td></tr>)
          <<~ROW.chomp
            <tr>
            <td class="nowrap">#{run_pill(run)}</td>
            <td class="nowrap">#{stamp(run.started_at, now)}</td>
            <td class="nowrap">#{took}</td>
            <td class="hide-sm">#{metrics}</td>
            <td class="mono hide-sm muted">#{h(run.trigger)}</td>
            </tr>#{detail_row}
          ROW
        end.join("\n")

        name = encode_uri_component(job.name)
        silenced = !job.silenced_until.nil? && job.silenced_until > now
        silence_form =
          if silenced
            %(<form class="inline" method="post" action="#{h(base)}/jobs/#{name}/unsilence"><button type="submit">Unsilence (until #{h(Duration.relative(job.silenced_until, now))})</button></form>)
          else
            %(<form class="inline" method="post" action="#{h(base)}/jobs/#{name}/silence"><select name="for"><option value="1h">1 hour</option><option value="4h">4 hours</option><option value="1d">1 day</option><option value="7d">1 week</option></select> <button type="submit">Silence</button></form>)
          end
        stats = job.stats
        p50 = stats.p50_ms.nil? ? "?" : h(Duration.format(stats.p50_ms))
        p95 = stats.p95_ms.nil? ? "?" : h(Duration.format(stats.p95_ms))
        schedule =
          if truthy?(d.schedule)
            h(d.schedule) + (truthy?(d.timezone) ? %( <span class="muted">#{h(d.timezone)}</span>) : "")
          else
            %(<span class="muted">none</span>)
          end
        budget = truthy?(d.budget) ? entries(d.budget).map { |k, v| "#{k} ≤ #{text(v)}" }.join(", ") : nil
        tags = d.tags
        failures = d.failures_before_alert
        runs_table =
          if runs.empty?
            %(<div class="empty">No runs yet.</div>)
          else
            <<~TABLE.chomp
              <table>
              <thead><tr><th>Status</th><th>Started</th><th>Duration</th><th class="hide-sm">Metrics</th><th class="hide-sm">Trigger</th></tr></thead>
              <tbody>#{run_rows}</tbody></table>
            TABLE
          end

        body = <<~BODY.chomp

          <header>
            <h1><a href="#{h(base)}/">CronWatch</a> <span class="muted">/</span> #{h(job.name)}</h1>
            <div class="actions">
              #{health_pill(job)}
              #{silence_form}
              <details class="confirm"><summary>Forget</summary><form class="inline" method="post" action="#{h(base)}/jobs/#{name}/forget"><span class="muted">Remove this job and its runs from the store?</span> <button type="submit">Forget</button></form></details>
            </div>
          </header>
          <div class="grid">
            <div class="card stat"><div class="k">Last run</div><div class="v">#{job.last_run ? h(Duration.relative(job.last_run.started_at, now)) : "never"}</div></div>
            <div class="card stat"><div class="k">Next due</div><div class="v">#{truthy?(job.next_expected_at) ? h(Duration.relative(job.next_expected_at, now)) : "no schedule"}</div></div>
            <div class="card stat"><div class="k">Success, last #{h(stats.runs)}</div><div class="v">#{h(ok_rate)}</div></div>
            <div class="card stat"><div class="k">p50 / p95</div><div class="v">#{p50} <span class="muted">/</span> #{p95}</div></div>
          </div>
          <div class="card" style="margin-bottom:20px">
          <dl>
            <dt>Schedule</dt><dd class="mono">#{schedule}</dd>
            <dt>Grace</dt><dd class="mono">#{h(d.grace.nil? ? "10m" : d.grace)}</dd>
            <dt>Timeout</dt><dd class="mono">#{h(d.timeout.nil? ? "1h" : d.timeout)}</dd>
            #{truthy?(d.max_duration) ? %(<dt>Max duration</dt><dd class="mono">#{h(d.max_duration)}</dd>) : ""}
            #{budget ? %(<dt>Budget</dt><dd class="mono">#{h(budget)}</dd>) : ""}
            #{truthy?(d.expect) ? %(<dt>Expect</dt><dd class="mono">#{h(d.expect)}</dd>) : ""}
            #{truthy?(failures) && failures > 1 ? %(<dt>Alert after</dt><dd>#{h(failures)} consecutive failures</dd>) : ""}
            #{truthy?(d.description) ? %(<dt>Description</dt><dd>#{h(d.description)}</dd>) : ""}
            #{tags.is_a?(Array) && tags.any? ? %(<dt>Tags</dt><dd>#{tags.map { |t| %(<span class="pill mutedpill">#{h(t)}</span>) }.join(" ")}</dd>) : ""}
            #{job.open.any? ? %(<dt>Open</dt><dd>#{job.open.map { |c| %(<span class="pill warn">#{h(c.to_s.sub("_", " "))}</span>) }.join(" ")}</dd>) : ""}
            #{job.consecutive_failures.positive? ? %(<dt>Consecutive failures</dt><dd>#{h(job.consecutive_failures)}</dd>) : ""}
          </dl>
          </div>
          <div class="card">
          #{runs_table}
          </div>
          <footer><a href="#{h(base)}/api/jobs/#{name}">JSON</a></footer>
        BODY
        layout("#{job.name}: CronWatch", body, refresh: 60)
      end

      def message_page(title, message, base)
        layout(title, %(<header><h1><a href="#{h(base)}/">CronWatch</a></h1></header><div class="card"><div class="empty"><strong>#{h(title)}</strong><br>#{h(message)}</div></div>))
      end
    end
  end
end
