defmodule Cronwatch.Web.HTML do
  @moduledoc false
  # The dashboard's pages (routes/html.ts), byte for byte, carried over from
  # the Go port's routes_html.go through the Rust port's web/html.rs: set
  # like cronwatch.dev, a printed sheet on grey paper, a serif for what a
  # person reads, a mono for what a machine printed, neutral greys, and
  # colour only for the states CronWatch reports. The page loads nothing but
  # its own app shell, and works without its one script.

  alias Cronwatch.Duration
  alias Cronwatch.Evaluate
  alias Cronwatch.Format
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Web.PWA
  alias Cronwatch.Web.Timeline

  import Cronwatch.Web.Text,
    only: [escape_html: 1, escape_name: 1, escape_value: 1, encode_uri_component: 1, num: 1, to_fixed: 2]

  # The clock face from cronwatch.dev, in the text colour.
  @mark ~s(<svg viewBox="0 0 40 40" aria-hidden="true" focusable="false"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="none" stroke="currentColor" stroke-opacity=".22" stroke-width="1.5"/><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>)

  defp h(s), do: escape_html(s)

  # A page. `base` is where the dashboard is mounted ("" at the root);
  # `refresh`, when above 0, is the page's refresh in seconds.
  defp layout(title, body, base, refresh) do
    b = h(base)
    meta = if refresh > 0, do: ~s(<meta http-equiv="refresh" content="#{refresh}">), else: ""

    IO.iodata_to_binary([
      "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n",
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">\n",
      "<meta name=\"robots\" content=\"noindex,nofollow\">\n",
      "<meta name=\"color-scheme\" content=\"light dark\">\n",
      meta,
      "\n<title>",
      h(title),
      "</title>\n<meta name=\"theme-color\" content=\"",
      PWA.theme_color(),
      "\" media=\"(prefers-color-scheme: light)\">\n<meta name=\"theme-color\" content=\"",
      PWA.theme_color_dark(),
      "\" media=\"(prefers-color-scheme: dark)\">\n",
      "<meta name=\"mobile-web-app-capable\" content=\"yes\">\n",
      "<meta name=\"apple-mobile-web-app-capable\" content=\"yes\">\n",
      "<meta name=\"apple-mobile-web-app-title\" content=\"CronWatch\">\n",
      "<meta name=\"apple-mobile-web-app-status-bar-style\" content=\"default\">\n",
      "<link rel=\"manifest\" href=\"",
      b,
      "/manifest.webmanifest\">\n<link rel=\"icon\" href=\"",
      b,
      "/icons/icon.svg\" type=\"image/svg+xml\">\n<link rel=\"apple-touch-icon\" href=\"",
      b,
      "/icons/apple-touch-icon.png\">\n<script src=\"",
      b,
      "/app.js\" defer></script>\n<style>",
      PWA.style_css(),
      "</style>\n</head>\n<body><div class=\"sheet\">",
      body,
      "</div></body>\n</html>"
    ])
  end

  # The header's mark and name, and a crumb after it when one is given.
  defp brand(base, crumb) do
    home = ~s(<a href="#{h(base)}/">#{@mark}<span>CronWatch</span></a>)

    case crumb do
      nil ->
        ~s(<p class="brand">#{home}</p>)

      c ->
        ~s(<p class="brand">#{home}<span class="slash" aria-hidden="true">/</span><span class="crumb">#{escape_name(c)}</span></p>)
    end
  end

  # The healths in the SDK's order, with their class and label.
  @health_order [
    {"failing", "bad", "failing"},
    {"stuck", "bad", "stuck"},
    {"late", "warn", "late"},
    {"healthy", "ok", "healthy"},
    {"silenced", "muted", "silenced"},
    {"never_ran", "muted", "never ran"}
  ]

  # A health this version does not know, as the SDK's lookup would leave it.
  defp health_label(health) do
    case List.keyfind(@health_order, health, 0) do
      {_, cls, label} -> {cls, label}
      nil -> {"undefined", "undefined"}
    end
  end

  @doc ~S|`c.replace("_", " ")`: the first underscore only.|
  def condition_text(c), do: String.replace(c, "_", " ", global: false)

  # The job's health, with any open condition it does not already say (over
  # budget, under floor, slow) after it.
  defp health_state(job) do
    {cls, label} = health_label(job.health)

    extras =
      for c <- job.open, c not in ["missed", "failed", "stuck"], into: "" do
        ~s(<span class="state warn">#{h(condition_text(c))}</span>)
      end

    ~s(<span class="state #{cls}"><i class="sq #{cls}" aria-hidden="true"></i>#{label}</span>#{extras})
  end

  defp run_state(run) do
    cls =
      case run.status do
        "ok" -> "ok"
        "running" -> "info"
        _ -> "bad"
      end

    ~s(<span class="state #{cls}">#{h(run.status)}</span>)
  end

  # The last twenty runs, oldest first, as bars as tall as they took; grey
  # unless something went wrong.
  @bar 4.0
  @gap 1.5
  @hgt 22.0

  defp sparkline(runs) do
    points = Enum.take(runs, 20)

    if length(points) < 2 do
      ""
    else
      took = fn r -> (r.duration_ms || 0) * 1.0 end
      most = points |> Enum.map(took) |> Enum.reduce(1.0, &max/2)

      bars =
        points
        |> Enum.reverse()
        |> Enum.with_index()
        |> Enum.map_join(fn {r, i} ->
          x = to_fixed(i * (@bar + @gap), 1)

          if r.status == "running" do
            ~s(<rect class="running" x="#{x}" y="15.5" width="3" height="6"/>)
          else
            {floor, cls} = if r.status == "ok", do: {2.0, ""}, else: {6.0, ~s( class="bad")}
            tall = max(floor, took.(r) / most * @hgt)

            ~s(<rect#{cls} x="#{x}" y="#{to_fixed(@hgt - tall, 1)}" width="4" height="#{to_fixed(tall, 1)}" rx=".5"/>)
          end
        end)

      w = to_fixed(length(points) * (@bar + @gap) - @gap, 1)

      ~s(<svg class="spark" width="#{w}" height="22" viewBox="0 0 #{w} 22" aria-hidden="true" focusable="false">#{bars}</svg>)
    end
  end

  # A time as "5m ago", with the full UTC time as its title.
  defp stamp(nil, _now), do: ~s(<span class="muted">never</span>)

  defp stamp(at, now) do
    case JS.iso_time(at) do
      nil -> ~s(<span class="nowrap">#{JS.beyond_dates(at)}</span>)
      iso -> stamp_iso(iso, at, now)
    end
  end

  defp stamp_iso(iso, at, now) do
    title = iso |> String.replace("T", " ", global: false) |> binary_part(0, 19)
    ~s(<time class="nowrap" datetime="#{iso}" title="#{title} UTC">#{h(Duration.relative(at, now))}</time>)
  end

  # The counts by health, the ones needing attention first; a zero is set
  # faint rather than left out, so the row keeps its shape.
  defp health_figures(jobs) do
    figures =
      for {health, cls, label} <- @health_order, into: "" do
        n = Enum.count(jobs, &(&1.health == health))
        shown = if n == 0, do: "zero", else: cls
        ~s(<div class="#{shown}"><dt><i class="sq #{cls}" aria-hidden="true"></i>#{label}</dt><dd>#{num(n)}</dd></div>)
      end

    ~s(<dl class="figures">#{figures}</dl>)
  end

  # A definition's field when it is truthy, as a template's `d.x ? ... : ...`
  # reads it.
  defp truthy_field(d, key) do
    v = Object.get(d, key)
    if Format.truthy?(v), do: v
  end

  # The board's schedule column.
  defp schedule_cell(d) do
    case truthy_field(d, "schedule") do
      nil ->
        ~s(<span class="muted">no schedule</span>)

      sched ->
        tz = truthy_field(d, "timezone")
        escape_value(sched) <> if(tz, do: ~s(<span class="tz">#{escape_value(tz)}</span>), else: "")
    end
  end

  @doc "The board: every job, the last day's timeline, and the table."
  def dashboard_page(jobs, runs_by_job, now, base, checked_at, lanes) do
    total = length(jobs)
    attention = Enum.count(jobs, &(&1.health != "healthy"))

    headline =
      cond do
        total == 0 -> "No jobs yet."
        attention == 0 and total == 1 -> "The one job is healthy."
        attention == 0 -> "All #{num(total)} jobs are healthy."
        true -> "#{num(total)} job#{if total == 1, do: "", else: "s"}, <b>#{num(attention)} needing attention</b>."
      end

    rows = Enum.map_join(jobs, "\n", &board_row(&1, runs_by_job, now, base))

    checked = if checked_at in [nil, 0], do: "", else: ", checked #{h(Duration.relative(checked_at, now))}"

    {health, sections} =
      if jobs == [] do
        {~s|<p class="empty">Declare one with <code>cw.job("name", { schedule: "0 2 * * *" })</code> and run it once, and it shows up here.</p>|,
         ""}
      else
        sp = {now - Timeline.board_behind_ms(), now + Timeline.board_ahead_ms(), now}

        {health_figures(jobs),
         IO.iodata_to_binary([
           "<section class=\"sec\" aria-label=\"Last 24 hours\">\n  <h2>Last 24 hours</h2>\n",
           "  <p class=\"lede\">One lane per job. Faint ticks mark when it was due, bars the runs it recorded, as long as they took. A dashed box is a slot nothing ran in. Times are UTC.</p>\n",
           "  <div class=\"wide\">",
           Timeline.day_timeline(lanes, sp, base, total),
           "</div>\n</section>\n<section class=\"sec\" aria-label=\"Jobs\">\n  <h2>Jobs</h2>\n",
           "  <p class=\"lede\">Every job in the store. Open one for its week, its runs, and their output.</p>\n",
           "  <div class=\"wide\"><table class=\"board\">\n",
           "<thead><tr><th>Job</th><th>Health</th><th class=\"hide-sm\">Schedule</th><th>Last run</th><th class=\"hide-sm\">Next due</th><th class=\"hide-sm\">Recent runs</th></tr></thead>\n",
           "<tbody>",
           rows,
           "</tbody></table></div>\n</section>"
         ])}
      end

    body =
      IO.iodata_to_binary([
        "\n<header class=\"top\">\n  ",
        brand(base, nil),
        "\n  <div class=\"actions\">\n    <span class=\"meta\">",
        h(Timeline.clock_utc(now)),
        " UTC",
        checked,
        "</span>\n    <form class=\"inline\" method=\"post\" action=\"",
        h(base),
        "/check\"><button class=\"primary\" type=\"submit\">Run check now</button></form>\n  </div>\n</header>\n<main>\n",
        "<section class=\"sec\" aria-label=\"Health\">\n  <h2>Health</h2>\n  <div>\n    <p class=\"headline\">",
        headline,
        "</p>\n    ",
        health,
        "\n  </div>\n</section>\n",
        sections,
        "\n</main>\n<footer><span>Refreshes every minute. Times are UTC.</span><a href=\"",
        h(base),
        "/api/jobs\">JSON</a><a class=\"version\" href=\"https://github.com/cronwatchdev/cronwatch/blob/main/CHANGELOG.md\">cronwatch ",
        Cronwatch.version(),
        "</a></footer>"
      ])

    layout("CronWatch", body, base, 60)
  end

  defp board_row(job, runs_by_job, now, base) do
    d = job.definition

    desc =
      case truthy_field(d, "description") do
        nil -> ""
        v -> ~s(<span class="desc">#{escape_value(v)}</span>)
      end

    last =
      case job.last_run do
        nil ->
          ~s(<span class="muted">never</span>)

        r ->
          took = if r.duration_ms, do: ~s(<span class="sub">took #{h(Duration.format(r.duration_ms))}</span>), else: ""
          "#{run_state(r)} #{stamp(r.started_at, now)}#{took}"
      end

    next =
      case job.next_expected_at do
        nil ->
          ~s(<span class="muted">not scheduled</span>)

        n ->
          overdue = if n < now, do: ~s(<span class="state warn">overdue</span> ), else: ""
          ~s(#{overdue}#{stamp(n, now)}<span class="sub">#{h(Timeline.when_utc(n, now))} UTC</span>)
      end

    IO.iodata_to_binary([
      "<tr>\n<td class=\"job\"><a class=\"name\" href=\"",
      h(base),
      "/jobs/",
      encode_uri_component(job.name),
      "\">",
      escape_name(job.name),
      "</a>",
      desc,
      "</td>\n<td class=\"health\">",
      health_state(job),
      "</td>\n<td class=\"nowrap hide-sm\">",
      schedule_cell(d),
      "</td>\n<td class=\"nowrap last\">",
      last,
      "</td>\n<td class=\"nowrap hide-sm\">",
      next,
      "</td>\n<td class=\"hide-sm\">",
      sparkline(Map.get(runs_by_job, job.name, [])),
      "</td>\n</tr>"
    ])
  end

  # A metric's value as the run list shows it: whole numbers as they are,
  # others to four places.
  defp metric_text(v), do: if(JS.integer?(v), do: num(v), else: to_fixed(v, 4))

  defp metric_pairs(%Object{} = metrics), do: Object.to_list(metrics)
  defp metric_pairs(metrics) when is_map(metrics) and not is_struct(metrics), do: Enum.to_list(metrics)
  defp metric_pairs(_), do: []

  defp run_row(run, now) do
    error =
      if run.error in [nil, ""],
        do: "",
        else: ~s(<details class="out error" open><summary>error</summary><pre>#{h(run.error)}</pre></details>)

    output =
      if run.output in [nil, ""] do
        ""
      else
        open = if run.status == "ok", do: "", else: " open"
        ~s(<details class="out"#{open}><summary>output</summary><pre>#{h(run.output)}</pre></details>)
      end

    detail = error <> output

    # A foreign row may hold a metric that is no finite number (null, text); it is left out.
    metrics =
      for {name, value} <- metric_pairs(run.metrics), is_number(value), into: "" do
        ~s(<span><span class="k">#{h(name)}</span> #{h(metric_text(value))}</span>)
      end

    took = if run.duration_ms, do: h(Duration.format(run.duration_ms)), else: ~s(<span class="muted">running</span>)
    metric_cell = if metrics == "", do: "", else: ~s(<span class="metrics">#{metrics}</span>)

    {has_detail, detail_row} =
      if detail == "",
        do: {"", ""},
        else: {~s( class="has-detail"), ~s(<tr class="detail"><td colspan="5">#{detail}</td></tr>)}

    IO.iodata_to_binary([
      "<tr",
      has_detail,
      ">\n<td class=\"nowrap\">",
      run_state(run),
      "</td>\n<td class=\"nowrap\">",
      h(Timeline.when_utc(run.started_at, now)),
      " <span class=\"muted\">UTC</span><span class=\"sub\">",
      stamp(run.started_at, now),
      "</span></td>\n<td class=\"nowrap\">",
      took,
      "</td>\n<td class=\"hide-sm\">",
      metric_cell,
      "</td>\n<td class=\"hide-sm muted\">",
      h(run.trigger),
      "</td>\n</tr>",
      detail_row
    ])
  end

  @doc """
  One job: its state and figures, its last seven days, its runs with their
  output, and its definition. `complete` is false when `runs` does not reach
  back over the whole week (the run list shows the newest fifty).
  """
  def job_page(job, runs, now, base, complete) do
    d = job.definition
    ok_rate = "#{num(JS.round(job.stats.ok_rate * 100))}%"
    listed = Enum.take(runs, 50)
    run_rows = Enum.map_join(listed, "\n", &run_row(&1, now))

    silenced = job.silenced_until != nil and job.silenced_until > now
    path = "#{h(base)}/jobs/#{encode_uri_component(job.name)}"
    why = Timeline.lane_note(job, Timeline.missed_at(job, Timeline.lane_schedule(job), [], now), now)
    why_html = if why == "", do: "", else: ~s(<span class="why">#{h(why)}</span>)

    desc =
      case truthy_field(d, "description") do
        nil -> ""
        v -> ~s(<p class="desc">#{escape_value(v)}</p>)
      end

    silence =
      if silenced do
        ~s|<form class="inline" method="post" action="#{path}/unsilence"><button type="submit">Unsilence (until #{h(Duration.relative(job.silenced_until, now))})</button></form>|
      else
        ~s(<details class="confirm"><summary>Silence</summary><form class="inline" method="post" action="#{path}/silence"><span>for</span> <button type="submit" name="for" value="1h">1 hour</button><button type="submit" name="for" value="4h">4 hours</button><button type="submit" name="for" value="1d">1 day</button><button type="submit" name="for" value="7d">1 week</button></form></details>)
      end

    last_run = if job.last_run, do: h(Duration.relative(job.last_run.started_at, now)), else: "never"

    next_due =
      if job.next_expected_at, do: h(Duration.relative(job.next_expected_at, now)), else: "<small>no schedule</small>"

    percentile = fn p -> if p, do: h(Duration.format(p)), else: "?" end

    runs_section =
      if listed == [] do
        ~s(<p class="lede">No runs yet.</p>)
      else
        newest = if length(listed) == 1, do: "run", else: "#{num(length(listed))} runs"

        IO.iodata_to_binary([
          "<p class=\"lede\">The newest ",
          newest,
          ", with any error and output.</p>\n  <div class=\"wide\"><table class=\"runs\">\n",
          "<thead><tr><th>Status</th><th>Started</th><th>Took</th><th class=\"hide-sm\">Metrics</th><th class=\"hide-sm\">Trigger</th></tr></thead>\n",
          "<tbody>",
          run_rows,
          "</tbody></table></div>"
        ])
      end

    body =
      IO.iodata_to_binary([
        "\n<header class=\"top\">\n  ",
        brand(base, job.name),
        "\n  <div class=\"actions\"><span class=\"meta\">",
        h(Timeline.clock_utc(now)),
        " UTC</span></div>\n</header>\n<main>\n<section class=\"sec intro\" aria-label=\"Job\">\n  <h2>Job</h2>\n  <div>\n",
        "    <h1 class=\"jobname\">",
        escape_name(job.name),
        "</h1>\n    ",
        desc,
        "\n    <p class=\"stateline\">",
        health_state(job),
        why_html,
        "</p>\n    <div class=\"actions\">\n      ",
        silence,
        "\n    </div>\n    <dl class=\"figures\">\n      <div><dt>Last run</dt><dd>",
        last_run,
        "</dd></div>\n      <div><dt>Next due</dt><dd>",
        next_due,
        "</dd></div>\n      <div><dt>Success, last ",
        h(num(job.stats.runs)),
        "</dt><dd>",
        h(ok_rate),
        "</dd></div>\n      <div><dt>p50 / p95</dt><dd>",
        percentile.(job.stats.p50_ms),
        " <small>/ ",
        percentile.(job.stats.p95_ms),
        "</small></dd></div>\n    </dl>\n  </div>\n</section>\n",
        "<section class=\"sec\" aria-label=\"Last 7 days\">\n  <h2>Last 7 days</h2>\n",
        "  <p class=\"lede\">A lane per UTC day, today first. Faint ticks mark when the job was due, bars its runs, as long as they took.</p>\n",
        "  <div class=\"wide\">",
        Timeline.week_timeline(job, runs, complete, now),
        "</div>\n</section>\n<section class=\"sec\" aria-label=\"Runs\">\n  <h2>Runs</h2>\n  ",
        runs_section,
        "\n</section>\n<section class=\"sec\" aria-label=\"Definition\">\n  <h2>Definition</h2>\n  <dl class=\"def\">\n",
        "  <dt>Schedule</dt><dd>",
        definition_schedule(d),
        "</dd>\n  <dt>Grace</dt><dd>",
        or_default(d, "grace", "10m"),
        "</dd>\n  <dt>Timeout</dt><dd>",
        or_default(d, "timeout", "1h"),
        "</dd>\n  ",
        definition_row(d, "maxDuration", "Max duration"),
        "\n  ",
        limits_row(d, "budget", "Budget", "≤"),
        "\n  ",
        limits_row(d, "floor", "Floor", "≥"),
        "\n  ",
        definition_row(d, "expect", "Expect"),
        "\n  ",
        alert_after_row(d),
        "\n  ",
        tags_row(d),
        "\n  ",
        open_row(job),
        "\n  ",
        failures_row(job),
        "\n  </dl>\n</section>\n<section class=\"sec delete\" aria-label=\"Delete\">\n  <h2>Delete</h2>\n  <div>\n  <p class=\"lede\">Removes this job and all its runs from the store, which cannot be undone. A job still in your code comes back on its next run, with no history.</p>\n  <details class=\"confirm\"><summary>Delete history</summary><form class=\"inline\" method=\"post\" action=\"",
        path,
        "/forget\"><span>Delete this job and all its runs?</span> <button class=\"danger\" type=\"submit\">Delete</button><a class=\"button\" href=\"",
        path,
        "\">Cancel</a></form></details>\n  </div>\n</section>\n</main>\n<footer><span>Refreshes every minute. Times are UTC.</span><a href=\"",
        h(base),
        "/api/jobs/",
        encode_uri_component(job.name),
        "\">JSON</a><a class=\"version\" href=\"https://github.com/cronwatchdev/cronwatch/blob/main/CHANGELOG.md\">cronwatch ",
        Cronwatch.version(),
        "</a></footer>"
      ])

    layout("#{job.name}: CronWatch", body, base, 60)
  end

  defp definition_schedule(d) do
    case truthy_field(d, "schedule") do
      nil ->
        ~s(<span class="muted">none</span>)

      sched ->
        tz = truthy_field(d, "timezone")
        escape_value(sched) <> if(tz, do: ~s( <span class="muted">#{escape_value(tz)}</span>), else: "")
    end
  end

  # h(d[key] ?? fallback).
  defp or_default(d, key, fallback) do
    case Object.get(d, key) do
      nil -> h(fallback)
      v -> escape_value(v)
    end
  end

  defp definition_row(d, key, label) do
    case truthy_field(d, key) do
      nil -> ""
      v -> "<dt>#{label}</dt><dd>#{escape_value(v)}</dd>"
    end
  end

  defp limits_row(d, key, label, sign) do
    case truthy_field(d, key) do
      nil ->
        ""

      v ->
        parts =
          case v do
            %Object{} = o -> Enum.map(Object.to_list(o), fn {k, limit} -> "#{k} #{sign} #{Format.js_text(limit)}" end)
            _ -> []
          end

        "<dt>#{label}</dt><dd>#{h(Enum.join(parts, ", "))}</dd>"
    end
  end

  defp alert_after_row(d) do
    case truthy_field(d, "failuresBeforeAlert") do
      nil ->
        ""

      v ->
        if Timeline.greater?(Evaluate.js_number(v), 1),
          do: "<dt>Alert after</dt><dd>#{escape_value(v)} consecutive failures</dd>",
          else: ""
    end
  end

  defp tags_row(d) do
    tags =
      case Object.get(d, "tags") do
        list when is_list(list) -> Enum.map(list, &escape_value/1)
        # A string's length and map are not an array's, so the SDK's page
        # would fail on one; show it as it is.
        t when is_binary(t) and t != "" -> [h(t)]
        _ -> []
      end

    if tags == [], do: "", else: "<dt>Tags</dt><dd>#{Enum.join(tags, ", ")}</dd>"
  end

  defp open_row(%{open: []}), do: ""

  defp open_row(job) do
    spans =
      for c <- job.open, into: "" do
        cls = if c in ["failed", "stuck"], do: "bad", else: "warn"
        ~s(<span class="state #{cls}">#{h(condition_text(c))}</span>)
      end

    "<dt>Open</dt><dd>#{spans}</dd>"
  end

  defp failures_row(job) do
    if job.consecutive_failures > 0,
      do: "<dt>Failures in a row</dt><dd>#{num(job.consecutive_failures)}</dd>",
      else: ""
  end

  @doc """
  A page with one message. With `sign_in`, a form under it takes the token
  and sends it as `?token=`, which the routes move into the cookie: the way
  in where there is no address bar to open a link with, such as an app on an
  iPhone's home screen.
  """
  def message_page(title, message, base, sign_in \\ false) do
    form =
      if sign_in,
        do:
          ~s(<form class="signin" method="post" action="#{h(base)}/signin"><label for="token">Token</label><input id="token" name="token" type="password" autocomplete="current-password" autocapitalize="off" spellcheck="false" required><button class="primary" type="submit">Sign in</button></form>),
        else: ""

    body =
      ~s(<header class="top">#{brand(base, nil)}</header><main class="message"><h1>#{h(title)}</h1><p>#{h(message)}</p>#{form}</main>)

    layout(title, body, base, 0)
  end
end
