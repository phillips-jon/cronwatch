# frozen_string_literal: true

module Cronwatch
  class Web
    # The dashboard's pages, markup for markup the SDK's routes/html.ts. The
    # one script, app.js, only registers the service worker: the pages refresh
    # themselves and the forget button confirms with a <details>.
    #
    # Set like cronwatch.dev: a printed sheet on grey paper, a serif for what a
    # person reads, a mono for what a machine printed, neutral greys, and
    # colour only for the states CronWatch reports. The page loads nothing but
    # its own app shell (its CSP is default-src 'none' plus 'self' for the
    # script, the manifest, the worker and images), so the fonts are system
    # stacks that echo the site's Newsreader and IBM Plex Mono, and use them
    # when they are installed.
    #
    # Installed as an app (display-mode: standalone) the header stays at the
    # top as the app's bar, and the page keeps clear of notches and the home
    # indicator with the safe-area insets (the viewport is viewport-fit=cover).
    #
    # Motion is CSS only and says something: marks arrive in time order, the
    # now line drops in last, and open problems (a missed slot, a running bar)
    # breathe slowly. prefers-reduced-motion turns all of it off.
    module HTML
      CSS = "\n" + <<~'CSS'
        :root{color-scheme:light dark;--paper:#f4f4f5;--sheet:#fff;--sunk:#fafafa;--rule:#e4e4e7;--rule-2:#d4d4d8;--tick:#909098;--ink:#000;--body:#18181b;--muted:#71717a;--ok:#15803d;--warn:#a16207;--bad:#b91c1c;--serif:"Newsreader",ui-serif,Georgia,Cambria,"Times New Roman",serif;--mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--who:200px}
        @media(prefers-color-scheme:dark){:root{--paper:#09090b;--sheet:#111113;--sunk:#18181b;--rule:#27272a;--rule-2:#3f3f46;--tick:#66666f;--ink:#fff;--body:#e4e4e7;--muted:#a1a1aa;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171}}
        *{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
        body{margin:0;background:var(--paper);color:var(--ink);font:400 16px/1.55 var(--serif);-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
        a{color:inherit;text-decoration:underline;text-decoration-thickness:1px;text-underline-offset:.16em;text-decoration-color:var(--rule-2)}a:hover{text-decoration-color:currentColor}
        :focus-visible{outline:2px solid var(--ink);outline-offset:2px}
        code,pre,.mono{font-family:var(--mono)}
        .vh{position:absolute!important;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
        .sheet{max-width:1180px;min-height:100vh;margin:0 auto;background:var(--sheet);border-inline:1px solid var(--rule);padding:0 clamp(16px,4vw,48px)}
        .top{display:flex;align-items:center;justify-content:space-between;gap:12px 20px;flex-wrap:wrap;padding:18px 0 17px;border-bottom:1px solid var(--rule)}
        .brand{display:flex;align-items:center;gap:10px;margin:0;font:600 18px/1.2 var(--serif);letter-spacing:-.01em;min-width:0}
        .brand a{display:inline-flex;align-items:center;gap:10px;text-decoration:none}.brand svg{width:24px;height:24px;flex:none;color:var(--ink)}
        .brand .crumb{font:500 15px/1.2 var(--mono);color:var(--body);overflow-wrap:anywhere}.brand .slash{color:var(--rule-2);font-weight:400}
        .actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
        .meta{font:400 12px/1.4 var(--mono);color:var(--muted)}
        button,select,details.confirm>summary{font:500 12.5px/1 var(--mono);color:var(--ink);background:var(--sheet);border:1px solid var(--rule-2);border-radius:3px;padding:8px 11px;cursor:pointer}
        select{padding:7px 8px}
        button:hover,select:hover,details.confirm>summary:hover{border-color:var(--muted)}
        button.primary{background:var(--ink);border-color:var(--ink);color:var(--sheet)}button.primary:hover{opacity:.86}
        form.inline{display:inline-flex;align-items:center;gap:6px;margin:0}
        details.confirm{display:inline-flex;align-items:center;gap:8px;margin:0}details.confirm>summary{list-style:none;display:inline-block}
        details.confirm>summary::-webkit-details-marker{display:none}details.confirm[open]>summary{border-color:var(--muted)}
        details.confirm form{margin-left:8px;font-size:14px;color:var(--muted)}
        .sec{display:grid;grid-template-columns:150px minmax(0,1fr);gap:10px 40px;padding:30px 0;border-top:1px solid var(--rule)}
        .top+main>.sec:first-child{border-top:0}
        .sec>h2{margin:0;font:500 11px/1.5 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--muted);padding-top:5px}
        .sec>.wide{grid-column:1/-1;min-width:0}
        .lede{margin:0;color:var(--muted);font-size:16px;max-width:64ch;text-wrap:pretty}
        .headline{margin:0;font:400 clamp(24px,3.2vw,32px)/1.2 var(--serif);letter-spacing:-.01em;text-wrap:balance}
        .headline b{font-weight:600}
        .state{font:500 12.5px/1.4 var(--mono);white-space:nowrap}.state+.state::before{content:" \00b7  ";color:var(--muted);font-weight:400}
        .ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.muted{color:var(--muted)}.info{color:var(--ink)}
        .sq{display:inline-block;width:8px;height:8px;border-radius:1.5px;background:currentColor;margin-right:7px;vertical-align:1px;flex:none}
        .sq.muted{background:none;box-shadow:inset 0 0 0 1.5px var(--tick)}
        .figures{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:0;margin:22px 0 0;border-top:1px solid var(--rule)}
        .figures>div{display:flex;flex-direction:column-reverse;justify-content:flex-end;gap:4px;padding:14px 16px 2px 0}
        .figures dt{font:500 11px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);display:flex;align-items:center}
        .figures dd{margin:0;font:400 30px/1.1 var(--serif);font-variant-numeric:tabular-nums;color:var(--ink)}
        .figures dd small{font-size:17px;color:var(--muted)}
        .figures .zero dd{color:var(--rule-2)}
        .figures .bad dd{color:var(--bad)}.figures .warn dd{color:var(--warn)}
        .stateline{margin:12px 0 0;display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px}
        .stateline .why{font-style:italic;color:var(--muted)}
        .jobname{margin:0;font:500 clamp(22px,3vw,28px)/1.2 var(--mono);letter-spacing:-.01em;overflow-wrap:anywhere}
        .desc{margin:6px 0 0;color:var(--body);max-width:64ch}
        .intro .actions{margin-top:18px}
        table{width:100%;border-collapse:collapse}
        th{text-align:left;font:500 10.5px/1.2 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);padding:0 14px 10px 0;border-bottom:1px solid var(--rule);white-space:nowrap}
        td{padding:12px 14px 12px 0;border-bottom:1px solid var(--rule);vertical-align:top;font:400 12.5px/1.5 var(--mono);color:var(--body)}
        tbody tr:last-child td{border-bottom:0}
        td.job{font-family:var(--serif);font-size:15px;min-width:180px}
        td.job .name{font:500 13.5px/1.5 var(--mono);color:var(--ink)}
        td.job .desc{display:block;margin:2px 0 0;font-size:14px;color:var(--muted);line-height:1.4}
        td .tz,td .sub{display:block;color:var(--muted);font-size:11.5px}
        .nowrap{white-space:nowrap}
        .spark{display:block;overflow:visible}.spark rect{fill:var(--tick)}.spark rect.bad{fill:var(--bad)}.spark rect.warn{fill:var(--warn)}.spark rect.running{fill:none;stroke:var(--ink);stroke-width:1}
        .runs td{padding-top:11px;padding-bottom:11px}.runs tr.has-detail td{border-bottom:0;padding-bottom:4px}.runs tr.detail td{padding-top:0}
        .metrics{display:flex;flex-wrap:wrap;gap:2px 14px}.metrics .k{color:var(--muted)}
        pre{margin:6px 0 0;padding:12px 14px;background:var(--sunk);border:1px solid var(--rule);border-radius:3px;font:400 12.5px/1.55 var(--mono);color:var(--body);white-space:pre-wrap;overflow-wrap:anywhere;max-height:340px;overflow:auto}
        details.out{margin-top:4px}details.out>summary{cursor:pointer;font:400 12px/1.6 var(--mono);color:var(--muted)}details.out>summary:hover{color:var(--ink)}
        details.out.error>summary{color:var(--bad)}
        dl.def{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:8px 28px;margin:0}
        dl.def dt{font:500 11px/1.9 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
        dl.def dd{margin:0;font:400 13.5px/1.7 var(--mono);color:var(--body);overflow-wrap:anywhere}dl.def dd.prose{font:400 16px/1.55 var(--serif)}
        .empty{padding:28px 0 8px;color:var(--muted);max-width:60ch}
        .empty code{font-size:.86em;color:var(--ink)}
        .message{padding:clamp(56px,12vh,120px) 0;text-align:center}
        .message h1{margin:0;font:400 clamp(28px,4vw,40px)/1.15 var(--serif);letter-spacing:-.015em}
        .message p{margin:14px auto 0;max-width:52ch;color:var(--muted);text-wrap:pretty}
        .signin{display:flex;flex-wrap:wrap;align-items:center;justify-content:center;gap:8px;margin:28px auto 0;max-width:420px}
        .signin label{font:500 11px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
        .signin input{flex:1 1 180px;min-width:0;font:400 16px/1.2 var(--mono);color:var(--ink);background:var(--sheet);border:1px solid var(--rule-2);border-radius:3px;padding:8px 10px}
        footer{display:flex;flex-wrap:wrap;gap:6px 18px;padding:20px 0 40px;border-top:1px solid var(--rule);font:400 12px/1.5 var(--mono);color:var(--muted)}
        .timeline{margin:18px 0 0}
        .timeline .axis,.timeline .under,.timeline .over,.timeline .lane{display:grid;grid-template-columns:var(--who) minmax(0,1fr)}
        .timeline .hours{position:relative;height:22px;font:400 11px/1 var(--mono);color:var(--muted);letter-spacing:.04em}
        .timeline .hours span{position:absolute;top:2px;transform:translateX(-50%);white-space:nowrap}
        .timeline .hours .nowlabel{color:var(--ink);font-weight:500;animation:cw-fade .5s 1s both}
        .timeline .field{position:relative}
        .timeline .under,.timeline .over{position:absolute;inset:0;pointer-events:none}
        .timeline .under>div,.timeline .over>div{position:relative}
        .timeline .gl{position:absolute;top:0;bottom:0;width:1px;background:var(--rule)}
        .timeline .future{position:absolute;top:0;bottom:0;right:0;background:var(--sunk)}
        .timeline .now{position:absolute;top:-6px;bottom:0;width:1.5px;margin-left:-.75px;background:var(--ink);transform-origin:top;animation:cw-drop .6s .85s cubic-bezier(.2,.8,.2,1) both}
        .timeline .lanes{position:relative;list-style:none;margin:0;padding:0;border-top:1px solid var(--rule);border-bottom:1px solid var(--rule)}
        .timeline .lane{align-items:center;min-height:40px}
        .timeline .who{display:grid;grid-template-columns:auto minmax(0,1fr);align-items:center;column-gap:0;padding:6px 14px 6px 0;min-width:0}
        .timeline .who .sched{grid-column:2}
        .timeline.week .who{display:flex;align-items:baseline;gap:10px}
        .timeline .who .name{font:500 13px/1.35 var(--mono);color:var(--ink);overflow-wrap:anywhere}
        .timeline .who .sched{font:400 11px/1.35 var(--mono);color:var(--muted);white-space:nowrap}
        .timeline .track{position:relative;height:24px}
        .timeline .marks{display:block;width:100%;height:24px;overflow:visible}
        .timeline .note{position:absolute;top:50%;transform:translateY(-50%);font:italic 400 14px/1.2 var(--serif);color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 3px;text-shadow:0 0 3px var(--sheet),0 0 3px var(--sheet),0 0 6px var(--sheet);animation:cw-fade .6s 1.1s both}
        .timeline .note.before{text-align:right}
        .timeline .legend{display:flex;flex-wrap:wrap;gap:6px 18px;margin:14px 0 0;padding-left:var(--who);font:400 11.5px/1.4 var(--mono);color:var(--muted)}
        .timeline .legend span{display:inline-flex;align-items:center;gap:7px}
        .timeline .more{margin:10px 0 0;padding-left:var(--who);font-size:14px;color:var(--muted);font-style:italic}
        .key{width:16px;height:12px;overflow:visible}
        .marks *{vector-effect:non-scaling-stroke}
        svg .base{stroke:var(--rule);stroke-width:1}
        svg .tick{stroke:var(--tick);stroke-width:1.5}svg .tick.ahead{stroke-dasharray:2 2;opacity:.75}
        svg .cadence{stroke:var(--tick);stroke-width:2;stroke-dasharray:1 3}
        svg .run{stroke-width:2;stroke-linejoin:round}
        svg .run.ok{fill:var(--ok);stroke:var(--ok)}
        svg .run.bad{fill:var(--bad);stroke:var(--bad)}
        svg .run.timeout{fill:var(--bad);fill-opacity:.28;stroke:var(--bad);stroke-width:1.5}
        svg .run.warn{fill:var(--warn);stroke:var(--warn)}
        svg .run.running{fill:none;stroke:var(--ink);stroke-width:1.5}
        svg .run.stuck{fill:var(--bad);fill-opacity:.12;stroke:var(--bad);stroke-width:1.5}
        svg .missed{fill:none;stroke:var(--bad);stroke-width:1.5;stroke-dasharray:3 2.5}
        svg .unloaded{fill:var(--sunk)}
        svg .ahead{fill:var(--sunk)}
        svg .nowline{stroke:var(--ink);stroke-width:1.5}
        .marks .tick{animation:cw-fade .4s var(--d,0ms) both}
        .marks .run,.marks .missed{transform-box:fill-box;transform-origin:0 50%;animation:cw-grow .55s cubic-bezier(.2,.8,.2,1) var(--d,0ms) both}
        .marks .missed,.marks .run.running,.marks .run.stuck{animation:cw-grow .55s cubic-bezier(.2,.8,.2,1) var(--d,0ms) both,cw-breathe 2.6s ease-in-out calc(var(--d,0ms) + .6s) infinite alternate}
        .figures>div{animation:cw-rise .5s cubic-bezier(.2,.8,.2,1) both}
        .figures>div:nth-child(2){animation-delay:40ms}.figures>div:nth-child(3){animation-delay:80ms}.figures>div:nth-child(4){animation-delay:120ms}.figures>div:nth-child(5){animation-delay:160ms}.figures>div:nth-child(6){animation-delay:200ms}
        @keyframes cw-fade{from{opacity:0}}
        @keyframes cw-grow{from{opacity:0;transform:scaleX(0)}}
        @keyframes cw-drop{from{opacity:0;transform:scaleY(0)}}
        @keyframes cw-rise{from{opacity:0;transform:translateY(4px)}}
        @keyframes cw-breathe{to{opacity:.38}}
        body{padding:0 env(safe-area-inset-right) 0 env(safe-area-inset-left)}
        footer{padding-bottom:calc(40px + env(safe-area-inset-bottom))}
        @media(display-mode:standalone){
        .top{position:sticky;top:0;z-index:2;background:var(--sheet);padding-top:calc(14px + env(safe-area-inset-top));padding-bottom:13px;-webkit-user-select:none;user-select:none}
        .message{padding-top:clamp(40px,8vh,80px)}
        }
        @media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
        @media(max-width:760px){
        .sec{grid-template-columns:minmax(0,1fr);gap:10px;padding:24px 0}
        .hide-sm{display:none}
        :root{--who:0px}
        .timeline .lane{grid-template-columns:minmax(0,1fr);padding:6px 0 8px}
        .timeline .who{padding:0 0 4px}
        .timeline .who .name{background:var(--sheet);padding-right:4px}
        .timeline .hours .minor,.timeline .hours .near{display:none}
        .timeline .note{font-size:13px}
        td.job{min-width:0}
        table.board thead{display:none}
        table.board tr{display:grid;grid-template-columns:minmax(0,1fr) auto;column-gap:14px;padding:12px 0;border-bottom:1px solid var(--rule)}
        table.board tbody tr:last-child{border-bottom:0}
        table.board td{border:0;padding:0}
        table.board td.last{grid-column:1/-1;margin-top:4px;white-space:normal}
        table.board td.last .sub{display:inline;margin-left:8px}
        .runs td.nowrap{white-space:normal}
        dl.def{grid-template-columns:minmax(0,1fr);gap:0}dl.def dd{margin-bottom:10px}
        }
      CSS

      # The clock face from cronwatch.dev, in the text colour.
      MARK = '<svg viewBox="0 0 40 40" aria-hidden="true" focusable="false"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="none" stroke="currentColor" stroke-opacity=".22" stroke-width="1.5"/><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>'

      # In the order the board counts them, the ones needing attention first.
      HEALTH = {
        failing: %w[bad failing], stuck: %w[bad stuck], late: %w[warn late], healthy: %w[ok healthy],
        silenced: %w[muted silenced], never_ran: ["muted", "never ran"],
      }.freeze
      # Conditions the health state already says; the others are named after it.
      SHOWN_BY_HEALTH = %i[missed failed stuck].freeze
      # What encodeURIComponent leaves alone.
      URI_UNRESERVED = /[A-Za-z0-9\-_.!~*'()]/

      module_function

      # escapeHtml: String(value ?? "") with & < > " ' escaped.
      def h(value)
        text(value).gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&#39;")
      end

      # escapeName: a job name shown as text, with a break allowed after each
      # run of _ : . / - so it wraps at its separators. Never in an attribute.
      def name_html(value)
        h(value).gsub(%r{([_:./-]+)(?=[^_:./-])}, '\1<wbr>')
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

      # A page. `base` is where the dashboard is mounted ("" at the root): the
      # head links the web app manifest, the icons and app.js, the one script,
      # which only registers the service worker (Web::PWA). Everything works
      # without it.
      def layout(title, body, base, refresh: nil)
        b = h(base)
        <<~HTML.chomp
          <!doctype html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
          <meta name="robots" content="noindex,nofollow">
          <meta name="color-scheme" content="light dark">
          #{truthy?(refresh) ? "<meta http-equiv=\"refresh\" content=\"#{text(refresh)}\">" : ""}
          <title>#{h(title)}</title>
          <meta name="theme-color" content="#{PWA::THEME_COLOR}" media="(prefers-color-scheme: light)">
          <meta name="theme-color" content="#{PWA::THEME_COLOR_DARK}" media="(prefers-color-scheme: dark)">
          <meta name="mobile-web-app-capable" content="yes">
          <meta name="apple-mobile-web-app-capable" content="yes">
          <meta name="apple-mobile-web-app-title" content="CronWatch">
          <meta name="apple-mobile-web-app-status-bar-style" content="default">
          <link rel="manifest" href="#{b}/manifest.webmanifest">
          <link rel="icon" href="#{b}/icons/icon.svg" type="image/svg+xml">
          <link rel="apple-touch-icon" href="#{b}/icons/apple-touch-icon.png">
          <script src="#{b}/app.js" defer></script>
          <style>#{CSS}</style>
          </head>
          <body><div class="sheet">#{body}</div></body>
          </html>
        HTML
      end

      def brand(base, crumb = nil)
        home = %(<a href="#{h(base)}/">#{MARK}<span>CronWatch</span></a>)
        return %(<p class="brand">#{home}</p>) if crumb.nil?

        %(<p class="brand">#{home}<span class="slash" aria-hidden="true">/</span><span class="crumb">#{name_html(crumb)}</span></p>)
      end

      # The job's health, with any open condition it does not already say (over budget, slow) after it.
      def health_state(job)
        cls, label = HEALTH.fetch(job.health.to_sym)
        extras = job.open.map(&:to_sym).reject { |c| SHOWN_BY_HEALTH.include?(c) }
                    .map { |c| %(<span class="state warn">#{h(c.to_s.sub("_", " "))}</span>) }.join
        %(<span class="state #{cls}"><i class="sq #{cls}" aria-hidden="true"></i>#{label}</span>#{extras})
      end

      def run_state(run)
        status = run.status.to_s
        cls = if status == "ok" then "ok"
              elsif status == "running" then "info"
              else "bad"
              end
        %(<span class="state #{cls}">#{h(status)}</span>)
      end

      # The last twenty runs, oldest first, as bars as tall as they took; grey unless something went wrong.
      def sparkline(runs)
        points = runs.first(20).reverse
        return "" if points.length < 2

        bar = 4
        gap = 1.5
        hgt = 22
        max = [*points.map { |r| r.duration_ms || 0 }, 1].max
        bars = points.each_with_index.map do |r, i|
          x = to_fixed(i * (bar + gap), 1)
          status = r.status.to_s
          next %(<rect class="running" x="#{x}" y="#{text(hgt - 6.5)}" width="#{bar - 1}" height="6"/>) if status == "running"

          tall = [status == "ok" ? 2 : 6, (r.duration_ms || 0).fdiv(max) * hgt].max
          cls = status == "ok" ? "" : %( class="bad")
          %(<rect#{cls} x="#{x}" y="#{to_fixed(hgt - tall, 1)}" width="#{bar}" height="#{to_fixed(tall, 1)}" rx=".5"/>)
        end.join
        w = (points.length * (bar + gap)) - gap
        %(<svg class="spark" width="#{to_fixed(w, 1)}" height="#{hgt}" viewBox="0 0 #{to_fixed(w, 1)} #{hgt}" aria-hidden="true" focusable="false">#{bars}</svg>)
      end

      def stamp(at, now)
        return %(<span class="muted">never</span>) if at.nil?

        iso = JS.iso(at.to_i)
        %(<time class="nowrap" datetime="#{iso}" title="#{iso.sub("T", " ")[0, 19]} UTC">#{h(Duration.relative(at, now))}</time>)
      end

      # Counts by health, the ones needing attention first; a zero is set faint
      # rather than left out, so the row keeps its shape.
      def health_figures(jobs)
        cells = HEALTH.map do |health, (cls, label)|
          n = jobs.count { |j| j.health.to_sym == health }
          %(<div class="#{n.zero? ? "zero" : cls}"><dt><i class="sq #{cls}" aria-hidden="true"></i>#{label}</dt><dd>#{n}</dd></div>)
        end
        %(<dl class="figures">#{cells.join}</dl>)
      end

      def dashboard_page(jobs, runs_by_job, now, base, checked_at, lanes = nil)
        lanes ||= jobs.first(Timeline::BOARD_LANES).map do |job|
          Timeline::LaneInput.new(job: job, runs: runs_by_job[job.name] || [], complete: true)
        end
        attention = jobs.count { |j| j.health.to_sym != :healthy }
        headline =
          if jobs.empty? then "No jobs yet."
          elsif attention.zero? then "#{jobs.length == 1 ? "The one job is" : "All #{jobs.length} jobs are"} healthy."
          else "#{jobs.length} job#{jobs.length == 1 ? "" : "s"}, <b>#{attention} needing attention</b>."
          end

        rows = jobs.map do |job|
          last = job.last_run
          d = job.definition
          description = truthy?(d.description) ? %(<span class="desc">#{h(d.description)}</span>) : ""
          schedule =
            if truthy?(d.schedule)
              "#{h(d.schedule)}#{truthy?(d.timezone) ? %(<span class="tz">#{h(d.timezone)}</span>) : ""}"
            else
              %(<span class="muted">no schedule</span>)
            end
          last_cell =
            if last
              took = last.duration_ms.nil? ? "" : %(<span class="sub">took #{h(Duration.format(last.duration_ms))}</span>)
              "#{run_state(last)} #{stamp(last.started_at, now)}#{took}"
            else
              %(<span class="muted">never</span>)
            end
          next_at = job.next_expected_at
          next_cell =
            if next_at.nil?
              %(<span class="muted">not scheduled</span>)
            else
              overdue = next_at < now ? %(<span class="state warn">overdue</span> ) : ""
              %(#{overdue}#{stamp(next_at, now)}<span class="sub">#{h(Timeline.when_at(next_at, now))} UTC</span>)
            end
          <<~ROW.chomp
            <tr>
            <td class="job"><a class="name" href="#{h(base)}/jobs/#{encode_uri_component(job.name)}">#{name_html(job.name)}</a>#{description}</td>
            <td class="health">#{health_state(job)}</td>
            <td class="nowrap hide-sm">#{schedule}</td>
            <td class="nowrap last">#{last_cell}</td>
            <td class="nowrap hide-sm">#{next_cell}</td>
            <td class="hide-sm">#{sparkline(runs_by_job[job.name] || [])}</td>
            </tr>
          ROW
        end.join("\n")

        span = Timeline::Span.new(from: now - Timeline::BOARD_BEHIND_MS, to: now + Timeline::BOARD_AHEAD_MS, now: now)
        checked = truthy?(checked_at) ? ", checked #{h(Duration.relative(checked_at, now))}" : ""
        figures =
          if jobs.empty?
            %(<p class="empty">Declare one with <code>CW.job("name", schedule: "0 2 * * *")</code> and run it once, and it shows up here.</p>)
          else
            health_figures(jobs)
          end
        sections =
          if jobs.empty?
            ""
          else
            <<~SECTIONS.chomp
              <section class="sec" aria-label="Last 24 hours">
                <h2>Last 24 hours</h2>
                <p class="lede">One lane per job. Faint ticks mark when it was due, bars the runs it recorded, as long as they took. A dashed box is a slot nothing ran in. Times are UTC.</p>
                <div class="wide">#{Timeline.day_timeline(lanes, span, base, jobs.length)}</div>
              </section>
              <section class="sec" aria-label="Jobs">
                <h2>Jobs</h2>
                <p class="lede">Every job in the store. Open one for its week, its runs and their output.</p>
                <div class="wide"><table class="board">
              <thead><tr><th>Job</th><th>Health</th><th class="hide-sm">Schedule</th><th>Last run</th><th class="hide-sm">Next due</th><th class="hide-sm">Recent runs</th></tr></thead>
              <tbody>#{rows}</tbody></table></div>
              </section>
            SECTIONS
          end
        body = <<~BODY.chomp

          <header class="top">
            #{brand(base)}
            <div class="actions">
              <span class="meta">#{h(Timeline.clock(now))} UTC#{checked}</span>
              <form class="inline" method="post" action="#{h(base)}/check"><button class="primary" type="submit">Run check now</button></form>
            </div>
          </header>
          <main>
          <section class="sec" aria-label="Health">
            <h2>Health</h2>
            <div>
              <p class="headline">#{headline}</p>
              #{figures}
            </div>
          </section>
          #{sections}
          </main>
          <footer><span>Refreshes every minute. Times are UTC.</span><a href="#{h(base)}/api/jobs">JSON</a></footer>
        BODY
        layout("CronWatch", body, base, refresh: 60)
      end

      # One job: its state and figures, its last seven days, its runs with
      # their output, and its definition. `complete` is false when `runs` does
      # not reach back over the whole week (the run list shows the newest fifty).
      def job_page(job, runs, now, base, complete = true)
        d = job.definition
        ok_rate = "#{JS.number(JS.round(job.stats.ok_rate * 100))}%"
        listed = runs.first(50)
        run_rows = listed.map do |run|
          detail = [
            truthy?(run.error) ? %(<details class="out error" open><summary>error</summary><pre>#{h(run.error)}</pre></details>) : "",
            truthy?(run.output) ? %(<details class="out"#{run.status.to_s == "ok" ? "" : " open"}><summary>output</summary><pre>#{h(run.output)}</pre></details>) : "",
          ].join
          metrics = entries(run.metrics).map do |k, v|
            %(<span><span class="k">#{h(k)}</span> #{h(JS.integer?(v) ? v : to_fixed(v, 4))}</span>)
          end.join
          took = run.duration_ms.nil? ? %(<span class="muted">running</span>) : h(Duration.format(run.duration_ms))
          detail_row = detail.empty? ? "" : %(<tr class="detail"><td colspan="5">#{detail}</td></tr>)
          <<~ROW.chomp
            <tr#{detail.empty? ? "" : ' class="has-detail"'}>
            <td class="nowrap">#{run_state(run)}</td>
            <td class="nowrap">#{h(Timeline.when_at(run.started_at, now))} <span class="muted">UTC</span><span class="sub">#{stamp(run.started_at, now)}</span></td>
            <td class="nowrap">#{took}</td>
            <td class="hide-sm">#{metrics.empty? ? "" : %(<span class="metrics">#{metrics}</span>)}</td>
            <td class="hide-sm muted">#{h(run.trigger)}</td>
            </tr>#{detail_row}
          ROW
        end.join("\n")

        silenced = !job.silenced_until.nil? && job.silenced_until > now
        path = "#{h(base)}/jobs/#{encode_uri_component(job.name)}"
        why = Timeline.lane_note(job, Timeline.missed_at(job, Timeline.parsed_schedule(job), [], now), now)
        silence_form =
          if silenced
            %(<form class="inline" method="post" action="#{path}/unsilence"><button type="submit">Unsilence (until #{h(Duration.relative(job.silenced_until, now))})</button></form>)
          else
            %(<form class="inline" method="post" action="#{path}/silence"><select name="for" aria-label="Silence for"><option value="1h">1 hour</option><option value="4h">4 hours</option><option value="1d">1 day</option><option value="7d">1 week</option></select><button type="submit">Silence</button></form>)
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
        open = job.open.map do |c|
          %(<span class="state #{%w[failed stuck].include?(c.to_s) ? "bad" : "warn"}">#{h(c.to_s.sub("_", " "))}</span>)
        end.join
        runs_section =
          if listed.empty?
            %(<p class="lede">No runs yet.</p>)
          else
            <<~RUNS.chomp
              <p class="lede">The newest #{listed.length == 1 ? "run" : "#{listed.length} runs"}, with any error and output.</p>
                <div class="wide"><table class="runs">
              <thead><tr><th>Status</th><th>Started</th><th>Took</th><th class="hide-sm">Metrics</th><th class="hide-sm">Trigger</th></tr></thead>
              <tbody>#{run_rows}</tbody></table></div>
            RUNS
          end

        body = <<~BODY.chomp

          <header class="top">
            #{brand(base, job.name)}
            <div class="actions"><span class="meta">#{h(Timeline.clock(now))} UTC</span></div>
          </header>
          <main>
          <section class="sec intro" aria-label="Job">
            <h2>Job</h2>
            <div>
              <h1 class="jobname">#{name_html(job.name)}</h1>
              #{truthy?(d.description) ? %(<p class="desc">#{h(d.description)}</p>) : ""}
              <p class="stateline">#{health_state(job)}#{why ? %(<span class="why">#{h(why)}</span>) : ""}</p>
              <div class="actions">
                #{silence_form}
                <details class="confirm"><summary>Forget</summary><form class="inline" method="post" action="#{path}/forget"><span>Remove this job and its runs from the store?</span> <button type="submit">Forget</button></form></details>
              </div>
              <dl class="figures">
                <div><dt>Last run</dt><dd>#{job.last_run ? h(Duration.relative(job.last_run.started_at, now)) : "never"}</dd></div>
                <div><dt>Next due</dt><dd>#{job.next_expected_at.nil? ? "<small>no schedule</small>" : h(Duration.relative(job.next_expected_at, now))}</dd></div>
                <div><dt>Success, last #{h(stats.runs)}</dt><dd>#{h(ok_rate)}</dd></div>
                <div><dt>p50 / p95</dt><dd>#{p50} <small>/ #{p95}</small></dd></div>
              </dl>
            </div>
          </section>
          <section class="sec" aria-label="Last 7 days">
            <h2>Last 7 days</h2>
            <p class="lede">A lane per UTC day, today first. Faint ticks mark when the job was due, bars its runs, as long as they took.</p>
            <div class="wide">#{Timeline.week_timeline(job, runs, complete, now)}</div>
          </section>
          <section class="sec" aria-label="Runs">
            <h2>Runs</h2>
            #{runs_section}
          </section>
          <section class="sec" aria-label="Definition">
            <h2>Definition</h2>
            <dl class="def">
            <dt>Schedule</dt><dd>#{schedule}</dd>
            <dt>Grace</dt><dd>#{h(d.grace.nil? ? "10m" : d.grace)}</dd>
            <dt>Timeout</dt><dd>#{h(d.timeout.nil? ? "1h" : d.timeout)}</dd>
            #{truthy?(d.max_duration) ? %(<dt>Max duration</dt><dd>#{h(d.max_duration)}</dd>) : ""}
            #{budget ? %(<dt>Budget</dt><dd>#{h(budget)}</dd>) : ""}
            #{truthy?(d.expect) ? %(<dt>Expect</dt><dd>#{h(d.expect)}</dd>) : ""}
            #{truthy?(failures) && failures > 1 ? %(<dt>Alert after</dt><dd>#{h(failures)} consecutive failures</dd>) : ""}
            #{tags.is_a?(Array) && tags.any? ? %(<dt>Tags</dt><dd>#{tags.map { |t| h(t) }.join(", ")}</dd>) : ""}
            #{job.open.any? ? %(<dt>Open</dt><dd>#{open}</dd>) : ""}
            #{job.consecutive_failures.positive? ? %(<dt>Failures in a row</dt><dd>#{h(job.consecutive_failures)}</dd>) : ""}
            </dl>
          </section>
          </main>
          <footer><span>Refreshes every minute. Times are UTC.</span><a href="#{h(base)}/api/jobs/#{encode_uri_component(job.name)}">JSON</a></footer>
        BODY
        layout("#{job.name}: CronWatch", body, base, refresh: 60)
      end

      # A page with one message. With `sign_in`, a form under it takes the
      # token and sends it as ?token=, which the app moves into the cookie:
      # the way in where there is no address bar to open a link with, such as
      # an app on an iPhone's home screen, which keeps its cookies apart from
      # Safari's.
      def message_page(title, message, base, sign_in: false)
        form = sign_in ? %(<form class="signin" method="get" action="#{h(base)}/"><label for="token">Token</label><input id="token" name="token" type="password" autocomplete="current-password" autocapitalize="off" spellcheck="false" required><button class="primary" type="submit">Sign in</button></form>) : ""
        layout(title, %(<header class="top">#{brand(base)}</header><main class="message"><h1>#{h(title)}</h1><p>#{h(message)}</p>#{form}</main>), base)
      end
    end
  end
end
