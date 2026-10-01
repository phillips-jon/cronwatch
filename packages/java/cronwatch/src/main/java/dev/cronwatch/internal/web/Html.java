package dev.cronwatch.internal.web;

import static dev.cronwatch.internal.web.Text.count;
import static dev.cronwatch.internal.web.Text.encodeUriComponent;
import static dev.cronwatch.internal.web.Text.escapeHtml;
import static dev.cronwatch.internal.web.Text.escapeName;
import static dev.cronwatch.internal.web.Text.escapeValue;
import static dev.cronwatch.internal.web.Text.num;
import static dev.cronwatch.internal.web.Text.toFixed;

import dev.cronwatch.Condition;
import dev.cronwatch.Definition;
import dev.cronwatch.JobHealth;
import dev.cronwatch.JobSummary;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.internal.duration.Durations;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.evaluate.Format;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.web.Timeline.LaneInput;
import dev.cronwatch.internal.web.Timeline.Span;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * The dashboard's pages ({@code routes/html.ts}), byte for byte, carried over from the Rust port's
 * {@code web/html.rs}: set like cronwatch.dev, a printed sheet on grey paper, a serif for what a
 * person reads, a mono for what a machine printed, neutral greys, and colour only for the states
 * CronWatch reports. The page loads nothing but its own app shell, and works without its one
 * script.
 */
public final class Html {
  private Html() {}

  /** The clock face from cronwatch.dev, in the text colour. */
  private static final String MARK =
      "<svg viewBox=\"0 0 40 40\" aria-hidden=\"true\" focusable=\"false\"><rect x=\"1\" y=\"1\""
          + " width=\"38\" height=\"38\" rx=\"9.5\" fill=\"none\" stroke=\"currentColor\""
          + " stroke-opacity=\".22\" stroke-width=\"1.5\"/><circle cx=\"20\" cy=\"20\" r=\"10.5\""
          + " fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"/><path d=\"M20 12.5V20h6\""
          + " fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\""
          + " stroke-linejoin=\"round\"/></svg>";

  /**
   * A page. {@code base} is where the dashboard is mounted ({@code ""} at the root); {@code
   * refresh}, when above 0, is the page's refresh in seconds.
   */
  private static String layout(String title, String body, String base, int refresh) {
    String b = escapeHtml(base);
    String meta = refresh > 0 ? "<meta http-equiv=\"refresh\" content=\"" + refresh + "\">" : "";
    return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">\n"
        + "<meta name=\"robots\" content=\"noindex,nofollow\">\n"
        + "<meta name=\"color-scheme\" content=\"light dark\">\n"
        + meta
        + "\n<title>"
        + escapeHtml(title)
        + "</title>\n<meta name=\"theme-color\" content=\""
        + Pwa.THEME_COLOR
        + "\" media=\"(prefers-color-scheme: light)\">\n<meta name=\"theme-color\" content=\""
        + Pwa.THEME_COLOR_DARK
        + "\" media=\"(prefers-color-scheme: dark)\">\n"
        + "<meta name=\"mobile-web-app-capable\" content=\"yes\">\n"
        + "<meta name=\"apple-mobile-web-app-capable\" content=\"yes\">\n"
        + "<meta name=\"apple-mobile-web-app-title\" content=\"CronWatch\">\n"
        + "<meta name=\"apple-mobile-web-app-status-bar-style\" content=\"default\">\n"
        + "<link rel=\"manifest\" href=\""
        + b
        + "/manifest.webmanifest\">\n<link rel=\"icon\" href=\""
        + b
        + "/icons/icon.svg\" type=\"image/svg+xml\">\n<link rel=\"apple-touch-icon\" href=\""
        + b
        + "/icons/apple-touch-icon.png\">\n<script src=\""
        + b
        + "/app.js\" defer></script>\n<style>"
        + Pwa.styleCss()
        + "</style>\n</head>\n<body><div class=\"sheet\">"
        + body
        + "</div></body>\n</html>";
  }

  /** The header's mark and name, and a crumb after it when one is given. */
  private static String brand(String base, @Nullable String crumb) {
    String home = "<a href=\"" + escapeHtml(base) + "/\">" + MARK + "<span>CronWatch</span></a>";
    if (crumb == null) {
      return "<p class=\"brand\">" + home + "</p>";
    }
    return "<p class=\"brand\">"
        + home
        + "<span class=\"slash\" aria-hidden=\"true\">/</span><span class=\"crumb\">"
        + escapeName(crumb)
        + "</span></p>";
  }

  /** The healths in the SDK's order, with their class and label. */
  private static final List<Object[]> HEALTH_ORDER =
      List.of(
          new Object[] {JobHealth.FAILING, "bad", "failing"},
          new Object[] {JobHealth.STUCK, "bad", "stuck"},
          new Object[] {JobHealth.LATE, "warn", "late"},
          new Object[] {JobHealth.HEALTHY, "ok", "healthy"},
          new Object[] {JobHealth.SILENCED, "muted", "silenced"},
          new Object[] {JobHealth.NEVER_RAN, "muted", "never ran"});

  private static String[] healthLabel(JobHealth health) {
    for (Object[] e : HEALTH_ORDER) {
      if (e[0].equals(health)) {
        return new String[] {(String) e[1], (String) e[2]};
      }
    }
    // A health this version does not know, as the SDK's lookup would leave it.
    return new String[] {"undefined", "undefined"};
  }

  /** {@code c.replace("_", " ")}: the first underscore only. */
  static String conditionText(Condition c) {
    return Text.replaceFirst(c.value(), "_", " ");
  }

  /** The job's health, with any open condition it does not already say (over budget, slow). */
  private static String healthState(JobSummary job) {
    String[] hl = healthLabel(job.health());
    StringBuilder extras = new StringBuilder();
    for (Condition c : job.open()) {
      if (!c.equals(Condition.MISSED)
          && !c.equals(Condition.FAILED)
          && !c.equals(Condition.STUCK)) {
        extras
            .append("<span class=\"state warn\">")
            .append(escapeHtml(conditionText(c)))
            .append("</span>");
      }
    }
    return "<span class=\"state "
        + hl[0]
        + "\"><i class=\"sq "
        + hl[0]
        + "\" aria-hidden=\"true\"></i>"
        + hl[1]
        + "</span>"
        + extras;
  }

  private static String runState(Run run) {
    String cls =
        run.status().equals(RunStatus.OK)
            ? "ok"
            : run.status().equals(RunStatus.RUNNING) ? "info" : "bad";
    return "<span class=\"state " + cls + "\">" + escapeHtml(run.status().value()) + "</span>";
  }

  private static double took(Run r) {
    return r.durationMs() == null ? 0 : (double) r.durationMs();
  }

  /**
   * The last twenty runs, oldest first, as bars as tall as they took; grey unless something went
   * wrong.
   */
  private static String sparkline(List<Run> runs) {
    List<Run> points = runs.subList(0, Math.min(runs.size(), 20));
    if (points.size() < 2) {
      return "";
    }
    final double bar = 4;
    final double gap = 1.5;
    final double hgt = 22;
    double most = 1;
    for (Run r : points) {
      most = Math.max(most, took(r));
    }
    StringBuilder bars = new StringBuilder();
    for (int i = 0; i < points.size(); i++) {
      Run r = points.get(points.size() - 1 - i);
      String x = toFixed(i * (bar + gap), 1);
      if (r.status().equals(RunStatus.RUNNING)) {
        bars.append("<rect class=\"running\" x=\"")
            .append(x)
            .append("\" y=\"15.5\" width=\"3\" height=\"6\"/>");
        continue;
      }
      boolean ok = r.status().equals(RunStatus.OK);
      double floor = ok ? 2 : 6;
      String cls = ok ? "" : " class=\"bad\"";
      double tall = Math.max(floor, (took(r) / most) * hgt);
      bars.append("<rect")
          .append(cls)
          .append(" x=\"")
          .append(x)
          .append("\" y=\"")
          .append(toFixed(hgt - tall, 1))
          .append("\" width=\"4\" height=\"")
          .append(toFixed(tall, 1))
          .append("\" rx=\".5\"/>");
    }
    String w = toFixed(points.size() * (bar + gap) - gap, 1);
    return "<svg class=\"spark\" width=\""
        + w
        + "\" height=\"22\" viewBox=\"0 0 "
        + w
        + " 22\" aria-hidden=\"true\" focusable=\"false\">"
        + bars
        + "</svg>";
  }

  /** A time as "5m ago", with the full UTC time as its title. */
  private static String stamp(@Nullable Long at, long now) {
    if (at == null) {
      return "<span class=\"muted\">never</span>";
    }
    String iso = Js.isoTime(at);
    if (iso == null) {
      return "<span class=\"nowrap\">" + Js.beyondDates(at) + "</span>";
    }
    String title = Text.replaceFirst(iso, "T", " ");
    return "<time class=\"nowrap\" datetime=\""
        + iso
        + "\" title=\""
        + title.substring(0, 19)
        + " UTC\">"
        + escapeHtml(Durations.formatRelative(at, now))
        + "</time>";
  }

  /**
   * The counts by health, the ones needing attention first; a zero is set faint rather than left
   * out, so the row keeps its shape.
   */
  private static String healthFigures(List<JobSummary> jobs) {
    StringBuilder b = new StringBuilder("<dl class=\"figures\">");
    for (Object[] e : HEALTH_ORDER) {
      long n = 0;
      for (JobSummary j : jobs) {
        if (j.health().equals(e[0])) {
          n++;
        }
      }
      String cls = (String) e[1];
      String shown = n == 0 ? "zero" : cls;
      b.append("<div class=\"")
          .append(shown)
          .append("\"><dt><i class=\"sq ")
          .append(cls)
          .append("\" aria-hidden=\"true\"></i>")
          .append((String) e[2])
          .append("</dt><dd>")
          .append(count(n))
          .append("</dd></div>");
    }
    return b.append("</dl>").toString();
  }

  /** A definition's field when it is truthy, as a template's {@code d.x ? ... : ...} reads it. */
  private static @Nullable Object truthyField(Definition d, String key) {
    Object v = d.get(key);
    return Evaluate.truthy(v) ? v : null;
  }

  /** The board's schedule column. */
  private static String scheduleCell(Definition d) {
    Object sched = truthyField(d, "schedule");
    if (sched == null) {
      return "<span class=\"muted\">no schedule</span>";
    }
    String out = escapeValue(sched);
    Object tz = truthyField(d, "timezone");
    if (tz != null) {
      out += "<span class=\"tz\">" + escapeValue(tz) + "</span>";
    }
    return out;
  }

  /** The board: every job's health, its last day and its recent runs. */
  public static String dashboardPage(
      List<JobSummary> jobs,
      Map<String, List<Run>> runsByJob,
      long now,
      String base,
      @Nullable Long checkedAt,
      List<LaneInput> lanes) {
    long attention = 0;
    for (JobSummary j : jobs) {
      if (!j.health().equals(JobHealth.HEALTHY)) {
        attention++;
      }
    }
    String headline;
    if (jobs.isEmpty()) {
      headline = "No jobs yet.";
    } else if (attention == 0 && jobs.size() == 1) {
      headline = "The one job is healthy.";
    } else if (attention == 0) {
      headline = "All " + count(jobs.size()) + " jobs are healthy.";
    } else {
      String s = jobs.size() == 1 ? "" : "s";
      headline =
          count(jobs.size()) + " job" + s + ", <b>" + count(attention) + " needing attention</b>.";
    }

    List<String> rows = new ArrayList<>();
    for (JobSummary job : jobs) {
      Definition d = job.definition();
      Object descValue = truthyField(d, "description");
      String desc =
          descValue == null ? "" : "<span class=\"desc\">" + escapeValue(descValue) + "</span>";
      String last;
      Run r = job.lastRun();
      if (r == null) {
        last = "<span class=\"muted\">never</span>";
      } else {
        last = runState(r) + " " + stamp(r.startedAt(), now);
        if (r.durationMs() != null) {
          last +=
              "<span class=\"sub\">took "
                  + escapeHtml(Durations.format((double) r.durationMs()))
                  + "</span>";
        }
      }
      String next;
      Long n = job.nextExpectedAt();
      if (n == null) {
        next = "<span class=\"muted\">not scheduled</span>";
      } else {
        String overdue = n < now ? "<span class=\"state warn\">overdue</span> " : "";
        next =
            overdue
                + stamp(n, now)
                + "<span class=\"sub\">"
                + escapeHtml(Timeline.when(n, now))
                + " UTC</span>";
      }
      rows.add(
          "<tr>\n<td class=\"job\"><a class=\"name\" href=\""
              + escapeHtml(base)
              + "/jobs/"
              + encodeUriComponent(job.name())
              + "\">"
              + escapeName(job.name())
              + "</a>"
              + desc
              + "</td>\n<td class=\"health\">"
              + healthState(job)
              + "</td>\n<td class=\"nowrap hide-sm\">"
              + scheduleCell(d)
              + "</td>\n<td class=\"nowrap last\">"
              + last
              + "</td>\n<td class=\"nowrap hide-sm\">"
              + next
              + "</td>\n<td class=\"hide-sm\">"
              + sparkline(runsByJob.getOrDefault(job.name(), List.of()))
              + "</td>\n</tr>");
    }

    String checked =
        checkedAt != null && checkedAt != 0
            ? ", checked " + escapeHtml(Durations.formatRelative(checkedAt, now))
            : "";
    String health =
        "<p class=\"empty\">Declare one with <code>cw.job(\"name\", { schedule: \"0 2 * * *\""
            + " })</code> and run it once, and it shows up here.</p>";
    String sections = "";
    if (!jobs.isEmpty()) {
      health = healthFigures(jobs);
      Span sp = new Span(now - Timeline.BOARD_BEHIND_MS, now + Timeline.BOARD_AHEAD_MS, now);
      sections =
          "<section class=\"sec\" aria-label=\"Last 24 hours\">\n  <h2>Last 24 hours</h2>\n"
              + "  <p class=\"lede\">One lane per job. Faint ticks mark when it was due, bars the"
              + " runs it recorded, as long as they took. A dashed box is a slot nothing ran in."
              + " Times are UTC.</p>\n"
              + "  <div class=\"wide\">"
              + Timeline.dayTimeline(lanes, sp, base, jobs.size())
              + "</div>\n</section>\n<section class=\"sec\" aria-label=\"Jobs\">\n  <h2>Jobs</h2>\n"
              + "  <p class=\"lede\">Every job in the store. Open one for its week, its runs and"
              + " their output.</p>\n"
              + "  <div class=\"wide\"><table class=\"board\">\n"
              + "<thead><tr><th>Job</th><th>Health</th><th class=\"hide-sm\">Schedule</th><th>Last"
              + " run</th><th class=\"hide-sm\">Next due</th><th class=\"hide-sm\">Recent"
              + " runs</th></tr></thead>\n"
              + "<tbody>"
              + String.join("\n", rows)
              + "</tbody></table></div>\n</section>";
    }
    String body =
        "\n<header class=\"top\">\n  "
            + brand(base, null)
            + "\n  <div class=\"actions\">\n    <span class=\"meta\">"
            + escapeHtml(Timeline.clock(now))
            + " UTC"
            + checked
            + "</span>\n    <form class=\"inline\" method=\"post\" action=\""
            + escapeHtml(base)
            + "/check\"><button class=\"primary\" type=\"submit\">Run check now</button></form>\n"
            + "  </div>\n</header>\n<main>\n"
            + "<section class=\"sec\" aria-label=\"Health\">\n  <h2>Health</h2>\n  <div>\n"
            + "    <p class=\"headline\">"
            + headline
            + "</p>\n    "
            + health
            + "\n  </div>\n</section>\n"
            + sections
            + "\n</main>\n<footer><span>Refreshes every minute. Times are UTC.</span><a href=\""
            + escapeHtml(base)
            + "/api/jobs\">JSON</a></footer>";
    return layout("CronWatch", body, base, 60);
  }

  /**
   * A metric's value as the run list shows it: whole numbers as they are, others to four places.
   */
  private static String metricText(double v) {
    return Js.isInteger(v) ? num(v) : toFixed(v, 4);
  }

  /**
   * One job: its state and figures, its last seven days, its runs with their output, and its
   * definition. {@code complete} is false when {@code runs} does not reach back over the whole week
   * (the run list shows the newest fifty).
   */
  public static String jobPage(
      JobSummary job, List<Run> runs, long now, String base, boolean complete) {
    Definition d = job.definition();
    String okRate = num(Js.round(job.stats().okRate() * 100)) + "%";
    List<Run> listed = runs.subList(0, Math.min(runs.size(), 50));
    List<String> runRows = new ArrayList<>();
    for (Run run : listed) {
      StringBuilder detail = new StringBuilder();
      String error = run.error();
      if (error != null && !error.isEmpty()) {
        detail
            .append("<details class=\"out error\" open><summary>error</summary><pre>")
            .append(escapeHtml(error))
            .append("</pre></details>");
      }
      String output = run.output();
      if (output != null && !output.isEmpty()) {
        String open = run.status().equals(RunStatus.OK) ? "" : " open";
        detail
            .append("<details class=\"out\"")
            .append(open)
            .append("><summary>output</summary><pre>")
            .append(escapeHtml(output))
            .append("</pre></details>");
      }
      StringBuilder metrics = new StringBuilder();
      for (Map.Entry<String, @Nullable Object> m : run.metrics().toValue().entries()) {
        // A store may hand back a metric that is no finite number (a foreign row); it is left out.
        if (!(m.getValue() instanceof Number x) || !Double.isFinite(x.doubleValue())) {
          continue;
        }
        double value = x.doubleValue();
        metrics
            .append("<span><span class=\"k\">")
            .append(escapeHtml(m.getKey()))
            .append("</span> ")
            .append(escapeHtml(metricText(value)))
            .append("</span>");
      }
      String tookCell =
          run.durationMs() == null
              ? "<span class=\"muted\">running</span>"
              : escapeHtml(Durations.format((double) run.durationMs()));
      String metricCell = metrics.isEmpty() ? "" : "<span class=\"metrics\">" + metrics + "</span>";
      String hasDetail = detail.isEmpty() ? "" : " class=\"has-detail\"";
      String detailRow =
          detail.isEmpty() ? "" : "<tr class=\"detail\"><td colspan=\"5\">" + detail + "</td></tr>";
      runRows.add(
          "<tr"
              + hasDetail
              + ">\n<td class=\"nowrap\">"
              + runState(run)
              + "</td>\n<td class=\"nowrap\">"
              + escapeHtml(Timeline.when(run.startedAt(), now))
              + " <span class=\"muted\">UTC</span><span class=\"sub\">"
              + stamp(run.startedAt(), now)
              + "</span></td>\n<td class=\"nowrap\">"
              + tookCell
              + "</td>\n<td class=\"hide-sm\">"
              + metricCell
              + "</td>\n<td class=\"hide-sm muted\">"
              + escapeHtml(run.trigger())
              + "</td>\n</tr>"
              + detailRow);
    }

    Long silencedUntil = job.silencedUntil();
    boolean silenced = silencedUntil != null && silencedUntil > now;
    String path = escapeHtml(base) + "/jobs/" + encodeUriComponent(job.name());
    String why =
        Timeline.laneNote(
            job, Timeline.missedAt(job, Timeline.laneSchedule(job), List.of(), now), now);
    String whyHtml = why.isEmpty() ? "" : "<span class=\"why\">" + escapeHtml(why) + "</span>";
    Object descValue = truthyField(d, "description");
    String desc = descValue == null ? "" : "<p class=\"desc\">" + escapeValue(descValue) + "</p>";
    String silence;
    if (silenced) {
      silence =
          "<form class=\"inline\" method=\"post\" action=\""
              + path
              + "/unsilence\"><button type=\"submit\">Unsilence (until "
              + escapeHtml(Durations.formatRelative(silencedUntil, now))
              + ")</button></form>";
    } else {
      silence =
          "<form class=\"inline\" method=\"post\" action=\""
              + path
              + "/silence\"><select name=\"for\" aria-label=\"Silence for\"><option"
              + " value=\"1h\">1 hour</option><option value=\"4h\">4 hours</option><option"
              + " value=\"1d\">1 day</option><option value=\"7d\">1 week</option></select><button"
              + " type=\"submit\">Silence</button></form>";
    }
    Run lastRunValue = job.lastRun();
    String lastRun =
        lastRunValue == null
            ? "never"
            : escapeHtml(Durations.formatRelative(lastRunValue.startedAt(), now));
    Long nextExpected = job.nextExpectedAt();
    String nextDue =
        nextExpected == null
            ? "<small>no schedule</small>"
            : escapeHtml(Durations.formatRelative(nextExpected, now));
    String runsSection;
    if (listed.isEmpty()) {
      runsSection = "<p class=\"lede\">No runs yet.</p>";
    } else {
      String newest = listed.size() == 1 ? "run" : count(listed.size()) + " runs";
      runsSection =
          "<p class=\"lede\">The newest "
              + newest
              + ", with any error and output.</p>\n  <div class=\"wide\"><table class=\"runs\">\n"
              + "<thead><tr><th>Status</th><th>Started</th><th>Took</th><th"
              + " class=\"hide-sm\">Metrics</th><th class=\"hide-sm\">Trigger</th></tr></thead>\n"
              + "<tbody>"
              + String.join("\n", runRows)
              + "</tbody></table></div>";
    }

    String body =
        "\n<header class=\"top\">\n  "
            + brand(base, job.name())
            + "\n  <div class=\"actions\"><span class=\"meta\">"
            + escapeHtml(Timeline.clock(now))
            + " UTC</span></div>\n</header>\n<main>\n<section class=\"sec intro\""
            + " aria-label=\"Job\">\n  <h2>Job</h2>\n  <div>\n"
            + "    <h1 class=\"jobname\">"
            + escapeName(job.name())
            + "</h1>\n    "
            + desc
            + "\n    <p class=\"stateline\">"
            + healthState(job)
            + whyHtml
            + "</p>\n    <div class=\"actions\">\n      "
            + silence
            + "\n      <details class=\"confirm\"><summary>Forget</summary><form class=\"inline\""
            + " method=\"post\" action=\""
            + path
            + "/forget\"><span>Remove this job and its runs from the store?</span> <button"
            + " type=\"submit\">Forget</button></form></details>\n"
            + "    </div>\n    <dl class=\"figures\">\n      <div><dt>Last run</dt><dd>"
            + lastRun
            + "</dd></div>\n      <div><dt>Next due</dt><dd>"
            + nextDue
            + "</dd></div>\n      <div><dt>Success, last "
            + escapeHtml(num((double) job.stats().runs()))
            + "</dt><dd>"
            + escapeHtml(okRate)
            + "</dd></div>\n      <div><dt>p50 / p95</dt><dd>"
            + percentile(job.stats().p50Ms())
            + " <small>/ "
            + percentile(job.stats().p95Ms())
            + "</small></dd></div>\n    </dl>\n  </div>\n</section>\n"
            + "<section class=\"sec\" aria-label=\"Last 7 days\">\n  <h2>Last 7 days</h2>\n"
            + "  <p class=\"lede\">A lane per UTC day, today first. Faint ticks mark when the job"
            + " was due, bars its runs, as long as they took.</p>\n"
            + "  <div class=\"wide\">"
            + Timeline.weekTimeline(job, runs, complete, now)
            + "</div>\n</section>\n<section class=\"sec\" aria-label=\"Runs\">\n  <h2>Runs</h2>\n  "
            + runsSection
            + "\n</section>\n<section class=\"sec\" aria-label=\"Definition\">\n"
            + "  <h2>Definition</h2>\n  <dl class=\"def\">\n"
            + "  <dt>Schedule</dt><dd>"
            + definitionSchedule(d)
            + "</dd>\n  <dt>Grace</dt><dd>"
            + orDefault(d, "grace", "10m")
            + "</dd>\n  <dt>Timeout</dt><dd>"
            + orDefault(d, "timeout", "1h")
            + "</dd>\n  "
            + definitionRow(d, "maxDuration", "Max duration")
            + "\n  "
            + budgetRow(d)
            + "\n  "
            + definitionRow(d, "expect", "Expect")
            + "\n  "
            + alertAfterRow(d)
            + "\n  "
            + tagsRow(d)
            + "\n  "
            + openRow(job)
            + "\n  "
            + failuresRow(job)
            + "\n  </dl>\n</section>\n</main>\n<footer><span>Refreshes every minute. Times are"
            + " UTC.</span><a href=\""
            + escapeHtml(base)
            + "/api/jobs/"
            + encodeUriComponent(job.name())
            + "\">JSON</a></footer>";
    return layout(job.name() + ": CronWatch", body, base, 60);
  }

  private static String percentile(@Nullable Long p) {
    return p == null ? "?" : escapeHtml(Durations.format((double) p));
  }

  private static String definitionSchedule(Definition d) {
    Object sched = truthyField(d, "schedule");
    if (sched == null) {
      return "<span class=\"muted\">none</span>";
    }
    String out = escapeValue(sched);
    Object tz = truthyField(d, "timezone");
    if (tz != null) {
      out += " <span class=\"muted\">" + escapeValue(tz) + "</span>";
    }
    return out;
  }

  /** {@code h(d[key] ?? fallback)}. */
  private static String orDefault(Definition d, String key, String fallback) {
    Object v = d.get(key);
    return v != null ? escapeValue(v) : escapeHtml(fallback);
  }

  private static String definitionRow(Definition d, String key, String label) {
    Object v = truthyField(d, key);
    return v == null ? "" : "<dt>" + label + "</dt><dd>" + escapeValue(v) + "</dd>";
  }

  private static String budgetRow(Definition d) {
    Object v = truthyField(d, "budget");
    if (v == null) {
      return "";
    }
    List<String> parts = new ArrayList<>();
    if (v instanceof JsObject o) {
      for (Map.Entry<String, @Nullable Object> e : o.entries()) {
        parts.add(e.getKey() + " ≤ " + Format.jsText(e.getValue()));
      }
    }
    return "<dt>Budget</dt><dd>" + escapeHtml(String.join(", ", parts)) + "</dd>";
  }

  private static String alertAfterRow(Definition d) {
    Object v = truthyField(d, "failuresBeforeAlert");
    if (v != null && Evaluate.jsNumber(v) > 1) {
      return "<dt>Alert after</dt><dd>" + escapeValue(v) + " consecutive failures</dd>";
    }
    return "";
  }

  private static String tagsRow(Definition d) {
    List<String> tags = new ArrayList<>();
    Object v = d.get("tags");
    if (v instanceof List<?> list) {
      for (Object e : list) {
        tags.add(escapeValue(e));
      }
    } else if (v instanceof String t && !t.isEmpty()) {
      // A string's length and map are not an array's, so the SDK's page would fail on one; show
      // it as it is.
      tags.add(escapeHtml(t));
    }
    if (tags.isEmpty()) {
      return "";
    }
    return "<dt>Tags</dt><dd>" + String.join(", ", tags) + "</dd>";
  }

  private static String openRow(JobSummary job) {
    if (job.open().isEmpty()) {
      return "";
    }
    StringBuilder spans = new StringBuilder();
    for (Condition c : job.open()) {
      String cls = c.equals(Condition.FAILED) || c.equals(Condition.STUCK) ? "bad" : "warn";
      spans
          .append("<span class=\"state ")
          .append(cls)
          .append("\">")
          .append(escapeHtml(conditionText(c)))
          .append("</span>");
    }
    return "<dt>Open</dt><dd>" + spans + "</dd>";
  }

  private static String failuresRow(JobSummary job) {
    if (job.consecutiveFailures() <= 0) {
      return "";
    }
    return "<dt>Failures in a row</dt><dd>" + num((double) job.consecutiveFailures()) + "</dd>";
  }

  /**
   * A page with one message. With {@code signIn}, a form under it posts the token to {@code
   * <base>/signin} in the body, keeping it out of the URL and access logs, and the routes set the
   * cookie: the way in where there is no address bar to open a link with, such as an app on an
   * iPhone's home screen.
   */
  public static String messagePage(String title, String message, String base, boolean signIn) {
    String form =
        signIn
            ? "<form class=\"signin\" method=\"post\" action=\""
                + escapeHtml(base)
                + "/signin\"><label for=\"token\">Token</label><input id=\"token\" name=\"token\""
                + " type=\"password\" autocomplete=\"current-password\" autocapitalize=\"off\""
                + " spellcheck=\"false\" required><button class=\"primary\" type=\"submit\">Sign"
                + " in</button></form>"
            : "";
    String body =
        "<header class=\"top\">"
            + brand(base, null)
            + "</header><main class=\"message\"><h1>"
            + escapeHtml(title)
            + "</h1><p>"
            + escapeHtml(message)
            + "</p>"
            + form
            + "</main>";
    return layout(title, body, base, 0);
  }
}
